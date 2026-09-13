-- companion/blackbox.lua
-- Always-on flight recorder: a fixed-capacity ring buffer of my state + group
-- state, sampled at `hz` from the main loop. Pure Lua over injected reader
-- callbacks so it is unit-testable; the TLO readers live in tloReaders() and
-- require('mq') lazily so loading this module never touches MQ.
--
--   local bb = BlackBox.new(BlackBox.tloReaders(), { hz = 2, seconds = 90 })
--   bb:tick(mq.gettime())    -- every main-loop pass (throttled inside)
--   bb:freeze(mq.gettime())  -- -> samples oldest..newest, t relative seconds (<= 0)
--   bb:deadEdge()            -- true once when me.dead flips false -> true

local M = {}
M.__index = M

---@param readers table { me = fn() -> table, group = fn() -> array, buffNames = fn() -> array }
---@param opts table|nil { hz = 2, seconds = 90 }
function M.new(readers, opts)
    opts = opts or {}
    local hz = opts.hz or 2
    return setmetatable({
        readers       = readers or {},
        intervalMs    = math.floor(1000 / hz),
        cap           = math.max(2, math.floor((opts.seconds or 90) * hz)),
        buf           = {},
        head          = 0,   -- index of the newest sample in buf
        count         = 0,
        lastMs        = nil,
        prevDead      = nil,
        prevBuffCount = nil,
        prevBuffNames = nil, -- set: name -> true
        _deadEdge     = false,
    }, M)
end

local function callReader(fn, default)
    if type(fn) ~= 'function' then return default end
    local ok, v = pcall(fn)
    if ok and type(v) == 'table' then return v end
    return default
end

-- Names currently buffed, as a set. Only called when the buff count changed.
function M:_buffSet()
    local set = {}
    for _, n in ipairs(callReader(self.readers.buffNames, {})) do set[n] = true end
    return set
end

---@param nowMs number
---@return boolean sampled
function M:tick(nowMs)
    if self.lastMs and (nowMs - self.lastMs) < self.intervalMs then return false end
    self.lastMs = nowMs
    local me = callReader(self.readers.me, nil)
    if not me then return false end
    me.t = nowMs
    me.group = callReader(self.readers.group, {})

    -- death edge (fallback detector when the "slain" chat line is filtered)
    local dead = me.dead and true or false
    if self.prevDead == false and dead then self._deadEdge = true end
    self.prevDead = dead

    -- buff drops: diff names only when the count changes
    local bc = tonumber(me.buffCount)
    me.buffsDropped = {}
    if bc ~= nil then
        if self.prevBuffCount == nil or bc > self.prevBuffCount then
            self.prevBuffNames = self:_buffSet()
        elseif bc < self.prevBuffCount then
            local cur = self:_buffSet()
            for name in pairs(self.prevBuffNames or {}) do
                if not cur[name] then me.buffsDropped[#me.buffsDropped + 1] = name end
            end
            table.sort(me.buffsDropped)
            self.prevBuffNames = cur
        end
        self.prevBuffCount = bc
    end

    self.head = (self.head % self.cap) + 1
    self.buf[self.head] = me
    if self.count < self.cap then self.count = self.count + 1 end
    return true
end

-- Oldest -> newest shallow copies with `t` in seconds relative to nowMs (<= 0).
---@param nowMs number
---@return table samples
function M:freeze(nowMs)
    local out = {}
    for i = 1, self.count do
        local idx = ((self.head - self.count + i - 1) % self.cap) + 1
        local s = self.buf[idx]
        local c = {}
        for k, v in pairs(s) do c[k] = v end
        c.t = (s.t - nowMs) / 1000
        out[#out + 1] = c
    end
    return out
end

--- The newest sample, or nil before the first tick. The ring still owns the
--- table -- callers must read it, never mutate it.
---@return table|nil
function M:latest()
    if self.count == 0 then return nil end
    return self.buf[self.head]
end

function M:deadEdge()
    local e = self._deadEdge
    self._deadEdge = false
    return e
end

-- ── group codec: "name:cls:hp:mana:dist:flag:mt:ma;..." ──────────────
function M.encodeGroup(arr)
    local parts = {}
    for _, m in ipairs(arr or {}) do
        local name = (tostring(m.name or '?'):gsub('[:;]', ''))
        parts[#parts + 1] = table.concat({
            name, tostring(m.cls or ''),
            tostring(math.floor(tonumber(m.hp) or 0)), tostring(math.floor(tonumber(m.mana) or 0)),
            tostring(math.floor(tonumber(m.dist) or 0)), tostring(m.flag or ''),
            m.mt and '1' or '0', m.ma and '1' or '0' }, ':')
    end
    return table.concat(parts, ';')
end

function M.decodeGroup(str)
    local out = {}
    for part in tostring(str or ''):gmatch('[^;]+') do
        local f = {}
        for v in (part .. ':'):gmatch('([^:]*):') do f[#f + 1] = v end
        out[#out + 1] = { name = f[1] or '?', cls = f[2] or '', hp = tonumber(f[3]) or 0,
            mana = tonumber(f[4]) or 0, dist = tonumber(f[5]) or 0, flag = f[6] or '',
            mt = f[7] == '1', ma = f[8] == '1' }
    end
    return out
end

-- ── TLO readers (the only place this module touches MQ) ───────────────
function M.tloReaders()
    local mq = require('mq')
    local function tlo(fn, default)
        local ok, v = pcall(fn)
        if ok and v ~= nil and v ~= 'NULL' then return v end
        return default
    end
    local function num(fn) return tonumber(tlo(fn, nil)) end
    -- MQBoolean members return true/false; MQBuff members (Rooted, Snared, ...)
    -- return the spell name or NULL. Both collapse to "is the flag set".
    local function flag(fn)
        local v = tlo(fn, nil)
        return v ~= nil and v ~= false and v ~= '' and v ~= 0
    end
    local FLAGS = {
        { 'stun',    function() return mq.TLO.Me.Stunned() end },
        { 'root',    function() return mq.TLO.Me.Rooted() end },
        { 'snare',   function() return mq.TLO.Me.Snared() end },
        { 'mez',     function() return mq.TLO.Me.Mezzed() end },
        { 'fear',    function() return mq.TLO.Me.Feared() end },
        { 'silence', function() return mq.TLO.Me.Silenced() end },
        { 'sit',     function() return mq.TLO.Me.Sitting() end },
        { 'wet',     function() return mq.TLO.Me.FeetWet() end },
        { 'lev',     function() return mq.TLO.Me.Levitating() end },
        { 'dead',    function() return mq.TLO.Me.Dead() end },
    }
    local function me()
        local flags, dead = {}, false
        for _, f in ipairs(FLAGS) do
            if flag(f[2]) then
                flags[#flags + 1] = f[1]
                if f[1] == 'dead' then dead = true end
            end
        end
        local xt = 0
        local slots = num(function() return mq.TLO.Me.XTargetSlots() end) or 0
        for i = 1, math.min(slots, 20) do
            local id = num(function() return mq.TLO.Me.XTarget(i).ID() end) or 0
            if id > 0 and tlo(function() return mq.TLO.Me.XTarget(i).TargetType() end, '') == 'Auto Hater' then
                xt = xt + 1
            end
        end
        return {
            hp         = num(function() return mq.TLO.Me.PctHPs() end),
            mana       = num(function() return mq.TLO.Me.PctMana() end),
            endur      = num(function() return mq.TLO.Me.PctEndurance() end),
            aggro      = num(function() return mq.TLO.Me.PctAggro() end),
            aggro2     = num(function() return mq.TLO.Me.SecondaryPctAggro() end),
            aggro2Name = tlo(function() return mq.TLO.Me.SecondaryAggroPlayer.CleanName() end, nil),
            target     = tlo(function() return mq.TLO.Target.CleanName() end, nil),
            targetPct  = num(function() return mq.TLO.Target.PctHPs() end),
            tot        = tlo(function() return mq.TLO.Me.TargetOfTarget.CleanName() end, nil),
            xtargets   = xt,
            casting    = tlo(function() return mq.TLO.Me.Casting.Name() end, nil),
            invuln     = (function()
                local v = tlo(function() return mq.TLO.Me.Invulnerable() end, nil)
                if type(v) == 'string' and v ~= '' and v:upper() ~= 'FALSE' then return v end
                return nil
            end)(),
            buffCount  = num(function() return mq.TLO.Me.CountBuffs() end),
            tank       = tlo(function() return mq.TLO.Group.MainTank.CleanName() end, nil),
            flags      = table.concat(flags, ','),
            dead       = dead,
        }
    end
    local function buffNames()
        -- buff slots can be sparse; scan a fixed range (only on count change)
        local out = {}
        for i = 1, 42 do
            local name = tlo(function() return mq.TLO.Me.Buff(i).Name() end, nil)
            if name and name ~= '' then out[#out + 1] = name end
        end
        return out
    end
    local function group()
        -- Group.Members excludes me; Member(1..n) are the others
        local out = {}
        local n = num(function() return mq.TLO.Group.Members() end) or 0
        for i = 1, n do
            local m = mq.TLO.Group.Member(i)
            local name = tlo(function() return m.Name() end, nil)
            if name then
                local flagv = ''
                if tlo(function() return m.Offline() end, false) == true then flagv = 'offline'
                elseif tlo(function() return m.OtherZone() end, false) == true then flagv = 'zone'
                elseif tlo(function() return m.Dead() end, false) == true then flagv = 'dead' end
                out[#out + 1] = {
                    name = name,
                    cls  = tlo(function() return m.Class.ShortName() end, ''),
                    hp   = num(function() return m.PctHPs() end) or 0,
                    mana = num(function() return m.PctMana() end) or 0,
                    dist = num(function() return m.Distance3D() end) or 0,
                    flag = flagv,
                    mt   = tlo(function() return m.MainTank() end, false) == true,
                    ma   = tlo(function() return m.MainAssist() end, false) == true,
                }
            end
        end
        return out
    end
    return { me = me, group = group, buffNames = buffNames }
end

return M
