-- companion/postmortem.lua
-- Pure death analyzer: black-box samples + the encounter's events around the
-- death -> a verdict (cause class, notable moments, breakdowns, narrative).
-- No mq dependency. Runs in the main loop (refreshHistory / onFinalize via
-- stamp), never inside the ImGui callback.

local M = {}

M.HEALER_CLASSES = { CLR = true, DRU = true, SHM = true }
M.CC_ORDER = { 'stun', 'mez', 'fear', 'root', 'snare' }
M.CC_LABEL = { stun = 'stunned', mez = 'mezzed', fear = 'feared', root = 'rooted', snare = 'snared' }
M.DAMAGE_KINDS = { melee = true, nuke = true, dot = true, ds = true, spell = true }
M.ATTACK_KINDS = { melee = true, nuke = true, spell = true }
M.CAUSE_LABEL = {
    burst = 'burst', sustained = 'outdamaged', noheals = 'no heals', cc = 'crowd controlled',
    aggro = 'pulled aggro', overwhelmed = 'overwhelmed', environmental = 'environmental',
    dot = 'damage over time', unknown = 'unknown',
}

local function comma(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    return (s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

local function isMe(name, playerName)
    if not name then return false end
    local n = tostring(name):lower()
    return n == tostring(playerName or ''):lower() or n == 'you' or n == 'yourself'
end

local function flagSet(str)
    local s = {}
    for f in tostring(str or ''):gmatch('[^,]+') do s[f] = true end
    return s
end

local function sortDesc(arr) table.sort(arr, function(a, b) return a.total > b.total end) return arr end

-- Events re-based to death-relative seconds (rel <= 0), within the window.
local function windowEvents(events, deathT, window)
    local out = {}
    for _, e in ipairs(events or {}) do
        local rel = (e.t or 0) - deathT
        if rel >= -window and rel <= 0.01 then
            local c = {}
            for k, v in pairs(e) do c[k] = v end
            c.rel = rel
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return out
end

local function isIncomingHit(e, playerName)
    return isMe(e.target, playerName) and (e.outcome == 'hit' or e.outcome == nil)
        and M.DAMAGE_KINDS[e.kind or ''] and (e.amount or 0) > 0
end

local function incomingIn(evs, secs, playerName)
    local r = { total = 0, bySource = {}, byKind = {}, attackers = 0 }
    local src, kind, atk = {}, {}, {}
    for _, e in ipairs(evs) do
        if e.rel >= -secs and isIncomingHit(e, playerName) then
            local s = e.source or '?'
            r.total = r.total + e.amount
            src[s] = (src[s] or 0) + e.amount
            kind[e.kind] = (kind[e.kind] or 0) + e.amount
            if M.ATTACK_KINDS[e.kind] then atk[s] = true end
        end
    end
    for n, v in pairs(src) do
        r.bySource[#r.bySource + 1] = { name = n, total = v, pct = r.total > 0 and v / r.total * 100 or 0 }
    end
    for n, v in pairs(kind) do
        r.byKind[#r.byKind + 1] = { name = n, total = v, pct = r.total > 0 and v / r.total * 100 or 0 }
    end
    sortDesc(r.bySource); sortDesc(r.byKind)
    for _ in pairs(atk) do r.attackers = r.attackers + 1 end
    return r
end

local function healsIn(evs, secs, playerName)
    local r = { total = 0, byHealer = {} }
    local by = {}
    for _, e in ipairs(evs) do
        if e.rel >= -secs and e.kind == 'heal' and isMe(e.target, playerName) and (e.amount or 0) > 0 then
            r.total = r.total + e.amount
            by[e.source or '?'] = (by[e.source or '?'] or 0) + e.amount
        end
    end
    for n, v in pairs(by) do r.byHealer[#r.byHealer + 1] = { name = n, total = v } end
    sortDesc(r.byHealer)
    return r
end

local function hpSeries(samples, window)
    local out = {}
    for _, s in ipairs(samples) do
        if (s.t or 0) >= -window and s.hp ~= nil then out[#out + 1] = { t = s.t, hp = s.hp } end
    end
    return out
end

-- HP at (the last sample at or before) death-relative time t.
local function hpAt(series, t)
    local v = nil
    for _, p in ipairs(series) do
        if p.t <= t then v = p.hp else break end
    end
    return v
end

-- Largest HP% drop inside any `span`-second stretch of the last `secs` seconds.
local function maxDrop(series, secs, span)
    local best, from, to = 0, nil, nil
    for i = 1, #series do
        if series[i].t >= -secs then
            for j = i + 1, #series do
                if series[j].t - series[i].t > span then break end
                local d = series[i].hp - series[j].hp
                if d > best then best, from, to = d, series[i], series[j] end
            end
        end
    end
    return best, from, to
end

local function healerReasons(last)
    local out = {}
    for _, m in ipairs(last and last.group or {}) do
        if M.HEALER_CLASSES[m.cls] then
            if m.flag == 'dead' then out[#out + 1] = m.name .. ' was dead'
            elseif m.flag == 'zone' or m.flag == 'offline' then out[#out + 1] = m.name .. ' was not in the zone'
            elseif (m.dist or 0) > 100 then out[#out + 1] = string.format('%s was %d away', m.name, math.floor(m.dist))
            elseif (m.mana or 100) < 10 then out[#out + 1] = m.name .. ' was out of mana' end
        end
    end
    return out
end

-- Healer cast failures (fizzle/interrupt) inside the window, by healer name.
local function healerCastFails(evs, last, playerName)
    local healers = {}
    for _, m in ipairs(last and last.group or {}) do if M.HEALER_CLASSES[m.cls] then healers[m.name] = 0 end end
    local out = {}
    for _, e in ipairs(evs) do
        if e.kind == 'castfail' and e.source and healers[e.source] then healers[e.source] = healers[e.source] + 1 end
    end
    for name, n in pairs(healers) do
        if n >= 2 then out[#out + 1] = string.format('%s had %d spells fizzle/interrupted', name, n) end
    end
    table.sort(out)
    return out
end

-- ── moments ───────────────────────────────────────────────────────────
local function buildMoments(samples, evs, series, playerName, window, killer)
    local ms = {}
    local function add(t, kind, text, color) ms[#ms + 1] = { t = t, kind = kind, text = text, color = color } end

    -- HP threshold crossings (first time each)
    local crossed = {}
    local prev = nil
    for _, p in ipairs(series) do
        for _, thr in ipairs({ 75, 50, 25 }) do
            if not crossed[thr] and prev and prev >= thr and p.hp < thr then
                crossed[thr] = true
                add(p.t, 'hp', string.format('HP fell below %d%%', thr), 'enemy')
            end
        end
        prev = p.hp
    end

    -- sample-derived: CC onset, aggro, ToT, buff drops, group state changes
    local seenFlag, seenAggro, seenTot = {}, false, false
    local memberFlag, memberOom, memberFar = {}, {}, {}
    for _, s in ipairs(samples) do
        if (s.t or 0) >= -window then
            local fs = flagSet(s.flags)
            for _, f in ipairs(M.CC_ORDER) do
                if fs[f] and not seenFlag[f] then seenFlag[f] = true; add(s.t, 'cc', 'You were ' .. M.CC_LABEL[f], 'spell') end
            end
            if (s.aggro or 0) >= 90 and not seenAggro then
                seenAggro = true
                add(s.t, 'aggro', string.format('Aggro reached %d%%', math.floor(s.aggro)), 'gold')
            end
            if isMe(s.tot, playerName) and not seenTot then
                seenTot = true
                add(s.t, 'aggro', (s.target or 'The mob') .. ' turned on you', 'gold')
            end
            for _, b in ipairs(s.buffsDropped or {}) do add(s.t, 'buff', b .. ' faded', 'dot') end
            for _, m in ipairs(s.group or {}) do
                local pf = memberFlag[m.name]
                if pf ~= nil and pf ~= m.flag and m.flag ~= '' then
                    local what = m.flag == 'dead' and ' died' or (m.flag == 'zone' and ' left the zone' or ' went offline')
                    add(s.t, 'group', m.name .. what, 'resist')
                end
                memberFlag[m.name] = m.flag
                if M.HEALER_CLASSES[m.cls] then
                    if (m.mana or 100) < 10 and not memberOom[m.name] then
                        memberOom[m.name] = true; add(s.t, 'group', m.name .. ' (healer) out of mana', 'resist')
                    end
                    if (m.dist or 0) > 100 and not memberFar[m.name] then
                        memberFar[m.name] = true; add(s.t, 'group', string.format('%s (healer) out of range (%d)', m.name, math.floor(m.dist)), 'resist')
                    end
                end
            end
        end
    end

    -- event-derived: heals on me, my buff fades, my cast failures, killing blow, death
    local blow = nil
    for _, e in ipairs(evs) do
        if e.kind == 'heal' and isMe(e.target, playerName) and (e.amount or 0) > 0 then
            add(e.rel, 'heal', string.format('%s healed you for %s (%s)', e.source or '?', comma(e.amount), e.ability or '?'), 'green')
        elseif e.kind == 'wornoff' then
            add(e.rel, 'buff', (e.ability or '?') .. ' wore off', 'dot')
        elseif e.kind == 'castfail' and isMe(e.source, playerName) then
            add(e.rel, 'cast', string.format('Your %s %s', e.ability or '?', e.outcome == 'interrupt' and 'was interrupted' or (e.outcome == 'blocked' and 'did not take hold' or 'fizzled')), 'gold')
        elseif isIncomingHit(e, playerName) then
            blow = e
        end
    end
    if blow then
        add(blow.rel, 'blow', string.format('Killing blow: %s for %s (%s)', blow.source or '?', comma(blow.amount), blow.ability or '?'), 'resist')
    end
    add(0, 'death', 'You died' .. ((killer and killer ~= '?') and (' - killed by ' .. killer) or ''), 'resist')

    table.sort(ms, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return (a.kind == 'death' and 1 or 0) < (b.kind == 'death' and 1 or 0)
    end)
    return ms
end

-- ── narrative ─────────────────────────────────────────────────────────
local function topNames(list, n)
    local out = {}
    for i, s in ipairs(list) do
        if i > n then break end
        out[#out + 1] = s.name
    end
    return #out > 0 and table.concat(out, ', ') or 'nothing'
end

local function healSentence(heals10)
    if heals10.total <= 0 then return 'No heals landed in the last 10s.' end
    local parts = {}
    for i, h in ipairs(heals10.byHealer) do
        if i > 3 then break end
        parts[#parts + 1] = string.format('%s %s', h.name, comma(h.total))
    end
    return 'Heals landed in the last 10s: ' .. table.concat(parts, ', ') .. '.'
end

-- ── public ────────────────────────────────────────────────────────────
---@param input table { samples, events, deathT, playerName, killer?, window? }
---@return table verdict
function M.analyze(input)
    local samples    = input.samples or {}
    local playerName = input.playerName or 'You'
    local window     = input.window or 60
    local deathT     = input.deathT or 0
    local evs        = windowEvents(input.events, deathT, window)
    local series     = hpSeries(samples, window)
    local last       = samples[#samples]
    local inc10      = incomingIn(evs, 10, playerName)
    local inc30      = incomingIn(evs, 30, playerName)
    local heals10    = healsIn(evs, 10, playerName)

    -- killer: row/record first, then the death event, then the last hit
    local killer = input.killer
    if not killer or killer == '?' then
        for _, e in ipairs(evs) do if e.kind == 'death' and e.source and e.source ~= '?' then killer = e.source end end
    end
    if not killer or killer == '?' then
        for i = #evs, 1, -1 do if isIncomingHit(evs[i], playerName) then killer = evs[i].source; break end end
    end
    killer = killer or '?'

    local hpNow  = series[#series] and series[#series].hp or nil
    local hp10   = hpAt(series, -10) or hpNow
    local drop10 = (hp10 and hpNow) and (hp10 - hpNow) or 0
    local burst, bFrom, bTo = maxDrop(series, 10, 3)

    -- CC in >= 2 of the last 6 samples
    local ccCount, ccLabel = 0, nil
    for i = math.max(1, #samples - 5), #samples do
        local fs = flagSet(samples[i].flags)
        for _, f in ipairs(M.CC_ORDER) do
            if fs[f] then ccCount = ccCount + 1; ccLabel = ccLabel or M.CC_LABEL[f]; break end
        end
    end

    local reasons = healerReasons(last)
    for _, r in ipairs(healerCastFails(evs, last, playerName)) do reasons[#reasons + 1] = r end

    -- aggro: a tank exists (not me) and my aggro/ToT flipped to me in the last 15s
    local tank = last and last.tank or nil
    local iAmTank = tank ~= nil and isMe(tank, playerName)
    local prevLow, prevNotMe, aggroGain, totGain = nil, nil, false, false
    for _, s in ipairs(samples) do
        if (s.t or 0) >= -window then
            local low = (s.aggro or 0) < 100
            local notMe = not isMe(s.tot, playerName)
            if prevLow == true and not low and s.t >= -15
                and s.aggro2Name ~= nil and tostring(s.aggro2Name):lower() == tostring(tank or ''):lower() then
                aggroGain = true
            end
            if prevNotMe == true and not notMe and s.t >= -15 then totGain = true end
            prevLow, prevNotMe = low, notMe
        end
    end
    local pulledAggro = tank ~= nil and not iAmTank and (aggroGain or totGain)

    local dotPct = 0
    for _, k in ipairs(inc10.byKind) do if k.name == 'dot' then dotPct = k.pct end end

    local cause
    if drop10 >= 30 and inc10.total == 0 then cause = 'environmental'
    elseif ccCount >= 2 and inc10.total > 0 then cause = 'cc'
    elseif burst >= 40 then cause = 'burst'
    elseif inc10.total > 0 and heals10.total < inc10.total * 0.25 and #reasons > 0 then cause = 'noheals'
    elseif pulledAggro and inc10.total > 0 then cause = 'aggro'
    elseif inc10.attackers >= 3 then cause = 'overwhelmed'
    elseif inc10.total > 0 and dotPct >= 60 then cause = 'dot'
    elseif inc10.total > 0 then cause = 'sustained'
    else cause = 'unknown' end

    local top = topNames(inc10.bySource, 2)
    local n1
    if cause == 'environmental' then
        n1 = string.format('Died with no attackers: lost %d%% HP in the last 10s with no damage lines (fall, drowning, or an unlogged source).', math.floor(drop10 + 0.5))
    elseif cause == 'cc' then
        n1 = string.format('Died while %s: took %s from %s over the last 10s and could not act.', ccLabel or 'crowd controlled', comma(inc10.total), top)
    elseif cause == 'burst' then
        n1 = string.format('Died to a %s burst from %s in %.1fs (%d%% -> %d%%).', comma(inc10.total), top,
            (bFrom and bTo) and (bTo.t - bFrom.t) or 0, bFrom and math.floor(bFrom.hp + 0.5) or 0, bTo and math.floor(bTo.hp + 0.5) or 0)
    elseif cause == 'noheals' then
        n1 = string.format('Outdamaged with no healing: %s taken vs %s healed in the last 10s. %s.', comma(inc10.total), comma(heals10.total), table.concat(reasons, '; '))
    elseif cause == 'aggro' then
        n1 = string.format('Pulled aggro from %s (tank) and was killed by %s: %s taken in the last 10s.', tank or '?', top, comma(inc10.total))
    elseif cause == 'overwhelmed' then
        n1 = string.format('Overwhelmed by %d attackers: %s taken in the last 10s (top: %s).', inc10.attackers, comma(inc10.total), top)
    elseif cause == 'dot' then
        n1 = string.format('Died to damage over time: %d%% of the %s taken in the last 10s was DoT (%s).', math.floor(dotPct + 0.5), comma(inc10.total), top)
    elseif cause == 'sustained' then
        n1 = string.format('Outdamaged by %s: %s taken vs %s healed over the last 10s.', top, comma(inc10.total), comma(heals10.total))
    else
        n1 = string.format('Died with no damage recorded in the last %ds; killer: %s.', window, killer)
    end
    local narrative = { n1 }
    if cause ~= 'noheals' and cause ~= 'sustained' and cause ~= 'unknown' then narrative[2] = healSentence(heals10) end

    -- sparkline ticks: incoming hits + heals within the window
    local ticks = {}
    for _, e in ipairs(evs) do
        if isIncomingHit(e, playerName) then ticks[#ticks + 1] = { t = e.rel, kind = 'dmg', amount = e.amount }
        elseif e.kind == 'heal' and isMe(e.target, playerName) and (e.amount or 0) > 0 then ticks[#ticks + 1] = { t = e.rel, kind = 'heal', amount = e.amount } end
    end

    return {
        cause = cause, killer = killer, narrative = narrative,
        hpSeries = series, moments = buildMoments(samples, evs, series, playerName, window, killer), ticks = ticks,
        incoming10 = inc10, incoming30 = inc30, heals10 = heals10, attackers = inc10.attackers,
        groupAtDeath = last and last.group or {}, stateAtDeath = last and last.flags or '',
        healerReasons = reasons, hpNow = hpNow, hp10 = hp10,
    }
end

-- Cache cause/narrative/hp_curve on each death record before persistence.
---@param fight table  from combat.buildFight (has events + deaths_detail)
---@param playerName string
function M.stamp(fight, playerName)
    for _, d in ipairs(fight.deaths_detail or {}) do
        local ok, v = pcall(M.analyze, { samples = d.samples, events = fight.events, deathT = d.t,
            playerName = d.player or playerName, killer = d.killer }) -- d.player: a peer's death (recorder)
        if ok and v then
            d.cause = v.cause
            d.narrative = table.concat(v.narrative or {}, ' ')
            local parts = {}
            for _, p in ipairs(v.hpSeries or {}) do
                parts[#parts + 1] = string.format('%.1f:%d', p.t, math.floor((p.hp or 0) + 0.5))
            end
            d.hp_curve = table.concat(parts, ',')
        else
            d.cause, d.narrative, d.hp_curve = 'unknown', '', ''
        end
    end
    return fight
end

return M
