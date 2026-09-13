-- Run: luajit tests/test_smartheal.lua   (from F:\lua\companion)
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local SH = require('smartheal')

-- ── a fight the brain covered: tank holds, casts land ──────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, floorPct = 15, maName = 'Daly', shadow = false })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 90 } } }, 0)
SH.onMessage({ kind = 'decision', seq = 1, spell = 'Sacred Light', target = 'Daly',
               tier = 'single', trigger = 'stable_efficiency', targetPct = 70, targetDps = 500 })
SH.onMessage({ kind = 'ack', seq = 1, result = 'CAST_SUCCESS' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 62 } } }, 1000)

local snap = SH.snapshot()
check('snapshot exists', snap ~= nil)
check('tank named', snap and snap.maName == 'Daly', snap and snap.maName)
check('tank min hp', snap and snap.tankMinHp == 62, snap and snap.tankMinHp)
check('tier counted', snap and snap.tiers.single == 1, snap and snap.tiers.single)
check('result counted', snap and snap.results.CAST_SUCCESS == 1)
check('casts counted', snap and snap.casts == 1, snap and snap.casts)
check('decision got its result', snap and snap.decisions[1].result == 'CAST_SUCCESS')
check('no emergency seconds', snap and snap.tankEmergSec == 0, snap and snap.tankEmergSec)

-- ── the tank crosses the emergency line: seconds accrue ────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, maName = 'Daly' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 80 } } }, 0)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 40 } } }, 500)   -- no credit: dt lands on entry
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 } } }, 1500)  -- 1.0s at/below 45
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 70 } } }, 2000)  -- 0.5s at/below 45
snap = SH.snapshot()
check('emergency seconds accrue', snap and math.abs(snap.tankEmergSec - 1.5) < 0.01, snap and snap.tankEmergSec)
check('min hp tracked across dips', snap and snap.tankMinHp == 30, snap and snap.tankMinHp)

-- ── no emergency line yet: seconds must not be invented ────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 10 } } }, 0)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 10 } } }, 5000)
snap = SH.snapshot()
check('no line means unknown seconds', snap and snap.tankEmergSec == nil, snap and snap.tankEmergSec)

-- ── veto, net, unknown kind ────────────────────────────────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'veto', spell = 'Sacred Elixir', target = 'Daly', pct = 42, replacement = 'Pious Light' })
SH.onMessage({ kind = 'net', count = 2 })
check('unknown kind rejected', SH.onMessage({ kind = 'wat' }) == false)
check('non-table rejected', SH.onMessage('nope') == false)
snap = SH.snapshot()
check('veto counted', snap and snap.vetoes == 1)
check('net counted', snap and snap.netFires == 2, snap and snap.netFires)
check('unknown counted', snap and snap.unknown == 1, snap and snap.unknown)

-- ── ack with no matching decision must not crash ───────────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'ack', seq = 99, result = 'SKIP_LOS' })
snap = SH.snapshot()
check('orphan ack counted', snap and snap.results.SKIP_LOS == 1)

-- ── bridge restart mid-fight: seq resets, no double counting ───────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'decision', seq = 7, spell = 'Pious Light', target = 'Daly', tier = 'single' })
SH.onMessage({ kind = 'decision', seq = 1, spell = 'Pious Light', target = 'Zion', tier = 'emergency' })
SH.onMessage({ kind = 'ack', seq = 1, result = 'CAST_SUCCESS' })
snap = SH.snapshot()
check('restart keeps both decisions', snap and #snap.decisions == 2, snap and #snap.decisions)
check('restart acks the new one', snap and snap.decisions[2].result == 'CAST_SUCCESS')
check('restart leaves the stale one open', snap and snap.decisions[1].result == nil)

-- ── ring is capped ─────────────────────────────────────────────────────
SH.resetAll(); SH.setPlayer('Freerez')
for i = 1, SH.RING + 5 do
  SH.onMessage({ kind = 'decision', seq = i, spell = 'Pious Light', target = 'Daly', tier = 'single' })
end
snap = SH.snapshot()
check('ring capped', snap and #snap.decisions == SH.RING, snap and #snap.decisions)
check('ring keeps the newest', snap and snap.decisions[SH.RING].seq == SH.RING + 5)

-- ── stamp writes onto the fight and resets ─────────────────────────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, maName = 'Daly' })
SH.onMessage({ kind = 'decision', seq = 1, spell = 'Sacred Light', target = 'Daly', tier = 'single' })
SH.onMessage({ kind = 'ack', seq = 1, result = 'CAST_SUCCESS' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 55 } } }, 0)
local fight = { deaths = 0 }
local sum = SH.stamp(fight)
check('stamp returns a summary', sum ~= nil)
check('stamp sets min hp', fight.sh_min_hp == 55, fight.sh_min_hp)
check('stamp sets casts', fight.sh_casts == 1, fight.sh_casts)
check('stamp sets a compact summary', type(fight.sh_summary) == 'string' and fight.sh_summary:find('tier:single=1', 1, true) ~= nil, fight.sh_summary)
check('stamp carries decisions', type(fight.sh_decisions) == 'table' and #fight.sh_decisions == 1)
check('stamp reset the bucket', SH.snapshot() == nil)

-- ── a fight with no bridge traffic finalizes to nil ────────────────────
SH.resetAll(); SH.setPlayer('Freerez')
local quiet = { deaths = 0 }
check('quiet fight stamps nil', SH.stamp(quiet) == nil)
check('quiet fight untouched', quiet.sh_summary == nil)

-- ── a member who leaves the group stops accruing emergency seconds ──────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, maName = 'Daly' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 }, { name = 'Zion', hp = 20 } } }, 0)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 }, { name = 'Zion', hp = 20 } } }, 1000)
-- Zion leaves the group; only Daly is sampled from here on
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 } } }, 2000)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 } } }, 3000)
snap = SH.snapshot()
local daly, zion
for _, m in ipairs(snap.members) do
  if m.name == 'Daly' then daly = m elseif m.name == 'Zion' then zion = m end
end
check('present member keeps accruing', daly and math.abs(daly.emergSec - 3.0) < 0.01, daly and daly.emergSec)
check('departed member stops accruing', zion and math.abs(zion.emergSec - 2.0) < 0.01, zion and zion.emergSec)

-- ── snapshot is cached between mutations, and invalidated by each one ───
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, maName = 'Daly' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 80 } } }, 0)
local s1 = SH.snapshot()
local s2 = SH.snapshot()
check('snapshot cached while unchanged', rawequal(s1, s2))
SH.onMessage({ kind = 'decision', seq = 1, spell = 'Pious Light', target = 'Daly', tier = 'single' })
local s3 = SH.snapshot()
check('a message rebuilds the snapshot', not rawequal(s2, s3))
check('rebuilt snapshot sees the new decision', s3 and s3.tiers.single == 1, s3 and s3.tiers.single)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 60 } } }, 1000)
local s4 = SH.snapshot()
check('a sample rebuilds the snapshot', not rawequal(s3, s4))
check('rebuilt snapshot sees the new hp', s4 and s4.tankMinHp == 60, s4 and s4.tankMinHp)
-- a quiet bucket caches its nil rather than re-deciding every frame
SH.reset()
check('quiet bucket snapshots nil', SH.snapshot() == nil)
check('quiet bucket still nil when cached', SH.snapshot() == nil)

-- ── finding 3: config must survive M.stamp's fight-boundary reset ──────
-- The bridge only resends 'config' when a value changes, so fight 2+ gets
-- no new config message. M.reset() (called by M.stamp) must not lose it.
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, floorPct = 15, maName = 'Daly', shadow = false })
SH.onMessage({ kind = 'decision', seq = 1, spell = 'Sacred Light', target = 'Daly', tier = 'single' })
SH.onMessage({ kind = 'ack', seq = 1, result = 'CAST_SUCCESS' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 90 } } }, 0)
SH.stamp({ deaths = 0 }) -- fight 1 ends; no second config message follows
-- fight 2, no config resent
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 90 } } }, 0)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 } } }, 1000)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 30 } } }, 2000)
local snap2 = SH.snapshot()
check('config survives stamp: tank still resolves', snap2 and snap2.maName == 'Daly', snap2 and snap2.maName)
check('config survives stamp: emergency still accrues', snap2 and snap2.tankEmergSec and snap2.tankEmergSec > 0,
    snap2 and snap2.tankEmergSec)

-- ── finding 4: a zeroed/offline reading must not pin minHp to 0 ────────
SH.resetAll(); SH.setPlayer('Freerez')
SH.onMessage({ kind = 'config', emergencyPct = 45, maName = 'Daly' })
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 55 } } }, 0)
-- Daly zones/goes offline: blackbox reports hp=0, not a real near-death dip
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 0 } } }, 1000)
SH.observe({ hp = 100, group = { { name = 'Daly', hp = 60 } } }, 2000)
local snap3 = SH.snapshot()
check('zero reading does not pin minHp to 0', snap3 and snap3.tankMinHp == 55, snap3 and snap3.tankMinHp)

io.write(string.format('smartheal: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
