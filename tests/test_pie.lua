-- Run: luajit tests/test_pie.lua   (from F:\lua\companion)
--
-- The damage-share pie (Live "Damage share" card + the mini meter) folds the
-- meter rows into ranked slices with an "others" tail. Pins the pure slice
-- builder; the wedge drawing itself only runs in-game.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

package.preload['mq'] = function() return { gettime = function() return 0 end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function()
  local t = noop(); t.SLICE = { 'pet', 'spell', 'green' }; return t
end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end

local UI = require('companion.ui')

-- empty / zero rows
local s, grand = UI.pieSlices({}, 8)
check('no rows -> no slices', #s == 0 and grand == 0)
s = UI.pieSlices({ { name = 'a', total = 0 } }, 8)
check('zero totals dropped', #s == 0)

-- ranking, fractions, colours
s, grand = UI.pieSlices({
  { name = 'Rogue', total = 300 }, { name = 'Tester', total = 100, mine = true },
  { name = 'Mage', total = 600 },
}, 8)
check('grand total', grand == 1000, grand)
check('ranked by total', s[1].name == 'Mage' and s[2].name == 'Rogue' and s[3].name == 'Tester')
check('fractions sum to 1', math.abs(s[1].frac + s[2].frac + s[3].frac - 1) < 1e-9)
check('top share', math.abs(s[1].frac - 0.6) < 1e-9, s[1].frac)
check('my row is gold', s[3].color == 'you' and s[3].mine)
check('others cycle the slice palette', s[1].color == 'pet' and s[2].color == 'spell', s[1].color .. ',' .. s[2].color)

-- cap: 5 rows into 4 slices = top 3 + "others (2)"
local rows = {}
for i = 1, 5 do rows[#rows + 1] = { name = 'p' .. i, total = i * 10 } end
s, grand = UI.pieSlices(rows, 4)
check('capped to maxSlices', #s == 4, #s)
check('others is last', s[4].others and s[4].name == 'others (2)', s[4].name)
check('others sums the tail', s[4].total == 30, s[4].total) -- p1 + p2
check('others colour', s[4].color == 'fgFaint')
check('palette wraps past its length', s[1].color == 'pet' and s[3].color == 'green')
s = UI.pieSlices(rows, 5)
check('exactly maxSlices rows -> no others', #s == 5 and not s[5].others)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
