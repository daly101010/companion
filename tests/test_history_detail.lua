-- Run: luajit tests/test_history_detail.lua   (from F:\lua\companion)
--
-- The History detail panel derives its source list, per-source ability rows,
-- kind series and totals from a selected fight's events. Those are cached on
-- the selection (and the timeline's per-source event subset on the snapshot)
-- so the render callback stops re-walking every event each frame.
package.path = './?.lua;../?.lua;' .. package.path
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end

package.preload['mq'] = function() return { gettime = function() return 0 end } end
local function noop() return setmetatable({}, { __index = function() return function() end end }) end
package.preload['ImGui'] = function() return noop() end
package.preload['companion.theme'] = function() return noop() end
package.preload['companion.export'] = function() return noop() end
package.preload['companion.postmortem'] = function() return noop() end
_G.printf = function() end

local UI = require('companion.ui')
UI.setup({ db = { getAllPrefs = function() return {} end }, playerName = 'Me' })

local sel = {
  fight = { id = 1, duration = 10 },
  abilities = {
    { source = 'Me', ability = 'Slash', kind = 'melee', total = 600 },
    { source = 'Me', ability = 'Nuke', kind = 'nuke', total = 900 },
    { source = 'Bob', ability = 'Kick', kind = 'melee', total = 100 },
  },
  events = {
    { t = 0.5, source = 'Me', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 300, outcome = 'hit' },
    { t = 1.2, source = 'Me', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 300, outcome = 'hit' },
    { t = 1.5, source = 'Me', target = 'a rat', ability = 'Nuke', kind = 'nuke', amount = 900, outcome = 'hit' },
    { t = 2.0, source = 'Me', target = 'a rat', ability = 'Slash', kind = 'melee', amount = 0, outcome = 'miss' },
    { t = 3.0, source = 'a rat', target = 'Me', ability = 'Bite', kind = 'melee', amount = 50, outcome = 'hit' },
    { t = 4.0, source = 'a rat', target = 'Me', ability = 'Bite', kind = 'melee', amount = 70, outcome = 'hit', crit = 1 },
    { t = 4.5, source = 'Bob', target = 'a rat', ability = 'Kick', kind = 'melee', amount = 100, outcome = 'hit' },
  },
}

-- sources: ability rollups first, then the mob that hit me from the event log
local srcs = UI.histSources(sel)
check('three sources', #srcs == 3, #srcs)
check('ranked by total', srcs[1].name == 'Me' and srcs[1].total == 1500)
check('mob appended as incoming', srcs[2].name == 'a rat' and srcs[2].incoming and srcs[2].total == 120)
check('mob dps over fight duration', math.abs(srcs[2].dps - 12) < 1e-9)
check('same table on the next frame', UI.histSources(sel) == srcs)

-- my derived data: ability rows come from fight_ability, totals from events
local d = UI.histDerived(sel, 'Me')
check('own events only', #d.events == 4)
check('ability rows from rollups, sorted', d.abils[1].ability == 'Nuke' and d.abils[2].ability == 'Slash')
check('encounter total counts hits only', d.stot == 1500, d.stot)
check('active seconds = distinct hit seconds', d.asec == 2, d.asec) -- seconds 0 and 1
check('kind series per second', d.kind.melee[0] == 300 and d.kind.melee[1] == 300 and d.kind.nuke[1] == 900)
check('cached per source', UI.histDerived(sel, 'Me') == d)

-- the mob has no ability rows: they are rebuilt from its events
local m = UI.histDerived(sel, 'a rat')
check('mob abilities from events', #m.abils == 1 and m.abils[1].ability == 'Bite' and m.abils[1].total == 120)
check('mob hits/crits/min/max', m.abils[1].hits == 2 and m.abils[1].crits == 1 and m.abils[1].min_hit == 50 and m.abils[1].max_hit == 70)
check('different source, different cache entry', m ~= d)

-- timeline subset cached on the snapshot table
local snap = { events = sel.events, duration = 10 }
local ev = UI.sourceEvents(snap, 'Bob')
check('subset holds only that source', #ev == 1 and ev[1].source == 'Bob')
check('subset cached on the snapshot', UI.sourceEvents(snap, 'Bob') == ev)
check('new snapshot object rebuilds', UI.sourceEvents({ events = sel.events }, 'Bob') ~= ev)

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
