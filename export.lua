-- companion/export.lua
-- Turn a fight into shareable text: a full multi-line report written to a file,
-- plus a compact one-liner printed to the MQ console (paste into guild chat).
-- `ctx` shape (assembled by the UI from a live snapshot or a history selection):
--   { title, zone, duration, sources=[{name,total,dps}],
--     breakdown=[abilities], healers=[{name,total,hps,overpct}],
--     incoming=[{name,total}] }

local mq = require('mq')

local M = {}

-- self-contained formatters (kept out of ui.lua's locals)
local function comma(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    return (s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end
local function fmtK(n)
    n = n or 0
    if n >= 1e6 then return string.format('%.2fM', n / 1e6) end
    if n >= 1000 then return string.format('%.1fk', n / 1000) end
    return tostring(math.floor(n + 0.5))
end
local function mmss(sec)
    sec = math.floor(sec or 0)
    return string.format('%d:%02d', math.floor(sec / 60), sec % 60)
end

---@param ctx table
---@return string  compact one-line summary
function M.compact(ctx)
    local top = {}
    for i, s in ipairs(ctx.sources or {}) do
        if i > 3 then break end
        top[#top + 1] = s.name .. ' ' .. comma(s.dps)
    end
    return string.format('[Companion] %s (%s): %s',
        ctx.title or 'fight', mmss(ctx.duration), table.concat(top, ', '))
end

---@param ctx table
---@return string  full multi-line report
function M.report(ctx)
    local L = {}
    local function line(s) L[#L + 1] = s end
    line(('== Companion parse: %s (%s%s) =='):format(ctx.title or 'fight', mmss(ctx.duration),
        ctx.zone and ctx.zone ~= '' and (', ' .. ctx.zone) or ''))
    line('')
    line('Damage by source:')
    for i, s in ipairs(ctx.sources or {}) do
        line(('  %2d. %-22s %10s  %s dps'):format(i, s.name, fmtK(s.total), comma(s.dps)))
    end
    if ctx.breakdown and #ctx.breakdown > 0 then
        line('')
        line('Your breakdown:')
        for _, a in ipairs(ctx.breakdown) do
            local extra = ''
            if (a.hits or 0) > 0 then extra = ('  %d hits'):format(a.hits) end
            if (a.crits or 0) > 0 and (a.hits or 0) > 0 then
                extra = extra .. ('  %d%% crit'):format(math.floor(a.crits / a.hits * 100 + 0.5))
            end
            line(('  %-22s %10s%s'):format(a.ability or '?', fmtK(a.total), extra))
        end
    end
    if ctx.healers and #ctx.healers > 0 then
        line('')
        line('Healing:')
        for i, h in ipairs(ctx.healers) do
            line(('  %2d. %-22s %10s  %s hps  %d%% over'):format(
                i, h.name, fmtK(h.total), comma(h.hps or 0), math.floor((h.overpct or 0) + 0.5)))
        end
    end
    if ctx.incoming and #ctx.incoming > 0 then
        line('')
        line('Incoming:')
        for _, s in ipairs(ctx.incoming) do
            line(('  %-22s %10s'):format(s.name, fmtK(s.total)))
        end
    end
    return table.concat(L, '\n')
end

-- Write `text` to a timestamped file in the config dir. Returns the path or nil.
function M.save(text)
    local path = string.format('%s/companion_parse_%s.txt', mq.configDir, os.date('%Y%m%d_%H%M%S'))
    local f = io.open(path, 'w')
    if not f then
        printf('\ar[companion]\ax could not write export to %s', path)
        return nil
    end
    f:write(text); f:close()
    return path
end

-- Full export: save the report to a file and print the compact line to console.
---@param ctx table
function M.run(ctx)
    local path = M.save(M.report(ctx))
    local line = M.compact(ctx)
    printf('\ag[companion]\ax %s', line)
    if path then printf('\ag[companion]\ax full report: \ay%s\ax', path) end
    return path
end

-- ── death post-mortem ────────────────────────────────────────────────
---@param verdict table  postmortem.analyze output
---@param row table      S.hist.deaths row { killer, zone, started_at, mob }
---@param playerName string
---@return string
function M.deathReport(verdict, row, playerName)
    local L = {}
    local function line(s) L[#L + 1] = s end
    line(('== Companion death report: %s killed by %s (%s) =='):format(playerName, verdict.killer or '?',
        os.date('%Y-%m-%d %H:%M', row.started_at or os.time())))
    line(('Zone: %s   Mob: %s   Cause: %s'):format(row.zone or '?', row.mob or '?', verdict.cause or '?'))
    line('')
    for _, s in ipairs(verdict.narrative or {}) do line(s) end
    line('')
    line('Timeline (seconds before death):')
    for _, m in ipairs(verdict.moments or {}) do line(('  %6.1fs  %s'):format(m.t, m.text)) end
    line('')
    line('Incoming (last 10s): ' .. comma(verdict.incoming10.total))
    for _, s in ipairs(verdict.incoming10.bySource or {}) do
        line(('  %-22s %10s  %3d%%'):format(s.name, fmtK(s.total), math.floor(s.pct + 0.5)))
    end
    line('Heals (last 10s): ' .. comma(verdict.heals10.total))
    for _, h in ipairs(verdict.heals10.byHealer or {}) do line(('  %-22s %10s'):format(h.name, fmtK(h.total))) end
    if #(verdict.groupAtDeath or {}) > 0 then
        line('')
        line('Group at death:')
        for _, m in ipairs(verdict.groupAtDeath) do
            line(('  %-16s %-4s hp %3d%%  mana %3d%%  dist %4d  %s%s'):format(m.name, m.cls, m.hp or 0, m.mana or 0,
                m.dist or 0, m.flag or '', m.mt and ' [MT]' or ''))
        end
    end
    if verdict.stateAtDeath and verdict.stateAtDeath ~= '' then line(''); line('Your state: ' .. verdict.stateAtDeath) end
    return table.concat(L, '\n')
end

function M.saveDeath(text, playerName)
    local path = string.format('%s/companion_death_%s_%s.txt', mq.configDir, playerName or 'me', os.date('%Y%m%d-%H%M%S'))
    local f = io.open(path, 'w')
    if not f then
        printf('\ar[companion]\ax could not write death report to %s', path)
        return nil
    end
    f:write(text); f:close()
    return path
end

-- Console recap (narrative + the last few moments) and the full report file.
function M.runDeath(verdict, row, playerName)
    local path = M.saveDeath(M.deathReport(verdict, row, playerName), playerName)
    printf('\ag[companion]\ax \arDeath\ax (%s): %s', verdict.cause or '?', table.concat(verdict.narrative or {}, ' '))
    local ms = verdict.moments or {}
    for i = math.max(1, #ms - 7), #ms do printf('  \ay%6.1fs\ax  %s', ms[i].t, ms[i].text) end
    if path then printf('\ag[companion]\ax full report: \ay%s\ax', path) end
    return path
end

return M
