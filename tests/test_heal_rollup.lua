-- Run: luajit tests/test_heal_rollup.lua   (from F:\lua\companion)
-- A lifetap's damage line and its "You healed <me> for N (M) ... by <tap>" line must
-- land in separate ability rows: damage row keyed source|ability (kind nuke/dot),
-- heal row keyed source|ability|heal (kind heal). Pure heals only get the heal row.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
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
Combat.init({
  playerName = function() return 'Esskay' end,
  getZone = function() return 'Corathus Mines' end,
  getWeapons = function() return nil, nil end,
  getTarget = function() return 'a creep reaper' end,
  spellDuration = function(spell) return spell == 'Bond of Inruku' and 7 or 0 end,
  isRaidTarget = function() return false end,
})

local function getActive()
  local i = 1
  while true do
    local name, value = debug.getupvalue(Combat.primaryTarget, i)
    if not name then return nil end
    if name == 'active' then return value end
    i = i + 1
  end
end

local record = Combat._recordForTest
record { source = 'Esskay', target = 'a creep reaper', ability = 'Crush', kind = 'melee', amount = 671, mine = true, outcome = 'hit' }
record { source = 'Esskay', target = 'a creep reaper', ability = 'Touch of the Devourer', kind = 'nuke', amount = 3025, mine = true, outcome = 'hit' }
record { source = 'Esskay', target = 'Esskay', ability = 'Touch of the Devourer', kind = 'heal', amount = 398, over = 2628, mine = true, outcome = 'hit' }
record { source = 'Esskay', target = 'Esskay', ability = 'Pious Light', kind = 'heal', amount = 4979, over = 188, mine = true, outcome = 'hit' }

local enc = getActive()
check('encounter open', enc ~= nil)
local ab = enc and enc.abilities or {}

local melee = ab['Esskay|Crush']
check('melee row unchanged', melee and melee.kind == 'melee' and melee.total == 671 and melee.hits == 1,
  melee and (tostring(melee.kind) .. '/' .. tostring(melee.total)))

local tapDmg = ab['Esskay|Touch of the Devourer']
check('tap damage row: kind nuke, damage only', tapDmg and tapDmg.kind == 'nuke' and tapDmg.total == 3025
  and tapDmg.hits == 1 and (tapDmg.over or 0) == 0,
  tapDmg and string.format('%s total=%s hits=%s over=%s', tostring(tapDmg.kind), tostring(tapDmg.total), tostring(tapDmg.hits), tostring(tapDmg.over)))

local tapHeal = ab['Esskay|Touch of the Devourer|heal']
check('tap heal row: kind heal, effective + overheal', tapHeal and tapHeal.kind == 'heal' and tapHeal.total == 398
  and tapHeal.hits == 1 and tapHeal.over == 2628,
  tapHeal and string.format('%s total=%s hits=%s over=%s', tostring(tapHeal.kind), tostring(tapHeal.total), tostring(tapHeal.hits), tostring(tapHeal.over)))

check('pure heal: heal row only', ab['Esskay|Pious Light|heal'] ~= nil and ab['Esskay|Pious Light|heal'].kind == 'heal'
  and ab['Esskay|Pious Light'] == nil)

-- casts: the tap classifies as damage, the pure heal as heal
handlers.cmp_cast_my('You begin casting Touch of the Devourer.', 'Touch of the Devourer')
handlers.cmp_cast_my('You begin casting Pious Light.', 'Pious Light')

clock = clock + 1000
local snap = Combat.snapshot()
check('snapshot built', snap ~= nil)

local function findRow(list, ability)
  for _, a in ipairs(list or {}) do if a.ability == ability then return a end end
end
local dmgView = snap and snap.abilitiesBySource and snap.abilitiesBySource['Esskay']
local healView = snap and snap.healAbilitiesBySource and snap.healAbilitiesBySource['Esskay']
check('tap in damage view as damage', findRow(dmgView, 'Touch of the Devourer') and findRow(dmgView, 'Touch of the Devourer').kind == 'nuke')
check('tap in heal view as heal', findRow(healView, 'Touch of the Devourer') and findRow(healView, 'Touch of the Devourer').kind == 'heal')
check('pure heal not in damage view', findRow(dmgView, 'Pious Light') == nil)

local function castKind(spell)
  for _, c in ipairs(snap and snap.casts or {}) do if c.spell == spell then return c.kind end end
end
check('tap cast classifies damage', castKind('Touch of the Devourer') == 'damage', castKind('Touch of the Devourer'))
check('pure heal cast classifies heal', castKind('Pious Light') == 'heal', castKind('Pious Light'))

io.write(string.format('test_heal_rollup: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
