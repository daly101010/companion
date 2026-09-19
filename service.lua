-- companion/service.lua
-- The companion fight parser as an embeddable service: everything
-- companion/init.lua wires and pumps, minus the window/bind ownership (the
-- host script owns those). One canonical copy shared by maui (Parser panel)
-- and medley (Parse panel); standalone companion keeps its own init.lua.
-- Never run standalone companion on a character running a host: both would
-- parse every combat line and write companion.db twice.
--
-- Lifecycle (the host drives all three):
--   Service.init()      before the main loop; returns ok, err. On failure
--                       (e.g. lsqlite3 missing) the service stays disabled:
--                       tick/shutdown no-op and Service.error carries why.
--   Service.tick()      every main-loop iteration (DB writes live here)
--   Service.shutdown()  on terminate (flushes the active fight, closes DB)
--
-- Service.UI is companion.ui: hosts call UI.drawDockedBody() inside their own
-- window (docked) or UI.render() (companion's own floating window, popout).

local mq     = require('mq')
local Combat = require('companion.combat')
local DB     = require('companion.db')
local UI     = require('companion.ui')
local Group  = require('companion.group')
local BlackBox   = require('companion.blackbox')
local Postmortem = require('companion.postmortem')

local M = { UI = UI, enabled = false, error = nil }

local db = nil
local blackbox = nil
local readers = nil -- black-box TLO readers; .raid() is polled by tick for the raid scope
local playerName, server = 'You', 'unknown'
local sessionStart = 0
local fightsThisSession = 0
local needRefresh = true
local lastRefresh, lastXp, lastPrune, lastBcast, lastPrefs = 0, 0, 0, 0, 0
local pruneMore = false -- a prune slice reported leftover work
local lastRaid = 0
local lastZone = ''

local function tlo(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil and v ~= 'NULL' then return v end
    return default
end

local function aaTotal()
    local total = tlo(function() return mq.TLO.Me.AAPointsTotal() end, nil)
    if total then return total end
    return tlo(function() return mq.TLO.Me.AAPointsSpent() end, 0) + tlo(function() return mq.TLO.Me.AAPoints() end, 0)
end

local function sessionMeta()
    return {
        dur    = os.time() - sessionStart,
        fights = fightsThisSession,
        level  = tlo(function() return mq.TLO.Me.Level() end, nil),
        aa     = aaTotal(),
    }
end

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

function M.init()
    playerName = tlo(function() return mq.TLO.Me.Name() end, 'You')
    server     = tlo(function() return mq.TLO.EverQuest.Server() end, 'unknown')

    local dbPath = string.format('%s/companion.db', mq.configDir)
    local okDb, ret = pcall(DB.new, dbPath)
    if not okDb or not ret then
        M.error = okDb and ('could not open ' .. dbPath) or tostring(ret)
        return false, M.error
    end
    db = ret
    sessionStart = os.time()
    db:startSession(server, playerName)

    -- always-on flight recorder (2 Hz, last 90 s) frozen onto the fight on death
    readers  = BlackBox.tloReaders()
    blackbox = BlackBox.new(readers, { hz = 2, seconds = 90 })

    Combat.init({
        playerName   = function() return playerName end,
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
            return tlo(function() return mq.TLO.Spawn('=' .. name).Master.CleanName() end, nil)
        end,
        getWeapons   = function()
            return tlo(function() return mq.TLO.Me.Inventory('mainhand').Name() end, nil),
                tlo(function() return mq.TLO.Me.Inventory('offhand').Name() end, nil)
        end,
        spellDuration = function(name)
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
            db:saveFight(fight)
            fightsThisSession = fightsThisSession + 1
            needRefresh = true
        end,
    })

    Group.init(playerName)
    Combat.setEventHook(function(ev) Group.broadcastEvent(ev) end)
    UI.setup({ combat = Combat, db = db, playerName = playerName, group = Group })
    UI.loadPrefs()

    lastZone = tlo(function() return mq.TLO.Zone.ShortName() end, '')
    db:snapshotXp(tlo(function() return mq.TLO.Me.Level() end, nil), aaTotal())

    M.enabled = true
    return true
end

function M.reset()
    if not M.enabled then return end
    Combat.flush()
    needRefresh = true
end

function M.exportLive()
    if M.enabled then UI.exportLive() end
end

function M.exportDeath()
    if M.enabled then UI.exportDeath() end
end

-- One main-loop pass: event rollup, zone flush, ~1 Hz group broadcast,
-- history refresh + pref save, XP snapshot, event prune. Same cadence as
-- companion/init.lua's loop.
function M.tick()
    if not M.enabled then return end
    Combat.tick()
    if blackbox:tick(mq.gettime()) then
        UI.setRoster(blackbox:latest().group) -- group roster for the "group only" meter scope
    end
    if blackbox:deadEdge() then Combat.recordDeath(nil) end

    local zone = tlo(function() return mq.TLO.Zone.ShortName() end, lastZone)
    if zone ~= lastZone then
        Combat.zoned()
        lastZone = zone
        needRefresh = true
    end

    db:drainEvents(400) -- a slice of the last fight's queued event rows (see db.lua)
    local t = mq.gettime()
    if (t - lastRaid) > 5000 then
        UI.setRaidRoster(readers.raid())
        lastRaid = t
    end
    if (t - lastBcast) > 1000 then
        broadcastDps()
        lastBcast = t
    end
    -- History refresh is DB work on the game thread, so it only runs while the
    -- panel is actually on screen; needRefresh stays pending across a hidden
    -- stretch and is served (with the slow tier forced) on the next draw.
    -- hasPendingSelect stays ungated: /companion death + export work closed.
    local visible = UI.isVisible()
    if UI.hasPendingSelect() or (visible and (needRefresh or (t - lastRefresh) > 2000)) then
        UI.refreshHistory(sessionMeta(), needRefresh)
        needRefresh = false
        lastRefresh = t
    end
    -- Cheap (string compares; writes only on an actual change) and driven by
    -- UI state that can change right before the panel is hidden, so it is not
    -- gated on visibility -- just kept off the 2s history path.
    if (t - lastPrefs) > 2000 then
        UI.savePrefs()
        lastPrefs = t
    end
    if (t - lastXp) > 60000 then
        db:snapshotXp(tlo(function() return mq.TLO.Me.Level() end, nil), aaTotal())
        lastXp = t
    end
    -- prune in bounded slices: one every 10 min, then every tick while more
    -- expired rows remain (each slice releases the write lock)
    if pruneMore or (t - lastPrune) > 600000 then
        pruneMore = db:pruneEvents(UI.retentionDays(), 2000)
        lastPrune = t
    end
end

function M.shutdown()
    if not M.enabled then return end
    Combat.shutdown() -- flushes the active fight (persists via onFinalize) + unregisters
    db:close()
    M.enabled = false
end

return M
