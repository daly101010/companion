-- Run: luajit tests/test_peer_death.lua   (from F:\lua\companion)
--
-- A box that does not record ships its death (frozen black-box samples plus
-- the last 60s of events that targeted it) to the recorder, which folds them
-- into its own fight as a death record tagged with the peer's name, so the
-- post-mortem is analyzed and stored there instead of being lost.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
package.preload['mq'] = function()
  return { gettime = function() return clock end, doevents = function() end, event = function() end, unevent = function() end }
end
_G.printf = function() end

local Combat = require('combat')
local Postmortem = require('postmortem')
local finalized, shipped
Combat.init({
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'anguish' end,
  getWeapons = function() return nil, nil end,
  freezeBlackBox = function() return { { t = -1.0, hp = 40, flags = '', group = {} }, { t = -0.5, hp = 15, flags = '', group = {} } } end,
  onDeath = function(payload) shipped = payload end,
  onFinalize = function(f) finalized = f end,
})
Combat.timeoutSec = 5
local record = Combat._recordForTest

-- ── the dying box: build its payload ──
record({ source = 'Calbuss', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 100, mine = true, outcome = 'hit' })
clock = clock + 1000
record({ source = 'a rat', target = 'Calbuss', ability = 'Bite', kind = 'melee', amount = 400, incoming = true, outcome = 'hit' })
clock = clock + 1000
record({ source = 'Healbot', target = 'Calbuss', ability = 'Remedy', kind = 'heal', amount = 200, mine = false, outcome = 'hit' })
clock = clock + 1000
record({ source = 'a rat', target = 'Calbuss', ability = 'Bite', kind = 'melee', amount = 900, incoming = true, outcome = 'hit' })
Combat.recordDeath('a rat')
check('death payload shipped', shipped and shipped.id == 'death' and shipped.sender == 'Calbuss' and shipped.killer == 'a rat')
check('samples carried, terminal sample appended', shipped and #shipped.samples == 3 and shipped.samples[3].terminal and shipped.samples[3].hp == 0)
check('only events that targeted me', shipped and #shipped.events == 3, shipped and #shipped.events)
check('event times relative to the death (<= 0)', shipped and shipped.events[1].t == -2 and shipped.events[3].t == 0, shipped and shipped.events[1].t)
check('heal received included', shipped and shipped.events[2].kind == 'heal' and shipped.events[2].source == 'Healbot')

-- ── the recorder: ingest a peer's death into its own fight ──
clock = clock + 20000; Combat.tick() -- close the first fight
finalized = nil
record({ source = 'Calbuss', target = 'Overlord', ability = 'Slash', kind = 'melee', amount = 100, mine = true, outcome = 'hit' })
clock = clock + 5000; Combat.tick()
local peer = {
  id = 'death', sender = 'Bob', at = os.time(), killer = 'Overlord',
  samples = { { t = -1.0, hp = 30, flags = '', group = {} }, { t = 0, hp = 0, flags = '', group = {}, terminal = true } },
  events = {
    { t = -2, source = 'Overlord', target = 'Bob', ability = 'Slam', kind = 'melee', amount = 5000, outcome = 'hit' },
    { t = 0,  source = 'Overlord', target = 'Bob', ability = 'Slam', kind = 'melee', amount = 9000, outcome = 'hit' },
  },
}
check('own echo ignored', not Combat.ingestPeerDeath({ id = 'death', sender = 'Calbuss' }))
check('garbage ignored', not Combat.ingestPeerDeath(nil) and not Combat.ingestPeerDeath({ id = 'dps', sender = 'Bob' }))
check('peer death ingested', Combat.ingestPeerDeath(peer))
local snap = Combat.snapshot()
check('not counted as my death', snap.deaths == 0, snap.deaths)
check('peer events re-based onto my fight clock', (function()
  local found = 0
  for _, e in ipairs(snap.events) do if e.target == 'Bob' and e.kind == 'melee' then found = found + 1; if e.t < 0 then return false end end end
  return found == 2
end)())
check('peer damage taken is not my incoming', snap.incoming == 0)

clock = clock + 20000; Combat.tick()
check('finalized with the peer death record', finalized and #finalized.deaths_detail == 1 and finalized.deaths_detail[1].player == 'Bob')
check('finalized deaths counter untouched', finalized and finalized.deaths == 0)
Postmortem.stamp(finalized, 'Calbuss')
local d = finalized.deaths_detail[1]
check('stamped as the peer (a cause was found)', d.cause ~= nil and d.cause ~= 'unknown', d.cause)
check('analyzed over the peer\'s own incoming (14,000 taken)', type(d.narrative) == 'string' and d.narrative:find('14,000', 1, true) ~= nil, d.narrative)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
