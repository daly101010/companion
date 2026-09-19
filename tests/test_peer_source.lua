-- Run: luajit tests/test_peer_source.lua   (from F:\lua\companion)
--
-- group.lua: the companion_events receiver hands peers' events to
-- G.onPeerEvent (never our own echo, never when sharing is off), and
-- isFreshPeerSource recognises fresh peers and their pets.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local now = 1000
local callbacks = {}
package.preload['mq'] = function() return { gettime = function() return now end } end
package.preload['actors'] = function()
  return { register = function(name, fn) callbacks[name] = fn; return { send = function() end } end }
end
_G.printf = function() end

local G = require('group')
G.init('Calbuss')
check('event receiver registered', type(callbacks.companion_events) == 'function')

local got = {}
G.onPeerEvent = function(p) got[#got + 1] = p end
local function deliver(mailbox, payload) callbacks[mailbox](function() return payload end) end

deliver('companion_events', { id = 'evt', sender = 'Bob', source = 'Bob', amount = 10, outcome = 'hit' })
check('peer event handed to onPeerEvent', #got == 1 and got[1].sender == 'Bob')
deliver('companion_events', { id = 'evt', sender = 'Calbuss', source = 'Calbuss', amount = 10, outcome = 'hit' })
check('own echo dropped', #got == 1)
deliver('companion_events', { id = 'dps', sender = 'Bob' })
check('non-event payload dropped', #got == 1)
deliver('companion_events', 'junk')
check('junk dropped', #got == 1)
G.setEnabled(false)
deliver('companion_events', { id = 'evt', sender = 'Bob', source = 'Bob', amount = 10, outcome = 'hit' })
check('sharing off drops peer events', #got == 1)
G.setEnabled(true)

-- fresh peer sources
deliver('companion_dps', { id = 'dps', player = 'Bob', playerDmg = 1 })
check('fresh peer is a peer source', G.isFreshPeerSource('Bob'))
check('case-insensitive', G.isFreshPeerSource('bob'))
check('fresh peer pet is a peer source', G.isFreshPeerSource('Bob`s pet'))
check('stranger is not', G.isFreshPeerSource('Randomdude') == false)
check('stranger pet is not', G.isFreshPeerSource('Randomdude`s pet') == false)
check('nil is not', G.isFreshPeerSource(nil) == false)
now = now + 7000
check('stale peer is not a peer source', G.isFreshPeerSource('Bob') == false)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
