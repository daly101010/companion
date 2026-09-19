-- Run: luajit tests/test_export_run.lua   (from F:\lua\companion)
--
-- Zone-run export: the UI builds a context from a loaded run (S.selRun
-- shape) and export.lua renders the one-liner and the report from it.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
package.preload['mq'] = function() return { gettime = function() return 0 end, configDir = '/tmp' } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end
local Export = require('companion.export')
local UI = require('companion.ui')
UI.setup({ db = { getAllPrefs = function() return {} end }, playerName = 'Me' })

local sr = {
  run = { session_id = 1, zone = 'anguish', fights = 3, started_at = 1700000000, ended_at = 1700003600,
          combat_sec = 600, total_dmg = 6000000, player_dmg = 1000000, pet_dmg = 200000, incoming = 300000,
          deaths = 1, heal_total = 50000, is_raid = 1 },
  fights = {
    { id = 3, primary_target = 'Overlord', started_at = 1700003000, duration = 300, dps = 15000, total_dmg = 4500000, killed = 1, mob_min_hp = 0, is_raid = 1 },
    { id = 2, primary_target = 'Overlord', started_at = 1700001000, duration = 200, dps = 5000, total_dmg = 1000000, killed = 0, mob_min_hp = 35, is_raid = 1 },
    { id = 1, primary_target = 'a bat', started_at = 1700000000, duration = 100, dps = 5000, total_dmg = 500000, killed = 1 },
  },
  sources = { { source = 'Me', total = 1000000 }, { source = 'Bob', total = 3000000 }, { source = 'Me`s pet', total = 200000, is_pet = 1 } },
  targets = { { mob = 'Overlord', fights = 2, total_dmg = 5500000, avg_dps = 10000 }, { mob = 'a bat', fights = 1, total_dmg = 500000, avg_dps = 5000 } },
}
local ctx = UI.runExportCtx(sr)
check('combined dps over combat time', ctx.dps == 10000, ctx.dps)
check('wall time from first pull to last end', ctx.wall_sec == 3600)
check('mine = player + pet', ctx.mine == 1200000)
check('source dps over combat time, sorted', ctx.sources[1].name == 'Bob' and ctx.sources[1].dps == 5000)
check('attempt text on targets', ctx.targets[1].attempts == '2 attempts, kill on #2', ctx.targets[1].attempts)
check('fights chronological with tags', ctx.fightList[1].target == 'a bat' and ctx.fightList[1].tag == ''
  and ctx.fightList[2].tag == '#1 wipe 35%' and ctx.fightList[3].tag == '#2 kill', ctx.fightList[2].tag)

local line = Export.runCompact(ctx)
check('one-liner names zone, fights, dps', line:find('anguish', 1, true) and line:find('3 fights', 1, true) and line:find('10,000 dps', 1, true), line)
check('one-liner tops by dps', line:find('top: Bob 5,000, Me 1,667', 1, true), line)

local rep = Export.runReport(ctx)
check('report header', rep:find('== Companion zone run: anguish', 1, true) and rep:find(', raid)', 1, true))
check('report totals line', rep:find('wall 60:00   combat 10:00   10,000 dps', 1, true), rep)
check('report share line', rep:find('you%+pet 1.20M %(20%%%)'), rep)
check('report lists targets with attempts', rep:find('Overlord                 2x', 1, true) and rep:find('2 attempts, kill on #2', 1, true))
check('report lists fights with tags', rep:find('#1 wipe 35%', 1, true) and rep:find('#2 kill', 1, true))

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
