-- Run: luajit tests/test_event_cap.lua   (from F:\lua\companion)
-- The raw event log has two budgets: the player's own lines, incoming to me, kills, deaths and
-- fades must never be crowded out by a raid's third-person melee. Anguish 2026-09-13: boss fights
-- hit the single 4000-event cap 57-90 s in, so every later own cast/resist was missing from
-- `event` while the rollups kept counting. Also: own casts just before the first damage line of a
-- pull attach to the encounter that line opens.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local clock = 0
local target = 'Overlord Mata Muram'
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
  playerName = function() return 'Calbuss' end,
  getZone = function() return 'anguish' end,
  getWeapons = function() return nil, nil end,
  getTarget = function() return target end,
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
local function count(enc, pred)
  local n = 0
  for _, e in ipairs(enc.events) do if pred(e) then n = n + 1 end end
  return n
end

check('own budget defaults to the other budget', Combat.maxOwnEvents == Combat.maxEvents, Combat.maxOwnEvents)
Combat.maxEvents, Combat.maxOwnEvents = 5, 8

-- ── a raid's melee fills the other-player budget ─────────────────────────
record { source = 'Calbuss', target = target, ability = "Vakk`dra's Sickly Mists", kind = 'dot', amount = 1000, mine = true, outcome = 'hit' }
local enc = getActive()
check('own hit opened an encounter', enc ~= nil)
for _ = 1, 12 do
  record { source = 'Daly', target = target, ability = 'Crush', kind = 'melee', amount = 10, mine = false, outcome = 'hit' }
end
local function dalyMelee(e) return e.source == 'Daly' and e.kind == 'melee' end
check('other-player events stop at maxEvents', count(enc, dalyMelee) == 5, count(enc, dalyMelee))
check('rollups still count every capped hit', enc.sources['Daly'] and enc.sources['Daly'].total == 120,
  enc.sources['Daly'] and enc.sources['Daly'].total)

-- ── own lines, kills and deaths still land after that cap ────────────────
handlers.cmp_cast_my("You begin casting Ashengate Pyre.", 'Ashengate Pyre')
check('own cast kept past the other-player cap',
  count(enc, function(e) return e.kind == 'cast' and e.source == 'Calbuss' and e.ability == 'Ashengate Pyre' and e.target == target end) == 1)
handlers.cmp_my_resist('Overlord Mata Muram resisted your Ashengate Pyre!', target, 'Ashengate Pyre')
check('own resist kept past the other-player cap',
  count(enc, function(e) return e.outcome == 'resist' and e.ability == 'Ashengate Pyre' and e.target == target end) == 1)
record { source = 'a raging pit hound', target = 'Calbuss', ability = 'Bite', kind = 'melee', amount = 500, incoming = true, outcome = 'hit' }
check('incoming damage to me kept past the other-player cap', count(enc, function(e) return e.source == 'a raging pit hound' end) == 1)
handlers.cmp_kill_other('a raging pit hound has been slain by Daly!', 'a raging pit hound', 'Daly')
check('kill line kept past the other-player cap', count(enc, function(e) return e.kind == 'kill' end) == 1)
handlers.cmp_cast_ot('Daly begins casting Complete Heal.', 'Daly', 'Complete Heal')
check('other-player cast dropped at the cap', count(enc, function(e) return e.ability == 'Complete Heal' end) == 0)
check('other-player cast still counted in the cast rollup', enc.casts['Daly|Complete Heal'] and enc.casts['Daly|Complete Heal'].casts == 1)
check('recordDeath returns a new death', Combat.recordDeath('Overlord Mata Muram') == true)
local d = enc.deathRecords[#enc.deathRecords]
check('death event kept past the other-player cap', d and d.eventIndex and enc.events[d.eventIndex] and enc.events[d.eventIndex].kind == 'death',
  d and tostring(d.eventIndex))

-- ── the own budget is bounded too ────────────────────────────────────────
for _ = 1, 20 do
  record { source = 'Calbuss', target = target, ability = "Vakk`dra's Sickly Mists", kind = 'dot', amount = 900, mine = true, outcome = 'hit' }
end
-- own budget so far: opening hit, cast, resist, incoming hit, kill line (source Daly), death = 6,
-- then the 20 own hits fill the last 2 slots
local own = count(enc, function(e) return not dalyMelee(e) end)
check('own-line events stop at maxOwnEvents', own == 8, own)
check('the other-player count is unchanged by own lines', count(enc, dalyMelee) == 5)

-- ── pre-pull own casts attach to the encounter the first damage opens ────
clock = clock + 60000
Combat.tick()
check('encounter closed after the gap', getActive() == nil)
Combat.maxEvents, Combat.maxOwnEvents = 4000, 4000

clock = clock + 1000
handlers.cmp_cast_my("You begin casting Vakk`dra's Sickly Mists.", "Vakk`dra's Sickly Mists")
handlers.cmp_cast_ot('Daly begins casting Complete Heal.', 'Daly', 'Complete Heal')
check('a cast alone still opens no encounter', getActive() == nil)
clock = clock + 3000
record { source = 'Calbuss', target = target, ability = "Vakk`dra's Sickly Mists", kind = 'dot', amount = 1100, mine = true, outcome = 'hit' }
enc = getActive()
local pre = enc and enc.events[1]
check('pre-pull own cast is the first event of the new encounter', pre and pre.kind == 'cast' and pre.source == 'Calbuss'
  and pre.ability == "Vakk`dra's Sickly Mists" and pre.target == target and pre.t == 0,
  pre and (tostring(pre.kind) .. '/' .. tostring(pre.ability) .. '/' .. tostring(pre.t)))
check('pre-pull own cast counted in the cast rollup', enc and enc.casts["Calbuss|Vakk`dra's Sickly Mists"]
  and enc.casts["Calbuss|Vakk`dra's Sickly Mists"].casts == 1)
check('other players are not buffered pre-pull', enc and enc.casts['Daly|Complete Heal'] == nil)

clock = clock + 60000
Combat.tick()
handlers.cmp_cast_my('You begin casting Dead Men Floating.', 'Dead Men Floating')
clock = clock + (Combat.prePullCastSec + 4) * 1000
record { source = 'Calbuss', target = target, ability = 'Ashengate Pyre', kind = 'dot', amount = 1400, mine = true, outcome = 'hit' }
enc = getActive()
check('a cast older than prePullCastSec is not attached', enc and count(enc, function(e) return e.kind == 'cast' end) == 0
  and enc.casts['Calbuss|Dead Men Floating'] == nil)

io.write(string.format('test_event_cap: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
