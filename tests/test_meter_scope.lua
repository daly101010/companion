-- Run: luajit tests/test_meter_scope.lua   (from F:\lua\companion)
--
-- The "group only" meter scope (Settings / the all|group toggle on the mini
-- meter and source cards) keeps only me, my group members (black-box roster),
-- companion peers and those players' pets, so a raid parse stays readable.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

-- ── stubs: nothing here renders, so ImGui/theme can be inert ──
package.preload['mq'] = function() return { gettime = function() return 0 end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end

local UI = require('companion.ui')

local prefs = {}
local db = {
  getAllPrefs = function() return prefs end,
  setPref     = function(_, k, v) prefs[k] = tostring(v) end,
}
local peers = {}
local group = { freshPeers = function() return peers end }
UI.setup({ db = db, playerName = 'Tester', group = group })

-- ── roster from the black-box sample shape ({ name = ... }, me excluded) ──
UI.setRoster({ { name = 'Healbot', cls = 'CLR' }, { name = 'Tankguy' } })
peers = { { player = 'Boxmage', playerDmg = 100 } }

local function inScope(row) return UI.inGroupScope(row) end
check('me by name',            inScope({ name = 'Tester' }))
check('me by mine flag',       inScope({ name = 'You', mine = true }))
check('my pet',                inScope({ name = 'Tester`s pet' }))
check('group member',          inScope({ name = 'Healbot' }))
check('group member, any case', inScope({ name = 'HEALBOT' }))
check('group member pet',      inScope({ name = "Tankguy`s pet" }))
check('group member warder (apostrophe)', inScope({ name = "Tankguy's warder" }))
check('peer row (broadcast)',  inScope({ name = 'Boxmage', peer = true }))
check('peer seen third-person', inScope({ name = 'Boxmage' }) == false, 'peers not in roster are not group unless flagged')
check('peer pet by owner',     inScope({ name = 'Boxmage`s pet' }))
check('raid stranger',         inScope({ name = 'Randomdude' }) == false)
check('raid stranger pet',     inScope({ name = 'Randomdude`s pet' }) == false)
check('mob',                   inScope({ name = 'a raid boss' }) == false)

-- roster replaces, never accumulates; nil leaves it alone
UI.setRoster({ 'Newguy' })
check('bare-name roster entries', inScope({ name = 'Newguy' }))
check('old member dropped',       inScope({ name = 'Healbot' }) == false)
UI.setRoster(nil)
check('nil sample keeps roster',  inScope({ name = 'Newguy' }))

-- ── persistence: set_grouponly round-trips through prefs ──
check('off by default', UI.groupOnly() == false)
UI.setGroupOnly(true)
UI.savePrefs()
check('saved as set_grouponly=1', prefs.set_grouponly == '1', prefs.set_grouponly)
UI.setGroupOnly(false)
UI.loadPrefs()
check('loadPrefs restores it', UI.groupOnly() == true)

-- ── mini meter rows: merged, scoped, cached per snapshot/mode/scope ──
UI.setRoster({ 'Healbot' })
peers = { { player = 'Boxmage', playerDmg = 500, playerDps = 50, petName = 'Xarn', petDmg = 100, petDps = 10, healTotal = 0 } }
local snap = { sources = {
  { name = 'Tester', total = 900, dps = 90, mine = true },
  { name = 'Boxmage', total = 10, dps = 1 },       -- my third-person estimate; peer report wins
  { name = 'Randomdude', total = 700, dps = 70 },
}, healSources = {} }
UI.setGroupOnly(false)
local rows = UI.miniRows(snap, false)
check('peer overrides third-person row', rows[3] and rows[3].name == 'Boxmage' and rows[3].total == 500 and rows[3].peer)
check('ranked by total', rows[1].name == 'Tester' and rows[2].name == 'Randomdude' and rows[4].name == 'Xarn')
check('same snapshot -> same table (cached)', UI.miniRows(snap, false) == rows)
UI.setGroupOnly(true)
local scoped = UI.miniRows(snap, false)
check('scope change rebuilds', scoped ~= rows)
check('scoped drops the stranger', #scoped == 3 and scoped[3].name == 'Xarn')
check('mode change rebuilds', UI.miniRows(snap, true) ~= scoped)
check('new snapshot rebuilds', UI.miniRows({ sources = {}, healSources = {} }, false) ~= scoped)
UI.setGroupOnly(false)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
