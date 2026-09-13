-- Run: lua tests/test_blackbox.lua   (from F:\lua\companion)
-- Pure ring-buffer tests: capacity/ordering, relative t on freeze, dead edge
-- fires once, buff-drop diff only on a count decrease, group codec round-trip.
package.path = './?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

local BlackBox = require('blackbox')

-- fake readers driven by these upvalues
local hp, dead, buffCount, buffNames = 100, false, 3, { 'A', 'B', 'C' }
local readers = {
  me = function() return { hp = hp, dead = dead, buffCount = buffCount, flags = dead and 'dead' or '' } end,
  group = function() return { { name = 'Healz', cls = 'CLR', hp = 90, mana = 50, dist = 12, flag = '', mt = false, ma = false } } end,
  buffNames = function() return buffNames end,
}

-- ── capacity + ordering ──
local bb = BlackBox.new(readers, { hz = 2, seconds = 2 }) -- cap 4
check('cap = 4', bb.cap == 4, bb.cap)
check('first tick samples', bb:tick(0) == true)
check('throttled tick skipped', bb:tick(100) == false)
hp = 90; bb:tick(500)
hp = 80; bb:tick(1000)
hp = 70; bb:tick(1500)
hp = 60; bb:tick(2000) -- overwrites the oldest (hp=100)
local s = bb:freeze(2000)
check('count capped', #s == 4, #s)
check('oldest first', s[1].hp == 90, s[1].hp)
check('newest last', s[4].hp == 60, s[4].hp)
check('t relative <= 0', s[4].t == 0 and s[1].t == -1.5, s[1].t .. ',' .. s[4].t)
check('group attached', s[4].group[1].name == 'Healz')

-- ── dead edge ──
check('no edge yet', bb:deadEdge() == false)
dead = true; bb:tick(2500)
check('edge fires', bb:deadEdge() == true)
check('edge fires once', bb:deadEdge() == false)
bb:tick(3000)
check('still dead: no new edge', bb:deadEdge() == false)
dead = false

-- ── buff drop diff ──
local bb2 = BlackBox.new(readers, { hz = 2, seconds = 10 })
bb2:tick(0) -- count 3, names captured
buffCount = 4; buffNames = { 'A', 'B', 'C', 'D' }; bb2:tick(500)
local f = bb2:freeze(500)
check('increase: nothing dropped', #f[#f].buffsDropped == 0)
buffCount = 2; buffNames = { 'A', 'D' }; bb2:tick(1000)
f = bb2:freeze(1000)
check('decrease: dropped B,C', table.concat(f[#f].buffsDropped, ',') == 'B,C', table.concat(f[#f].buffsDropped, ','))
bb2:tick(1500)
f = bb2:freeze(1500)
check('steady: nothing dropped', #f[#f].buffsDropped == 0)

-- ── reader failure is skipped, not fatal ──
local bb3 = BlackBox.new({ me = function() error('boom') end }, { hz = 2, seconds = 10 })
check('failing reader -> no sample', bb3:tick(0) == false)
check('freeze empty ok', #bb3:freeze(0) == 0)

-- ── group codec ──
local enc = BlackBox.encodeGroup({
  { name = 'Healz', cls = 'CLR', hp = 90.4, mana = 50, dist = 12.6, flag = '', mt = false, ma = true },
  { name = 'Tanky', cls = 'WAR', hp = 10, mana = 0, dist = 3, flag = 'dead', mt = true, ma = false },
})
check('encode', enc == 'Healz:CLR:90:50:12::0:1;Tanky:WAR:10:0:3:dead:1:0', enc)
local dec = BlackBox.decodeGroup(enc)
check('decode count', #dec == 2)
check('decode fields', dec[2].name == 'Tanky' and dec[2].cls == 'WAR' and dec[2].hp == 10 and dec[2].flag == 'dead' and dec[2].mt == true and dec[2].ma == false)
check('decode empty', #BlackBox.decodeGroup('') == 0 and #BlackBox.decodeGroup(nil) == 0)

io.write(string.format('test_blackbox: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
