-- Run: luajit tests/test_attempts.lua   (from F:\lua\companion)
--
-- Attempt tracking: within a zone run, fights on the same target are
-- numbered in fight-id order and marked kill/wipe with the best (lowest) HP%.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
package.preload['mq'] = function() return { gettime = function() return 0 end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end
local UI = require('companion.ui')

local fights = { -- newest first, as runFights returns them
  { id = 14, primary_target = 'a bat', killed = 1 },
  { id = 13, primary_target = 'Overlord', killed = 1, mob_min_hp = 0 },
  { id = 12, primary_target = 'Overlord', killed = 0, mob_min_hp = 12 },
  { id = 11, primary_target = 'Overlord', killed = 0, mob_min_hp = 40 },
  { id = 10, primary_target = 'Jelvan', killed = 0, mob_min_hp = 55 },
  { id = 9,  primary_target = 'Jelvan', killed = 0 },
}
local at = UI.attemptsByTarget(fights)
local ov = at['Overlord']
check('attempts counted', ov.attempts == 3 and ov.kills == 1)
check('numbered in id order', ov.byFight[11].n == 1 and ov.byFight[12].n == 2 and ov.byFight[13].n == 3)
check('kill flagged on the right attempt', ov.byFight[13].killed and not ov.byFight[12].killed)
check('best pct = lowest wipe hp', ov.bestPct == 12, ov.bestPct)
check('summary text', UI.attemptText(ov) == '3 attempts, kill on #3', UI.attemptText(ov))
local jv = at['Jelvan']
check('wipes only', jv.attempts == 2 and jv.kills == 0 and jv.bestPct == 55)
check('wipe summary text', UI.attemptText(jv) == '2 attempts, best 55%', UI.attemptText(jv))
check('single kill text', UI.attemptText(at['a bat']) == 'kill')
check('unknown target', UI.attemptText(nil) == '')
check('all kills text', UI.attemptText({ attempts = 2, kills = 2, byFight = {} }) == '2 attempts, all kills')
check('single wipe text', UI.attemptText({ attempts = 1, kills = 0, bestPct = 33.4, byFight = {} }) == 'wipe at 33%')
check('killed as boolean accepted', UI.attemptsByTarget({ { id = 1, primary_target = 'x', killed = true } })['x'].kills == 1)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
