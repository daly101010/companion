-- Run: lua tests/test_postmortem.lua   (from F:\lua\companion)
-- One synthetic scenario per cause class + moments + narrative + stamp.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local PM = require('postmortem')
local ME = 'Calbuss'
local DEATH_T = 100 -- encounter-relative death time

-- samples every 0.5s from -10s..0 with hp from fn(t); extra(t) merges fields
local function mkSamples(hpFn, extra)
  local out = {}
  for i = 0, 20 do
    local t = -10 + i * 0.5
    local s = { t = t, hp = hpFn(t), flags = '', aggro = 0, group = {}, buffsDropped = {} }
    if extra then for k, v in pairs(extra(t)) do s[k] = v end end
    out[#out + 1] = s
  end
  return out
end
-- incoming hit to me at death-relative time rel
local function hit(rel, src, amt, kind)
  return { t = DEATH_T + rel, source = src, target = ME, ability = kind == 'dot' and src or 'Slash', kind = kind or 'melee', amount = amt, outcome = 'hit' }
end
local function heal(rel, healer, amt)
  return { t = DEATH_T + rel, source = healer, target = ME, ability = 'Heal', kind = 'heal', amount = amt, outcome = 'hit' }
end
local deathEv = { t = DEATH_T, source = 'a dragon', target = ME, ability = 'Death', kind = 'death', amount = 0, outcome = 'death' }
local function run(samples, events)
  return PM.analyze({ samples = samples, events = events, deathT = DEATH_T, playerName = ME })
end
-- steady drain 100% -> 10% over the 10s window: 4.5%/sample, 27% per 3s span
-- (< 40 burst threshold) and it crosses all three 75/50/25 thresholds
local function drain(t) return math.max(0, 10 - t * 9) end
local function drainHits(src) local ev = {}; for i = 0, 19 do ev[#ev + 1] = hit(-10 + i * 0.5, src or 'a rat', 300) end; return ev end

-- 1. burst
do
  local s = mkSamples(function(t) return t < -2 and 100 or (t < -1 and 90 or 5) end)
  local v = run(s, { hit(-1.2, 'a dragon', 9000, 'nuke'), deathEv })
  check('burst cause', v.cause == 'burst', v.cause)
  check('burst killer', v.killer == 'a dragon', v.killer)
  check('burst narrative mentions dragon', v.narrative[1]:find('a dragon', 1, true) ~= nil, v.narrative[1])
end
-- 1b. one-shot: the only HP evidence is the terminal sample appended at death
do
  local s = { { t = -0.5, hp = 100, flags = '', aggro = 0, group = {}, buffsDropped = {} },
              { t = 0, hp = 0, flags = '', aggro = 0, group = {}, buffsDropped = {}, terminal = true } }
  local v = run(s, { hit(-0.2, 'a dragon', 12000, 'nuke'), deathEv })
  check('one-shot is burst', v.cause == 'burst', v.cause)
  check('one-shot hp series reaches 0', v.hpSeries[#v.hpSeries].hp == 0)
end
-- 2. environmental
do
  local s = mkSamples(function(t) return t < -5 and 100 or 100 - (t + 5) * 16 end) -- 100% -> 20% with no damage lines
  local v = run(s, { { t = DEATH_T, source = '?', target = ME, kind = 'death', amount = 0, outcome = 'death' } })
  check('environmental cause', v.cause == 'environmental', v.cause)
end
-- 3. cc
do
  local s = mkSamples(drain, function(t) return { flags = t >= -2 and 'stun' or '' } end)
  local v = run(s, drainHits())
  check('cc cause', v.cause == 'cc', v.cause)
  local found = false
  for _, m in ipairs(v.moments) do if m.kind == 'cc' then found = true end end
  check('cc moment', found)
end
-- 4. noheals (healer OOM, no heals)
do
  local grp = { { name = 'Healz', cls = 'CLR', hp = 80, mana = 4, dist = 10, flag = '', mt = false, ma = false } }
  local s = mkSamples(drain, function() return { group = grp } end)
  local v = run(s, drainHits())
  check('noheals cause', v.cause == 'noheals', v.cause)
  check('noheals reason', v.healerReasons[1] and v.healerReasons[1]:find('mana', 1, true) ~= nil, v.healerReasons[1])
end
-- 5. aggro (tank exists, my aggro climbs to 100 in the last 15s; heals fine)
do
  local grp = { { name = 'Tanky', cls = 'WAR', hp = 80, mana = 0, dist = 5, flag = '', mt = true, ma = false },
                { name = 'Healz', cls = 'CLR', hp = 80, mana = 80, dist = 10, flag = '', mt = false, ma = false } }
  local s = mkSamples(drain, function(t) return { group = grp, tank = 'Tanky', aggro = t < -6 and 30 or 100, aggro2Name = 'Tanky' } end)
  local ev = drainHits(); ev[#ev + 1] = heal(-4, 'Healz', 3000)
  local v = run(s, ev)
  check('aggro cause', v.cause == 'aggro', v.cause)
end
-- 5b. long-standing aggro (transition at -30s, outside the 15s window) is NOT 'aggro'
do
  local grp = { { name = 'Tanky', cls = 'WAR', hp = 80, mana = 0, dist = 5, flag = '', mt = true, ma = false },
                { name = 'Healz', cls = 'CLR', hp = 80, mana = 80, dist = 10, flag = '', mt = false, ma = false } }
  local s = {}
  for i = 0, 80 do
    local t = -40 + i * 0.5
    s[#s + 1] = { t = t, hp = math.max(0, 10 - t * 2.25), flags = '', group = grp, tank = 'Tanky', buffsDropped = {},
      aggro = t < -30 and 50 or 100 }
  end
  local ev = drainHits(); ev[#ev + 1] = heal(-4, 'Healz', 3000)
  local v = run(s, ev)
  check('old aggro is not the cause', v.cause ~= 'aggro', v.cause)
  check('old aggro falls through to sustained', v.cause == 'sustained', v.cause)
end
-- 5c. aggro climbs to 100 but the runner-up is not the tank: not 'aggro'
do
  local grp = { { name = 'Tanky', cls = 'WAR', hp = 80, mana = 0, dist = 5, flag = '', mt = true, ma = false },
                { name = 'Healz', cls = 'CLR', hp = 80, mana = 80, dist = 10, flag = '', mt = false, ma = false } }
  local s = mkSamples(drain, function(t) return { group = grp, tank = 'Tanky', aggro = t < -6 and 30 or 100, aggro2Name = 'Healz' } end)
  local ev = drainHits(); ev[#ev + 1] = heal(-4, 'Healz', 3000)
  local v = run(s, ev)
  check('non-tank runner-up is not aggro', v.cause ~= 'aggro', v.cause)
end
-- 6. overwhelmed (3 attackers, no tank)
do
  local s = mkSamples(drain)
  local ev = {}
  for i = 0, 9 do ev[#ev + 1] = hit(-10 + i, 'a rat', 200); ev[#ev + 1] = hit(-9.5 + i, 'a bat', 200); ev[#ev + 1] = hit(-9.7 + i, 'a snake', 200) end
  local v = run(s, ev)
  check('overwhelmed cause', v.cause == 'overwhelmed', v.cause)
  check('attackers = 3', v.incoming10.attackers == 3, v.incoming10.attackers)
end
-- 7. dot
do
  local s = mkSamples(drain)
  local ev = {}
  for i = 0, 9 do ev[#ev + 1] = hit(-10 + i, 'Plague', 700, 'dot'); ev[#ev + 1] = hit(-9.5 + i, 'a rat', 100) end
  local v = run(s, ev)
  check('dot cause', v.cause == 'dot', v.cause)
end
-- 8. sustained + moments + heals
do
  local s = mkSamples(drain)
  local ev = drainHits(); ev[#ev + 1] = heal(-3, 'Healz', 500); ev[#ev + 1] = deathEv
  local v = run(s, ev)
  check('sustained cause', v.cause == 'sustained', v.cause)
  local kinds = {}
  for _, m in ipairs(v.moments) do kinds[m.kind] = (kinds[m.kind] or 0) + 1 end
  check('hp crossings 75/50/25', kinds.hp == 3, kinds.hp)
  check('heal moment', kinds.heal == 1, kinds.heal)
  check('death moment last', v.moments[#v.moments].kind == 'death')
  check('moments chronological', v.moments[1].t <= v.moments[#v.moments].t)
  check('heals10 total', v.heals10.total == 500, v.heals10.total)
  check('ticks include heal + dmg', #v.ticks == 21, #v.ticks)
  check('hpSeries populated', #v.hpSeries == 21, #v.hpSeries)
end
-- 9. unknown (nothing at all)
do
  local v = run({}, {})
  check('unknown cause', v.cause == 'unknown', v.cause)
  check('unknown narrative non-empty', type(v.narrative[1]) == 'string' and #v.narrative[1] > 0)
end
-- 10. buff drop + group member death moments
do
  local function grpAt(t) return { { name = 'Healz', cls = 'CLR', hp = t < -4 and 50 or 0, mana = 60, dist = 10, flag = t < -4 and '' or 'dead', mt = false, ma = false } } end
  local s = mkSamples(drain, function(t) return { group = grpAt(t), buffsDropped = (t == -6) and { 'Rune V' } or {} } end)
  local v = run(s, drainHits())
  local buff, died = false, false
  for _, m in ipairs(v.moments) do
    if m.kind == 'buff' and m.text:find('Rune V', 1, true) then buff = true end
    if m.kind == 'group' and m.text:find('Healz', 1, true) then died = true end
  end
  check('buff drop moment', buff)
  check('group death moment', died)
  check('healer dead reason -> noheals', v.cause == 'noheals', v.cause)
end
-- 11. stamp
do
  local fight = { events = drainHits(), deaths_detail = { { t = DEATH_T, killer = 'a rat', samples = mkSamples(drain) } } }
  PM.stamp(fight, ME)
  local d = fight.deaths_detail[1]
  check('stamp cause', d.cause == 'sustained', d.cause)
  check('stamp narrative', type(d.narrative) == 'string' and #d.narrative > 0)
  check('stamp hp_curve', d.hp_curve:match('^%-10%.0:100,') ~= nil, d.hp_curve:sub(1, 20))
  check('CAUSE_LABEL', PM.CAUSE_LABEL.noheals == 'no heals')
end

io.write(string.format('test_postmortem: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
