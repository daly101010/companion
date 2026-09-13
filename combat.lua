-- companion/combat.lua
-- Combat capture + encounter engine. Registers mq.event patterns (the same
-- family sidekick-next/utils/damage_events.lua proved out), normalizes each
-- line into a damage/miss/kill event, segments the stream into encounters by
-- an inactivity gap, and rolls up per-source / per-ability stats plus a raw
-- event log for the timeline.
--
-- Pure-log capture has a known ceiling (no raw-vs-mitigated damage, and
-- third-person crit attribution is best-effort) — this is the robust,
-- patch-proof tier. Overheal IS captured from the "for N (M)" heal format,
-- including full-overheal "for 0 (M)" ticks. A future C++ color-channel source
-- could feed record() with higher fidelity without changing anything downstream.

local mq = require('mq')

local M  = {}

-- ── config / wiring ───────────────────────────────────────────────────
M.timeoutSec = 12   -- gap that closes an encounter
M.maxEvents  = 4000 -- per-encounter raw event cap (timeline + persistence)

local cb = {
    onFinalize   = nil, -- fn(fight)  called when an encounter closes
    onMobDps     = nil, -- fn(rows)   per-attacker incoming-dps rows when an encounter closes (see M.mobDpsRows)
    getPet       = function() return nil end,
    getZone      = function() return '' end,
    isRaidTarget = function(_) return false end,
    playerName   = function() return 'You' end,
    getMaster    = function(_) return nil end, -- fn(name) -> owner name for a bare pet name
    spellDuration = function(_) return 0 end,  -- fn(spell) -> buff duration in TICKS (6s each)
    getWeapons   = function() return nil, nil end, -- fn() -> mainhandName, offhandName
    freezeBlackBox = nil, -- fn(nowMs) -> samples[] (blackbox:freeze); nil when no recorder is wired
}

-- Cache of spell name -> duration in ticks (static spell data; query once).
local hotDurCache = {}
local function hotTicks(spell)
    local d = hotDurCache[spell]
    if d == nil then d = cb.spellDuration(spell) or 0; hotDurCache[spell] = d end
    return d
end

local active     = nil -- current encounter or nil
local last       = nil -- last finalized encounter (kept for display)
local registered = {}

local function now() return mq.gettime() / 1000 end

-- ── melee verb tables ─────────────────────────────────────────────────
-- Every verb is tracked as its own ability ("Slash", "Crush", "Kick", ...) so
-- weapon-skill and special-attack damage are separated, not lumped into one
-- "Melee" bucket. All share the same line shape ("You <verb> <tgt> for N ...").
local MELEE_VERBS = {
    'hit', 'slash', 'crush', 'pierce', 'punch', 'bite', 'claw', 'gore',
    'maul', 'slam', 'smash', 'sting', 'slice', 'strike', 'rend', 'shoot',
    'backstab', 'bash', 'kick', 'frenzy', 'cleave', 'smite', 'reave',
}

-- English 3rd-person singular: sh/ch/ss/s/x/z -> +es; consonant+y -> +ies;
-- otherwise +s (verbs ending in 'e' just take the +s branch: gore->gores).
local function pluralVerb(verb)
    if verb:match('sh$') or verb:match('ch$') or verb:match('ss$') or verb:match('[sxz]$') then
        return verb .. 'es'
    end
    if verb:match('[^aeiou]y$') then return verb:sub(1, -2) .. 'ies' end
    return verb .. 's'
end

-- Ability name for a verb = the capitalized verb ("slash" -> "Slash").
local function abilityForVerb(verb)
    verb = tostring(verb)
    return verb:sub(1, 1):upper() .. verb:sub(2)
end

local function parseAmount(v)
    if type(v) == 'string' then v = v:gsub(',', '') end
    return tonumber(v) or 0
end

-- Log bucket for a hit size (base 1.3 => ~30% per bucket). Feeds per-ability
-- hit-size histograms for percentiles; representative value is 1.3^bucket.
local HIST_BASE = 1.3
local LOG_BASE = math.log(HIST_BASE)
local function bucketOf(amt)
    if amt < 1 then return 0 end
    return math.floor(math.log(amt) / LOG_BASE)
end
-- value at a bucket edge (for turning a percentile bucket back into a number)
local function bucketValue(b) return HIST_BASE ^ b end

local function ci_eq(a, b) return tostring(a):lower() == tostring(b):lower() end

local function isMe(name)
    return ci_eq(name, 'you') or ci_eq(name, cb.playerName())
end

-- ── encounter lifecycle ───────────────────────────────────────────────
local function newEncounter()
    local mh, oh = cb.getWeapons() -- weapon set you pulled with (captured at fight start)
    return {
        startClock = now(),
        lastClock  = now(),
        startTime  = os.time(),
        zone       = cb.getZone(),
        mainhand   = mh,
        offhand    = oh,
        targets    = {}, -- name -> damage dealt to it
        sources    = {}, -- name -> { total, mine, isPet }
        abilities  = {}, -- "source|ability" -> rollup
        casts      = {}, -- "caster|spell" -> { casts, fizzles, interrupts, blocked, activations }
        healTotal  = 0,  -- my effective healing (kept out of damage totals)
        overheal   = 0,  -- my wasted healing (the (M)-N part)
        healBy     = {}, -- healer name -> { total, over, activeSec, lastBucket, targets={tgt->{total,over}} }
        healRecv   = {}, -- target name -> { total, over } (healing received, all healers)
        events     = {},
        buckets    = {}, -- integer second -> player damage (for live dps line)
        kindSeries = {}, -- source -> kind -> { second -> damage } (stacked dps chart)
        playerDmg  = 0,
        petDmg     = 0,
        otherDmg   = 0,
        incoming   = 0,
        incomingBy = {}, -- attacker name -> damage dealt TO me (per-mob incoming)
        incomingAt = {}, -- attacker name -> { first, last } encounter-relative seconds it was hitting me
        avoided    = 0,
        avoidBy    = {}, -- avoid type -> count (miss/dodge/parry/riposte/block/rune)
        incMeleeHits = 0, -- melee swings that LANDED on me (avoidance denominator)
        deaths     = 0,
        deathRecords = {}, -- { t, killer, samples, eventIndex } per death (black-box freeze)
        hpAnchorPct = nil, -- last sampled HP% of the primary target
        hpAnchorDmg = 0,   -- damage dealt to that target at the anchor sample
        hpEst       = { sum = 0, weight = 0, target = nil }, -- weighted max-HP estimate
        hpLastSample = nil, -- gettime() of the last 1Hz HP sample (per-encounter,
                             -- so a fresh encounter never inherits a prior one's throttle)
    }
end

-- `refresh` (default true) bumps the activity clock. Casts pass false so a
-- stream of buff casts can't hold a fight open past its damage.
local function ensureActive(refresh)
    if not active then active = newEncounter() end
    if refresh ~= false then active.lastClock = now() end
    return active
end

-- ── hit modifiers ─────────────────────────────────────────────────────
-- Hit qualifiers ride in a trailing "(...)", e.g. "... points of damage.
-- (Lucky Critical Twincast)". Taxonomy mirrors EQLogParser. Multiple can stack.
local MOD_KEYWORDS = {
    crit          = { 'Critical', 'Crippling Blow', 'Deadly Strike', 'Finishing Blow' },
    lucky         = { 'Lucky' },
    twincast      = { 'Twincast' },
    flurry        = { 'Flurry' },
    rampage       = { 'Rampage' }, -- also matches "Wild Rampage"
    strikethrough = { 'Strikethrough' },
    riposte       = { 'Riposte' },
    slay          = { 'Slay Undead' },
    assassinate   = { 'Assassinate' },
    headshot      = { 'Headshot' },
    doublebow     = { 'Double Bow Shot' },
    finishing     = { 'Finishing Blow' },
}
-- Failures (fizzle/interrupt/blocked) are logged as kind 'castfail' so the
-- death post-mortem can see a healer's Complete Heal getting interrupted.
local FAIL_OUTCOME = { fizzles = 'fizzle', interrupts = 'interrupt', blocked = 'blocked' }

local EMPTY_MODS = {}

-- Parse the modifier set off a damage line. Returns a shared empty table when
-- there's no "(...)" (the common case) to avoid per-hit allocation.
local function parseModifiers(line)
    if not line or not line:find('(', 1, true) then return EMPTY_MODS end
    local m = {}
    for flag, kws in pairs(MOD_KEYWORDS) do
        for _, k in ipairs(kws) do
            if line:find(k, 1, true) then m[flag] = true break end
        end
    end
    -- a struck-through riposte isn't a clean riposte (per EQLogParser)
    if m.riposte and m.strikethrough then m.riposte = nil end
    return m
end

-- Serialize a per-ability modifier count table to a compact "k:v,k:v" string
-- for storage (decoded in the UI).
local function encodeMods(mods)
    if not mods then return '' end
    local parts = {}
    for k, v in pairs(mods) do
        if v and v > 0 then parts[#parts + 1] = k .. ':' .. v end
    end
    return table.concat(parts, ',')
end

-- Optional external observer — set via M.setEventHook(fn) below. Fires once per
-- normalized event at the top of record() so other same-machine scripts can
-- consume companion's parse output instead of re-running their own mq.event
-- pattern set. Deliberately protected: a hook error is logged once and cleared.
M.onEvent = nil
local _hookErrPrinted = false
function M.setEventHook(fn)
    M.onEvent = (type(fn) == 'function') and fn or nil
    _hookErrPrinted = false
end

-- ── recording ─────────────────────────────────────────────────────────
-- ev = { source, target, ability, kind, amount, mine, myPet, isPet, incoming, outcome, line }
-- outcome: 'hit' | 'miss' | 'resist'. `line` (when present) carries hit modifiers.
local function record(ev)
    if M.onEvent then
        local ok, err = pcall(M.onEvent, ev)
        if not ok and not _hookErrPrinted then
            _hookErrPrinted = true
            printf('\ar[companion]\ax event hook failed (silenced): %s', tostring(err))
        end
    end

    local enc = ensureActive()

    -- resolve crit + full modifier set from the line (falls back to ev.crit)
    local mset = parseModifiers(ev.line)
    local crit = mset.crit or ev.crit or false

    -- event log (capped). Skip pure-overheal ticks (heal with 0 effective) —
    -- some procs/HoTs spam thousands of "for 0 (M)" lines and would blow the cap;
    -- their overheal is still counted in the rollup below.
    if #enc.events < M.maxEvents and not (ev.kind == 'heal' and (ev.amount or 0) <= 0) then
        enc.events[#enc.events + 1] = {
            t       = enc.lastClock - enc.startClock,
            source  = ev.source,
            target  = ev.target,
            ability = ev.ability,
            kind    = ev.kind,
            amount  = ev.amount or 0,
            crit    = crit,
            outcome = ev.outcome,
        }
    end

    -- incoming damage only contributes to the incoming total; it must not land
    -- in the outgoing source/ability/target rollups.
    if ev.incoming then
        if ev.outcome == 'hit' then
            local amt = ev.amount or 0
            if ev.kind == 'melee' then enc.incMeleeHits = enc.incMeleeHits + 1 end -- landed swing
            if amt > 0 then
                enc.incoming = enc.incoming + amt
                local src = ev.source or '?'
                enc.incomingBy[src] = (enc.incomingBy[src] or 0) + amt
                local t = enc.lastClock - enc.startClock
                local at = enc.incomingAt[src]
                if at then at.last = t else enc.incomingAt[src] = { first = t, last = t } end
            end
        end
        return
    end

    -- outgoing: ability rollup keyed by source+ability (drives the breakdown).
    -- Heals get their own row (key suffix |heal, kind 'heal'): a lifetap's damage line and
    -- its "You healed <me> ... by <tap>" line must not share one row, or the damage view
    -- counts the heal and the heal view never sees it.
    local key = (ev.source or '?') .. '|' .. (ev.ability or '?')
    if ev.kind == 'heal' then key = key .. '|heal' end
    local a = enc.abilities[key]
    if not a then
        a = { source = ev.source, ability = ev.ability, kind = ev.kind,
            total = 0, hits = 0, misses = 0, crits = 0, resists = 0, min_hit = 0, max_hit = 0, mods = {}, hist = {} }
        enc.abilities[key] = a
    end
    if ev.outcome == 'miss' then
        a.misses = a.misses + 1
        return
    elseif ev.outcome == 'resist' then
        a.resists = a.resists + 1
        return
    end

    local amt = ev.amount or 0

    -- heals are handled BEFORE the amt<=0 bail: a full-overheal tick logs as
    -- "for 0 (M)" and must still count its overheal. They get an ability row +
    -- per-healer rollup, but never flow into damage sources/targets/DPS.
    if ev.kind == 'heal' then
        if amt > 0 then
            a.total = a.total + amt
            a.hits = a.hits + 1
            if a.min_hit == 0 or amt < a.min_hit then a.min_hit = amt end
            if amt > a.max_hit then a.max_hit = amt end
        end
        if crit then a.crits = a.crits + 1 end
        a.over = (a.over or 0) + (ev.over or 0)
        a.ticks = (a.ticks or 0) + 1        -- every LOGGED tick (incl. "for 0")
        if a.hotDur == nil then a.hotDur = hotTicks(ev.ability) end -- ticks/cast if a HoT
        local h = enc.healBy[ev.source]
        if not h then h = { total = 0, over = 0, activeSec = 0, lastBucket = -1, targets = {} }; enc.healBy[ev.source] = h end
        h.total = h.total + amt
        h.over = h.over + (ev.over or 0)
        local hb = math.floor(now())
        if hb ~= h.lastBucket then h.lastBucket = hb; h.activeSec = h.activeSec + 1 end
        -- who this healer healed, and overall healing received
        local tgt = ev.target or '?'
        local ht = h.targets[tgt]
        if not ht then ht = { total = 0, over = 0 }; h.targets[tgt] = ht end
        ht.total = ht.total + amt; ht.over = ht.over + (ev.over or 0)
        local rr = enc.healRecv[tgt]
        if not rr then rr = { total = 0, over = 0 }; enc.healRecv[tgt] = rr end
        rr.total = rr.total + amt; rr.over = rr.over + (ev.over or 0)
        if ev.mine then
            enc.healTotal = enc.healTotal + amt
            enc.overheal = enc.overheal + (ev.over or 0)
        end
        return
    end

    if amt <= 0 then return end
    a.total = a.total + amt
    a.hits = a.hits + 1
    if crit then a.crits = a.crits + 1 end
    for flag, on in pairs(mset) do
        if on and flag ~= 'crit' then a.mods[flag] = (a.mods[flag] or 0) + 1 end
    end
    if a.min_hit == 0 or amt < a.min_hit then a.min_hit = amt end
    if amt > a.max_hit then a.max_hit = amt end
    local hb = bucketOf(amt); a.hist[hb] = (a.hist[hb] or 0) + 1 -- hit-size distribution

    -- source rollup (outgoing damage by attacker)
    local s = enc.sources[ev.source]
    if not s then
        s = { total = 0, mine = ev.mine, isPet = ev.isPet, activeSec = 0, lastBucket = -1 }
        enc.sources[ev.source] = s
    end
    s.total = s.total + amt
    -- active seconds = distinct 1s buckets this source dealt damage (ACT/sidekick-
    -- style DPS denominator; excludes idle time, even mid-fight lulls)
    local abucket = math.floor(now())
    if abucket ~= s.lastBucket then s.lastBucket = abucket; s.activeSec = s.activeSec + 1 end

    -- per-source per-kind time buckets (stacked dps chart)
    do
        local sec = math.floor(enc.lastClock - enc.startClock)
        local ks = enc.kindSeries[ev.source]
        if not ks then ks = {}; enc.kindSeries[ev.source] = ks end
        local kb = ks[ev.kind or '?']
        if not kb then kb = {}; ks[ev.kind or '?'] = kb end
        kb[sec] = (kb[sec] or 0) + amt
    end

    -- target + direction split
    if ev.target and ev.target ~= '' then
        enc.targets[ev.target] = (enc.targets[ev.target] or 0) + amt
    end
    -- you + your pet feed the "you + pet" dps line
    if ev.mine or ev.myPet then
        local sec = math.floor(enc.lastClock - enc.startClock)
        enc.buckets[sec] = (enc.buckets[sec] or 0) + amt
    end
    if ev.mine then
        enc.playerDmg = enc.playerDmg + amt
    elseif ev.myPet then
        enc.petDmg = enc.petDmg + amt -- only MY pet counts toward my DPS
    else
        enc.otherDmg = enc.otherDmg + amt -- other players AND their pets
    end
end

-- ── cast tracking ─────────────────────────────────────────────────────
-- Counts cast attempts and their failure modes per caster+spell. Activations
-- ("You activate X") are disciplines/AAs and count separately. Casts NEVER
-- create or refresh an encounter — buffing/singing out of combat must not spawn
-- a phantom fight — so they only attach to an already-active encounter.
local function castEntry(caster, spell)
    local enc = active
    if not enc then return nil end
    local key = (caster or '?') .. '|' .. (spell or '?')
    local c = enc.casts[key]
    if not c then
        c = { source = caster, spell = spell, casts = 0, fizzles = 0, interrupts = 0,
            blocked = 0, activations = 0 }
        enc.casts[key] = c
    end
    return c
end

-- `evKind` distinguishes how it was used: 'cast' (spells), 'song' (singing),
-- 'activate' (discs/AAs/clickies). Recorded on the event so the timeline can
-- style and filter them separately.
local function recordCast(caster, spell, field, evKind)
    -- Resolve the current target once for own spell casts: used both by the
    -- mailbox hook below and by the persisted event-log entry further down.
    -- Other callers (other players' casts, activations) leave this nil -> ''.
    local ownCastTarget = nil
    if field == 'casts' and isMe(caster) then
        ownCastTarget = ''
        if cb.getTarget then
            local ok, name = pcall(cb.getTarget)
            if ok and type(name) == 'string' then ownCastTarget = name end
        end
    end
    -- Own cast attempts go to the event hook even with no encounter open: the
    -- first DoT of a pull usually lands before any damage line has started one.
    if field == 'casts' and M.onEvent and isMe(caster) then
        local ok, err = pcall(M.onEvent, {
            source = caster, target = ownCastTarget, ability = spell, kind = 'cast',
            amount = 0, mine = true, outcome = 'cast',
        })
        if not ok and not _hookErrPrinted then
            _hookErrPrinted = true
            printf('\ar[companion]\ax event hook failed (silenced): %s', tostring(err))
        end
    end
    local c = castEntry(caster, spell)
    if not c then return end -- no active fight: ignore out-of-combat casts/songs
    c[field] = c[field] + 1
    if evKind == 'song' then c.isSong = true end
    -- time-stamp casts/activations into the event log so the timeline can show
    -- WHEN a spell/song/disc/AA/clicky was used (persisted like any other event).
    if field == 'casts' or field == 'activations' or FAIL_OUTCOME[field] then
        local enc = active -- castEntry just ensured it
        if enc and #enc.events < M.maxEvents then
            local isFail = FAIL_OUTCOME[field] ~= nil
            enc.events[#enc.events + 1] = {
                t       = now() - enc.startClock,
                source  = caster,
                target  = ownCastTarget or '',
                ability = spell,
                kind    = isFail and 'castfail' or (evKind or (field == 'activations' and 'activate' or 'cast')),
                amount  = 0,
                crit    = false,
                outcome = isFail and FAIL_OUTCOME[field] or 'cast',
            }
        end
    end
end

-- Classify a cast by what its spell was observed doing this fight.
local function classifyCast(enc, c)
    if c.activations > 0 then return 'activate' end
    local k = (c.source or '?') .. '|' .. (c.spell or '?')
    local a = enc.abilities[k]
    if a then
        if a.kind == 'heal' then return 'heal' end
        if a.kind == 'nuke' or a.kind == 'dot' then return 'damage' end
    end
    -- heals roll up under source|spell|heal; a lifetap's damage row above wins
    if enc.abilities[k .. '|heal'] then return 'heal' end
    if c.isSong then return 'song' end
    return 'other' -- buff / utility / never landed
end

-- Sorted cast rollup for display + persistence.
local function buildCasts(enc)
    local out = {}
    for _, c in pairs(enc.casts) do
        c.kind = classifyCast(enc, c)
        out[#out + 1] = c
    end
    table.sort(out, function(x, y)
        return (x.casts + x.activations) > (y.casts + y.activations)
    end)
    return out
end

-- Build the persistence/display record from an encounter.
local function buildFight(enc)
    local duration = math.max(1.0, enc.lastClock - enc.startClock)
    local total = enc.playerDmg + enc.petDmg + enc.otherDmg

    -- primary target = most-damaged mob
    local primary, best = nil, -1
    for name, dmg in pairs(enc.targets) do
        if dmg > best then best, primary = dmg, name end
    end

    local abilities = {}
    for _, a in pairs(enc.abilities) do
        -- keep only entries that dealt/attempted something meaningful
        if a.total > 0 or a.misses > 0 or a.resists > 0 or (a.over or 0) > 0 then
            local s = enc.sources[a.source]
            a.is_pet = s and s.isPet or false -- stamp pet-ness from the source classification
            a.mods_str = encodeMods(a.mods) -- serialize modifier counts for the DB
            a.hist_str = encodeMods(a.hist) -- same "k:v" format works for the histogram
            abilities[#abilities + 1] = a
        end
    end
    table.sort(abilities, function(x, y) return x.total > y.total end)

    return {
        started_at     = enc.startTime,
        ended_at       = os.time(),
        duration       = duration,
        zone           = enc.zone,
        primary_target = primary,
        mainhand       = enc.mainhand,
        offhand        = enc.offhand,
        is_raid        = primary and cb.isRaidTarget(primary) or false,
        player_dmg     = enc.playerDmg,
        pet_dmg        = enc.petDmg,
        other_dmg      = enc.otherDmg,
        total_dmg      = total,
        dps            = total / duration,
        player_dps     = (enc.playerDmg + enc.petDmg) / duration,
        incoming       = enc.incoming,
        deaths         = enc.deaths,
        heal_total     = enc.healTotal,
        overheal       = enc.overheal,
        mob_max_hp     = (enc.hpEst.weight > 0) and (enc.hpEst.sum / enc.hpEst.weight) or nil,
        mob_hp_weight  = enc.hpEst.weight,
        abilities      = abilities,
        casts          = buildCasts(enc),
        events         = enc.events,
        deaths_detail  = enc.deathRecords, -- black-box freezes, one per death
        _enc           = enc, -- kept for live display (buckets, avoided)
    }
end

-- ── zone-wide (Overall) accumulator ───────────────────────────────────
-- Folds every finalized fight into a running total, reset on zone change, so
-- the UI can show "this pull" vs "the whole zone".
local overall = nil
local overallRev = 0 -- bumped on every merge/reset so the snapshot cache can invalidate
local function resetOverall()
    overall = newEncounter()
    overall.fightTime = 0
    overall.fightCount = 0
    overallRev = overallRev + 1
end

local function mergeIntoOverall(enc)
    if not overall then resetOverall() end
    overall.fightTime = overall.fightTime + math.max(0, enc.lastClock - enc.startClock)
    overall.fightCount = overall.fightCount + 1
    overall.zone = enc.zone
    overall.playerDmg = overall.playerDmg + enc.playerDmg
    overall.petDmg = overall.petDmg + enc.petDmg
    overall.otherDmg = overall.otherDmg + enc.otherDmg
    overall.incoming = overall.incoming + enc.incoming
    overall.avoided = overall.avoided + enc.avoided
    overall.incMeleeHits = overall.incMeleeHits + enc.incMeleeHits
    for t, c in pairs(enc.avoidBy) do overall.avoidBy[t] = (overall.avoidBy[t] or 0) + c end
    overall.deaths = overall.deaths + enc.deaths
    overall.healTotal = overall.healTotal + enc.healTotal
    overall.overheal = overall.overheal + enc.overheal
    for n, v in pairs(enc.targets) do overall.targets[n] = (overall.targets[n] or 0) + v end
    for n, s in pairs(enc.sources) do
        local o = overall.sources[n]
        if not o then o = { total = 0, mine = s.mine, isPet = s.isPet, activeSec = 0, lastBucket = -1 }; overall.sources[n] = o end
        o.total = o.total + s.total
        o.activeSec = o.activeSec + (s.activeSec or 0)
    end
    for k, a in pairs(enc.abilities) do
        local o = overall.abilities[k]
        if not o then
            o = { source = a.source, ability = a.ability, kind = a.kind, total = 0, hits = 0, misses = 0,
                crits = 0, resists = 0, min_hit = 0, max_hit = 0, mods = {}, hist = {}, over = 0, ticks = 0,
                hotDur = a.hotDur, is_pet = a.is_pet }
            overall.abilities[k] = o
        end
        o.total = o.total + a.total; o.hits = o.hits + a.hits; o.misses = o.misses + a.misses
        o.crits = o.crits + a.crits; o.resists = o.resists + a.resists
        o.over = (o.over or 0) + (a.over or 0); o.ticks = (o.ticks or 0) + (a.ticks or 0)
        if o.min_hit == 0 or (a.min_hit > 0 and a.min_hit < o.min_hit) then o.min_hit = a.min_hit end
        if a.max_hit > o.max_hit then o.max_hit = a.max_hit end
        for f, c in pairs(a.mods or {}) do o.mods[f] = (o.mods[f] or 0) + c end
        for b, c in pairs(a.hist or {}) do o.hist[b] = (o.hist[b] or 0) + c end
    end
    for n, h in pairs(enc.healBy) do
        local o = overall.healBy[n]
        if not o then o = { total = 0, over = 0, activeSec = 0, lastBucket = -1, targets = {} }; overall.healBy[n] = o end
        o.total = o.total + h.total; o.over = o.over + h.over; o.activeSec = o.activeSec + h.activeSec
        for tn, tv in pairs(h.targets or {}) do
            local ot = o.targets[tn]; if not ot then ot = { total = 0, over = 0 }; o.targets[tn] = ot end
            ot.total = ot.total + tv.total; ot.over = ot.over + tv.over
        end
    end
    for n, r in pairs(enc.healRecv) do
        local o = overall.healRecv[n]; if not o then o = { total = 0, over = 0 }; overall.healRecv[n] = o end
        o.total = o.total + r.total; o.over = o.over + r.over
    end
    for n, v in pairs(enc.incomingBy) do overall.incomingBy[n] = (overall.incomingBy[n] or 0) + v end
    for k, c in pairs(enc.casts) do
        local o = overall.casts[k]
        if not o then
            o = { source = c.source, spell = c.spell, casts = 0, fizzles = 0, interrupts = 0,
                blocked = 0, activations = 0, isSong = c.isSong }
            overall.casts[k] = o
        end
        o.casts = o.casts + c.casts; o.fizzles = o.fizzles + c.fizzles; o.interrupts = o.interrupts + c.interrupts
        o.blocked = o.blocked + c.blocked; o.activations = o.activations + c.activations
    end
    overallRev = overallRev + 1
end

-- Per-attacker incoming DPS for an encounter: damage the mob did to me over the
-- window it was actually hitting me (first..last landed hit), floored at
-- MIN_MOB_WINDOW seconds so a single crit does not read as 2000 dps. Consumed by
-- init.lua's MobDPS ini writer, which muleassist's AutoCharmPick ranks charm
-- candidates by. Pure: no TLO, no clock.
M.MIN_MOB_WINDOW = 6
function M.mobDpsRows(enc)
    local rows = {}
    for name, dmg in pairs(enc.incomingBy or {}) do
        if (dmg or 0) > 0 then
            local at = enc.incomingAt and enc.incomingAt[name]
            local secs = at and (at.last - at.first) or 0
            if secs < M.MIN_MOB_WINDOW then secs = M.MIN_MOB_WINDOW end
            rows[#rows + 1] = { name = name, dmg = dmg, secs = secs, dps = dmg / secs }
        end
    end
    table.sort(rows, function(a, b) return a.dps > b.dps end)
    return rows
end

local function finalize()
    if not active then return end
    local fight = buildFight(active)
    local enc = active
    last = fight
    active = nil
    -- pure-cast encounters (buffing between pulls: no damage either way, no
    -- deaths) stay visible as `last` but are not persisted or folded into Overall
    if fight.total_dmg == 0 and fight.incoming == 0 and fight.deaths == 0
        and fight.heal_total == 0 then
        return
    end
    mergeIntoOverall(enc)
    if cb.onFinalize then pcall(cb.onFinalize, fight) end
    if cb.onMobDps then pcall(cb.onMobDps, M.mobDpsRows(enc)) end
end

-- ── pet ownership resolution ───────────────────────────────────────────
-- Pet given-names are drawn from a shared random pool, so two players' pets can
-- share a name — keying damage by the pet's name would merge/misattribute them.
-- Combat text normally prints the owner ("<Owner>`s pet"), which is
-- unambiguous; for a bare pet name we fall back to the spawn's Master via TLO.
-- Results are cached (cleared on zone) to avoid per-line TLO lookups.
local petCache = {}

-- Returns (isPet, ownerName|nil).
local function resolvePet(name)
    if not name then return false, nil end
    local c = petCache[name]
    if c ~= nil then return c.isPet, c.owner end
    local owner = name:match("^(.-)[`']s %a+$") -- "<Owner>`s pet" / "<Owner>'s warder"
    local isPet = owner ~= nil and owner ~= ''
    if not isPet then
        local m = cb.getMaster(name) -- bare name -> Spawn(name).Master (best-effort)
        if m and m ~= '' and not ci_eq(m, name) then owner, isPet = m, true end
    end
    petCache[name] = { isPet = isPet, owner = owner }
    return isPet, owner
end

-- Classify a source name -> (isMine, isMyPet, isAnyPet, normalizedName).
-- Pets normalize to "<Owner>`s pet" so reused names never collide across owners.
local function classifySource(name)
    if isMe(name) then return true, false, false, cb.playerName() end
    local isPet, owner = resolvePet(name)
    if not isPet then return false, false, false, name end
    local norm = (owner and owner ~= '') and (owner .. "`s pet") or name
    local myPet = owner ~= nil and isMe(owner)
    if not myPet then
        local pn = cb.getPet()
        if pn and ci_eq(name, pn) then myPet, norm = true, cb.playerName() .. "`s pet" end
    end
    return false, myPet, true, norm
end

-- ── event registration ────────────────────────────────────────────────
local function reg(name, pattern, fn)
    mq.event(name, pattern, fn)
    registered[#registered + 1] = name
end

-- Route a third-person damage line, resolving direction and pet ownership.
local function outgoing(line, attacker, target, amount, kind, ability)
    if isMe(target) then -- incoming to me (target printed as YOU)
        record { source = attacker, target = cb.playerName(), ability = ability, kind = kind,
            amount = parseAmount(amount), incoming = true, outcome = 'hit' }
        return
    end
    local mine, myPet, isPet, src = classifySource(attacker)
    if mine then return end -- own lines are handled by first-person events
    record { source = src, target = target, ability = ability, kind = kind,
        amount = parseAmount(amount), mine = false, myPet = myPet, isPet = isPet, outcome = 'hit',
        line = line }
end

-- ── my death ──────────────────────────────────────────────────────────
-- One death prints "You have been slain by X!" AND "You died.", and the
-- black-box Me.Dead edge may fire too; all within a few seconds, though the
-- Me.Dead edge can lag the chat line by more than that across a zone/death-
-- camera. Collapse them: the first call records, later calls inside 20s only
-- back-fill a killer we didn't have. Returns true when a new death was recorded.
local lastDeathClock = -1e9
---@param killer string|nil
---@return boolean
function M.recordDeath(killer)
    local t = now()
    if (t - lastDeathClock) < 20 then
        if killer and killer ~= '?' and active and #active.deathRecords > 0 then
            local d = active.deathRecords[#active.deathRecords]
            if d.killer == '?' then
                d.killer = killer
                local e = active.events[d.eventIndex]
                if e and e.kind == 'death' then e.source = killer end
            end
        end
        return false
    end
    lastDeathClock = t
    local enc = ensureActive()
    enc.deaths = enc.deaths + 1
    local relT = t - enc.startClock
    local eventIndex = nil -- index of the death event, nil when the log is at its cap
    if #enc.events < M.maxEvents then
        enc.events[#enc.events + 1] = { t = relT, source = killer or '?', target = cb.playerName(),
            ability = 'Death', kind = 'death', amount = 0, crit = false, outcome = 'death' }
        eventIndex = #enc.events
    end
    local samples = nil
    if cb.freezeBlackBox then
        local ok, s = pcall(cb.freezeBlackBox, mq.gettime())
        if ok and type(s) == 'table' then samples = {}; for i, v in ipairs(s) do samples[i] = v end end
    end
    -- terminal sample: the chat line fires before the next 2 Hz tick, so the
    -- newest real sample predates the killing blow. Close the curve at 0 HP.
    samples = samples or {}
    local lastS = samples[#samples]
    samples[#samples + 1] = { t = 0, hp = 0, flags = lastS and lastS.flags or '', group = lastS and lastS.group or {},
        tank = lastS and lastS.tank or nil, aggro = lastS and lastS.aggro or nil, aggro2Name = lastS and lastS.aggro2Name or nil,
        tot = lastS and lastS.tot or nil, buffsDropped = {}, terminal = true }
    enc.deathRecords[#enc.deathRecords + 1] = { t = relT, killer = killer or '?', samples = samples,
        eventIndex = eventIndex }
    return true
end

function M.registerEvents()
    if #registered > 0 then return end
    local me = cb.playerName()

    -- ── my melee: "You <verb> <tgt> for N points of damage.[ (Critical)]" ──
    for _, verb in ipairs(MELEE_VERBS) do
        local ability = abilityForVerb(verb)
        reg('cmp_my_' .. verb, string.format("You %s #1# for #2# point#*# of damage#*#", verb),
            function(line, target, amount)
                record { source = me, target = target, ability = ability, kind = 'melee',
                    amount = parseAmount(amount), mine = true, outcome = 'hit', line = line }
            end)
    end

    -- my melee miss / avoidance: "You try to <verb> <tgt>, but miss!"
    reg('cmp_my_miss', "You try to #1# #2#, but #*#", function(_, verb, target)
        record { source = me, target = target, ability = abilityForVerb(verb), kind = 'melee', outcome = 'miss' }
    end)

    -- my spell / proc damage: "You hit <tgt> for N points of <element> damage by <Spell>.[ (Critical)]"
    reg('cmp_my_spell', "You hit #1# for #2# point#*# of #3# damage by #4#.#*#",
        function(line, target, amount, _element, spell)
            record { source = me, target = target, ability = spell, kind = 'nuke',
                amount = parseAmount(amount), mine = true, outcome = 'hit', line = line }
        end)

    -- my direct nuke without a spell name (fallback): "... points of non-melee damage"
    reg('cmp_my_nuke', "You hit #1# for #2# point#*# of non-melee damage#*#", function(line, target, amount)
        record { source = me, target = target, ability = 'Direct damage', kind = 'nuke',
            amount = parseAmount(amount), mine = true, outcome = 'hit', line = line }
    end)

    -- my DoT ticks: "<tgt> has taken N damage from your <Spell>.[ (Critical)]"
    reg('cmp_my_dot', "#1# has taken #2# damage from your #3#.#*#", function(line, target, amount, spell)
        record { source = me, target = target, ability = spell, kind = 'dot',
            amount = parseAmount(amount), mine = true, outcome = 'hit', line = line }
    end)

    -- my spell resisted: "<tgt> resisted your <Spell>!"
    reg('cmp_my_resist', "#1# resisted your #2#!#*#", function(_, target, spell)
        record { source = me, target = target, ability = spell, kind = 'nuke', outcome = 'resist' }
    end)

    -- my damage shield: "<tgt> is <verb> by YOUR <element> for N points of non-melee damage"
    reg('cmp_my_ds', "#1# is #2# by YOUR #3# for #4# point#*# of non-melee damage#*#",
        function(_, target, _verb, _element, amount)
            record { source = me, target = target, ability = 'Damage shield', kind = 'ds',
                amount = parseAmount(amount), mine = true, outcome = 'hit' }
        end)

    -- my heals: "You healed <tgt> for N (M) hit points by <Spell>." — N is the
    -- effective heal, M the pre-cap amount; overheal = M - N. The no-(M) form
    -- registers separately; its handler skips (M) lines to avoid double counts.
    reg('cmp_my_heal_over', "You healed #1# for #2# (#3#) hit points by #4#.#*#",
        function(_, target, amount, rawAmount, spell)
            local eff, raw = parseAmount(amount), parseAmount(rawAmount)
            record { source = me, target = target, ability = spell, kind = 'heal',
                amount = eff, over = math.max(0, raw - eff), mine = true, outcome = 'hit' }
        end)
    reg('cmp_my_heal', "You healed #1# for #2# hit points by #3#.#*#", function(_, target, amount, spell)
        if tostring(amount):find('(', 1, true) then return end -- (M) form handled above
        record { source = me, target = target, ability = spell, kind = 'heal',
            amount = parseAmount(amount), mine = true, outcome = 'hit' }
    end)
    -- heals with no named spell (lifetaps, procs): "You healed X for N [(M)] hit points."
    reg('cmp_my_heal_over2', "You healed #1# for #2# (#3#) hit points.#*#",
        function(_, target, amount, rawAmount)
            local eff, raw = parseAmount(amount), parseAmount(rawAmount)
            record { source = me, target = target, ability = 'Healing', kind = 'heal',
                amount = eff, over = math.max(0, raw - eff), mine = true, outcome = 'hit' }
        end)
    reg('cmp_my_heal2', "You healed #1# for #2# hit points.#*#", function(_, target, amount)
        if tostring(amount):find('(', 1, true) then return end -- (M) form handled above
        record { source = me, target = target, ability = 'Healing', kind = 'heal',
            amount = parseAmount(amount), mine = true, outcome = 'hit' }
    end)

    -- other players' heals: "<Healer> healed <Target> for N (M) hit points by <Spell>."
    -- (reflexive target himself/herself/itself -> the healer). isMe(healer) skips
    -- so my own lines aren't double-counted. Passive "X has been healed" (no
    -- healer) isn't matched — unattributable.
    local function reflexive(target, healer)
        if target == 'himself' or target == 'herself' or target == 'itself' then return healer end
        return target
    end
    reg('cmp_ot_heal_over', "#1# healed #2# for #3# (#4#) hit points by #5#.#*#",
        function(_, healer, target, amount, rawAmount, spell)
            if isMe(healer) then return end
            local eff, raw = parseAmount(amount), parseAmount(rawAmount)
            record { source = healer, target = reflexive(target, healer), ability = spell, kind = 'heal',
                amount = eff, over = math.max(0, raw - eff), mine = false, outcome = 'hit' }
        end)
    reg('cmp_ot_heal', "#1# healed #2# for #3# hit points by #4#.#*#",
        function(_, healer, target, amount, spell)
            if isMe(healer) or tostring(amount):find('(', 1, true) then return end
            record { source = healer, target = reflexive(target, healer), ability = spell, kind = 'heal',
                amount = parseAmount(amount), mine = false, outcome = 'hit' }
        end)

    -- ── casts / fizzles / interrupts / activations ──
    reg('cmp_cast_my', "You begin casting #1#.#*#", function(_, spell)
        recordCast(me, spell, 'casts')
    end)
    reg('cmp_sing_my', "You begin singing #1#.#*#", function(_, spell)
        recordCast(me, spell, 'casts', 'song')
    end)
    reg('cmp_cast_ot', "#1# begins casting #2#.#*#", function(_, caster, spell)
        local mine, _, _, src = classifySource(caster)
        if not mine then recordCast(src, spell, 'casts') end
    end)
    reg('cmp_sing_ot', "#1# begins singing #2#.#*#", function(_, caster, spell)
        local mine, _, _, src = classifySource(caster)
        if not mine then recordCast(src, spell, 'casts', 'song') end
    end)
    reg('cmp_fizz_my', "Your #1# spell fizzles!#*#", function(_, spell)
        recordCast(me, spell, 'fizzles')
    end)
    reg('cmp_fizz_ot', "#1#'s #2# spell fizzles!#*#", function(_, caster, spell)
        recordCast(caster, spell, 'fizzles')
    end)
    reg('cmp_int_my', "Your #1# spell is interrupted.#*#", function(_, spell)
        recordCast(me, spell, 'interrupts')
    end)
    reg('cmp_int_ot', "#1#'s #2# spell is interrupted.#*#", function(_, caster, spell)
        recordCast(caster, spell, 'interrupts')
    end)
    reg('cmp_block_my', "Your #1# spell did not take hold#*#", function(_, spell)
        recordCast(me, spell, 'blocked')
    end)
    reg('cmp_act_my', "You activate #1#.#*#", function(_, ability)
        recordCast(me, ability, 'activations')
    end)
    reg('cmp_act_ot', "#1# activates #2#.#*#", function(_, caster, ability)
        local mine, _, _, src = classifySource(caster)
        if not mine then recordCast(src, ability, 'activations') end
    end)

    -- ── others / pets (third person). Direction resolved in outgoing(). ──
    reg('cmp_ot_nuke', "#1# hit #2# for #3# point#*# of non-melee damage#*#", function(line, atk, tgt, amt)
        -- guard: a damage-shield line whose target NAME contains "hit" lets the
        -- greedy #2# swallow " is <verb> by <owner>'s <elem>" — that's a DS,
        -- handled by cmp_ot_ds, so bail (a real nuke target has no " is "/" by ")
        if tgt:find(' is ', 1, true) or tgt:find(' by ', 1, true) then return end
        outgoing(line, atk, tgt, amt, 'nuke', 'Direct damage')
    end)
    -- third-person spell/proc damage uses singular "hit" (e.g. "X hit you for N
    -- points of magic damage by Harm Touch")
    reg('cmp_ot_spell', "#1# hit #2# for #3# point#*# of #4# damage by #5#.#*#",
        function(line, atk, tgt, amt, _element, spell)
            outgoing(line, atk, tgt, amt, 'nuke', spell)
        end)
    reg('cmp_ot_dot', "#1# has taken #2# damage from #3# by #4#.#*#", function(line, tgt, amt, spell, caster)
        if isMe(tgt) then return end -- incoming DoT to me is handled by cmp_in_dot
        local mine, myPet, isPet, src = classifySource(caster)
        if mine then return end
        record { source = src, target = tgt, ability = spell, kind = 'dot',
            amount = parseAmount(amt), mine = false, myPet = myPet, isPet = isPet, outcome = 'hit',
            line = line }
    end)
    -- incoming DoT to me: "You have taken N damage from <Spell>[ by <caster>]."
    reg('cmp_in_dot', "You have taken #1# damage from #2#.#*#", function(_, amount, spell)
        record { source = spell, target = me, ability = spell, kind = 'dot',
            amount = parseAmount(amount), incoming = true, outcome = 'hit' }
    end)
    -- others' damage shields: "<tgt> is <verb> by <Owner>'s <element> for N points of non-melee damage"
    reg('cmp_ot_ds', "#1# is #2# by #3#'s #4# for #5# point#*# of non-melee damage#*#",
        function(_, tgt, _verb, owner, _element, amount)
            -- owner here is the DS owner ("<Owner>'s frost"); classify by that name
            local mine, myPet, isPet, src = classifySource(owner)
            if mine then return end
            record { source = src, target = tgt, ability = 'Damage shield', kind = 'ds',
                amount = parseAmount(amount), mine = false, myPet = myPet, isPet = isPet, outcome = 'hit' }
        end)
    -- damage-shield damage to me: "YOU are <verb> by <mob>'s <element> for N points of non-melee damage!"
    reg('cmp_in_ds', "YOU are #1# by #2# for #3# point#*# of non-melee damage#*#",
        function(_, _verb, _src, amount)
            record { source = 'damage shield', target = me, ability = 'Damage shield', kind = 'ds',
                amount = parseAmount(amount), incoming = true, outcome = 'hit' }
        end)
    for _, verb in ipairs(MELEE_VERBS) do
        local ability = abilityForVerb(verb)
        reg('cmp_ot_' .. verb, string.format("#1# %s #2# for #3# point#*# of damage#*#", pluralVerb(verb)),
            function(line, atk, tgt, amt) outgoing(line, atk, tgt, amt, 'melee', ability) end)
    end

    -- incoming melee miss on me (avoidance)
    -- incoming avoidance: "<mob> tries to <verb> YOU, but <outcome>" — outcome is
    -- misses! / YOU dodge! / YOU parry! / YOU riposte! / YOU block! / YOUR magical
    -- skin absorbs the blow!  Classify so we can break avoidance down by type.
    reg('cmp_in_miss', "#1# tries to #2# YOU, but #3#", function(_, _atk, _verb, outcome)
        local enc = ensureActive()
        enc.avoided = enc.avoided + 1
        local o = tostring(outcome):lower()
        local t = o:find('dodge') and 'dodge' or o:find('parry') and 'parry'
            or o:find('riposte') and 'riposte' or o:find('block') and 'block'
            or (o:find('magical skin') or o:find('absorb')) and 'rune' or 'miss'
        enc.avoidBy[t] = (enc.avoidBy[t] or 0) + 1
    end)

    -- deaths
    reg('cmp_kill_you', "You have slain #1#!#*#", function(_, target)
        local enc = ensureActive()
        if #enc.events < M.maxEvents then
            enc.events[#enc.events + 1] = { t = enc.lastClock - enc.startClock, source = cb.playerName(),
                target = target, ability = 'Kill', kind = 'kill', amount = 0, outcome = 'kill' }
        end
    end)
    -- most kills are made by the tank, not us: record the same shape as
    -- cmp_kill_you but only when a fight is already open (a bystander kill
    -- line must never open or refresh an encounter on its own), and never
    -- through record() -- this must not touch damage rollups.
    reg('cmp_kill_other', "#1# has been slain by #2#!#*#", function(_, target, killer)
        if not active then return end
        local enc = ensureActive(false)
        if #enc.events < M.maxEvents then
            enc.events[#enc.events + 1] = { t = enc.lastClock - enc.startClock, source = killer,
                target = target, ability = 'Kill', kind = 'kill', amount = 0, outcome = 'kill' }
        end
    end)
    -- my death: chat-line entry points into M.recordDeath (deduped there)
    reg('cmp_death_me', "You have been slain by #1#!#*#", function(_, killer) M.recordDeath(killer) end)
    reg('cmp_death_me2', "You died.#*#", function() M.recordDeath(nil) end)

    -- my buff fading: "Your <Spell> spell has worn off." (the "worn off of <mob>"
    -- form for buffs on others does not match: the pattern needs "off." right
    -- after "worn"). Logged only while a fight is open; never opens one.
    reg('cmp_wornoff', "Your #1# spell has worn off.#*#", function(_, spell)
        if not active then return end
        local enc = ensureActive(false)
        if #enc.events < M.maxEvents then
            enc.events[#enc.events + 1] = { t = now() - enc.startClock, source = me, target = me,
                ability = spell, kind = 'wornoff', amount = 0, crit = false, outcome = 'fade' }
        end
    end)
end

function M.unregisterEvents()
    for _, name in ipairs(registered) do pcall(mq.unevent, name) end
    registered = {}
end

-- ── public API ─────────────────────────────────────────────────────────
---@param opts table  { onFinalize, getPet, getZone, isRaidTarget, playerName, getMaster, getWeapons, spellDuration, getTarget, getTargetPct, freezeBlackBox }
function M.init(opts)
    opts = opts or {}
    for k, v in pairs(opts) do cb[k] = v end
    M.registerEvents()
end

-- Forward-declared: defined below (after M.primaryTarget), assigned there.
local sampleMobHp

-- Pump events and close the encounter if the inactivity gap elapsed. Call once
-- per main-loop tick (outside any ImGui callback).
function M.tick()
    mq.doevents()
    sampleMobHp()
    if active and (now() - active.lastClock) >= M.timeoutSec then
        finalize()
    end
end

-- Force-close the active encounter (/reload, shutdown). Also drops the pet-owner
-- cache, since pet names get recycled across zones.
function M.flush()
    if active then finalize() end
    petCache = {}
end

-- Zone change: close the active fight, then reset the Overall accumulator so it
-- reflects the new zone.
function M.zoned()
    if active then finalize() end
    petCache = {}
    resetOverall()
end

function M.shutdown()
    M.flush()
    M.unregisterEvents()
end

-- Is a fight currently live?
function M.inCombat() return active ~= nil end

-- Most-damaged target of the active encounter (nil when idle).
function M.primaryTarget()
    if not active then return nil end
    local best, name = -1, nil
    for n, dmg in pairs(active.targets) do
        if dmg > best then best, name = dmg, n end
    end
    return name
end

-- 1 Hz mob max-HP sampler: maxHP ~= damage dealt / (HP% lost / 100), weighted by
-- the %-delta so a big drop counts more than a 1% flicker. A rise > 2% (heal,
-- regen, target swap) re-anchors instead of producing a negative estimate.
--
-- Throttle state (hpLastSample) lives on the encounter, not as a module local:
-- a module-level clock would carry the previous (finalized) encounter's last
-- sample time into a brand-new encounter and could wrongly skip its first tick.
function sampleMobHp()
    if not active or not cb.getTargetPct then return end
    local enc = active
    local t = mq.gettime()
    if enc.hpLastSample and (t - enc.hpLastSample) < 1000 then return end
    enc.hpLastSample = t
    local name = M.primaryTarget()
    if not name then return end
    local ok, pct = pcall(cb.getTargetPct, name)
    pct = ok and tonumber(pct) or nil
    if not pct then return end
    local dmg = enc.targets[name] or 0
    if enc.hpAnchorPct == nil or enc.hpEst.target ~= name or pct > enc.hpAnchorPct + 2 then
        -- (re)anchor: first sample of the encounter, primary target switched, or
        -- HP% rose more than 2% (heal/regen). Always anchor at the CURRENT
        -- cumulative damage to this target — sampleMobHp runs after record() has
        -- already processed this tick's damage lines, so the %HP just read
        -- already reflects that damage. Anchoring the first sample at 0 instead
        -- would charge already-spent damage to the next %-drop and overestimate
        -- max HP on the first interval of every fight.
        enc.hpEst.target = name
        enc.hpAnchorPct, enc.hpAnchorDmg = pct, dmg
        return
    end
    local drop = enc.hpAnchorPct - pct
    if drop < 1 then return end
    local dealt = dmg - enc.hpAnchorDmg
    if dealt > 0 then
        -- weight is the %-drop; (dealt*100/drop)*drop reduces to dealt*100 but is
        -- written out so the per-sample max-HP estimate (dealt*100/drop) is visible
        -- before it's folded into the weighted sum.
        enc.hpEst.sum = enc.hpEst.sum + dealt * 100
        enc.hpEst.weight = enc.hpEst.weight + drop
    end
    enc.hpAnchorPct, enc.hpAnchorDmg = pct, dmg
end

-- Snapshot the fight to display: the live encounter if any, else the last one.
-- Returns a display-shaped table (or nil if nothing yet).
--
-- Rebuilding is O(events + abilities); the live UI calls this every frame, so we
-- cache and rebuild at most ~5x/sec (and immediately when the active encounter
-- identity changes — fight start/end). Duration/DPS thus tick 5x/sec, which is
-- imperceptible but keeps the render cheap on long/raid fights.
local snapCache = { t = 0, data = nil, ref = false }

-- Build the display snapshot from an encounter. `fixedDuration`/`nameOverride`
-- let the zone-wide Overall accumulator reuse this (its duration is summed fight
-- time, not wall clock).
local function buildSnapshot(enc, live, fixedDuration, nameOverride)
    local duration = fixedDuration or math.max(1.0, enc.lastClock - enc.startClock)
    local total = enc.playerDmg + enc.petDmg + enc.otherDmg

    local primary, best = nil, -1
    for name, dmg in pairs(enc.targets) do if dmg > best then best, primary = dmg, name end end

    -- sources sorted by damage (only outgoing hits ever create a source entry)
    local sources = {}
    for name, s in pairs(enc.sources) do
        sources[#sources + 1] = { name = name, total = s.total, mine = s.mine, isPet = s.isPet,
            dps = s.total / duration, activeSec = s.activeSec or 0,
            activeDps = s.total / math.max(1, s.activeSec or 1) }
    end
    table.sort(sources, function(a, b) return a.total > b.total end)

    -- per-source ability breakdown, split damage vs heal so the damage view
    -- never shows heal rows and the healing view never shows damage rows.
    local bySource, healBySource = {}, {}
    for _, a in pairs(enc.abilities) do
        if a.total > 0 or a.misses > 0 or a.resists > 0 or (a.over or 0) > 0 then
            local dst = (a.kind == 'heal') and healBySource or bySource
            local arr = dst[a.source]
            if not arr then arr = {}; dst[a.source] = arr end
            arr[#arr + 1] = a
        end
    end
    for _, arr in pairs(bySource) do table.sort(arr, function(a, b) return a.total > b.total end) end
    for _, arr in pairs(healBySource) do table.sort(arr, function(a, b) return a.total > b.total end) end
    local me = cb.playerName()
    local abilities = bySource[me] or {}

    -- HoT tick efficiency: expected ticks = casts * ticks-per-cast; wasted =
    -- expected - logged (silent full-overheal ticks that never print a line).
    -- Only meaningful where we have cast data (our own HoTs), so it self-scopes.
    for src, arr in pairs(healBySource) do
        for _, a in ipairs(arr) do
            if (a.hotDur or 0) >= 2 then
                local c = enc.casts[src .. '|' .. a.ability]
                local casts = c and c.casts or 0
                if casts > 0 then
                    a.expectedTicks = casts * a.hotDur
                    a.wastedTicks = math.max(0, a.expectedTicks - (a.ticks or 0))
                    local avgTick = (a.total + (a.over or 0)) / math.max(1, a.ticks or 0)
                    a.wastedHeal = a.wastedTicks * avgTick -- estimated silent overheal
                end
            end
        end
    end

    -- healer rollup for the healing meter, each with its target distribution
    local healSources = {}
    for name, h in pairs(enc.healBy) do
        local combined = h.total + h.over
        local targets = {}
        for tn, tv in pairs(h.targets or {}) do
            targets[#targets + 1] = { name = tn, total = tv.total, over = tv.over }
        end
        table.sort(targets, function(a, b) return a.total > b.total end)
        healSources[#healSources + 1] = {
            name = name, total = h.total, over = h.over, hps = h.total / duration,
            activeSec = h.activeSec, activeHps = h.total / math.max(1, h.activeSec),
            overpct = combined > 0 and (h.over / combined * 100) or 0, mine = isMe(name),
            targets = targets,
        }
    end
    table.sort(healSources, function(a, b) return a.total > b.total end)

    -- healing received per target (across all healers)
    local healReceived = {}
    for tn, tv in pairs(enc.healRecv) do
        healReceived[#healReceived + 1] = { name = tn, total = tv.total, over = tv.over }
    end
    table.sort(healReceived, function(a, b) return a.total > b.total end)

    -- per-second dps line
    local series = {}
    local maxSec = math.floor(duration)
    for sec = 0, maxSec do series[#series + 1] = { t = sec, dps = enc.buckets[sec] or 0 } end

    local snap = {
        live       = live,
        fightCount = enc.fightCount, -- set only on the Overall accumulator
        name       = nameOverride or primary or 'Combat',
        zone       = enc.zone,
        duration   = duration,
        total      = total,
        dps        = total / duration,
        playerDps  = (enc.playerDmg + enc.petDmg) / duration,
        playerDmg  = enc.playerDmg,
        petDmg     = enc.petDmg,
        incoming   = enc.incoming,
        incomingDps = enc.incoming / duration,
        avoidance  = (function()
            local swings = enc.incMeleeHits + enc.avoided
            return {
                swings = swings, landed = enc.incMeleeHits, avoided = enc.avoided,
                pct = swings > 0 and (enc.avoided / swings * 100) or 0, by = enc.avoidBy,
            }
        end)(),
        incomingSources = (function()
            local arr = {}
            for name, tot in pairs(enc.incomingBy) do
                arr[#arr + 1] = { name = name, total = tot, dps = tot / duration }
            end
            table.sort(arr, function(a, b) return a.total > b.total end)
            return arr
        end)(),
        avoided    = enc.avoided,
        deaths     = enc.deaths,
        healTotal  = enc.healTotal,
        overheal   = enc.overheal,
        eventCount = #enc.events,
        sources    = sources,
        abilities  = abilities,
        abilitiesBySource = bySource,
        healSources = healSources,
        healReceived = healReceived,
        healAbilitiesBySource = healBySource,
        kindSeriesBySource = enc.kindSeries,
        casts      = buildCasts(enc),
        events     = enc.events,
        series     = series,
        is_raid    = primary and cb.isRaidTarget(primary) or false,
    }
    return snap
end

function M.snapshot()
    local nowMs = mq.gettime()
    if snapCache.data ~= nil and snapCache.ref == active and (nowMs - snapCache.t) < 180 then
        return snapCache.data
    end
    local enc, live
    if active then enc, live = active, true else enc, live = last and last._enc or nil, false end
    if not enc then
        snapCache.data, snapCache.ref, snapCache.t = false, active, nowMs
        return nil
    end
    local snap = buildSnapshot(enc, live)
    snapCache.data, snapCache.ref, snapCache.t = snap, active, nowMs
    return snap
end

-- Zone-wide totals across all fights since the last zone change. Cached; only
-- rebuilds when a fight merges in (overallRev changes), not every frame.
local overallCache = { rev = -1, data = nil }
function M.overallSnapshot()
    if not overall or (overall.fightCount or 0) == 0 then return nil end
    if overallCache.rev == overallRev then return overallCache.data end
    local snap = buildSnapshot(overall, false, overall.fightTime, 'Overall - ' .. (overall.zone or 'zone'))
    overallCache.rev, overallCache.data = overallRev, snap
    return snap
end

M._recordForTest = record

return M
