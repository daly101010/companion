-- Run: luajit tests/test_peer_ingest.lua   (from F:\lua\companion)
--
-- One recorder, many boxes: a fresh companion peer reports its own damage
-- and heals first-person over companion_events; the recorder ingests those
-- (Combat.ingestPeerEvent) and drops its own third-person parse of that peer
-- and its pet, so each hit is counted once with the peer's exact numbers.
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
local peers = { bob = true } -- fresh companion peers (lowercased)
Combat.init({
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'anguish' end,
  getWeapons = function() return nil, nil end,
  isPeerSource = function(name)
    local n = tostring(name):lower()
    local owner = n:match("^(.-)`s pet$")
    return peers[n] == true or (owner ~= nil and peers[owner] == true)
  end,
})
local record = Combat._recordForTest
local hooked = {}
Combat.setEventHook(function(ev) hooked[#hooked + 1] = ev end)

local function total(name)
  for _, s in ipairs(Combat.snapshot().sources) do if s.name == name then return s.total end end
  return nil
end

-- my own hit opens the fight and is broadcast as usual
record({ source = 'Calbuss', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 100, mine = true, outcome = 'hit' })
check('own hit recorded', total('Calbuss') == 100)

-- my third-person view of Bob (a fresh peer) is dropped; a stranger's is kept
record({ source = 'Bob', target = 'a rat', ability = 'Kick', kind = 'melee', amount = 999, outcome = 'hit' })
record({ source = 'Bob`s pet', target = 'a rat', ability = 'Bite', kind = 'melee', amount = 999, isPet = true, outcome = 'hit' })
record({ source = 'Randomdude', target = 'a rat', ability = 'Kick', kind = 'melee', amount = 50, outcome = 'hit' })
clock = clock + 200
check('peer third-person dropped', total('Bob') == nil)
check('peer pet third-person dropped', total('Bob`s pet') == nil)
check('stranger kept', total('Randomdude') == 50)
check('dropped lines were still offered to the hook', #hooked == 4)

-- Bob's first-person events arrive and land under his name
local n0 = #hooked
check('peer hit ingested', Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'Bob', target = 'a rat',
  ability = 'Kick', kind = 'melee', amount = 120, outcome = 'hit', crit = true }))
check('peer pet ingested', Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'Bob`s pet', target = 'a rat',
  ability = 'Bite', kind = 'melee', amount = 30, outcome = 'hit', isPet = true }))
check('peer heal ingested', Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'Bob', target = 'Calbuss',
  ability = 'Remedy', kind = 'heal', amount = 500, over = 100, outcome = 'hit' }))
clock = clock + 200
local snap = Combat.snapshot()
check('peer damage under his name', total('Bob') == 120 and total('Bob`s pet') == 30)
check('peer pet flagged', (function() for _, s in ipairs(snap.sources) do if s.name == 'Bob`s pet' then return s.isPet end end end)())
check('peer heal in the healer meter', (function() for _, h in ipairs(snap.healSources) do if h.name == 'Bob' then return h.total == 500 end end end)())
check('peer events are never re-broadcast', #hooked == n0)
check('peer damage counts as other, not mine', snap.playerDmg == 100)

-- filtered out: relayed third-person lines, incoming, casts, my own echo, misses
check('peer relaying a stranger is ignored', not Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'Randomdude',
  target = 'a rat', ability = 'Kick', kind = 'melee', amount = 70, outcome = 'hit' }))
check('peer incoming is ignored', not Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'a rat', target = 'Bob',
  ability = 'Bite', kind = 'melee', amount = 70, outcome = 'hit', incoming = true }))
check('peer cast is ignored', not Combat.ingestPeerEvent({ id = 'evt', sender = 'Bob', source = 'Bob', target = '',
  ability = 'Remedy', kind = 'cast', amount = 0, outcome = 'cast' }))
check('own echo is ignored', not Combat.ingestPeerEvent({ id = 'evt', sender = 'Calbuss', source = 'Calbuss', target = 'a rat',
  ability = 'Slash', kind = 'melee', amount = 70, outcome = 'hit' }))
check('garbage is ignored', not Combat.ingestPeerEvent(nil) and not Combat.ingestPeerEvent({ sender = 'Bob' }))
clock = clock + 200
check('totals untouched by the ignored events', total('Randomdude') == 50 and total('Bob') == 120)

-- a peer that stopped being fresh is parsed third-person again
peers.bob = nil
record({ source = 'Bob', target = 'a rat', ability = 'Kick', kind = 'melee', amount = 5, outcome = 'hit' })
clock = clock + 200
check('stale peer falls back to third-person', total('Bob') == 125)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
