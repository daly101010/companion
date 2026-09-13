-- Run: lua tests/test_death_capture.lua   (from F:\lua\companion)
-- Drives the registered mq.event handlers (captured from a fake mq) to prove:
-- a death freezes the black box onto the encounter, duplicate death lines
-- within 5s collapse into one (killer back-filled), wornoff/castfail events
-- are logged only while an encounter is open, and deaths_detail survives
-- buildFight/finalize.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 1000 -- ms
local handlers = {}
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
local finalized = nil
local FAKE_SAMPLES = { { t = -1, hp = 20 }, { t = 0, hp = 3 } }
Combat.init({
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'Dranik' end,
  getWeapons = function() return nil, nil end,
  getTarget = function() return 'a rat' end,
  freezeBlackBox = function(nowMs) check('freeze gets nowMs', nowMs == clock, nowMs); return FAKE_SAMPLES end,
  onFinalize = function(fight) finalized = fight end,
})
local record = Combat._recordForTest

local function getActive()
  local i = 1
  while true do
    local name, value = debug.getupvalue(Combat.primaryTarget, i)
    if not name then return nil end
    if name == 'active' then return value end
    i = i + 1
  end
end
local function lastEvent() local e = getActive().events; return e[#e] end

check('cmp_wornoff registered', type(handlers.cmp_wornoff) == 'function')
check('cmp_death_me registered', type(handlers.cmp_death_me) == 'function')

-- wornoff / castfail with no encounter: ignored, never opens one
handlers.cmp_wornoff('Your Rune V spell has worn off.', 'Rune V')
handlers.cmp_fizz_my('Your Heal spell fizzles!', 'Heal')
check('no encounter from wornoff/castfail', getActive() == nil)

-- open an encounter with a hit, then log wornoff + castfail
record { source = 'a rat', target = 'Calbuss', ability = 'Bite', kind = 'melee', amount = 50, incoming = true, outcome = 'hit' }
handlers.cmp_wornoff('Your Rune V spell has worn off.', 'Rune V')
check('wornoff event', lastEvent().kind == 'wornoff' and lastEvent().ability == 'Rune V' and lastEvent().outcome == 'fade', lastEvent().kind)
handlers.cmp_fizz_my('Your Heal spell fizzles!', 'Heal')
check('fizzle event', lastEvent().kind == 'castfail' and lastEvent().outcome == 'fizzle' and lastEvent().source == 'Calbuss')
handlers.cmp_int_ot("Healz's Complete Heal spell is interrupted.", 'Healz', 'Complete Heal')
check('other interrupt event', lastEvent().kind == 'castfail' and lastEvent().outcome == 'interrupt' and lastEvent().source == 'Healz' and lastEvent().ability == 'Complete Heal')
check('castfail counted in casts rollup', getActive().casts['Healz|Complete Heal'].interrupts == 1)

-- death via chat line
clock = 5000
handlers.cmp_death_me('You have been slain by a rat!', 'a rat')
local enc = getActive()
check('deaths = 1', enc.deaths == 1, enc.deaths)
check('death event', lastEvent().kind == 'death' and lastEvent().source == 'a rat')
check('deathRecords 1', #enc.deathRecords == 1)
check('record killer', enc.deathRecords[1].killer == 'a rat')
check('record samples copied+terminal', #enc.deathRecords[1].samples == #FAKE_SAMPLES + 1)
check('record samples[1] preserved', enc.deathRecords[1].samples[1] == FAKE_SAMPLES[1])
do
  local last = enc.deathRecords[1].samples[#enc.deathRecords[1].samples]
  check('terminal sample at 0 hp', last.t == 0 and last.hp == 0 and last.terminal == true)
end
check('record t', math.abs(enc.deathRecords[1].t - (5000 - 1000) / 1000) < 0.001, enc.deathRecords[1].t)

-- "You died." right after: deduped
handlers.cmp_death_me2('You died.')
check('dedupe within 5s', getActive().deaths == 1, getActive().deaths)
-- TLO edge fallback right after: deduped too
check('recordDeath returns false when deduped', Combat.recordDeath(nil) == false)
check('still 1 death', getActive().deaths == 1)

-- edge-first then chat line: killer back-filled
clock = 30000
check('edge death recorded', Combat.recordDeath(nil) == true)
check('deaths = 2', getActive().deaths == 2)
check('unknown killer', getActive().deathRecords[2].killer == '?')
handlers.cmp_death_me('You have been slain by a bat!', 'a bat')
check('still 2 deaths', getActive().deaths == 2)
check('killer back-filled', getActive().deathRecords[2].killer == 'a bat', getActive().deathRecords[2].killer)
local ev = getActive().events[getActive().deathRecords[2].eventIndex]
check('death event killer back-filled', ev.kind == 'death' and ev.source == 'a bat')

-- at the event cap: no death event is appended, eventIndex must be nil (not a stale index)
clock = 55000
local savedMax = Combat.maxEvents
Combat.maxEvents = #getActive().events
check('capped death recorded', Combat.recordDeath('a wolf') == true)
check('deaths = 3', getActive().deaths == 3, getActive().deaths)
check('eventIndex nil at cap', getActive().deathRecords[3].eventIndex == nil, tostring(getActive().deathRecords[3].eventIndex))
Combat.maxEvents = savedMax

-- deaths_detail survives finalize
clock = 80000
Combat.flush()
check('finalized', finalized ~= nil)
check('deaths_detail on fight', finalized and #finalized.deaths_detail == 3, finalized and #finalized.deaths_detail)
check('fight.deaths = 3', finalized and finalized.deaths == 3)

io.write(string.format('test_death_capture: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
