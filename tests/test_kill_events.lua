-- Run: luajit tests/test_kill_events.lua   (from F:\lua\companion)
-- Drives the registered mq.event handlers directly (captured from the fake
-- mq.event table below) to prove: (1) an own-cast event now carries the
-- current target's name instead of '', and (2) "X has been slain by Y!"
-- (the tank's kill, not "You have slain X!") is now recorded as a kill event
-- -- but only while an encounter is already open, and never through record()
-- (it must not touch damage rollups).
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
local target = 'a rat'
local handlers = {} -- event name -> fn, captured from mq.event registration
package.preload['mq'] = function()
  return {
    gettime = function() return clock end,
    doevents = function() end,
    event = function(name, _pattern, fn) handlers[name] = fn end,
    unevent = function() end,
  }
end
_G.printf = function() end

local Combat = require('combat')
local finalized
Combat.init({
  onFinalize = function(f) finalized = f end,
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'Dranik' end,
  getWeapons = function() return nil, nil end,
  getTarget = function() return target end,
})

check('cmp_cast_my registered', type(handlers.cmp_cast_my) == 'function')
check('cmp_kill_you registered', type(handlers.cmp_kill_you) == 'function')
check('cmp_kill_other registered', type(handlers.cmp_kill_other) == 'function')

-- Test-only introspection, same trick as test_hp_estimate.lua: peek at the
-- live (unfinalized) encounter via the `active` upvalue closed over by
-- Combat.primaryTarget().
local function getActive()
  local i = 1
  while true do
    local name, value = debug.getupvalue(Combat.primaryTarget, i)
    if not name then return nil end
    if name == 'active' then return value end
    i = i + 1
  end
end

-- ── own cast now carries the resolved target ────────────────────────────
-- Casts never open/refresh an encounter on their own (buffing out of combat
-- must not spawn a phantom fight) -- open one with a landed hit first, same
-- as real play (the pull's damage starts the fight before any cast fires).
check('no encounter yet', getActive() == nil)
local record = Combat._recordForTest
target = 'a drachnid champion'
record { source = 'Calbuss', target = target, ability = 'Slash', kind = 'melee', amount = 10, mine = true, outcome = 'hit' }
local enc = getActive()
check('hit opened an encounter', enc ~= nil)
handlers.cmp_cast_my('You begin casting Venin of Thorns.', 'Venin of Thorns')
check('own cast attached to the open encounter', #enc.events == 2)
local castEv = enc and enc.events[#enc.events]
check('own cast event carries target from getTarget', castEv and castEv.target == 'a drachnid champion' and castEv.kind == 'cast',
  castEv and castEv.target)

-- other players' casts still get no target (unrelated to our getTarget)
handlers.cmp_cast_ot('Daly begins casting Complete Heal.', 'Daly', 'Complete Heal')
local otherCastEv = enc.events[#enc.events]
check('other-player cast event target stays empty', otherCastEv and otherCastEv.target == '', otherCastEv and otherCastEv.target)

-- ── "X has been slain by Y!" while an encounter IS open ─────────────────
local nBefore = #enc.events
local dmgBefore = enc.targets['a drachnid champion'] -- already non-nil from the melee hit above
handlers.cmp_kill_other('a drachnid champion has been slain by Daly!', 'a drachnid champion', 'Daly')
check('kill-by-other appended one event', #enc.events == nBefore + 1)
local killEv = enc.events[#enc.events]
check('kill-by-other event shape', killEv and killEv.kind == 'kill' and killEv.outcome == 'kill'
  and killEv.target == 'a drachnid champion' and killEv.source == 'Daly' and killEv.ability == 'Kill' and killEv.amount == 0,
  killEv and (tostring(killEv.kind) .. '/' .. tostring(killEv.target) .. '/' .. tostring(killEv.source)))

-- must not have touched damage rollups (it doesn't go through record())
check('kill-by-other does not add to sources rollup', enc.sources['Daly'] == nil)
check('kill-by-other does not change the existing targets rollup', enc.targets['a drachnid champion'] == dmgBefore, enc.targets['a drachnid champion'])

-- ── "X has been slain by Y!" with NO encounter open records nothing ─────
-- force-finalize the open encounter first
clock = clock + 20000 -- past the inactivity gap (gettime() is in ms)
Combat.tick()
check('encounter finalized (no longer active)', getActive() == nil)
check('finalized fight is flagged killed (slain line named the primary target)', finalized and finalized.killed == true,
  finalized and tostring(finalized.killed))
handlers.cmp_kill_other('a bat has been slain by Daly!', 'a bat', 'Daly')
check('kill-by-other with no active fight opens nothing', getActive() == nil)

io.write(string.format('test_kill_events: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
