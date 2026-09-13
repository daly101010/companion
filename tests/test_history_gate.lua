-- Run: luajit tests/test_history_gate.lua   (from F:\lua\companion)
--
-- The history refresh is blocking SQLite on the game thread, so it is gated
-- two ways: a visibility beacon (only refresh while a draw path is running)
-- and a slow tier (recentDeaths + the aggregates cost ~150ms on a large DB;
-- only recentFights runs at the caller's cadence). These tests pin both.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

-- ── stubs: ui.lua only needs mq.gettime here; the rest never runs off-render ──
local nowMs = 0
package.preload['mq'] = function() return { gettime = function() return nowMs end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end

local UI = require('companion.ui')

-- ── fake DB: counts each query so the tiers are observable ──
local calls = { fights = 0, deaths = 0, targets = 0, weapons = 0 }
local db = {
  recentFights     = function() calls.fights = calls.fights + 1; return {} end,
  recentDeaths     = function() calls.deaths = calls.deaths + 1; return {} end,
  targetAggregates = function() calls.targets = calls.targets + 1; return {} end,
  weaponAggregates = function() calls.weapons = calls.weapons + 1; return {} end,
  getAllPrefs      = function() return {} end,
}
UI.setup({ db = db, playerName = 'Tester' })

-- ── visibility beacon ──
check('hidden before any draw', UI.isVisible() == false)
UI.markDrawn()
check('visible right after a draw', UI.isVisible() == true)
nowMs = nowMs + 999
check('still visible within 1s', UI.isVisible() == true)
nowMs = nowMs + 2
check('hidden past 1s', UI.isVisible() == false)

-- ── slow tier ──
nowMs = 100000
UI.refreshHistory({})
check('first refresh runs the slow tier', calls.deaths == 1 and calls.targets == 1 and calls.weapons == 1,
  string.format('d=%d t=%d w=%d', calls.deaths, calls.targets, calls.weapons))
check('first refresh runs recentFights', calls.fights == 1, calls.fights)

nowMs = nowMs + 2000
UI.refreshHistory({})
check('2s later: recentFights only', calls.fights == 2 and calls.deaths == 1,
  string.format('f=%d d=%d', calls.fights, calls.deaths))

nowMs = nowMs + 2000
UI.refreshHistory({})
check('4s in: still no slow tier', calls.deaths == 1, calls.deaths)

nowMs = nowMs + 6001 -- 10.001s since the last slow tier
UI.refreshHistory({})
check('slow tier again past 10s', calls.deaths == 2 and calls.targets == 2 and calls.weapons == 2,
  string.format('d=%d t=%d w=%d', calls.deaths, calls.targets, calls.weapons))

-- force: a finished fight (needRefresh) must not wait out the slow tier
nowMs = nowMs + 100
UI.refreshHistory({}, true)
check('force runs the slow tier immediately', calls.deaths == 3, calls.deaths)
nowMs = nowMs + 100
UI.refreshHistory({})
check('force reset the slow-tier clock', calls.deaths == 3, calls.deaths)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
