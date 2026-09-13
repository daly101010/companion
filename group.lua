-- companion/group.lua
-- Cross-character DPS sharing over MQ Actors. Each companion broadcasts its OWN
-- current-fight summary (~1 Hz) to the shared 'companion_dps' mailbox; every
-- instance merges peers' first-person totals into an authoritative group meter.
--
-- We broadcast only a small summary (player + pet totals/dps), never the event
-- log, so the cost is a few hundred bytes at 1 Hz per character.

local mq          = require('mq')
local ok, actors  = pcall(require, 'actors')

local G           = {}
G.peers           = {} -- player name -> { player, playerDmg, playerDps, petName, petDmg, petDps, target, t }
G.me              = 'You'
G.actor           = nil
G.enabled         = false -- actors available AND user hasn't disabled sharing
G.on              = true  -- user setting

-- Enable/disable sharing at runtime (Settings panel).
function G.setEnabled(v)
    G.on = v and true or false
    if not G.on then G.peers = {} end
end

local MAILBOX     = 'companion_dps'

-- Second mailbox for per-event normalized parse output. Consumers on the same
-- character (e.g. sidekick-next) can subscribe here to skip their own mq.event
-- pattern registration entirely. Same-character routing means every peer's
-- broadcast reaches every listener; receivers must filter on payload.sender.
local EVENT_MAILBOX = 'companion_events'
G.eventActor = nil

-- MQ registers a Lua actor mailbox as '<script>:<name>', and an address-less
-- send targets the sender's OWN full mailbox name -- so a maui-hosted parser
-- broadcasting on 'maui:companion_dps' never reaches a medley-hosted one on
-- 'medley:companion_dps'. Every send fans out to each known script's mailbox
-- instead (same fix as ploot/service.lua). Sends to a mailbox nobody
-- registered are dropped silently (non-RPC).
G.HOST_SCRIPTS    = { 'companion', 'maui', 'medley' }          -- run the parser (dps peers)
G.EVENT_CONSUMERS = { 'companion', 'maui', 'medley', 'sidekick-next', 'necrobrain' } -- subscribe to companion_events

local function fan_out(actor, mailbox, scripts, payload)
    for _, script in ipairs(scripts) do
        actor:send({ mailbox = mailbox, script = script }, payload)
    end
end

---@param playerName string
function G.init(playerName)
    G.me = playerName or 'You'
    if not ok or not actors then
        printf('\ay[companion]\ax actors unavailable — group sharing off (solo meter only).')
        return
    end
    G.actor = actors.register(MAILBOX, function(message)
        local c = message()
        if type(c) ~= 'table' or c.id ~= 'dps' then return end
        local who = c.player
        if not who or who == G.me then return end -- ignore our own broadcast
        G.peers[who] = {
            player = who,
            playerDmg = c.playerDmg or 0, playerDps = c.playerDps or 0,
            petName = c.petName, petDmg = c.petDmg or 0, petDps = c.petDps or 0,
            healTotal = c.healTotal or 0, healDps = c.healDps or 0,
            target = c.target, live = c.live, t = mq.gettime(),
        }
    end)
    -- Event mailbox: registered as a no-op receiver so send() has a valid
    -- endpoint. Consumers register their own actors.register(EVENT_MAILBOX, ...)
    -- in their own scripts; each script gets its own callback dispatch.
    G.eventActor = actors.register(EVENT_MAILBOX, function() end)
    G.enabled = G.actor ~= nil
end

--- Broadcast a single normalized combat event. Called from a hook registered on
--- Combat.setEventHook(); fires per event so keep the payload lean. Consumers
--- (same character or otherwise) filter on payload.sender to decide relevance.
--- @param ev table  Event as passed to Combat.record()
function G.broadcastEvent(ev)
    if not G.enabled or not G.eventActor or not G.on then return end
    if type(ev) ~= 'table' then return end
    -- Landed hits, my resists, and my casts. Misses stay local: nothing downstream
    -- acts on them and every send costs an actor hop.
    local outcome = ev.outcome
    if outcome ~= 'hit' and outcome ~= 'resist' and outcome ~= 'cast' then return end
    local amount = tonumber(ev.amount) or 0
    if outcome == 'hit' and amount <= 0 and ev.kind ~= 'heal' then return end
    pcall(function()
        fan_out(G.eventActor, EVENT_MAILBOX, G.EVENT_CONSUMERS, {
            id       = 'evt',
            sender   = G.me,
            sentAt   = mq.gettime(),
            source   = ev.source,
            target   = ev.target,
            ability  = ev.ability,
            kind     = ev.kind,
            amount   = amount,
            outcome  = outcome,
            incoming = ev.incoming == true,
            isPet    = ev.isPet == true,
            myPet    = ev.myPet == true,
            crit     = ev.crit == true,
            over     = tonumber(ev.over) or nil,
        })
    end)
end

-- Broadcast my current-fight summary. `s` = { playerDmg, playerDps, petName,
-- petDmg, petDps, target, live }.
function G.broadcast(s)
    if not G.enabled or not G.actor or not G.on then return end
    s.id = 'dps'
    s.player = G.me
    pcall(function() fan_out(G.actor, MAILBOX, G.HOST_SCRIPTS, s) end)
end

-- Peers seen within `maxAgeMs` (default 6s), so members who stopped fighting or
-- logged out drop out of the meter.
---@param maxAgeMs? number
---@return table  array of peer summaries
function G.freshPeers(maxAgeMs)
    if not G.on then return {} end
    maxAgeMs = maxAgeMs or 6000
    local now = mq.gettime()
    local out = {}
    for _, p in pairs(G.peers) do
        if (now - p.t) <= maxAgeMs then out[#out + 1] = p end
    end
    return out
end

return G
