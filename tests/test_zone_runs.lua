-- Run: luajit tests/test_zone_runs.lua   (from F:\lua\companion)
--
-- History > By Zone groups fights per (session, zone). Selecting a run loads
-- its fights/sources/targets through refreshHistory (never in render), the
-- current session's run is reloaded when a fight finishes, and older runs are
-- left alone.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local nowMs = 0
package.preload['mq'] = function() return { gettime = function() return nowMs end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end

local UI = require('companion.ui')

local runs = {
  { session_id = 7, zone = 'anguish', fights = 3, started_at = 100, ended_at = 900, combat_sec = 300, total_dmg = 30000 },
  { session_id = 5, zone = 'anguish', fights = 9, started_at = 10, ended_at = 90, combat_sec = 800, total_dmg = 90000 },
  { session_id = 7, zone = '', fights = 1, started_at = 950, ended_at = 960, combat_sec = 10, total_dmg = 100 },
}
local calls = { fights = {}, sources = {}, targets = {} }
local db = {
  recentFights     = function() return {} end,
  recentDeaths     = function() return {} end,
  targetAggregates = function() return {} end,
  weaponAggregates = function() return {} end,
  getAllPrefs      = function() return {} end,
  sessionId        = function() return 7 end,
  zoneRuns         = function() return runs end,
  runFights  = function(_, id, zone) calls.fights[#calls.fights + 1] = id .. ':' .. zone; return { { id = 1 }, { id = 2 } } end,
  runSources = function(_, id, zone) calls.sources[#calls.sources + 1] = id .. ':' .. zone; return { { source = 'Me', total = 5 } } end,
  runTargets = function(_, id, zone) calls.targets[#calls.targets + 1] = id .. ':' .. zone; return {} end,
}
UI.setup({ db = db, playerName = 'Me' })

check('nothing selected at start', UI.selectedRun() == nil)
check('no pending select at start', UI.hasPendingSelect() == false)

-- select the older Anguish run
UI.selectRun(runs[2])
check('run selection is pending', UI.hasPendingSelect() == true)
UI.refreshHistory({}, false)
local sr = UI.selectedRun()
check('run loaded', sr ~= nil and sr.run.session_id == 5)
check('fights/sources/targets queried for it', calls.fights[1] == '5:anguish' and calls.sources[1] == '5:anguish' and calls.targets[1] == '5:anguish')
check('fights attached', sr and #sr.fights == 2)
check('pending cleared', UI.hasPendingSelect() == false)

-- an old run is not reloaded when a fight finishes
UI.refreshHistory({}, true)
check('old run not reloaded on force', #calls.fights == 1, #calls.fights)

-- the current session's run IS reloaded on force, not on a plain tick
UI.selectRun(runs[1]); UI.refreshHistory({}, false)
check('current run loaded', #calls.fights == 2 and calls.fights[2] == '7:anguish')
UI.refreshHistory({}, false)
check('plain tick leaves it', #calls.fights == 2)
UI.refreshHistory({}, true)
check('force reloads the current session run', #calls.fights == 3 and calls.fights[3] == '7:anguish')

-- a missing zone binds '' so COALESCE(zone,'') matches
UI.selectRun(runs[3]); UI.refreshHistory({}, false)
check('empty zone bound as empty string', calls.fights[#calls.fights] == '7:')

UI.clearRun()
check('clear drops the selection', UI.selectedRun() == nil)
UI.refreshHistory({}, true)
check('nothing reloads after clear', #calls.fights == 4, #calls.fights)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
