-- companion/smartheal.lua
-- Per-fight rollup of the SmartHeals brain: what ma_healbridge.lua decided
-- (actor mailbox 'companion_smartheal') and what happened to the group's HP
-- (companion's own 2 Hz black-box samples).
--
-- PURE: no mq, no ImGui, no DB handle. Every clock value arrives as an argument
-- so this runs under plain luajit in tests. init.lua owns all the wiring.
--
-- Lifecycle mirrors postmortem.lua: the main loop feeds it, then stamp(fight)
-- writes the summary onto the fight table just before db:saveFight persists it.

local M = {}

M.RING = 12  -- decisions kept for the UI detail list

local player = 'You'

local function newBucket()
    return {
        tiers        = {},  -- tier name -> count
        results      = {},  -- ack result -> count
        casts        = 0,   -- acks whose result was CAST_SUCCESS
        vetoes       = 0,
        netFires     = 0,   -- macro-side safety net (bridge reports the delta)
        unknown      = 0,   -- messages of a kind we do not understand
        decisions    = {},  -- ring of the last M.RING decisions
        pending      = {},  -- seq -> decision awaiting its ack
        members      = {},  -- name -> { minHp, emergMs }
        lastSampleMs = nil,
        sawTraffic   = false,
        sawSamples   = false,
    }
end

local cur = newBucket()

-- Session-lifetime, not per-fight: the bridge only resends 'config' when a
-- value changes, so from fight 2 onward there may be no new config message
-- at all. newBucket()/M.reset() must never own or clear these.
local config = {
    emergencyPct = nil, -- from the bridge's config message; nil = unknown
    floorPct     = nil,
    maName       = nil,
    shadow       = false,
}

-- Deliberately session-lifetime and intentionally not reset per fight.
local session = { fights = 0, casts = 0, vetoes = 0, netFires = 0 }

-- snapshot() is called once per frame from init.lua's main loop, so rebuilding
-- the members array and sorting it every frame is wasted work. Rebuild only
-- when something actually changed. Mirrors combat.lua's snapCache, but keyed on
-- mutation rather than elapsed time so the UI never shows a stale figure.
local snapCache = { dirty = true, data = nil }

function M.reset() cur = newBucket(); snapCache.dirty = true end

--- Full reset including the session-lifetime config, for test isolation only.
--- Production code (init.lua) never calls this -- config intentionally
--- survives M.reset() across fights within one running process.
function M.resetAll()
    M.reset()
    config = { emergencyPct = nil, floorPct = nil, maName = nil, shadow = false }
    session = { fights = 0, casts = 0, vetoes = 0, netFires = 0 }
end

---@param name string  the local character, tracked alongside group members
function M.setPlayer(name)
    if type(name) == 'string' and name ~= '' then player = name end
end

--- Handle one actor message from the bridge.
---@param msg table  { kind = 'config'|'decision'|'ack'|'veto'|'net', ... }
---@return boolean handled  false for a malformed or unknown message
function M.onMessage(msg)
    if type(msg) ~= 'table' then return false end
    local kind = msg.kind

    if kind == 'config' then
        config.emergencyPct = tonumber(msg.emergencyPct)
        config.floorPct     = tonumber(msg.floorPct)
        if type(msg.maName) == 'string' and msg.maName ~= '' then config.maName = msg.maName end
        config.shadow       = msg.shadow == true
        cur.sawTraffic   = true
        snapCache.dirty  = true
        return true

    elseif kind == 'decision' then
        local tier = tostring(msg.tier or 'single')
        local d = {
            seq     = tonumber(msg.seq) or 0,
            spell   = tostring(msg.spell or '?'),
            target  = tostring(msg.target or '?'),
            tier    = tier,
            trigger = msg.trigger and tostring(msg.trigger) or nil,
            pct     = tonumber(msg.targetPct),
            dps     = tonumber(msg.targetDps),
            isHoT   = msg.isHoT == true,
            result  = nil,
        }
        cur.tiers[tier]     = (cur.tiers[tier] or 0) + 1
        -- A bridge restart replays low sequence numbers. Overwriting the pending
        -- slot would silently drop the older decision's ack; leaving it unacked
        -- is the honest outcome and matches ma_bridge_state's restart rule.
        cur.pending[d.seq]  = d
        local ring = cur.decisions
        ring[#ring + 1] = d
        while #ring > M.RING do table.remove(ring, 1) end
        cur.sawTraffic = true
        snapCache.dirty = true
        return true

    elseif kind == 'ack' then
        local seq = tonumber(msg.seq) or 0
        local res = tostring(msg.result or '?')
        cur.results[res] = (cur.results[res] or 0) + 1
        local d = cur.pending[seq]
        if d then d.result = res; cur.pending[seq] = nil end
        if res == 'CAST_SUCCESS' then
            cur.casts     = cur.casts + 1
            session.casts = session.casts + 1
        end
        cur.sawTraffic = true
        snapCache.dirty = true
        return true

    elseif kind == 'veto' then
        cur.vetoes     = cur.vetoes + 1
        session.vetoes = session.vetoes + 1
        cur.sawTraffic = true
        snapCache.dirty = true
        return true

    elseif kind == 'net' then
        local n = tonumber(msg.count) or 0
        if n > 0 then
            cur.netFires     = cur.netFires + n
            session.netFires = session.netFires + n
        end
        cur.sawTraffic = true
        snapCache.dirty = true
        return true
    end

    cur.unknown = cur.unknown + 1
    snapCache.dirty = true
    return false
end

--- Fold one black-box sample into the bucket.
---@param sample table   { hp = number, group = { {name=string, hp=number}, ... } }
---@param nowMs number   monotonic ms; only the delta between samples is used
function M.observe(sample, nowMs)
    if type(sample) ~= 'table' then return end
    nowMs = tonumber(nowMs) or 0

    -- Credit elapsed time to the PREVIOUS sample's HP readings, so a member is
    -- never charged for a window it was not yet in.
    local dt = 0
    if cur.lastSampleMs then dt = math.max(0, nowMs - cur.lastSampleMs) end
    local line = config.emergencyPct

    if dt > 0 and line then
        -- Only members present in the PREVIOUS sample may accrue this window.
        -- A member who left the group (camped, zoned, dropped) stops accruing
        -- instead of freezing at a low lastHp and inflating emergMs forever.
        for _, m in pairs(cur.members) do
            if m.seenAt == cur.lastSampleMs
                and m.lastHp and m.lastHp <= line and m.lastHp > 0 then
                m.emergMs = m.emergMs + dt
            end
        end
    end
    cur.lastSampleMs = nowMs

    local function note(name, hp)
        if type(name) ~= 'string' or name == '' then return end
        hp = tonumber(hp)
        if not hp then return end
        local m = cur.members[name]
        if not m then m = { minHp = 100, emergMs = 0 }; cur.members[name] = m end
        -- hp <= 0 means offline/zoned (blackbox's flag, not a real near-death
        -- reading) -- don't let it pin minHp to 0. Still track lastHp/seenAt so
        -- the member is not silently dropped.
        if hp > 0 and hp < m.minHp then m.minHp = hp end
        m.lastHp = hp
        m.seenAt = nowMs
    end

    note(player, sample.hp)
    for _, g in ipairs(sample.group or {}) do note(g.name, g.hp) end
    cur.sawSamples = true
    snapCache.dirty = true
end

local function tankStats()
    local m = config.maName and cur.members[config.maName] or nil
    if not m then return nil, nil end
    local sec = config.emergencyPct and (m.emergMs / 1000) or nil
    return m.minHp, sec
end

--- Compact "k=v,k=v" summary, the same shape fight_ability.mods uses so a new
--- key never needs a schema change.
local function compact()
    local parts = {}
    local keys = {}
    for tier in pairs(cur.tiers) do keys[#keys + 1] = 'tier:' .. tier end
    for res in pairs(cur.results) do keys[#keys + 1] = 'res:' .. res end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local kind, name = k:match('^(%a+):(.+)$')
        local n = (kind == 'tier') and cur.tiers[name] or cur.results[name]
        parts[#parts + 1] = string.format('%s=%d', k, n)
    end
    if cur.vetoes   > 0 then parts[#parts + 1] = 'veto=' .. cur.vetoes end
    if cur.netFires > 0 then parts[#parts + 1] = 'net=' .. cur.netFires end
    return table.concat(parts, ',')
end

--- Current bucket + session rollup, for the UI. nil until something is tracked.
--- READ-ONLY. The returned table is cached and handed out again on later frames,
--- and its `tiers`, `results` and `decisions` fields are live references into this
--- module's internal bucket -- only `members` is a fresh array. A caller that sorts
--- or clears any of them in place corrupts the accumulator, not just its own view.
function M.snapshot()
    if not snapCache.dirty then return snapCache.data end
    snapCache.dirty = false
    if not cur.sawTraffic and not cur.sawSamples then
        snapCache.data = nil
        return nil
    end
    local minHp, emergSec = tankStats()
    local members = {}
    for name, m in pairs(cur.members) do
        members[#members + 1] = {
            name = name, minHp = m.minHp,
            emergSec = config.emergencyPct and (m.emergMs / 1000) or nil,
        }
    end
    table.sort(members, function(a, b) return a.minHp < b.minHp end)
    snapCache.data = {
        emergencyPct = config.emergencyPct,
        floorPct     = config.floorPct,
        maName       = config.maName,
        shadow       = config.shadow,
        live         = cur.sawTraffic,
        tiers        = cur.tiers,
        results      = cur.results,
        casts        = cur.casts,
        vetoes       = cur.vetoes,
        netFires     = cur.netFires,
        unknown      = cur.unknown,
        decisions    = cur.decisions,
        members      = members,
        tankMinHp    = minHp,
        tankEmergSec = emergSec,
        session      = session,
    }
    return snapCache.data
end

--- Write this fight's summary onto `fight` (consumed by db:saveFight), then
--- start a fresh bucket. Called from init.lua's onFinalize, beside
--- Postmortem.stamp. Returns the summary, or nil when the bridge never spoke.
---@param fight table
---@return table|nil
function M.stamp(fight)
    if not cur.sawTraffic then snapCache.dirty = true; M.reset(); return nil end
    local minHp, emergSec = tankStats()
    local compactSummary = compact()
    if compactSummary == '' then compactSummary = nil end
    local sum = {
        tankMinHp    = minHp,
        tankEmergSec = emergSec,
        casts        = cur.casts,
        compact      = compactSummary,
        decisions    = cur.decisions,
    }
    if type(fight) == 'table' then
        fight.sh_min_hp    = minHp
        fight.sh_emerg_sec = emergSec
        fight.sh_casts     = cur.casts
        fight.sh_summary   = sum.compact
        fight.sh_decisions = cur.decisions
    end
    session.fights = session.fights + 1
    snapCache.dirty = true
    M.reset()
    return sum
end

return M
