-- Run: luajit tests/test_mob_dps.lua   (from F:\lua\companion)
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
local rows
Combat.init({ playerName = function() return 'Daly' end, onMobDps = function(r) rows = r end })
Combat.timeoutSec = 5
local record = Combat._recordForTest
check('test hook exposed', type(record) == 'function')

-- a rat hits Daly 3 times over 12 s (3000 total -> 250 dps); a bat hits once for 900 (floored to 6 s -> 150 dps)
clock = 1000
record({ source = 'a rat', target = 'Daly', ability = 'hit', kind = 'melee', amount = 1000, incoming = true, outcome = 'hit' })
clock = 7000
record({ source = 'a rat', target = 'Daly', ability = 'hit', kind = 'melee', amount = 1000, incoming = true, outcome = 'hit' })
record({ source = 'a bat', target = 'Daly', ability = 'hit', kind = 'melee', amount = 900, incoming = true, outcome = 'hit' })
clock = 13000
record({ source = 'a rat', target = 'Daly', ability = 'hit', kind = 'melee', amount = 1000, incoming = true, outcome = 'hit' })
-- Daly's own outgoing damage must not appear as an attacker
record({ source = 'Daly', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 500, mine = true, outcome = 'hit' })
clock = 20000
Combat.tick()
check('rows delivered on finalize', rows ~= nil)
check('two attackers', rows and #rows == 2, rows and #rows)
check('rat first (250 dps)', rows and rows[1].name == 'a rat' and math.abs(rows[1].dps - 250) < 0.01, rows and rows[1].dps)
check('rat window 12 s', rows and rows[1].secs == 12, rows and rows[1].secs)
check('bat floored to 6 s (150 dps)', rows and rows[2].name == 'a bat' and math.abs(rows[2].dps - 150) < 0.01, rows and rows[2].dps)

-- pure helper on a bare encounter shape
local r2 = Combat.mobDpsRows({ incomingBy = { x = 600 }, incomingAt = { x = { first = 0, last = 3 } } })
check('helper floors short windows', r2[1].secs == 6 and r2[1].dps == 100, r2[1].dps)
check('helper skips zero damage', #Combat.mobDpsRows({ incomingBy = { y = 0 } }) == 0)

io.write(string.format('test_mob_dps: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
