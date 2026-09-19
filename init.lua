-- companion/init.lua
-- Companion: a deep fight parser + session-history overlay for MacroQuest, in
-- the EQ Legends Companion visual language.
--   /lua run companion          start
--   /companion [show|hide|reset] control the window
--
-- Data flow: combat.lua captures the chat combat feed and segments it into
-- encounters; each finished encounter is persisted to companion.db (lsqlite3);
-- ui.lua renders the live fight and the history browser. All DB work and event
-- pumping happen here in the main loop — never inside the ImGui callback.

local mq     = require('mq')
local Combat = require('companion.combat')
local DB     = require('companion.db')
local UI     = require('companion.ui')
local Group  = require('companion.group')
local BlackBox   = require('companion.blackbox')
local Postmortem = require('companion.postmortem')
local Smartheal  = require('companion.smartheal')

-- Launch arguments: `/lua run companion mini` opens straight into the compact
-- meter; `hide` starts hidden; `full` forces the research console. Applied after
-- loadPrefs so an explicit arg wins over the persisted window mode.
local launchArgs = { ... }
local function hasArg(name)
    for _, a in ipairs(launchArgs) do if tostring(a):lower() == name then return true end end
    return false
end

-- ── startup identity ───────────────────────────────────────────────────
local function tlo(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil and v ~= 'NULL' then return v end
    return default
end

local playerName   = tlo(function() return mq.TLO.Me.Name() end, 'You')
local server       = tlo(function() return mq.TLO.EverQuest.Server() end, 'unknown')

local function aaTotal()
    local total = tlo(function() return mq.TLO.Me.AAPointsTotal() end, nil)
    if total then return total end
    return tlo(function() return mq.TLO.Me.AAPointsSpent() end, 0) + tlo(function() return mq.TLO.Me.AAPoints() end, 0)
end

-- ── database ───────────────────────────────────────────────────────────
local dbPath = string.format('%s/companion.db', mq.configDir)
local db = DB.new(dbPath)
if not db then
    printf('\ar[companion] could not open %s - aborting.', dbPath)
    return
end
local sessionStart = os.time()
-- The session row (and with it every write) starts only when this character
-- records fights: see UI.recording() / the `norecord` launch arg below.
db:setIdentity(server, playerName)

-- ── combat engine ──────────────────────────────────────────────────────
local fightsThisSession = 0
local needRefresh       = true

-- always-on flight recorder (2 Hz, last 90 s) frozen onto the fight on death
local readers  = BlackBox.tloReaders()
local blackbox = BlackBox.new(readers, { hz = 2, seconds = 90 })

Combat.init({
    playerName   = function() return playerName end,
    onMobDps     = function(rows)
        -- MobDPS_<server>_<me>.ini: [zone shortname] <mob name>=<ema dps>. Written by every
        -- box from its own incoming damage; muleassist's AutoCharmPick on the charmer reads
        -- the TANK's file (MainAssist) to rank charm candidates by how hard they hit.
        local zone = tlo(function() return mq.TLO.Zone.ShortName() end, '')
        local server = tlo(function() return mq.TLO.EverQuest.Server() end, '')
        if not zone or zone == '' or not server or server == '' then return end
        local file = string.format('MobDPS_%s_%s.ini', server, playerName)
        for _, r in ipairs(rows) do
            local nm = tostring(r.name)
            if not nm:find('`s pet', 1, true) and not nm:find("'s pet", 1, true) and not nm:find(',', 1, true) then
                local old = tonumber(tlo(function() return mq.TLO.Ini(file, zone, nm)() end, nil))
                local v = old and (0.7 * old + 0.3 * r.dps) or r.dps
                mq.cmdf('/ini "%s" "%s" "%s" "%.1f"', file, zone, nm, v)
            end
        end
    end,
    getPet       = function() return tlo(function() return mq.TLO.Me.Pet.CleanName() end, nil) end,
    getTarget    = function() return tlo(function() return mq.TLO.Target.CleanName() end, '') end,
    getTargetPct = function(name)
        return tlo(function() return mq.TLO.Spawn('=' .. name).PctHPs() end, nil)
    end,
    getZone      = function() return tlo(function() return mq.TLO.Zone.ShortName() end, '') end, -- short name carries the difficulty tier suffix (drachnidhive_70h); the long name does not
    isRaidTarget = function(name)
        return tlo(function() return mq.TLO.Spawn('=' .. name).Named() end, false) == true
    end,
    getMaster    = function(name)
        -- owner of a bare-named pet; nil for players/mobs or pets out of range
        return tlo(function() return mq.TLO.Spawn('=' .. name).Master.CleanName() end, nil)
    end,
    getWeapons   = function()
        -- weapon set equipped at fight start, for per-weapon-set DPS comparison
        return tlo(function() return mq.TLO.Me.Inventory('mainhand').Name() end, nil),
            tlo(function() return mq.TLO.Me.Inventory('offhand').Name() end, nil)
    end,
    spellDuration = function(name)
        -- buff duration in ticks (6s each), used to infer silent HoT overheal.
        -- Pattern from sidekick-next/utils/combat_spell_executor.lua: prefer
        -- Me.Spell().MyDuration (your focus/AA-adjusted), fall back to base Duration.
        return tlo(function()
            local mine = mq.TLO.Me.Spell(name)
            local d = 0
            if mine and mine() then d = tonumber(mine.MyDuration()) or 0 end
            if d <= 0 then d = tonumber(mq.TLO.Spell(name).Duration()) or 0 end
            return d
        end, 0) or 0
    end,
    freezeBlackBox = function(nowMs) return blackbox:freeze(nowMs) end,
    onFinalize   = function(fight)
        Postmortem.stamp(fight, playerName) -- cache cause/narrative for the list + export
        Smartheal.stamp(fight)              -- sh_* columns + decision rows; resets the bucket
        if UI.recording() then
            db:saveFight(fight)
            fightsThisSession = fightsThisSession + 1
        end
        needRefresh = true
    end,
    -- a fresh companion peer reports itself first-person (Group.onPeerEvent ->
    -- Combat.ingestPeerEvent), so our third-person parse of it is dropped
    isPeerSource = function(name) return Group.isFreshPeerSource(name) end,
})

Group.init(playerName)
-- SmartHeals feed: ma_healbridge.lua (sidekick-next) fans its decisions to this
-- mailbox on the local box. Absent bridge = no messages = cards stay hidden.
Smartheal.setPlayer(playerName)
do
    local okA, actorsLib = pcall(require, 'actors')
    if okA and actorsLib then
        pcall(actorsLib.register, 'companion_smartheal', function(message)
            local c = message()
            if type(c) == 'table' then Smartheal.onMessage(c) end
        end)
    end
end
-- Bridge the parser to the event mailbox so same-machine subscribers
-- (e.g. sidekick-next) can consume companion's parse output. The hook fires
-- once per normalized event at record() entry; Group.broadcastEvent filters
-- out misses/zero-amount and rides its own actor mailbox.
Combat.setEventHook(function(ev) Group.broadcastEvent(ev) end)
Group.onPeerEvent = function(payload) Combat.ingestPeerEvent(payload) end
UI.setup({ combat = Combat, db = db, playerName = playerName, group = Group })

-- Broadcast my current-fight summary to the group (~1 Hz, live fights only).
local function broadcastDps()
    local snap = Combat.snapshot()
    if not snap or not snap.live then return end
    local dur = math.max(1, snap.duration)
    Group.broadcast({
        playerDmg = snap.playerDmg, playerDps = snap.playerDmg / dur,
        petName   = tlo(function() return mq.TLO.Me.Pet.CleanName() end, nil),
        petDmg    = snap.petDmg, petDps = snap.petDmg / dur,
        healTotal = snap.healTotal or 0, healDps = (snap.healTotal or 0) / dur,
        target    = snap.name, live = snap.live,
    })
end

-- ── session snapshot for the history tiles ─────────────────────────────
local function sessionMeta()
    return {
        dur    = os.time() - sessionStart,
        fights = fightsThisSession,
        level  = tlo(function() return mq.TLO.Me.Level() end, nil),
        aa     = aaTotal(),
    }
end

-- ── commands ───────────────────────────────────────────────────────────
local running = true
mq.bind('/companion', function(arg)
    arg = (arg or ''):lower()
    if arg == 'hide' then
        UI.setOpen(false)
    elseif arg == 'show' then
        UI.setOpen(true)
    elseif arg == 'stop' or arg == 'exit' then
        running = false
    elseif arg == 'mini' then
        UI.toggleMini()
    elseif arg == 'export run' or arg == 'exportrun' then
        UI.exportRun()
    elseif arg == 'export' then
        UI.exportLive()
    elseif arg == 'death' then
        UI.exportDeath()
    elseif arg == 'reset' then
        Combat.flush()
        needRefresh = true
        printf('\ag[companion]\ax active fight flushed.')
    else
        UI.toggle()
    end
end)

UI.loadPrefs() -- restore window geometry, filters, mode, sort
if hasArg('mini') then UI.setMini(true) elseif hasArg('full') then UI.setMini(false) end
if hasArg('norecord') then UI.setRecording(false) elseif hasArg('record') then UI.setRecording(true) end
if UI.recording() then db:startSession(server, playerName) end
if hasArg('hide') then UI.setOpen(false) end
mq.imgui.init('Companion', UI.render)

printf('\ag[companion]\ax started for \ay%s\ax on \ay%s\ax%s. /companion to toggle, /companion stop to quit.',
    playerName, server, UI.recording() and '' or ' \ay(not recording)\ax')

-- ── main loop ──────────────────────────────────────────────────────────
local lastRefresh, lastXp, lastPrune, lastBcast, lastPrefs = 0, 0, 0, 0, 0
local pruneMore = false -- a prune slice reported leftover work
local lastRaid = 0
local lastZone = tlo(function() return mq.TLO.Zone.ShortName() end, '')

-- one XP snapshot at login so the trend has an anchor (no-op without a session)
db:snapshotXp(tlo(function() return mq.TLO.Me.Level() end, nil), aaTotal())

while running and mq.TLO.MacroQuest.GameState() == 'INGAME' do
    Combat.tick()
    local nowMs = mq.gettime()
    if blackbox:tick(nowMs) then
        -- The recorder just took a fresh sample; reuse it rather than reading TLOs again.
        -- Only while a fight is active: downtime HP (medding, running back) is not this
        -- fight's data, and the bucket does not reset until the fight ends.
        if Combat.inCombat() then Smartheal.observe(blackbox:latest(), nowMs) end
        UI.setRoster(blackbox:latest().group) -- group roster for the "group only" meter scope
    end
    UI.setSmartheal(Smartheal.snapshot())
    -- Me.Dead edge: catches a death whose chat line was filtered (deduped in Combat)
    if blackbox:deadEdge() then Combat.recordDeath(nil) end

    -- close the active fight on a zone change so it doesn't span zones
    local zone = tlo(function() return mq.TLO.Zone.ShortName() end, lastZone)
    if zone ~= lastZone then
        Combat.zoned()
        lastZone = zone
        needRefresh = true
    end

    db:drainEvents(400) -- a slice of the last fight's queued event rows (see db.lua)
    -- recording toggled on at runtime: open the session then (never re-opened)
    if UI.recording() and not db:sessionId() then db:startSession(server, playerName) end
    local t = mq.gettime()
    if (t - lastRaid) > 5000 then -- raid roster for the meter's raid scope
        UI.setRaidRoster(readers.raid())
        lastRaid = t
    end
    if (t - lastBcast) > 1000 then -- share my DPS with the group ~1 Hz
        broadcastDps()
        lastBcast = t
    end
    -- Only refresh while the window is actually drawn (see service.lua): the
    -- history queries are blocking SQLite on the game thread. needRefresh
    -- survives a hidden stretch and forces the slow tier on the next draw.
    local visible = UI.isVisible()
    if UI.hasPendingSelect() or (visible and (needRefresh or (t - lastRefresh) > 2000)) then
        UI.refreshHistory(sessionMeta(), needRefresh)
        needRefresh = false
        lastRefresh = t
    end
    if (t - lastPrefs) > 2000 then
        UI.savePrefs() -- persist any changed window/filter/mode/sort state
        lastPrefs = t
    end
    if UI.recording() and (t - lastXp) > 60000 then
        db:snapshotXp(tlo(function() return mq.TLO.Me.Level() end, nil), aaTotal())
        lastXp = t
    end
    -- prune in bounded slices: one every 10 min, then every tick while more
    -- expired rows remain (each slice releases the write lock). Recorder only.
    if UI.recording() and (pruneMore or (t - lastPrune) > 600000) then
        pruneMore = db:pruneEvents(UI.retentionDays(), 2000)
        lastPrune = t
    end

    mq.delay(50)
end

-- ── shutdown ───────────────────────────────────────────────────────────
Combat.shutdown() -- flushes the active fight (persists via onFinalize) + unregisters
db:close()
mq.imgui.destroy('Companion')
printf('\ag[companion]\ax stopped. %d fight(s) recorded this session.', fightsThisSession)
