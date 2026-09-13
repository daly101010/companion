-- Run: luajit tests/test_hp_estimate.lua   (from F:\lua\companion)
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
local pct = 100
local pcts = {}   -- per-target pct overrides (for the target-swap scenario); falls
                  -- back to the scalar `pct` above so every existing scenario that
                  -- never touches this table keeps behaving exactly as before.
package.preload['mq'] = function()
  return {
    gettime = function() return clock end,
    doevents = function() end,
    event = function() end, unevent = function() end,
  }
end
_G.printf = function() end

local Combat = require('combat')
local finalized
Combat.init({
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'Dranik' end,
  getWeapons = function() return nil, nil end,
  getTargetPct = function(name) return pcts[name] or pct end,
  onFinalize = function(fight) finalized = fight end,
})
Combat.timeoutSec = 5

-- feed damage through the public record path: the DoT tick handler is private,
-- so drive the same shape through the registered event by calling the hook target
local record = Combat._recordForTest
check('test hook exposed', type(record) == 'function')

-- Test-only introspection: peek at the live (unfinalized) encounter via the
-- `active` upvalue closed over by the public Combat.primaryTarget() function.
-- This lets us assert intermediate hpEst/anchor state mid-encounter without
-- ending the fight (finalize() would drop `active` and start a new fight) and
-- without adding any new export to combat.lua.
local function getActive()
  local i = 1
  while true do
    local name, value = debug.getupvalue(Combat.primaryTarget, i)
    if not name then return nil end
    if name == 'active' then return value end
    i = i + 1
  end
end

-- In real play the sampler runs (via Combat.tick) AFTER companion has already
-- processed the damage lines for that tick, so the very first %HP it ever
-- reads already reflects whatever damage has been dealt so far. The anchor
-- must be taken at that CURRENT cumulative damage, not at 0 -- anchoring at 0
-- would let the pre-anchor damage double-count into the next interval.
Combat.tick()                  -- no encounter open yet: sampler is a no-op
-- 1000 dmg drops the mob 2%: 50,000 HP
record({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 98
Combat.tick()                  -- first real sample: anchors at (98%, 1000dmg)
record({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'nuke', amount = 2000, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 94
Combat.tick()                  -- 4% drop against 2000 dmg (3000-1000) -> 50,000
check('primaryTarget', Combat.primaryTarget() == 'a rat')

clock = clock + 6000          -- pass the inactivity gap
Combat.tick()
check('finalized', finalized ~= nil)
check('mob_max_hp ~ 50000', finalized and math.abs(finalized.mob_max_hp - 50000) < 1, finalized and finalized.mob_max_hp)
-- only one measured interval here (the first sample anchors, it doesn't score):
-- 98 -> 94 is a 4-point drop, so weight = 4, not 6.
check('weight = 4', finalized and finalized.mob_hp_weight == 4, finalized and finalized.mob_hp_weight)

-- Mid-fight join: proves the first-sample bias is gone. 1000 dmg is dealt and
-- HP already reads 98% BEFORE the first tick ever runs (e.g. companion started
-- mid-pull). With the old (buggy) "anchor first sample at 0 dmg" behavior this
-- would have anchored at (98%, 0) instead of (98%, 1000), so the next interval
-- would score 2000 dmg over a 2% drop -> 100,000 HP (double the real value).
finalized = nil
record({ source = 'Calbuss', target = 'a snake', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
pct = 98
clock = clock + 1000
Combat.tick()                  -- anchors at (98%, 1000dmg) -- no bias
record({ source = 'Calbuss', target = 'a snake', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
pct = 96
clock = clock + 1000
Combat.tick()                  -- 2% drop against 1000 dmg (2000-1000) -> 50,000, not 100,000
clock = clock + 6000
Combat.tick()
check('mid-fight join has no first-sample bias', finalized and math.abs(finalized.mob_max_hp - 50000) < 1, finalized and finalized.mob_max_hp)

-- A heal (pct rising more than 2%) must reset the anchor, not produce a
-- negative estimate. Numbers re-derived for the "anchor at cumulative damage"
-- fix: the first sample of this encounter anchors at (90%, 500) -- the 500
-- dealt before that first %HP reading is folded into the anchor (as above),
-- not credited to any interval, matching how the sampler actually sees the
-- game (it never observes the mob before the first reading).
finalized = nil; pct = 100
Combat.tick()                  -- no encounter yet: no-op
record({ source = 'Calbuss', target = 'a bat', ability = 'Venin', kind = 'nuke', amount = 500, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 90
Combat.tick()                  -- anchors at (90%, 500dmg) -- no interval measured yet
record({ source = 'Calbuss', target = 'a bat', ability = 'Venin', kind = 'nuke', amount = 500, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 85
Combat.tick()                  -- 5% drop against 500 dmg (1000-500) -> 10,000 HP
pct = 100                      -- healed back up past the re-anchor threshold (85+2)
clock = clock + 1000
Combat.tick()                  -- re-anchors at (100%, 1000dmg) instead of going negative
record({ source = 'Calbuss', target = 'a bat', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 90
Combat.tick()                  -- 10% drop against 1000 dmg (2000-1000) -> 10,000 HP again
clock = clock + 6000
Combat.tick()
check('estimate survives a heal', finalized and finalized.mob_max_hp and finalized.mob_max_hp > 0, finalized and finalized.mob_max_hp)
-- sum = 500*100 (5% drop) + 1000*100 (10% drop) = 150,000; weight = 5 + 10 = 15
check('mob_max_hp after heal ~ 10000', finalized and math.abs(finalized.mob_max_hp - 10000) < 1, finalized and finalized.mob_max_hp)
check('weight after heal = 15', finalized and finalized.mob_hp_weight == 15, finalized and finalized.mob_hp_weight)

-- ── Edge case 1: target swap mid-encounter ──────────────────────────────────
-- When the most-damaged target changes (e.g. adds tank-swap), the sampler must
-- re-anchor on the new primary target instead of silently scoring the swap
-- tick against the old target's stale %HP (which would produce a garbage,
-- possibly negative-looking, estimate).
finalized = nil
pcts = {}
pct = 100
record({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'nuke', amount = 10, mine = true, outcome = 'hit' })
clock = clock + 1000
Combat.tick()                  -- anchors 'a rat' at (100%, 10dmg) -- no scoring yet
record({ source = 'Calbuss', target = 'a rat', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
clock = clock + 1000; pct = 98
Combat.tick()                  -- 2% drop against 1000 dmg (1010-10) -> est 50,000, weight 2
check('swap: rat interval scores weight 2', getActive() and getActive().hpEst.weight == 2, getActive() and getActive().hpEst.weight)
check('swap: rat interval scores ~50000', getActive() and math.abs(getActive().hpEst.sum / getActive().hpEst.weight - 50000) < 1)

-- 5000 dmg to 'a spider' makes it the new most-damaged target (5000 > 1010).
record({ source = 'Calbuss', target = 'a spider', ability = 'Venin', kind = 'nuke', amount = 5000, mine = true, outcome = 'hit' })
pcts['a spider'] = 80           -- spider's own %HP track, independent of the rat's
clock = clock + 1000
Combat.tick()                  -- primary target flips to the spider: RE-ANCHOR, no scoring
check('swap: primary target switched to spider', Combat.primaryTarget() == 'a spider')
check('swap: re-anchor adds no estimate (weight still 2)', getActive() and getActive().hpEst.weight == 2, getActive() and getActive().hpEst.weight)
check('swap: hpEst.target updated to spider', getActive() and getActive().hpEst.target == 'a spider')

-- 1000 more spider damage, spider pct drops 4 (80 -> 76): scores from the new anchor.
record({ source = 'Calbuss', target = 'a spider', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
pcts['a spider'] = 76
clock = clock + 1000
Combat.tick()                  -- 4% drop against 1000 dmg (6000-5000) -> est 25,000, weight 4 (running total 6)
clock = clock + 6000
Combat.tick()
check('swap: finalized', finalized ~= nil)
check('swap: primary_target is spider', finalized and finalized.primary_target == 'a spider', finalized and finalized.primary_target)
-- weighted mean: (50000*2 + 25000*4) / 6 = 200000/6 ~= 33333.33
check('swap: mob_max_hp weighted mean ~33333', finalized and math.abs(finalized.mob_max_hp - 33333.33) < 1, finalized and finalized.mob_max_hp)
check('swap: mob_hp_weight == 6', finalized and finalized.mob_hp_weight == 6, finalized and finalized.mob_hp_weight)

-- ── Edge case 2: nil PctHPs (mob out of range / unreadable) ─────────────────
-- getTargetPct can return nil (target too far, TargetHPs not populated yet).
-- The sampler must not crash on nil, must add nothing while nil, and must
-- anchor cleanly on the first numeric sample it does see -- so mob_hp_weight
-- only reflects drops observed after that point.
finalized = nil
pcts = {}
pct = nil
record({ source = 'Calbuss', target = 'a ghoul', ability = 'Venin', kind = 'nuke', amount = 500, mine = true, outcome = 'hit' })
clock = clock + 1000
Combat.tick()                  -- getTargetPct -> nil: no crash, no anchor taken
check('nil pct: no crash on nil sample', true)
check('nil pct: first nil sample takes no anchor', getActive() and getActive().hpAnchorPct == nil)
record({ source = 'Calbuss', target = 'a ghoul', ability = 'Venin', kind = 'nuke', amount = 500, mine = true, outcome = 'hit' })
clock = clock + 1000
Combat.tick()                  -- still nil: still no crash, still no anchor
check('nil pct: second nil sample still takes no anchor', getActive() and getActive().hpAnchorPct == nil)
record({ source = 'Calbuss', target = 'a ghoul', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
pct = 95
clock = clock + 1000
Combat.tick()                  -- first numeric sample: anchors at (95%, 2000dmg), no scoring
check('nil pct: first numeric sample anchors with no weight yet', getActive() and getActive().hpEst.weight == 0, getActive() and getActive().hpEst.weight)
record({ source = 'Calbuss', target = 'a ghoul', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
pct = 90
clock = clock + 1000
Combat.tick()                  -- 5% drop against 1000 dmg (3000-2000) -> est 20,000, weight 5
clock = clock + 6000
Combat.tick()
check('nil pct: finalized', finalized ~= nil)
check('nil pct: mob_max_hp reflects only the post-anchor drop (20000)', finalized and math.abs(finalized.mob_max_hp - 20000) < 1, finalized and finalized.mob_max_hp)
check('nil pct: weight reflects only the one measured drop (5)', finalized and finalized.mob_hp_weight == 5, finalized and finalized.mob_hp_weight)

-- ── Edge case 3: HP% drop with zero damage recorded between samples ─────────
-- A %HP drop can show up with no damage logged in between (regen glitch, or
-- damage from another group/unlogged source). The code requires `dealt > 0`
-- to score, so this must add nothing to the weight -- but the anchor should
-- still advance to the new %HP so a later *real* drop is measured from the
-- correct baseline instead of the stale pre-glitch one (which would otherwise
-- overstate the next interval's damage and understate max HP).
finalized = nil
pcts = {}
pct = 100
record({ source = 'Calbuss', target = 'a bear', ability = 'Venin', kind = 'nuke', amount = 1000, mine = true, outcome = 'hit' })
clock = clock + 1000
Combat.tick()                  -- anchors 'a bear' at (100%, 1000dmg)
pct = 97                        -- HP drops 3% with NO further damage recorded
clock = clock + 1000
Combat.tick()                  -- drop=3 (>=1) but dealt=1000-1000=0: nothing scored
check('zero-dmg drop: no weight added', getActive() and getActive().hpEst.weight == 0, getActive() and getActive().hpEst.weight)
check('zero-dmg drop: anchor still advances to new pct', getActive() and getActive().hpAnchorPct == 97, getActive() and getActive().hpAnchorPct)
-- a later legitimate drop must be measured from the moved anchor (97%,1000dmg),
-- not the stale pre-glitch one (100%,1000dmg) -- which would double the drop.
record({ source = 'Calbuss', target = 'a bear', ability = 'Venin', kind = 'nuke', amount = 970, mine = true, outcome = 'hit' })
pct = 90
clock = clock + 1000
Combat.tick()                  -- 7% drop against 970 dmg (1970-1000) -> est 970*100/7 ~= 13857.14
clock = clock + 6000
Combat.tick()
check('zero-dmg drop: finalized', finalized ~= nil)
check('zero-dmg drop: mob_max_hp measured from the moved anchor', finalized and math.abs(finalized.mob_max_hp - (970 * 100 / 7)) < 1, finalized and finalized.mob_max_hp)
check('zero-dmg drop: weight reflects only the legit drop (7)', finalized and finalized.mob_hp_weight == 7, finalized and finalized.mob_hp_weight)

io.write(string.format('test_hp_estimate: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
