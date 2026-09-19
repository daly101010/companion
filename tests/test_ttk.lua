-- Run: luajit tests/test_ttk.lua   (from F:\lua\companion)
--
-- Time-to-kill: the 1 Hz target-HP sampler keeps a 30s trail of (t, pct) on
-- the encounter; the snapshot exposes the current HP% and an ETA from the
-- trail's average slope. Heals and target swaps restart the trail.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
local pct = 100
package.preload['mq'] = function()
  return { gettime = function() return clock end, doevents = function() end, event = function() end, unevent = function() end }
end
_G.printf = function() end

local Combat = require('combat')
local finalized
Combat.init({
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'anguish' end,
  getWeapons = function() return nil, nil end,
  getTargetPct = function() return pct end,
  onFinalize = function(fight) finalized = fight end,
})
Combat.timeoutSec = 5
local record = Combat._recordForTest

local function hit(target, amt)
  record({ source = 'Calbuss', target = target, ability = 'Venin', kind = 'nuke', amount = amt or 100, mine = true, outcome = 'hit' })
end
-- one second passes, HP reads `p`, the sampler runs
local function second(p) clock = clock + 1000; pct = p; Combat.tick() end

hit('Overlord'); second(100)
check('pct shown from the first sample', Combat.snapshot().targetPct == 100)
check('no eta before 5s of trail', Combat.snapshot().ttk == nil)
for _, p in ipairs({ 98, 96, 94, 92, 90 }) do hit('Overlord'); second(p) end
local snap = Combat.snapshot()
check('pct tracks the latest sample', snap.targetPct == 90, snap.targetPct)
-- 10% over 5s = 2%/s, 90% left -> 45s
check('eta from the average slope', snap.ttk and math.abs(snap.ttk - 45) < 1e-6, snap.ttk)
check('lowest HP tracked', snap.mobMinPct == 90)

-- a heal (> 2% rise) restarts the trail: no eta until 5s of new samples
hit('Overlord'); second(95)
check('heal drops the eta', Combat.snapshot().ttk == nil)
check('min HP survives the heal', Combat.snapshot().mobMinPct == 90)
for _, p in ipairs({ 94, 93, 92, 91, 90 }) do hit('Overlord'); second(p) end
snap = Combat.snapshot()
check('eta returns from the new trail (1%/s, 90 left)', snap.ttk and math.abs(snap.ttk - 90) < 1e-6, snap.ttk)

-- HP stops falling: the window still holds the earlier fall, so the eta
-- stretches (slower average rate) instead of vanishing
local before = snap.ttk
for _ = 1, 6 do hit('Overlord'); second(90) end
snap = Combat.snapshot()
check('flat stretch stretches the eta', snap.ttk and snap.ttk > before and snap.targetPct == 90, snap.ttk)

-- the window drops samples older than 30s, so an old fast phase stops
-- dominating: 30 flat seconds then 6s of 1%/s -> eta from the recent 1%/s
for _ = 1, 30 do hit('Overlord'); second(90) end
for _, p in ipairs({ 89, 88, 87, 86, 85, 84 }) do hit('Overlord'); second(p) end
snap = Combat.snapshot()
-- window keeps ~31 samples: 24 flat + 7 falling -> slope 6%/30s = 0.2%/s -> 420s
check('eta uses the 30s window', snap.ttk and snap.ttk > 100 and snap.ttk < 1000, snap.ttk)

-- primary target switch (more damage on the new mob) restarts trail + min
for _ = 1, 8 do hit('Add', 1000); second(50) end
snap = Combat.snapshot()
check('target switch restarts the trail', snap.targetPct == 50 and snap.ttk == nil and snap.mobMinPct == 50)

clock = clock + 6000; Combat.tick()
check('min HP persists on the finalized fight', finalized and finalized.mob_min_hp == 50, finalized and finalized.mob_min_hp)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
