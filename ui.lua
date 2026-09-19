-- companion/ui.lua
-- ImGui rendering for the Companion overlay, in the EQ Legends Companion visual
-- language (see companion/theme.lua). Two views: Live Fight and History.
--
-- Charts and the fight timeline are hand-drawn via a crash-safe DrawList proxy
-- so the flat, dense look matches the source design. All DB reads happen in the
-- main loop (UI.refreshHistory) and are cached in S; the render callback only
-- reads state and never yields or hits the DB (ImGui callbacks disallow both).

local mq     = require('mq')
local ImGui  = require('ImGui')
local Theme  = require('companion.theme')
local Export = require('companion.export')
local Postmortem = require('companion.postmortem')

local UI    = {}

local S     = {
    open        = true,
    tab         = 'live',
    combat      = nil,
    db          = nil,
    playerName  = 'You',
    pendingSel  = nil, -- fightId requested from the history table
    sel         = nil, -- loaded { fight, abilities, events }
    pendingDeath = nil, -- row from S.hist.deaths requested from the Deaths tab
    selDeath    = nil, -- loaded { row, events, samples, verdict }
    exportRequest = false, -- set by the Deaths tab / /companion death; served in refreshHistory
    histMode    = 'fights', -- History left panel: 'fights' | 'targets' | 'weapons'
    targetFilter = nil, -- when set, the fights list is filtered to this mob
    weaponFilter = nil, -- {mainhand, offhand} filter for the fights list
    runFilter   = nil, -- zone-run row {session_id, zone, ...}: fights list shows that run only
    pendingRun  = nil, -- zone-run row requested from the By Zone table (served in refreshHistory)
    selRun      = nil, -- loaded { run, fights, sources, targets } for runFilter
    runView     = false, -- History right panel shows the run summary instead of a fight
    fightSearch = '',   -- fights-list target name filter
    fightSort   = { key = 'time', dir = 'desc' }, -- key: time|dps|dmg|dur
    liveScope   = 'fight', -- Live view: 'fight' (current pull) | 'overall' (zone totals)
    liveSource  = nil, -- selected attacker in the Live view (nil = local player)
    histSource  = nil, -- selected attacker in the History detail (nil = local player)
    healSource  = nil, -- selected healer in the Healing view (nil = local player)
    smartheal   = nil, -- SmartHeals snapshot, refreshed by the main loop (nil = no bridge)
    shDecisions = {},  -- persisted decision rows for the selected history fight
    tlFilters   = {},  -- timeline category toggles (absent/true = shown, false = hidden)
    tlHighlight = nil, -- ability name whose timeline lane is highlighted/tracked
    mini        = false, -- compact meter mode (just the current fight's DPS)
    miniMode    = 'dps', -- mini meter: 'dps' | 'hps'
    miniPie     = true,  -- mini meter: draw the damage-share pie under the bars
    settings    = { timeout = 12, retentionDays = 14, share = true, miniRows = 12, groupOnly = false },
    roster      = {},  -- lowercased names of my current group members (set by the main loop)
    hist        = { fights = {}, best = nil, sessions = {}, xp = {}, session = nil },
    lastRefresh = 0,
}

-- ── formatting ─────────────────────────────────────────────────────────
local function fmtK(n)
    n = n or 0
    if n >= 1e6 then return string.format('%.2fM', n / 1e6) end
    if n >= 1000 then return string.format('%.1fk', n / 1000) end
    return tostring(math.floor(n + 0.5))
end

local function comma(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    return (s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', ''))
end

local function mmss(sec)
    sec = math.floor(sec or 0)
    return string.format('%d:%02d', math.floor(sec / 60), sec % 60)
end

-- ── small ImGui helpers ────────────────────────────────────────────────
local function ctext(colorName, str)
    local r, g, b, a = Theme.rgba(colorName)
    ImGui.TextColored(r, g, b, a, str)
end

local function label(str) ctext('fgFaint', string.upper(str)) end

-- Right-align `str` on the current line (call right after printing the label).
local function rightText(colorName, str)
    local tw = ImGui.CalcTextSize(str)
    ImGui.SameLine()
    local avail = ImGui.GetContentRegionAvail() -- remaining width on this line, measured after SameLine
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, avail - tw))
    ctext(colorName, str)
end

local function cardHeader(text, meta, metaColor)
    label(text)
    if meta then rightText(metaColor or 'fgFaint', meta) end
    ImGui.Separator()
end

-- Full-width bar drawn at the cursor; advances layout by (w,h).
local function drawBar(fill, frac, h, w, alpha)
    local dl = Theme.drawlist(ImGui.GetWindowDrawList())
    h = h or 7
    if not dl then ImGui.Dummy(w, h); return end
    local x, y = ImGui.GetCursorScreenPos()
    dl:rectFilled(x, y, x + w, y + h, Theme.u32('bg'), 3)
    dl:rect(x, y, x + w, y + h, Theme.u32('lineSoft'), 3, 1)
    frac = math.max(0, math.min(1, frac or 0))
    local fw = math.max(2, w * frac)
    dl:rectFilled(x, y, x + fw, y + h, Theme.u32(fill, alpha or 1), 3)
    ImGui.Dummy(w, h)
end

-- Render a list of {name,nameColor,tag,tagColor,frac,fill,value,sub,alpha}.
local function statRows(id, rows)
    if not ImGui.BeginTable(id, 2, ImGuiTableFlags.SizingStretchProp) then return end
    ImGui.TableSetupColumn('m', ImGuiTableColumnFlags.WidthStretch)
    ImGui.TableSetupColumn('v', ImGuiTableColumnFlags.WidthFixed, 80)
    for i, r in ipairs(rows) do
        ImGui.PushID(i)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ctext(r.nameColor or 'fg', r.name)
        if r.tag then ImGui.SameLine(0, 7); ctext(r.tagColor or 'fgFaint', r.tag) end
        local w = ImGui.GetContentRegionAvail()
        drawBar(r.fill, r.frac, 7, w, r.alpha)
        ImGui.TableNextColumn()
        local vw = ImGui.CalcTextSize(r.value)
        local cw = ImGui.GetContentRegionAvail()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, cw - vw))
        ctext('fg', r.value)
        if r.sub then
            local sw = ImGui.CalcTextSize(r.sub)
            local cw2 = ImGui.GetContentRegionAvail()
            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, cw2 - sw))
            ctext('fgFaint', r.sub)
        end
        ImGui.PopID()
    end
    ImGui.EndTable()
end

-- Modifier counts are a live table or a "k:v,k:v" DB string; normalize to a table.
local function decodeMods(s)
    if type(s) == 'table' then return s end
    local m = {}
    if type(s) == 'string' then
        for k, v in s:gmatch('(%a+):(%d+)') do m[k] = tonumber(v) end
    end
    return m
end

-- Percentiles from a hit-size histogram ({bucket->count}, live table or "k:v"
-- DB string). Returns median, p90 as numbers (bucket base 1.3), or nil.
local HIST_BASE = 1.3
local function histPercentiles(hist)
    if type(hist) == 'string' then hist = decodeMods(hist) end
    if type(hist) ~= 'table' then return nil end
    local total, keys = 0, {}
    for b, c in pairs(hist) do total = total + c; keys[#keys + 1] = b end
    if total == 0 then return nil end
    table.sort(keys)
    local function at(p)
        local cum = 0
        for _, b in ipairs(keys) do
            cum = cum + hist[b]
            if cum >= p * total then return HIST_BASE ^ b end
        end
        return HIST_BASE ^ keys[#keys]
    end
    return at(0.5), at(0.9)
end

-- Which modifiers to annotate, in priority order.
local MOD_ORDER = { 'flurry', 'riposte', 'rampage', 'twincast', 'slay', 'assassinate', 'headshot', 'doublebow', 'lucky' }
local MOD_LABEL = { slay = 'slay', doublebow = '2-bow', assassinate = 'assn', headshot = 'hs' }

-- Build breakdown rows from an ability list (works for live or DB rows).
-- Bars scale within their own class: damage rows against the biggest damage
-- row, heal rows against the biggest heal row (a lone heal reads as 100% of
-- healing, not a sliver of the top nuke).
local function breakdownRows(abils)
    local topDmg, topHeal = 0, 0
    for _, a in ipairs(abils) do
        if a.kind == 'heal' then
            if a.total > topHeal then topHeal = a.total end
        elseif a.total > topDmg then
            topDmg = a.total
        end
    end
    local rows = {}
    for _, a in ipairs(abils) do
        if #rows >= 40 then break end -- match the timeline's lane cap; the card scrolls
        local top = (a.kind == 'heal') and topHeal or topDmg
        local hits, misses, resists, crits = a.hits or 0, a.misses or 0, a.resists or 0, a.crits or 0
        local ann = {}
        -- use count first: landed/attempts (attempts = hits + misses + resists),
        -- so "Kick 21/24x" = 21 landed of 24 uses, and a proc's count is visible
        local att = hits + misses + resists
        if att > 0 then
            ann[#ann + 1] = (hits < att) and (hits .. '/' .. att .. 'x') or (hits .. 'x')
        end
        if crits > 0 and hits > 0 then
            ann[#ann + 1] = string.format('%d%% crit', math.floor(crits / hits * 100 + 0.5))
        end
        if misses > 0 and hits > 0 then
            ann[#ann + 1] = string.format('%d%% miss', math.floor(misses / (hits + misses) * 100 + 0.5))
        elseif resists > 0 then
            ann[#ann + 1] = resists .. ' resist'
        end
        local mods = decodeMods(a.mods)
        for _, k in ipairs(MOD_ORDER) do
            if (mods[k] or 0) > 0 then ann[#ann + 1] = mods[k] .. ' ' .. (MOD_LABEL[k] or k) end
        end
        local over = a.over_total or a.over or 0
        if over > 0 then ann[#ann + 1] = fmtK(over) .. ' over' end
        -- hit-size distribution: median / p90 (damage rows only)
        if a.kind ~= 'heal' and hits > 0 and a.hist then
            local p50, p90 = histPercentiles(a.hist)
            if p50 then ann[#ann + 1] = string.format('med %s  p90 %s', fmtK(p50), fmtK(p90)) end
        end
        -- HoT tick efficiency: logged ticks vs expected, + estimated silent overheal
        if a.expectedTicks and a.expectedTicks > 0 then
            ann[#ann + 1] = string.format('%d/%d ticks', a.ticks or 0, a.expectedTicks)
            if (a.wastedTicks or 0) > 0 then
                ann[#ann + 1] = string.format('~%s silent (%d)', fmtK(a.wastedHeal or 0), a.wastedTicks)
            end
        end
        if hits > 0 then ann[#ann + 1] = fmtK(a.min_hit) .. '-' .. fmtK(a.max_hit) end
        rows[#rows + 1] = {
            name = a.ability, nameColor = Theme.kindColor(a.kind),
            tag = #ann > 0 and table.concat(ann, '  ') or nil,
            tagColor = (resists > 0 or misses > 0) and 'resist' or 'fgFaint',
            frac = top > 0 and a.total / top or 0, fill = Theme.kindColor(a.kind),
            value = fmtK(a.total),
        }
    end
    return rows
end

-- Aggregate a raw ability list into per-source totals (for the history detail,
-- where we only have DB ability rows, not a live source list).
local function sourcesFromAbilities(abils, duration)
    local agg = {}
    for _, a in ipairs(abils) do
        local s = agg[a.source]
        if not s then s = { name = a.source, total = 0, isPet = false }; agg[a.source] = s end
        s.total = s.total + (a.total or 0)
        if a.is_pet == 1 or a.is_pet == true then s.isPet = true end
    end
    local arr = {}
    for _, s in pairs(agg) do
        s.dps = duration > 0 and s.total / duration or 0
        s.mine = (s.name == S.playerName or s.name == 'You')
        arr[#arr + 1] = s
    end
    table.sort(arr, function(x, y) return x.total > y.total end)
    return arr
end

-- ── meter scope (all vs. group only) ───────────────────────────────────
-- In a raid the meter fills with 50+ strangers; "group only" keeps just me,
-- my group members (roster from the black-box sampler), companion peers (my
-- boxes, by definition) and any of those players' pets. Pets normalize to
-- "<Owner>`s pet" in combat.lua, so ownership is read straight off the name.
local function petOwner(name)
    return tostring(name or ''):match("^(.-)[`']s %a+$")
end

-- Lowercased set of fresh companion peers' names. Built once per scope pass
-- (not once per pet row -- freshPeers allocates and walks the peer table).
local function peerSet()
    local set = {}
    if S.group then
        for _, p in ipairs(S.group.freshPeers()) do set[tostring(p.player or ''):lower()] = true end
    end
    return set
end

-- Does this meter row belong to my group? row = { name, mine?, peer? }.
-- `peers` is a peerSet() (built by the caller; made here when omitted).
-- Exposed as UI.inGroupScope for the test.
local function inGroupScope(row, peers)
    if row.mine or row.peer then return true end
    local name = tostring(row.name or ''):lower()
    local me = tostring(S.playerName or ''):lower()
    if name == me or name == 'you' or S.roster[name] then return true end
    local owner = petOwner(row.name)
    if owner then
        owner = owner:lower()
        if owner == me or S.roster[owner] then return true end
        if (peers or peerSet())[owner] then return true end
    end
    return false
end

-- Apply the meter scope to an array of rows (returns the same array when off).
local function scopeRows(rows)
    if not S.settings.groupOnly then return rows end
    local peers = peerSet()
    local out = {}
    for _, r in ipairs(rows) do if inGroupScope(r, peers) then out[#out + 1] = r end end
    return out
end

-- Clickable "all | group" scope switch, drawn on the current line.
local function scopeToggle(gap)
    local g = S.settings.groupOnly
    ImGui.SameLine(0, gap or 8); ctext(g and 'fgFaint' or 'gold', 'all')
    if ImGui.IsItemClicked(0) then S.settings.groupOnly = false end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Show every damage source') end
    ImGui.SameLine(0, 6); ctext(g and 'you' or 'fgFaint', 'group')
    if ImGui.IsItemClicked(0) then S.settings.groupOnly = true end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Only me, my group members, my boxes and our pets (raids)') end
end

-- ── damage-share pie ───────────────────────────────────────────────────
-- Fold meter rows ({ name, total, mine? }) into at most maxSlices pie slices,
-- ranked by total; the tail past the cap collapses into one "others" slice.
-- Each slice: { name, total, frac, color, mine }. Pure -- exposed as
-- UI.pieSlices for the test.
local function pieSlices(rows, maxSlices)
    maxSlices = math.max(2, maxSlices or 8)
    local sorted, grand = {}, 0
    for _, r in ipairs(rows or {}) do
        if (r.total or 0) > 0 then sorted[#sorted + 1] = r; grand = grand + r.total end
    end
    table.sort(sorted, function(a, b) return a.total > b.total end)
    if grand <= 0 then return {}, 0 end
    local slices, ci = {}, 0
    local keep = (#sorted > maxSlices) and (maxSlices - 1) or #sorted
    for i = 1, keep do
        local r = sorted[i]
        local color
        if r.mine then color = 'you' else ci = ci + 1; color = Theme.SLICE[((ci - 1) % #Theme.SLICE) + 1] end
        slices[#slices + 1] = { name = r.name, total = r.total, frac = r.total / grand, color = color, mine = r.mine }
    end
    if keep < #sorted then
        local rest = 0
        for i = keep + 1, #sorted do rest = rest + sorted[i].total end
        slices[#slices + 1] = { name = string.format('others (%d)', #sorted - keep), total = rest,
            frac = rest / grand, color = 'fgFaint', others = true }
    end
    return slices, grand
end

-- Draw a pie of `slices` (radius r) at the cursor with a legend to its right,
-- using the crash-safe DrawList so a broken build just leaves the card blank.
-- Advances layout by (w, h). Wedges are triangle fans from the centre.
local function drawPie(slices, r, w)
    local lineH = ImGui.GetTextLineHeight()
    local h = math.max(2 * r + 6, #slices * (lineH + 2))
    local dl = Theme.drawlist(ImGui.GetWindowDrawList())
    if not dl or #slices == 0 then ImGui.Dummy(w, h); return end
    local x, y = ImGui.GetCursorScreenPos()
    local cx, cy = x + r + 3, y + h / 2
    local ang = -math.pi / 2 -- start at 12 o'clock, clockwise
    for _, sl in ipairs(slices) do
        local sweep = sl.frac * 2 * math.pi
        local segs = math.max(1, math.ceil(sweep / (2 * math.pi) * 48))
        local col = Theme.u32(sl.color)
        local step = sweep / segs
        local a0 = ang
        for i = 1, segs do
            local a1 = a0 + step
            dl:triangleFilled(cx, cy, cx + math.cos(a0) * r, cy + math.sin(a0) * r,
                cx + math.cos(a1) * r, cy + math.sin(a1) * r, col)
            a0 = a1
        end
        ang = ang + sweep
    end
    -- legend: colour swatch + name + share, one line per slice, clipped to the width
    local lx = x + 2 * r + 14
    local lw = w - (lx - x)
    local ly = y + math.max(0, (h - #slices * (lineH + 2)) / 2)
    for _, sl in ipairs(slices) do
        local pct = string.format('%d%%', math.floor(sl.frac * 100 + 0.5))
        local pw = ImGui.CalcTextSize(pct)
        dl:rectFilled(lx, ly + 3, lx + 8, ly + 3 + lineH - 6, Theme.u32(sl.color), 2)
        local name = tostring(sl.name)
        local maxNameW = lw - 14 - pw - 6
        if ImGui.CalcTextSize(name) > maxNameW then
            while #name > 2 and ImGui.CalcTextSize(name .. '..') > maxNameW do name = name:sub(1, -2) end
            name = name .. '..'
        end
        dl:text(lx + 12, ly, Theme.u32(sl.mine and 'you' or 'fg'), name)
        dl:text(x + w - pw, ly, Theme.u32('fgFaint'), pct)
        ly = ly + lineH + 2
    end
    ImGui.Dummy(w, h)
end

-- Clickable "damage by source" list. Highlights selName; returns clicked name or nil.
local function drawSourceList(id, sources, selName)
    local clicked = nil
    local top = sources[1] and sources[1].total or 1
    if not ImGui.BeginTable(id, 2, ImGuiTableFlags.SizingStretchProp) then return nil end
    ImGui.TableSetupColumn('m', ImGuiTableColumnFlags.WidthStretch)
    ImGui.TableSetupColumn('v', ImGuiTableColumnFlags.WidthFixed, 80)
    for i, s in ipairs(sources) do
        if i > 8 then break end
        ImGui.PushID(i)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        local color = s.mine and 'you' or (s.isPet and 'pet' or 'enemy')
        local r, g, b, a = Theme.rgba(color)
        ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
        -- Selectable(label, selected, flags) returns (selected, clicked) — the
        -- SECOND value is the click, the first is just current state
        local _, pressed = ImGui.Selectable(s.name .. '##src', s.name == selName, ImGuiSelectableFlags.None)
        if pressed then clicked = s.name end
        ImGui.PopStyleColor(1)
        local tag = s.mine and 'you' or (s.isPet and 'pet' or nil)
        if tag then ImGui.SameLine(0, 7); ctext(color, tag) end
        local w = ImGui.GetContentRegionAvail()
        drawBar(color, top > 0 and s.total / top or 0, 7, w)
        ImGui.TableNextColumn()
        local v = fmtK(s.total)
        local vw = ImGui.CalcTextSize(v); local cw = ImGui.GetContentRegionAvail()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, cw - vw)); ctext('fg', v)
        local sub = comma(s.dps) .. ' dps'
        local sw = ImGui.CalcTextSize(sub); local cw2 = ImGui.GetContentRegionAvail()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, cw2 - sw)); ctext('fgFaint', sub)
        ImGui.PopID()
    end
    ImGui.EndTable()
    return clicked
end

-- Aggregate event rows into breakdown-compatible ability rows for a source
-- that has no fight_ability entries (mobs: their hits on you are only in the
-- event log). crit comes back from the DB as 0/1.
local function abilitiesFromEvents(events, source)
    local agg = {}
    for _, e in ipairs(events or {}) do
        if e.source == source and (e.amount or 0) > 0 then
            local a = agg[e.ability or '?']
            if not a then
                a = { ability = e.ability or '?', kind = e.kind, total = 0, hits = 0,
                    misses = 0, resists = 0, crits = 0, min_hit = 0, max_hit = 0 }
                agg[e.ability or '?'] = a
            end
            a.total = a.total + e.amount
            a.hits = a.hits + 1
            if e.crit == 1 or e.crit == true then a.crits = a.crits + 1 end
            if a.min_hit == 0 or e.amount < a.min_hit then a.min_hit = e.amount end
            if e.amount > a.max_hit then a.max_hit = e.amount end
        end
    end
    local arr = {}
    for _, a in pairs(agg) do arr[#arr + 1] = a end
    table.sort(arr, function(x, y) return x.total > y.total end)
    return arr
end

-- Rebuild a kind -> { second -> damage } series from persisted event rows, so
-- the stacked DPS histogram works for historical fights too.
local function eventsToKindSeries(events, source)
    local ks = {}
    for _, e in ipairs(events or {}) do
        if e.source == source and (e.amount or 0) > 0 and (e.outcome == 'hit' or e.outcome == nil) then
            local kb = ks[e.kind or '?']
            if not kb then kb = {}; ks[e.kind or '?'] = kb end
            local sec = math.floor(e.t or 0)
            kb[sec] = (kb[sec] or 0) + e.amount
        end
    end
    return ks
end

-- Cast-funnel colors by observed spell role.
local CAST_COLOR = { damage = 'spell', heal = 'green', activate = 'gold', song = 'eqEffect', other = 'fgDim' }

-- Render the cast list for one source: spell, attempts, and failure modes.
local function drawCastRows(id, casts, source)
    local shown = 0
    for i, c in ipairs(casts) do
        if c.source == source and shown < 10 then
            shown = shown + 1
            ImGui.PushID(i)
            local n = (c.casts or 0) + (c.activations or 0)
            ctext(CAST_COLOR[c.kind] or 'fgDim', c.spell)
            ImGui.SameLine(0, 7)
            local ann = { n .. 'x' }
            if (c.fizzles or 0) > 0 then ann[#ann + 1] = c.fizzles .. ' fizzle' end
            if (c.interrupts or 0) > 0 then ann[#ann + 1] = c.interrupts .. ' interrupt' end
            if (c.blocked or 0) > 0 then ann[#ann + 1] = c.blocked .. ' blocked' end
            local bad = (c.fizzles or 0) + (c.interrupts or 0)
            ctext(bad > 0 and 'resist' or 'fgFaint', table.concat(ann, '  '))
            ImGui.PopID()
        end
    end
    if shown == 0 then ctext('fgFaint', 'no casts recorded') end
end

-- ── charts (hand-drawn) ────────────────────────────────────────────────
-- Stacked per-kind damage/sec chart for one source. `kindSeries` is
-- kind -> { second -> damage }; kinds stack bottom-up in category colors so the
-- graph shows WHAT the source was doing and its damage rate simultaneously.
local STACK_ORDER = { { 'melee', 'melee' }, { 'nuke', 'spell' }, { 'dot', 'dot' }, { 'ds', 'ds' } }

-- Shared plot geometry so the DPS chart and the timeline (stacked in the same
-- column) get identical x-axes: same left gutter, same right margin, and ticks
-- computed from the same whole-second duration.
local PLOT_PADL, PLOT_PADR = 96, 8

-- Timeline category filters (shared by live + history timelines).
local TL_FILTERS = {
    { key = 'melee', label = 'melee', color = 'melee' },
    { key = 'nuke',  label = 'spell', color = 'spell' },
    { key = 'dot',   label = 'dot',   color = 'dot' },
    { key = 'ds',    label = 'ds',    color = 'ds' },
    { key = 'heal',  label = 'heal',  color = 'green' },
    { key = 'cast',  label = 'casts', color = 'gold' },
    { key = 'song',  label = 'songs', color = 'eqEffect' },
}

-- Map an ability kind / event to its filter bucket.
local function filterKeyFor(kind, outcome)
    if kind == 'song' then return 'song' end
    if outcome == 'cast' or kind == 'cast' or kind == 'activate' then return 'cast' end
    return kind
end

local function tlAllowed(kind, outcome)
    local k = filterKeyFor(kind, outcome)
    if k == nil then return true end
    local v = S.tlFilters[k]
    return v ~= false
end

-- Clickable filter chips; lit = shown, faint = hidden.
local function drawTimelineFilters()
    ctext('fgFaint', 'show:')
    for _, f in ipairs(TL_FILTERS) do
        ImGui.SameLine(0, 8)
        local on = S.tlFilters[f.key] ~= false
        ctext(on and f.color or 'fgFaint', f.label)
        if ImGui.IsItemClicked(0) then
            S.tlFilters[f.key] = not on
        end
    end
end

local function drawStackedArea(kindSeries, duration, w, h)
    local dl = Theme.drawlist(ImGui.GetWindowDrawList())
    if not dl then ImGui.Dummy(w, h); return end
    local ox, oy = ImGui.GetCursorScreenPos()
    dl:rectFilled(ox, oy, ox + w, oy + h, Theme.u32('bg'), 6)
    local maxSec = math.max(1, math.floor(duration or 1))
    -- per-second totals + peak for scaling
    local totals, peak = {}, 1
    for sec = 0, maxSec do
        local tot = 0
        for _, k in ipairs(STACK_ORDER) do
            local kb = kindSeries and kindSeries[k[1]]
            tot = tot + (kb and kb[sec] or 0)
        end
        totals[sec] = tot
        if tot > peak then peak = tot end
    end
    -- layout: y-label gutter on the left (aligned with the timeline's lane
    -- gutter), time axis below the plot
    local padL, padB = PLOT_PADL, 14
    local innerW = math.max(10, w - padL - PLOT_PADR)
    local plotX = ox + padL

    -- gridlines with damage/sec value labels (bars scale off `peak`)
    for _, g in ipairs({ 0.25, 0.5, 0.75 }) do
        local gy = oy + (h - padB) * g
        dl:line(plotX, gy, plotX + innerW, gy, Theme.u32('white', 0.04), 1)
        dl:text(plotX - 34, gy - 6, Theme.u32('fgFaint'), fmtK(peak * (1 - g)))
    end
    -- smooth stacked AREA: interpolate each category between whole-second
    -- samples and fill the bands, with a gold outline for the total.
    local baseY = oy + h - padB
    local plotH = h - padB - 6
    local function yOf(v) return baseY - (v / peak) * plotH end
    -- category value at fractional time t (linear interp between second buckets)
    local function catAt(kb, t)
        if not kb then return 0 end
        local s0 = math.floor(t)
        local v0, v1 = kb[s0] or 0, kb[s0 + 1] or 0
        return v0 + (v1 - v0) * (t - s0)
    end
    local step = 2 -- px between samples (smoothness vs cost)
    local prevX, prevTopY
    local px = 0
    while px <= innerW do
        local x = plotX + px
        local t = (px / innerW) * maxSec
        local cum = 0
        for _, k in ipairs(STACK_ORDER) do
            local v = catAt(kindSeries and kindSeries[k[1]], t)
            if v > 0 then
                local yb, yt = yOf(cum), yOf(cum + v)
                dl:rectFilled(x, yt, x + step + 0.75, yb, Theme.u32(k[2], 0.55), 0)
                cum = cum + v
            end
        end
        local topY = yOf(cum)
        if prevX then dl:line(prevX, prevTopY, x, topY, Theme.u32('gold', 0.5), 1.2) end
        prevX, prevTopY = x, topY
        px = px + step
    end
    -- rolling-window DPS line (trailing average) overlaid as a bright trend
    local WIN = 6 -- seconds
    local run, pX, pY = 0, nil, nil
    for sec = 0, maxSec do
        run = run + (totals[sec] or 0)
        if sec >= WIN then run = run - (totals[sec - WIN] or 0) end
        local avg = run / math.min(sec + 1, WIN)
        local x = plotX + (maxSec > 0 and (sec / maxSec) or 0) * innerW
        local y = yOf(avg)
        if pX then dl:line(pX, pY, x, y, Theme.u32('fg', 0.95), 1.8) end
        pX, pY = x, y
    end
    -- time axis: quarter ticks with timestamps
    for _, f in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
        local sec = math.floor(maxSec * f)
        local x = plotX + f * innerW
        dl:line(x, oy + h - padB, x, oy + h - padB + 3, Theme.u32('white', 0.10), 1)
        local lbl = mmss(sec)
        local off = f == 0 and 0 or (f == 1 and -26 or -13)
        dl:text(x + off, oy + h - 12, Theme.u32('fgFaint'), lbl)
    end
    dl:text(ox + w - 88, oy + 2, Theme.u32('fgFaint'), comma(peak) .. ' peak/s')
    dl:line(plotX + 2, oy + 9, plotX + 16, oy + 9, Theme.u32('fg', 0.95), 1.8)
    dl:text(plotX + 20, oy + 3, Theme.u32('fgFaint'), '6s avg')
    ImGui.Dummy(w, h)

    -- hover: per-second breakdown tooltip (map mouse x -> nearest second)
    if ImGui.IsItemHovered() then
        local mx = ImGui.GetMousePos()
        local sec = math.floor((mx - plotX) / innerW * maxSec + 0.5)
        if sec >= 0 and sec <= maxSec then
            local parts, tot = {}, 0
            for _, k in ipairs(STACK_ORDER) do
                local kb = kindSeries and kindSeries[k[1]]
                local v = kb and kb[sec] or 0
                if v > 0 then
                    tot = tot + v
                    parts[#parts + 1] = string.format('%s %s', k[1], comma(v))
                end
            end
            if tot > 0 then
                ImGui.SetTooltip(string.format('%s  -  %s dmg%s', mmss(sec), comma(tot),
                    #parts > 1 and ('\n' .. table.concat(parts, '\n')) or ''))
            else
                ImGui.SetTooltip(mmss(sec) .. '  -  no damage')
            end
        end
    end
end

-- Trim a string with an ellipsis so it fits within maxW pixels. Returns
-- (display, wasTruncated).
local function truncateToWidth(s, maxW)
    local full = ImGui.CalcTextSize(s)
    if full <= maxW then return s, false end
    local n = math.max(1, math.floor(#s * maxW / full) - 1)
    local cand = s:sub(1, n) .. '..'
    while n > 1 and ImGui.CalcTextSize(cand) > maxW do
        n = n - 1; cand = s:sub(1, n) .. '..'
    end
    return cand, true
end

-- The fight timeline: a lane per ability of `source`, one tick per event; hollow
-- tick = miss/resist. Sizes to its lane count (no cap) at a fixed per-lane
-- height; the enclosing card scrolls when it's taller than the visible area.
local TL_LANE_H, TL_TOP, TL_AXIS = 18, 6, 18
local TL_MAX_LANES = 40 -- safety bound for pathological fights

-- Count the lanes a timeline would draw for a source (same rules as
-- drawTimeline), so the enclosing card can auto-fit its height.
local function timelineLaneCount(snap, source, abilities)
    local seen, n = {}, 0
    for _, a in ipairs(abilities or {}) do
        if n >= TL_MAX_LANES then return n end
        if not seen[a.ability] and tlAllowed(a.kind, nil) then seen[a.ability] = true; n = n + 1 end
    end
    for _, e in ipairs(snap.events or {}) do
        if n >= TL_MAX_LANES then return n end
        if e.source == source and e.outcome == 'cast' and e.ability
            and not seen[e.ability] and tlAllowed(e.kind, e.outcome) then
            seen[e.ability] = true; n = n + 1
        end
    end
    return n
end

-- Height a timeline of `laneCount` lanes needs (its own plot area).
local function timelineHeight(laneCount)
    return TL_TOP + math.max(1, laneCount) * TL_LANE_H + TL_AXIS
end

local function drawTimeline(snap, _h, source, abilities)
    local dl = Theme.drawlist(ImGui.GetWindowDrawList())
    local ox, oy = ImGui.GetCursorScreenPos()
    local w = ImGui.GetContentRegionAvail()
    local padL = PLOT_PADL
    local innerW = math.max(20, w - padL - PLOT_PADR)

    -- lanes = the selected source's damage abilities (sorted by damage) first,
    -- then lanes for casts/activations (songs, discs, AAs, clickies) with no
    -- damage row of their own. No visible-count cap (safety bound only).
    local lanes, laneOf = {}, {}
    for _, a in ipairs(abilities or {}) do
        if #lanes >= TL_MAX_LANES then break end
        if not laneOf[a.ability] and tlAllowed(a.kind, nil) then
            lanes[#lanes + 1] = { name = a.ability, kind = a.kind }
            laneOf[a.ability] = #lanes
        end
    end
    for _, e in ipairs(snap.events or {}) do
        if #lanes >= TL_MAX_LANES then break end
        if e.source == source and e.outcome == 'cast' and e.ability
            and not laneOf[e.ability] and tlAllowed(e.kind, e.outcome) then
            lanes[#lanes + 1] = { name = e.ability, kind = e.kind }
            laneOf[e.ability] = #lanes
        end
    end

    -- height is derived from the lane count
    local innerH = #lanes * TL_LANE_H
    local h = TL_TOP + innerH + TL_AXIS
    if not dl then ImGui.Dummy(w, h); return end
    dl:rectFilled(ox, oy, ox + w, oy + h, Theme.u32('bg'), 6)
    if #lanes == 0 then
        dl:text(ox + padL, oy + h / 2 - 6, Theme.u32('fgFaint'), 'no events yet')
        ImGui.Dummy(w, h)
        return
    end
    local laneH = TL_LANE_H
    local dur = math.max(1, snap.duration)

    -- time gridlines + axis labels (tick math identical to the DPS chart so
    -- the two x-axes line up when stacked)
    local maxSec = math.floor(dur)
    for _, f in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
        local sec = math.floor(maxSec * f)
        local x = ox + padL + f * innerW
        dl:line(x, oy + 6, x, oy + 6 + innerH, Theme.u32('white', 0.04), 1)
        local off = f == 0 and 0 or (f == 1 and -26 or -13)
        dl:text(x + off, oy + h - 14, Theme.u32('fgFaint'), mmss(sec))
    end
    local hi = S.tlHighlight -- highlighted lane name (click a row to track it)

    -- highlight band behind the tracked lane
    if hi and laneOf[hi] then
        local i = laneOf[hi]
        local y0 = oy + 6 + (i - 1) * laneH
        dl:rectFilled(ox + padL, y0, ox + w - PLOT_PADR, y0 + laneH, Theme.u32('gold', 0.10), 0)
    end

    -- lane labels + separators (highlighted label brightened, long names trimmed)
    local labelMaxW = padL - 12
    for i, ln in ipairs(lanes) do
        local cy = oy + 6 + (i - 0.5) * laneH
        local hit = (hi == ln.name)
        local disp = truncateToWidth(ln.name, labelMaxW)
        dl:text(ox + 6, cy - 6, Theme.u32(hit and 'gold' or 'fgDim'), disp)
        if i > 1 then
            local sy = oy + 6 + (i - 1) * laneH
            dl:line(ox + padL, sy, ox + w - PLOT_PADR, sy, Theme.u32('white', 0.03), 1)
        end
    end

    -- ticks (dim lanes other than the highlighted one, when one is set)
    for _, e in ipairs(snap.events) do
        local li = e.source == source and laneOf[e.ability]
        if li and not tlAllowed(e.kind, e.outcome) then li = nil end
        if li then
            local dim = hi and lanes[li].name ~= hi
            local a = dim and 0.28 or 0.9
            local cy = oy + 6 + (li - 0.5) * laneH
            local x = ox + padL + math.max(0, math.min(1, e.t / dur)) * innerW
            local th = math.min(laneH * 0.7, 6 + (e.amount or 0) ^ 0.5 * 0.25)
            local colName = Theme.kindColor(e.kind)
            if e.outcome == 'miss' or e.outcome == 'resist' then
                dl:rect(x - 1.4, cy - th / 2, x + 1.4, cy + th / 2, Theme.u32('resist', dim and 0.35 or 1), 1)
            elseif e.outcome == 'cast' then
                local ch = math.min(laneH * 0.6, 9)
                local mc = e.kind == 'song' and 'eqEffect' or 'gold'
                dl:rect(x - 2.2, cy - ch / 2, x + 2.2, cy + ch / 2, Theme.u32(mc, dim and 0.35 or 1), 1, 1.2)
            elseif e.outcome == 'hit' then
                dl:rectFilled(x - 1.4, cy - th / 2, x + 1.4, cy + th / 2, Theme.u32(colName, a), 1)
            end
        end
    end
    ImGui.Dummy(w, h)

    -- hover a lane label to see the full name; click a lane row to track it
    if ImGui.IsItemHovered() then
        local mx, my = ImGui.GetMousePos()
        local i = math.floor((my - (oy + 6)) / laneH) + 1
        local ln = lanes[i]
        if ln then
            if (mx - ox) < padL then ImGui.SetTooltip(ln.name) end -- full name in the label gutter
            if ImGui.IsItemClicked(0) then
                S.tlHighlight = (S.tlHighlight == ln.name) and nil or ln.name
            end
        end
    end
end

-- ── export ─────────────────────────────────────────────────────────────
local function exportCtxFromSnapshot(snap)
    local sources = {}
    for _, s in ipairs(snap.sources or {}) do sources[#sources + 1] = { name = s.name, total = s.total, dps = s.dps } end
    return {
        title = snap.name, zone = snap.zone, duration = snap.duration, sources = sources,
        breakdown = (snap.abilitiesBySource and snap.abilitiesBySource[S.playerName]) or snap.abilities or {},
        healers = snap.healSources, incoming = snap.incomingSources,
    }
end

local function exportCtxFromHistory(sel)
    local f = sel.fight
    local breakdown = {}
    for _, a in ipairs(sel.abilities or {}) do
        if a.source == S.playerName or a.source == 'You' then breakdown[#breakdown + 1] = a end
    end
    return {
        title = f.primary_target, zone = f.zone, duration = f.duration,
        sources = sourcesFromAbilities(sel.abilities, f.duration or 1), breakdown = breakdown,
    }
end

function UI.exportLive()
    local snap = S.combat and S.combat.snapshot()
    if not snap then printf('\ay[companion]\ax no fight to export.'); return end
    Export.run(exportCtxFromSnapshot(snap))
end

-- /companion death: export the selected death, or the most recent one.
-- Loading + file I/O happen in refreshHistory (main loop), never here.
function UI.exportDeath()
    if S.selDeath and S.selDeath.verdict then S.exportRequest = true; return end
    -- The history cache only refreshes while the panel is on screen, so with
    -- it never opened this list is empty. Ask the DB directly (binds run in
    -- the main loop, not in render, so a query here is legal).
    local d = S.hist.deaths and S.hist.deaths[1]
    if not d and S.db then
        S.hist.deaths = S.db:recentDeaths(40)
        d = S.hist.deaths[1]
    end
    if not d then printf('\ay[companion]\ax no deaths recorded.'); return end
    S.pendingDeath = d
    S.exportRequest = true
end

-- ── live view ──────────────────────────────────────────────────────────
local function drawLive()
    local overall = S.liveScope == 'overall'
    local snap = S.combat and (overall and S.combat.overallSnapshot() or S.combat.snapshot()) or nil
    if not snap then
        -- scope toggle is still useful when empty
        ctext(not overall and 'gold' or 'fgFaint', 'Fight')
        if ImGui.IsItemClicked(0) then S.liveScope = 'fight' end
        ImGui.SameLine(0, 8); ctext(overall and 'gold' or 'fgFaint', 'Overall')
        if ImGui.IsItemClicked(0) then S.liveScope = 'overall' end
        ImGui.Dummy(0, 12)
        ctext('fgFaint', overall and 'No fights recorded in this zone yet.'
            or 'Waiting for combat... deal or take damage to start a fight.')
        return
    end

    local availW = ImGui.GetContentRegionAvail()
    local leftW = math.floor(availW * 0.6)

    -- selected attacker drives the breakdown + timeline (default: local player).
    -- Falls back to player, then the top source, if the selection isn't in this fight.
    local sources = scopeRows(snap.sources)
    local function hasAbil(nm) return nm and snap.abilitiesBySource[nm] end
    -- a selection the scope just hid falls back like any missing source
    local function listed(nm)
        if not hasAbil(nm) then return false end
        for _, s in ipairs(sources) do if s.name == nm then return true end end
        return false
    end
    local sel = (listed(S.liveSource) and S.liveSource)
        or (hasAbil(S.playerName) and S.playerName)
        or (sources[1] and sources[1].name)
        or S.playerName
    local selAbil = snap.abilitiesBySource[sel] or {}
    local selInfo
    for _, s in ipairs(snap.sources) do if s.name == sel then selInfo = s break end end

    -- LEFT column
    ImGui.BeginChild('cmp_left', leftW, 0, false)
    do
        -- summary
        ImGui.BeginChild('cmp_sum', 0, 66, true)
        ctext('eqName', snap.name)
        rightText('gold', comma(snap.dps))
        ctext('fgDim', string.format('%s  %s', snap.zone ~= '' and snap.zone or 'unknown zone', mmss(snap.duration)))
        ImGui.SameLine(); ctext('fgFaint', snap.live and '  [LIVE]' or '  [ended]')
        ImGui.SameLine(0, 8); ctext(not overall and 'gold' or 'fgFaint', 'Fight')
        if ImGui.IsItemClicked(0) then S.liveScope = 'fight' end
        ImGui.SameLine(0, 6); ctext(overall and 'gold' or 'fgFaint', 'Overall')
        if ImGui.IsItemClicked(0) then S.liveScope = 'overall' end
        ImGui.SameLine(0, 10); ctext('gold', '[export]')
        if ImGui.IsItemClicked(0) then Export.run(exportCtxFromSnapshot(snap)) end
        ImGui.EndChild()

        if overall then
            -- zone totals: per-second chart & timeline don't apply across fights
            ImGui.BeginChild('cmp_ov', 0, 60, true)
            ctext('fgFaint', string.format('Zone totals across %d fights (%s of combat).',
                snap.fightCount or 0, mmss(snap.duration)))
            ctext('fgFaint', 'Per-second chart and timeline are per-fight only.')
            ImGui.EndChild()
        else
            -- dps over time, stacked by category, following the selected source
            ImGui.BeginChild('cmp_dps', 0, 170, true)
            label('DPS over time - ' .. sel)
            ImGui.SameLine()
            local lg = ImGui.GetContentRegionAvail()
            local legend = 'melee  spell  dot  ds'
            local lw2 = ImGui.CalcTextSize(legend)
            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, lg - lw2))
            ctext('melee', 'melee'); ImGui.SameLine(0, 6)
            ctext('spell', 'spell'); ImGui.SameLine(0, 6)
            ctext('dot', 'dot'); ImGui.SameLine(0, 6)
            ctext('ds', 'ds')
            ImGui.Separator()
            local w = ImGui.GetContentRegionAvail()
            drawStackedArea(snap.kindSeriesBySource and snap.kindSeriesBySource[sel], snap.duration, w, 116)
            ImGui.EndChild()

            -- timeline (follows the selected attacker); card auto-fits lane count
            local tlH = timelineHeight(timelineLaneCount(snap, sel, selAbil))
            local cardH = math.max(130, math.min(360, tlH + 74)) -- + header/filters/hint chrome
            ImGui.BeginChild('cmp_tl', 0, cardH, true)
            cardHeader(sel .. ' - Timeline', comma(snap.eventCount) .. ' events')
            drawTimelineFilters()
            drawTimeline(snap, 220, sel, selAbil)
            ctext('fgFaint', 'Click a row to track it. Hollow red = miss/resist, gold = cast, pink = song.')
            ImGui.EndChild()
        end
    end
    ImGui.EndChild()

    ImGui.SameLine()

    -- RIGHT column
    ImGui.BeginChild('cmp_right', 0, 0, false)
    do
        -- damage by source (click a row to drive the breakdown + timeline)
        ImGui.BeginChild('cmp_src', 0, 150, true)
        local outTotal = snap.total
        if S.settings.groupOnly then
            outTotal = 0
            for _, s in ipairs(sources) do outTotal = outTotal + (s.total or 0) end
        end
        label('Damage by source'); scopeToggle(10)
        rightText('fgFaint', fmtK(outTotal) .. ' out')
        ImGui.Separator()
        local clicked = drawSourceList('src_tbl', sources, sel)
        if clicked then S.liveSource = clicked end
        ImGui.EndChild()

        -- damage share: everyone in the fight (or just the group when scoped)
        ImGui.BeginChild('cmp_pie', 0, 178, true)
        local slices = pieSlices(sources, 8)
        cardHeader('Damage share', #slices > 0 and (#sources .. ' sources') or nil)
        if #slices == 0 then
            ctext('fgFaint', S.settings.groupOnly and 'nothing from your group yet' or 'no damage yet')
        else
            drawPie(slices, 46, ImGui.GetContentRegionAvail())
        end
        ImGui.EndChild()

        -- incoming, broken down per attacker (every mob/DoT/DS hitting you)
        ImGui.BeginChild('cmp_in', 0, 132, true)
        local inMeta = comma(snap.incomingDps) .. ' dps taken'
        cardHeader('Incoming', inMeta, 'enemy')
        -- defensive: avoidance % of melee swings + per-type breakdown
        local av = snap.avoidance
        if av and av.swings > 0 then
            ctext('green', string.format('%d%% avoided', math.floor(av.pct + 0.5)))
            local parts = {}
            for _, k in ipairs({ 'miss', 'parry', 'dodge', 'riposte', 'block', 'rune' }) do
                if (av.by[k] or 0) > 0 then parts[#parts + 1] = av.by[k] .. ' ' .. k end
            end
            ImGui.SameLine(0, 8); ctext('fgFaint', table.concat(parts, '  '))
        end
        local insrc = snap.incomingSources or {}
        if #insrc == 0 then
            ctext('fgFaint', 'no incoming damage')
        else
            local topI = insrc[1].total or 1
            local rows = {}
            for _, s in ipairs(insrc) do
                if #rows >= 6 then break end
                rows[#rows + 1] = { name = s.name, nameColor = 'fg',
                    frac = topI > 0 and s.total / topI or 0, fill = 'enemy',
                    value = fmtK(s.total), sub = comma(s.dps) .. ' dps' }
            end
            statRows('in_tbl', rows)
        end
        ImGui.EndChild()

        -- group: each fresh peer's full first-person broadcast (drill-down).
        -- We only receive a per-peer summary (dmg/pet/heal/target), never their
        -- event log, so this card surfaces everything a peer actually shares.
        if S.group then
            local peers = S.group.freshPeers()
            if #peers > 0 then
                table.sort(peers, function(a, b)
                    return ((a.playerDps or 0) + (a.petDps or 0)) > ((b.playerDps or 0) + (b.petDps or 0))
                end)
                ImGui.BeginChild('cmp_grp', 0, math.min(196, 44 + #peers * 40), true)
                -- group totals = my live dmg/heal dps + every peer's
                local dur = math.max(1, snap.duration)
                local myDps = snap.live and ((snap.playerDmg + (snap.petDmg or 0)) / dur) or 0
                local myHps = snap.live and ((snap.healTotal or 0) / dur) or 0
                local gDps, gHps = myDps, myHps
                for _, p in ipairs(peers) do
                    gDps = gDps + (p.playerDps or 0) + (p.petDps or 0)
                    gHps = gHps + (p.healDps or 0)
                end
                cardHeader(string.format('Group (%d + you)', #peers),
                    comma(gDps) .. ' dps' .. (gHps > 0 and ('  ' .. comma(gHps) .. ' hps') or ''), 'you')
                for _, p in ipairs(peers) do
                    ctext('fg', p.player)
                    if p.target and p.target ~= '' then
                        ImGui.SameLine(0, 6); ctext('fgFaint', '-> ' .. p.target)
                    end
                    rightText('gold', comma((p.playerDps or 0) + (p.petDps or 0)))
                    local sub = {}
                    if p.petName and p.petName ~= '' and (p.petDmg or 0) > 0 then
                        sub[#sub + 1] = 'pet ' .. p.petName .. ' ' .. comma(p.petDps)
                    end
                    if (p.healDps or 0) > 0 then sub[#sub + 1] = comma(p.healDps) .. ' hps' end
                    ctext('fgFaint', #sub > 0 and table.concat(sub, '   ') or '-')
                end
                ImGui.EndChild()
            end
        end

        -- breakdown of the selected attacker
        ImGui.BeginChild('cmp_break', 0, 210, true)
        local meta = ''
        if selInfo then
            local up = math.min(100, math.floor((selInfo.activeSec or 0) / math.max(1, snap.duration) * 100 + 0.5))
            meta = string.format('%s  %s dps / %s active  %d%% up',
                fmtK(selInfo.total), comma(selInfo.dps), comma(selInfo.activeDps or selInfo.dps), up)
        end
        cardHeader('Breakdown - ' .. sel, meta)
        statRows('brk_tbl', breakdownRows(selAbil))
        ImGui.EndChild()

        -- cast funnel of the selected attacker
        ImGui.BeginChild('cmp_casts', 0, 150, true)
        local healMeta = (snap.healTotal or 0) > 0
            and (fmtK(snap.healTotal) .. ' healed' ..
                ((snap.overheal or 0) > 0 and ('  ' .. fmtK(snap.overheal) .. ' over') or ''))
            or nil
        cardHeader('Casts - ' .. sel, healMeta)
        drawCastRows('cast_rows', snap.casts or {}, sel)
        ImGui.EndChild()

        -- event log
        ImGui.BeginChild('cmp_log', 0, 0, true)
        cardHeader('Event log', 'current fight')
        local ev = snap.events
        local startI = math.max(1, #ev - 60)
        for i = #ev, startI, -1 do
            local e = ev[i]
            if e.outcome == 'kill' then
                ctext('green', string.format('%s slain %s', e.source, e.target or ''))
            elseif e.outcome == 'cast' then
                local verb = e.kind == 'activate' and 'activate' or (e.kind == 'song' and 'sing' or 'cast')
                ctext(e.kind == 'song' and 'eqEffect' or 'gold',
                    string.format('%s  %s %s', verb, e.ability or '?', e.source))
            elseif e.outcome == 'miss' or e.outcome == 'resist' then
                ctext('fgFaint', string.format('%s %s %s (%s)', e.source, e.outcome, e.target or '', e.ability or ''))
            else
                local c = e.source == S.playerName and 'gold' or 'pet'
                ctext(c, string.format('%s  %s%s  %s -> %s', e.ability or '?', comma(e.amount),
                    e.crit and '!' or '', e.source, e.target or ''))
            end
        end
        ImGui.EndChild()
    end
    ImGui.EndChild()
end

-- ── history view ───────────────────────────────────────────────────────
-- Label a weapon set: "Mainhand / Offhand", just "Mainhand" for a 2H/empty
-- offhand, or "(unarmed)".
local function weaponLabel(mh, oh)
    if not mh or mh == '' then return '(unarmed)' end
    if oh and oh ~= '' then return mh .. ' / ' .. oh end
    return mh
end

-- Three-line SmartHeals readout for a persisted fight row. Renders nothing when
-- the fight predates the feature or the bridge was not running.
local function drawSmarthealRow(f)
    if not f or not f.sh_summary then return false end
    ImGui.Separator(); label('SmartHeals')
    if f.sh_min_hp then
        ctext('fg', 'tank low')
        rightText('green', math.floor(f.sh_min_hp + 0.5) .. '%')
    end
    if f.sh_emerg_sec and f.sh_emerg_sec > 0 then
        ctext('fg', 'under the line')
        rightText('red', string.format('%.1fs', f.sh_emerg_sec))
    end
    ctext('fg', 'smart casts')
    rightText('green', tostring(f.sh_casts or 0))
    ctext('fgFaint', f.sh_summary)
    return true
end

-- ── zone runs (History > By Zone) ──────────────────────────────────────
local function zoneLabel(zone) return (zone and zone ~= '') and zone or 'no zone' end

local function runLabel(r)
    return string.format('%s %s', zoneLabel(r.zone), os.date('%m/%d', r.started_at or 0))
end

-- Combined DPS over the run's combat time (sum of fight durations).
local function runDps(r)
    local sec = r.combat_sec or 0
    return sec > 0 and (r.total_dmg or 0) / sec or 0
end

-- Right-panel summary of one zone run: totals, everyone's damage over the
-- whole run (list + pie) and what was fought. Reads S.selRun only.
local function drawRunSummary(sr)
    local r = sr.run
    local combat = r.combat_sec or 0
    local wall = math.max(0, (r.ended_at or 0) - (r.started_at or 0))
    cardHeader('Zone run - ' .. zoneLabel(r.zone),
        string.format('%d fights  %s dps', r.fights or 0, comma(runDps(r))))
    ctext('fgDim', string.format('%s - %s   wall %s   combat %s',
        os.date('%b %d %H:%M', r.started_at or 0), os.date('%H:%M', r.ended_at or 0), mmss(wall), mmss(combat)))
    if (r.is_raid or 0) == 1 then ImGui.SameLine(0, 6); ctext('gold', '[RAID]') end

    local mine = (r.player_dmg or 0) + (r.pet_dmg or 0)
    local total = r.total_dmg or 0
    local myPct = total > 0 and math.floor(mine / total * 100 + 0.5) or 0
    ctext('fg', fmtK(total) .. ' damage')
    ImGui.SameLine(0, 10); ctext('you', string.format('%s you+pet (%d%%)', fmtK(mine), myPct))
    ImGui.SameLine(0, 10); ctext('enemy', fmtK(r.incoming) .. ' taken')
    if (r.deaths or 0) > 0 then ImGui.SameLine(0, 10); ctext('resist', 'x' .. r.deaths .. ' deaths') end
    if (r.heal_total or 0) > 0 then ImGui.SameLine(0, 10); ctext('green', fmtK(r.heal_total) .. ' healed') end
    ImGui.Separator()

    -- everyone's damage across the run (fight_ability rollup; heals excluded)
    local srcs = {}
    for _, row in ipairs(sr.sources or {}) do
        srcs[#srcs + 1] = { name = row.source, total = row.total or 0,
            dps = combat > 0 and (row.total or 0) / combat or 0,
            isPet = (row.is_pet == 1), mine = (row.source == S.playerName) }
    end
    label('Damage by source'); rightText('fgFaint', #srcs .. ' sources')
    if #srcs == 0 then
        ctext('fgFaint', 'no ability rows for this run')
    else
        drawSourceList('run_src', srcs, nil)
        ImGui.Separator()
        label('Damage share')
        drawPie(pieSlices(srcs, 8), 46, ImGui.GetContentRegionAvail())
    end
    ImGui.Separator()

    -- what the run fought
    label('Targets'); rightText('fgFaint', (r.targets or 0) .. ' distinct')
    if ImGui.BeginTable('run_tgt', 5, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerH)) then
        ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('N', ImGuiTableColumnFlags.WidthFixed, 30)
        ImGui.TableSetupColumn('Avg DPS', ImGuiTableColumnFlags.WidthFixed, 62)
        ImGui.TableSetupColumn('Avg dur', ImGuiTableColumnFlags.WidthFixed, 54)
        ImGui.TableSetupColumn('Damage', ImGuiTableColumnFlags.WidthFixed, 62)
        ImGui.TableHeadersRow()
        for i, t in ipairs(sr.targets or {}) do
            ImGui.PushID(i)
            ImGui.TableNextRow()
            ImGui.TableNextColumn(); ctext('fgDim', t.mob or 'combat')
            if (t.deaths or 0) > 0 then ImGui.SameLine(0, 6); ctext('resist', 'x' .. t.deaths) end
            ImGui.TableNextColumn(); ctext('fgDim', tostring(t.fights or 0))
            ImGui.TableNextColumn(); ctext('gold', comma(t.avg_dps))
            ImGui.TableNextColumn(); ctext('fgDim', mmss(t.avg_dur))
            ImGui.TableNextColumn(); ctext('fg', fmtK(t.total_dmg))
            ImGui.PopID()
        end
        ImGui.EndTable()
    end
    ctext('fgFaint', 'Click a fight on the left for its own breakdown; [totals] brings this back.')
end

local function drawHistory()
    local H = S.hist
    local availW = ImGui.GetContentRegionAvail()
    local leftW = math.floor(availW * 0.42) -- narrower fights list; detail gets the room

    -- left panel: Fights list or By-Target aggregates
    ImGui.BeginChild('h_fights', leftW, 0, false)
    ImGui.BeginChild('h_fights_card', 0, 0, true)

    -- mode chips
    ctext(S.histMode == 'fights' and 'gold' or 'fgFaint', 'Fights')
    if ImGui.IsItemClicked(0) then S.histMode = 'fights' end
    ImGui.SameLine(0, 12)
    ctext(S.histMode == 'targets' and 'gold' or 'fgFaint', 'By Target')
    if ImGui.IsItemClicked(0) then S.histMode = 'targets' end
    ImGui.SameLine(0, 12)
    ctext(S.histMode == 'weapons' and 'gold' or 'fgFaint', 'By Weapon')
    if ImGui.IsItemClicked(0) then S.histMode = 'weapons' end
    ImGui.SameLine(0, 12)
    ctext(S.histMode == 'runs' and 'gold' or 'fgFaint', 'By Zone')
    if ImGui.IsItemClicked(0) then S.histMode = 'runs' end
    if S.runFilter then
        ImGui.SameLine(0, 12); ctext('fgDim', runLabel(S.runFilter))
        ImGui.SameLine(0, 6); ctext(S.runView and 'gold' or 'fgFaint', '[totals]')
        if ImGui.IsItemClicked(0) then S.runView = true end
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Show the combined totals for this zone run') end
        ImGui.SameLine(0, 6); ctext('resist', '[clear]')
        if ImGui.IsItemClicked(0) then S.runFilter = nil; S.selRun = nil; S.runView = false end
    end
    if S.targetFilter then
        ImGui.SameLine(0, 12); ctext('fgDim', S.targetFilter)
        ImGui.SameLine(0, 6); ctext('resist', '[clear]')
        if ImGui.IsItemClicked(0) then S.targetFilter = nil end
    end
    if S.weaponFilter then
        ImGui.SameLine(0, 12); ctext('fgDim', weaponLabel(S.weaponFilter.mh, S.weaponFilter.oh))
        ImGui.SameLine(0, 6); ctext('resist', '[clear]')
        if ImGui.IsItemClicked(0) then S.weaponFilter = nil end
    end
    ImGui.Separator()

    if S.histMode == 'targets' then
        -- per-target aggregates; click a row to drill into that target's fights
        if ImGui.BeginTable('targets_tbl', 4, bit32.bor(ImGuiTableFlags.RowBg,
                ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.ScrollY)) then
            ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn('N', ImGuiTableColumnFlags.WidthFixed, 34)
            ImGui.TableSetupColumn('Avg DPS', ImGuiTableColumnFlags.WidthFixed, 62)
            ImGui.TableSetupColumn('Best', ImGuiTableColumnFlags.WidthFixed, 62)
            ImGui.TableHeadersRow()
            for i, t in ipairs(H.targets or {}) do
                ImGui.PushID(i)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local _, pressed = ImGui.Selectable((t.mob or '?') .. '##t', false,
                    ImGuiSelectableFlags.SpanAllColumns)
                if pressed then S.targetFilter = t.mob; S.histMode = 'fights' end
                if (t.deaths or 0) > 0 then ImGui.SameLine(0, 6); ctext('resist', 'x' .. t.deaths) end
                ImGui.TableNextColumn(); ctext('fgDim', tostring(t.fights))
                ImGui.TableNextColumn(); ctext('gold', comma(t.avg_dps))
                ImGui.TableNextColumn(); ctext('fgDim', comma(t.best_dps))
                ImGui.PopID()
            end
            ImGui.EndTable()
        end
    elseif S.histMode == 'runs' then
        -- one row per (session, zone): an instance run rolled up. Click to
        -- filter the fights list to that run and show its combined totals.
        if ImGui.BeginTable('runs_tbl', 5, bit32.bor(ImGuiTableFlags.RowBg,
                ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.ScrollY)) then
            ImGui.TableSetupColumn('Zone', ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn('When', ImGuiTableColumnFlags.WidthFixed, 74)
            ImGui.TableSetupColumn('N', ImGuiTableColumnFlags.WidthFixed, 30)
            ImGui.TableSetupColumn('DPS', ImGuiTableColumnFlags.WidthFixed, 58)
            ImGui.TableSetupColumn('Damage', ImGuiTableColumnFlags.WidthFixed, 62)
            ImGui.TableHeadersRow()
            for i, r in ipairs(H.runs or {}) do
                ImGui.PushID(i)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local isSel = S.runFilter and S.runFilter.session_id == r.session_id and S.runFilter.zone == r.zone
                local _, pressed = ImGui.Selectable(zoneLabel(r.zone) .. '##r', isSel and true or false,
                    ImGuiSelectableFlags.SpanAllColumns)
                if pressed then
                    S.pendingRun = r; S.runFilter = r; S.runView = true; S.histMode = 'fights'
                end
                if r.session_id == H.sessionId then ImGui.SameLine(0, 6); ctext('green', 'now') end
                if (r.is_raid or 0) == 1 then ImGui.SameLine(0, 6); ctext('gold', '[RAID]') end
                if (r.deaths or 0) > 0 then ImGui.SameLine(0, 6); ctext('resist', 'x' .. r.deaths) end
                ImGui.TableNextColumn(); ctext('fgDim', os.date('%m/%d %H:%M', r.started_at or 0))
                ImGui.TableNextColumn(); ctext('fgDim', tostring(r.fights or 0))
                ImGui.TableNextColumn(); ctext('gold', comma(runDps(r)))
                ImGui.TableNextColumn(); ctext('fg', fmtK(r.total_dmg))
                ImGui.PopID()
            end
            ImGui.EndTable()
        end
    elseif S.histMode == 'weapons' then
        -- per-weapon-set aggregates; click to drill into that set's fights.
        -- Ranked by your avg DPS so sets compare directly.
        if ImGui.BeginTable('weapons_tbl', 4, bit32.bor(ImGuiTableFlags.RowBg,
                ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.ScrollY)) then
            ImGui.TableSetupColumn('Weapon set', ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn('N', ImGuiTableColumnFlags.WidthFixed, 34)
            ImGui.TableSetupColumn('Avg DPS', ImGuiTableColumnFlags.WidthFixed, 62)
            ImGui.TableSetupColumn('Best', ImGuiTableColumnFlags.WidthFixed, 62)
            ImGui.TableHeadersRow()
            for i, wset in ipairs(H.weapons or {}) do
                ImGui.PushID(i)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local _, pressed = ImGui.Selectable(weaponLabel(wset.mainhand, wset.offhand) .. '##w', false,
                    ImGuiSelectableFlags.SpanAllColumns)
                if pressed then
                    S.weaponFilter = { mh = wset.mainhand, oh = wset.offhand }; S.histMode = 'fights'
                end
                ImGui.TableNextColumn(); ctext('fgDim', tostring(wset.fights))
                ImGui.TableNextColumn(); ctext('gold', comma(wset.avg_pdps))
                ImGui.TableNextColumn(); ctext('fgDim', comma(wset.best_pdps))
                ImGui.PopID()
            end
            ImGui.EndTable()
        end
    else
        -- search + sort controls
        ImGui.SetNextItemWidth(140)
        local txt, changed = ImGui.InputTextWithHint('##fsearch', 'filter target...', S.fightSearch)
        if changed then S.fightSearch = txt end
        ImGui.SameLine(0, 10); ctext('fgFaint', 'sort:')
        local function sortChip(lbl, key)
            local on = S.fightSort.key == key
            local arrow = on and (S.fightSort.dir == 'desc' and ' v' or ' ^') or ''
            ImGui.SameLine(0, 8); ctext(on and 'gold' or 'fgFaint', lbl .. arrow)
            if ImGui.IsItemClicked(0) then
                if on then S.fightSort.dir = (S.fightSort.dir == 'desc') and 'asc' or 'desc'
                else S.fightSort.key, S.fightSort.dir = key, 'desc' end
            end
        end
        sortChip('time', 'time'); sortChip('dps', 'dps'); sortChip('dmg', 'dmg'); sortChip('dur', 'dur')

        -- filter + sort a working copy
        local q = S.fightSearch:lower()
        local rows = {}
        local wf = S.weaponFilter
        -- a zone run lists ITS fights (queried per run, not capped by recentFights)
        local pool = H.fights
        if S.runFilter then pool = (S.selRun and S.selRun.fights) or {} end
        for _, f in ipairs(pool) do
            local target = (f.primary_target or 'combat')
            if (not S.targetFilter or f.primary_target == S.targetFilter)
                and (not wf or ((f.mainhand or '') == (wf.mh or '') and (f.offhand or '') == (wf.oh or '')))
                and (q == '' or target:lower():find(q, 1, true)) then
                rows[#rows + 1] = f
            end
        end
        local sk, dir = S.fightSort.key, S.fightSort.dir
        local function keyval(f)
            if sk == 'dps' then return f.dps or 0 end
            if sk == 'dmg' then return f.total_dmg or 0 end
            if sk == 'dur' then return f.duration or 0 end
            return f.started_at or 0
        end
        table.sort(rows, function(a, b)
            local va, vb = keyval(a), keyval(b)
            if dir == 'asc' then return va < vb else return va > vb end
        end)

        if ImGui.BeginTable('fights_tbl', 5, bit32.bor(ImGuiTableFlags.RowBg,
                ImGuiTableFlags.BordersInnerH, ImGuiTableFlags.ScrollY)) then
            ImGui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 60)
            ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableSetupColumn('Dur', ImGuiTableColumnFlags.WidthFixed, 44)
            ImGui.TableSetupColumn('DPS', ImGuiTableColumnFlags.WidthFixed, 64)
            ImGui.TableSetupColumn('Damage', ImGuiTableColumnFlags.WidthFixed, 70)
            ImGui.TableHeadersRow()
            for _, f in ipairs(rows) do
                ImGui.PushID(f.id)
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local selected = S.sel and S.sel.fight and S.sel.fight.id == f.id
                local _, pressed = ImGui.Selectable(os.date('%H:%M', f.started_at), selected,
                    ImGuiSelectableFlags.SpanAllColumns)
                if pressed then S.pendingSel = f.id; S.runView = false end
                ImGui.TableNextColumn()
                ctext('fgDim', f.primary_target or 'combat')
                if f.is_raid == 1 then ImGui.SameLine(0, 6); ctext('gold', '[RAID]') end
                ImGui.TableNextColumn(); ctext('fgDim', mmss(f.duration))
                ImGui.TableNextColumn(); ctext('gold', comma(f.dps))
                ImGui.TableNextColumn(); ctext('fg', fmtK(f.total_dmg))
                ImGui.PopID()
            end
            ImGui.EndTable()
        end
    end
    ImGui.EndChild()
    ImGui.EndChild()

    ImGui.SameLine()

    -- right: selected fight detail (now full height)
    ImGui.BeginChild('h_right', 0, 0, false)
    do
        -- selected fight detail: pick a source (players, pets, AND the mobs
        -- that hit you), then see its histogram, timeline, and breakdown
        ImGui.BeginChild('h_detail', 0, 0, true)
        if S.runView and S.selRun then
            drawRunSummary(S.selRun)
        elseif S.sel and S.sel.fight then
            local f = S.sel.fight
            local dur = f.duration or 1
            local srcs = sourcesFromAbilities(S.sel.abilities, dur)
            local named = {}
            for _, s in ipairs(srcs) do named[s.name] = true end
            -- append incoming attackers (mobs) from the event log: events that
            -- targeted YOU whose source has no outgoing ability rows
            local inAgg = {}
            for _, e in ipairs(S.sel.events or {}) do
                if e.target == S.playerName and (e.amount or 0) > 0
                    and e.source and not named[e.source] then
                    inAgg[e.source] = (inAgg[e.source] or 0) + e.amount
                end
            end
            for name, total in pairs(inAgg) do
                srcs[#srcs + 1] = { name = name, total = total, dps = total / dur, incoming = true }
            end
            table.sort(srcs, function(x, y) return x.total > y.total end)
            local function has(nm)
                for _, s in ipairs(srcs) do if s.name == nm then return true end end
                return false
            end
            local hsel = (has(S.histSource) and S.histSource)
                or (has(S.playerName) and S.playerName)
                or (srcs[1] and srcs[1].name) or S.playerName
            cardHeader('Breakdown - ' .. (f.primary_target or 'fight'),
                comma(f.dps) .. ' dps  ' .. mmss(f.duration))
            if f.mainhand and f.mainhand ~= '' then
                ctext('fgFaint', 'weapons: ' .. weaponLabel(f.mainhand, f.offhand))
            end
            ctext('gold', '[export]')
            if ImGui.IsItemClicked(0) then Export.run(exportCtxFromHistory(S.sel)) end
            local clicked = drawSourceList('hsel_tbl', srcs, hsel)
            if clicked then S.histSource = clicked end
            ImGui.Separator()

            -- ability rows: fight_ability for players/pets, event-derived for mobs
            local abils = {}
            for _, a in ipairs(S.sel.abilities) do
                if a.source == hsel then abils[#abils + 1] = a end
            end
            table.sort(abils, function(x, y) return (x.total or 0) > (y.total or 0) end)
            if #abils == 0 then abils = abilitiesFromEvents(S.sel.events, hsel) end

            -- stacked DPS histogram rebuilt from this fight's persisted events
            if S.sel.events and #S.sel.events > 0 then
                -- encounter vs active DPS for the selected source, from events
                local stot, abkt = 0, {}
                for _, e in ipairs(S.sel.events) do
                    if e.source == hsel and (e.amount or 0) > 0 and (e.outcome == 'hit' or e.outcome == nil) then
                        stot = stot + e.amount; abkt[math.floor(e.t or 0)] = true
                    end
                end
                local asec = 0; for _ in pairs(abkt) do asec = asec + 1 end
                label('DPS over time - ' .. hsel)
                if stot > 0 then
                    local up = math.min(100, math.floor(asec / math.max(1, dur) * 100 + 0.5))
                    rightText('fgFaint', string.format('%s dps / %s active  %d%% up',
                        comma(stot / dur), comma(stot / math.max(1, asec)), up))
                end
                local hw = ImGui.GetContentRegionAvail()
                drawStackedArea(eventsToKindSeries(S.sel.events, hsel), dur, hw, 130)
                -- timeline: same widget as the live view, fed from stored events
                label('Timeline')
                ImGui.SameLine(0, 12)
                drawTimelineFilters()
                drawTimeline({ events = S.sel.events, duration = dur }, 240, hsel, abils)
                ImGui.Separator()
            end
            statRows('hbrk_tbl', breakdownRows(abils))
            if S.sel.casts and #S.sel.casts > 0 then
                ImGui.Separator()
                label('Casts')
                drawCastRows('hcast_rows', S.sel.casts, hsel)
            end
            -- end of the detail panel: there is no heal/overheal readout to follow it
            if drawSmarthealRow(S.sel and S.sel.fight) then
                for _, d in ipairs(S.shDecisions or {}) do
                    local color = (d.result == 'CAST_SUCCESS') and 'green' or 'fgFaint'
                    ctext(color, string.format('%s > %s  %s  %s',
                        d.spell or '?', d.target or '?', d.tier or '?', d.result or 'pending'))
                end
            end
        else
            cardHeader('Breakdown', 'select a fight')
            ctext('fgFaint', 'Click a fight on the left, then a source, to see its breakdown.')
        end
        ImGui.EndChild()
    end
    ImGui.EndChild()
end

-- ── deaths view ────────────────────────────────────────────────────────
local CAUSE_COLOR = {
    burst = 'resist', sustained = 'enemy', noheals = 'gold', cc = 'spell', aggro = 'gold',
    overwhelmed = 'enemy', environmental = 'pet', dot = 'dot', unknown = 'fgFaint',
}

-- HP over the last 60s with damage (red, from the top) and heal (green, from
-- the bottom) ticks. Falls back to a text strip when no DrawList is available.
local function drawHpSpark(verdict, w, h)
    local series = verdict.hpSeries or {}
    if #series < 2 then ctext('fgFaint', 'No HP samples for this death.'); return end
    local WINDOW = 60
    local dl = Theme.drawlist(ImGui.GetWindowDrawList())
    if not dl then
        local parts = {}
        for _, t in ipairs({ -60, -30, -15, -10, -5, -2, 0 }) do
            local hp = nil
            for _, p in ipairs(series) do if p.t <= t then hp = p.hp end end
            if hp then parts[#parts + 1] = string.format('%ds %d%%', t, math.floor(hp + 0.5)) end
        end
        ctext('fgDim', table.concat(parts, '  ·  '))
        return
    end
    local x0, y0 = ImGui.GetCursorScreenPos()
    local function px(t) return x0 + (math.max(-WINDOW, t) + WINDOW) / WINDOW * w end
    local function py(hp) return y0 + h - (math.max(0, math.min(100, hp or 0)) / 100) * h end
    dl:rectFilled(x0, y0, x0 + w, y0 + h, Theme.u32('bg'), 4)
    for _, g in ipairs({ 25, 50, 75 }) do dl:line(x0, py(g), x0 + w, py(g), Theme.u32('lineSoft'), 1) end
    local maxAmt = 1
    for _, k in ipairs(verdict.ticks or {}) do if k.amount > maxAmt then maxAmt = k.amount end end
    for _, k in ipairs(verdict.ticks or {}) do
        local th = math.max(2, (k.amount / maxAmt) * (h * 0.5))
        local x = px(k.t)
        if k.kind == 'heal' then dl:line(x, y0 + h, x, y0 + h - th, Theme.u32('green', 0.8), 1)
        else dl:line(x, y0, x, y0 + th, Theme.u32('enemy', 0.7), 1) end
    end
    for i = 2, #series do
        dl:line(px(series[i - 1].t), py(series[i - 1].hp), px(series[i].t), py(series[i].hp), Theme.u32('gold'), 2)
    end
    dl:rect(x0, y0, x0 + w, y0 + h, Theme.u32('lineSoft'), 4, 1)
    dl:text(x0 + 4, y0 + 2, Theme.u32('fgFaint'), '-60s')
    dl:text(x0 + w - 34, y0 + 2, Theme.u32('fgFaint'), 'death')
    ImGui.Dummy(w, h)
end

-- Old recap for deaths recorded before the post-mortem tables existed.
local function drawLegacyRecap(d, events)
    local deathT = d.t or 1e18
    local incoming = {}
    for _, e in ipairs(events or {}) do
        if e.target == S.playerName and (e.amount or 0) > 0 and (e.t or 0) <= deathT + 0.01
            and (e.outcome == 'hit' or e.outcome == nil) then
            incoming[#incoming + 1] = e
        end
    end
    table.sort(incoming, function(a, b) return (a.t or 0) < (b.t or 0) end)
    local win, wtot = deathT - 10, 0
    for _, e in ipairs(incoming) do if (e.t or 0) >= win then wtot = wtot + e.amount end end
    ctext('enemy', string.format('%s taken in last 10s', comma(wtot)))
    ImGui.Separator()
    label('Final blows')
    local startI = math.max(1, #incoming - 15)
    for i = #incoming, startI, -1 do
        local e = incoming[i]
        ctext('fgFaint', string.format('-%4.1fs', deathT - (e.t or 0)))
        ImGui.SameLine(0, 8); ctext('fg', comma(e.amount))
        ImGui.SameLine(0, 8); ctext('fgDim', (e.ability or '?') .. '  ' .. (e.source or '?'))
    end
    if #incoming == 0 then ctext('fgFaint', 'No incoming damage recorded before this death.') end
    ctext('fgFaint', '(recorded before post-mortem capture existed - no state samples)')
end

local function drawVerdict(v)
    -- narrative
    for _, s in ipairs(v.narrative or {}) do ImGui.TextWrapped(s) end
    if ImGui.SmallButton('export##death') then S.exportRequest = true end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Print the recap to the console and write a report file (/companion death)') end
    ImGui.Separator()

    -- HP sparkline
    label('HP - last 60s')
    local w = ImGui.GetContentRegionAvail()
    drawHpSpark(v, math.max(80, w - 4), 64)
    ImGui.Separator()

    -- notable moments
    label('What happened')
    ImGui.BeginChild('d_moments', 0, 150, true)
    for i, m in ipairs(v.moments or {}) do
        ImGui.PushID(i)
        ctext('fgFaint', string.format('%6.1fs', m.t))
        ImGui.SameLine(0, 8)
        ctext(m.color or 'fg', m.text)
        ImGui.PopID()
    end
    if #(v.moments or {}) == 0 then ctext('fgFaint', 'Nothing notable recorded.') end
    ImGui.EndChild()

    -- incoming (last 10s) · group at death
    if ImGui.BeginTable('d_cols', 2, ImGuiTableFlags.SizingStretchSame) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        cardHeader('Incoming - last 10s', comma(v.incoming10.total))
        local rows, top = {}, (v.incoming10.bySource[1] and v.incoming10.bySource[1].total) or 1
        for i, s in ipairs(v.incoming10.bySource) do
            if i > 8 then break end
            rows[#rows + 1] = { name = s.name, nameColor = 'enemy', frac = s.total / top, fill = 'enemy',
                value = fmtK(s.total), sub = string.format('%d%%', math.floor(s.pct + 0.5)) }
        end
        if #rows > 0 then statRows('d_inc', rows) else ctext('fgFaint', 'no damage lines') end
        if (v.heals10.total or 0) > 0 then
            ctext('green', 'healed ' .. comma(v.heals10.total))
            for i, hh in ipairs(v.heals10.byHealer) do
                if i > 4 then break end
                ctext('fgDim', '  ' .. hh.name .. '  ' .. fmtK(hh.total))
            end
        end

        ImGui.TableNextColumn()
        cardHeader('Group at death', (#(v.groupAtDeath or {}) > 0) and (#v.groupAtDeath .. ' members') or 'solo')
        if v.stateAtDeath and v.stateAtDeath ~= '' then ctext('spell', 'you: ' .. v.stateAtDeath) end
        for _, m in ipairs(v.groupAtDeath or {}) do
            local healer = Postmortem.HEALER_CLASSES[m.cls]
            local color = m.flag ~= '' and 'resist' or (healer and 'green' or 'fg')
            ctext(color, string.format('%-14s %-4s', m.name, m.cls))
            ImGui.SameLine(0, 6)
            ctext('fgDim', string.format('hp %3d%%  mana %3d%%  %4dm %s%s', m.hp or 0, m.mana or 0, m.dist or 0,
                m.flag ~= '' and m.flag or '', m.mt and ' [MT]' or ''))
        end
        ImGui.EndTable()
    end
end

local function drawDeaths()
    local deaths = S.hist.deaths or {}
    local availW = ImGui.GetContentRegionAvail()
    local leftW = math.floor(availW * 0.38)

    -- left: list of recent deaths
    ImGui.BeginChild('d_list', leftW, 0, false)
    ImGui.BeginChild('d_list_card', 0, 0, true)
    cardHeader('Deaths', #deaths .. ' recorded')
    if #deaths == 0 then
        ctext('fgFaint', 'No deaths recorded yet. (Good.)')
    elseif ImGui.BeginTable('deaths_tbl', 4, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerH,
            ImGuiTableFlags.ScrollY)) then
        ImGui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 48)
        ImGui.TableSetupColumn('Zone', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Killer', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Cause', ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableHeadersRow()
        for i, d in ipairs(deaths) do
            ImGui.PushID(i)
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            local sel = S.selDeath and S.selDeath.row and S.selDeath.row.fight_id == d.fight_id
                and math.abs((S.selDeath.row.t or 0) - (d.t or 0)) < 0.01
            local _, pressed = ImGui.Selectable(os.date('%H:%M', d.started_at), sel,
                ImGuiSelectableFlags.SpanAllColumns)
            if pressed then S.pendingDeath = d end
            ImGui.TableNextColumn(); ctext('fgDim', (d.zone and d.zone ~= '') and d.zone or '?')
            ImGui.TableNextColumn(); ctext('enemy', (d.killer and d.killer ~= '?') and d.killer or 'unknown')
            ImGui.TableNextColumn()
            if d.cause then ctext(CAUSE_COLOR[d.cause] or 'fgFaint', Postmortem.CAUSE_LABEL[d.cause] or d.cause)
            else ctext('fgFaint', '-') end
            ImGui.PopID()
        end
        ImGui.EndTable()
    end
    ImGui.EndChild()
    ImGui.EndChild()

    ImGui.SameLine()

    -- right: post-mortem of the selected death
    ImGui.BeginChild('d_recap', 0, 0, true)
    if S.selDeath and S.selDeath.row then
        local d, v = S.selDeath.row, S.selDeath.verdict
        local killer = (v and v.killer) or d.killer
        cardHeader('Killed by ' .. ((killer and killer ~= '?') and killer or 'something unknown'),
            os.date('%H:%M', d.started_at) .. '  ' .. (d.mob or ''))
        if v then
            ctext(CAUSE_COLOR[v.cause] or 'fgFaint', string.upper(Postmortem.CAUSE_LABEL[v.cause] or v.cause))
            drawVerdict(v)
        else
            drawLegacyRecap(d, S.selDeath.events)
        end
        drawSmarthealRow(S.selDeath.row)
    else
        cardHeader('Death recap', 'select a death')
        ctext('fgFaint', 'Click a death on the left to see what killed you.')
    end
    ImGui.EndChild()
end

-- ── healing view ───────────────────────────────────────────────────────
local function drawHealing()
    local snap = S.combat and S.combat.snapshot() or nil
    if not snap then
        ImGui.Dummy(0, 20); ctext('fgFaint', 'Waiting for combat...'); return
    end
    local healers = scopeRows(snap.healSources or {})
    local totalHeal, totalOver = 0, 0
    for _, h in ipairs(healers) do totalHeal = totalHeal + h.total; totalOver = totalOver + h.over end

    ctext('eqName', snap.name)
    rightText('green', comma(totalHeal / math.max(1, snap.duration)) .. ' hps')
    local opct = (totalHeal + totalOver) > 0 and math.floor(totalOver / (totalHeal + totalOver) * 100 + 0.5) or 0
    ctext('fgDim', 'healed ' .. fmtK(totalHeal) .. '  ' .. opct .. '% overheal')
    ImGui.Separator()

    local sh = S.smartheal
    if sh and sh.live then
        local availW0 = ImGui.GetContentRegionAvail()
        local halfW = math.floor(availW0 * 0.5)

        -- ── Outcomes: did the healing keep people alive ───────────────
        ImGui.BeginChild('sh_out', halfW, 118, true)
        cardHeader('SmartHeals - outcomes',
            sh.shadow and 'shadow' or (sh.emergencyPct and ('emergency ' .. sh.emergencyPct .. '%') or 'no config'))
        local tankName = sh.maName or 'tank'
        if sh.tankMinHp then
            local danger = sh.emergencyPct and sh.tankMinHp <= sh.emergencyPct
            ctext('fg', tankName .. ' low')
            rightText(danger and 'red' or 'green', math.floor(sh.tankMinHp + 0.5) .. '%')
        else
            ctext('fgFaint', tankName .. ' low: no samples yet')
        end
        if sh.tankEmergSec then
            local groupSec = 0
            for _, m in ipairs(sh.members) do groupSec = groupSec + (m.emergSec or 0) end
            ctext('fg', 'under the line')
            rightText(sh.tankEmergSec > 0 and 'red' or 'fgFaint',
                string.format('%.1fs  (group %.1fs)', sh.tankEmergSec, groupSec))
        end
        ctext('fg', 'smart casts landed')
        rightText('green', tostring(sh.casts))
        if sh.netFires > 0 then
            ctext('fg', 'safety net fired')
            rightText('red', tostring(sh.netFires))
        end
        ImGui.EndChild()

        ImGui.SameLine()

        -- ── Decisions: what the brain chose ───────────────────────────
        ImGui.BeginChild('sh_dec', 0, 118, true)
        local nDec = 0
        for _, n in pairs(sh.tiers) do nDec = nDec + n end
        cardHeader('SmartHeals - decisions', nDec .. ' picks')
        local tierParts = {}
        for tier, n in pairs(sh.tiers) do tierParts[#tierParts + 1] = tier .. ' ' .. n end
        table.sort(tierParts)
        ctext('fgDim', #tierParts > 0 and table.concat(tierParts, '  ') or 'no picks yet')
        local skips = 0
        for res, n in pairs(sh.results) do
            if res ~= 'CAST_SUCCESS' then skips = skips + n end
        end
        local tail = string.format('%d cast  %d skipped', sh.casts, skips)
        if sh.vetoes > 0 then tail = tail .. string.format('  %d veto', sh.vetoes) end
        ctext('fgFaint', tail)
        ImGui.Separator()
        for i = #sh.decisions, 1, -1 do
            local d = sh.decisions[i]
            local color = (d.result == 'CAST_SUCCESS') and 'green'
                or (d.result == nil) and 'fgDim' or 'fgFaint'
            ctext(color, string.format('%s > %s', d.spell, d.target))
            rightText(color, d.result or 'pending')
            local sub = d.pct and (math.floor(d.pct + 0.5) .. '%') or '?'
            if d.dps then sub = sub .. '  ' .. comma(d.dps) .. ' dps' end
            if d.trigger and d.trigger ~= '' then sub = sub .. '  ' .. d.trigger end
            ctext('fgFaint', sub)
        end
        ImGui.EndChild()
        ImGui.Separator()
    end

    if #healers == 0 then ctext('fgFaint', 'no healing this fight'); return end

    local function has(nm)
        for _, h in ipairs(healers) do if h.name == nm then return true end end
        return false
    end
    local sel = (has(S.healSource) and S.healSource) or (has(S.playerName) and S.playerName) or healers[1].name
    local top = healers[1].total or 1

    local availW = ImGui.GetContentRegionAvail()
    local leftW = math.floor(availW * 0.5)

    -- left: healer meter (ranked by healing)
    ImGui.BeginChild('heal_list', leftW, 0, false)
    ImGui.BeginChild('heal_list_card', 0, 0, true)
    label('Healers'); scopeToggle(10)
    rightText('fgFaint', 'by healing')
    ImGui.Separator()
    for i, h in ipairs(healers) do
        ImGui.PushID(i)
        local color = h.mine and 'you' or 'green'
        local _, pressed = ImGui.Selectable(i .. '. ' .. h.name .. '##h', h.name == sel)
        if pressed then S.healSource = h.name end
        rightText('green', comma(h.hps) .. ' hps')
        ctext('fgFaint', string.format('%d%% over  %s', math.floor(h.overpct + 0.5), fmtK(h.total)))
        local w = ImGui.GetContentRegionAvail()
        drawBar(color, top > 0 and h.total / top or 0, 5, w)
        ImGui.PopID()
    end
    ImGui.EndChild()
    ImGui.EndChild()

    ImGui.SameLine()

    -- right: selected healer's per-spell breakdown (with overheal)
    ImGui.BeginChild('heal_detail', 0, 0, true)
    local info
    for _, h in ipairs(healers) do if h.name == sel then info = h break end end
    local meta = info and string.format('%s  %s hps  %d%% over',
        fmtK(info.total), comma(info.hps), math.floor(info.overpct + 0.5)) or ''
    cardHeader('Heals - ' .. sel, meta)
    local heals = (snap.healAbilitiesBySource or {})[sel] or {}
    if #heals == 0 then ctext('fgFaint', 'no heal spells recorded') else statRows('heal_brk', breakdownRows(heals)) end

    -- who this healer healed (target distribution)
    if info and info.targets and #info.targets > 0 then
        ImGui.Separator(); label('Targets')
        local ttop = info.targets[1].total or 1
        for i, t in ipairs(info.targets) do
            if i > 8 then break end
            ctext(t.name == S.playerName and 'you' or 'fg', t.name)
            rightText('green', fmtK(t.total))
            local pct = info.total > 0 and math.floor(t.total / info.total * 100 + 0.5) or 0
            local sub = pct .. '%'
            if (t.over or 0) > 0 then sub = sub .. '  ' .. fmtK(t.over) .. ' over' end
            ctext('fgFaint', sub)
            local w = ImGui.GetContentRegionAvail(); drawBar('green', ttop > 0 and t.total / ttop or 0, 4, w)
        end
    end

    -- overall healing received (all healers -> each target)
    local recv = snap.healReceived or {}
    if #recv > 0 then
        ImGui.Separator(); label('Healing received (all healers)')
        local rtop = recv[1].total or 1
        for i, t in ipairs(recv) do
            if i > 8 then break end
            ctext(t.name == S.playerName and 'you' or 'fg', t.name)
            rightText('green', fmtK(t.total))
            if (t.over or 0) > 0 then ctext('fgFaint', fmtK(t.over) .. ' over') end
            local w = ImGui.GetContentRegionAvail(); drawBar('green', rtop > 0 and t.total / rtop or 0, 4, w)
        end
    end
    ImGui.EndChild()
end

-- ── settings view ──────────────────────────────────────────────────────
local function drawSettings()
    ImGui.BeginChild('set_card', 0, 0, true)
    local st = S.settings
    ctext('fgFaint', 'Changes apply immediately and persist across sessions.')
    ImGui.Separator()

    label('Encounter timeout (seconds)')
    ImGui.SetNextItemWidth(220)
    local t, ch = ImGui.SliderInt('##set_timeout', st.timeout, 4, 30)
    if ch then st.timeout = t; if S.combat then S.combat.timeoutSec = t end end
    ctext('fgFaint', 'Gap of no combat that closes a fight.')
    ImGui.Dummy(0, 4)

    label('Event retention (days)')
    ImGui.SetNextItemWidth(220)
    local r, ch2 = ImGui.SliderInt('##set_retention', st.retentionDays, 1, 120)
    if ch2 then st.retentionDays = r end
    ctext('fgFaint', 'Raw events older than this are pruned; fight/ability rollups are kept forever.')
    ImGui.Dummy(0, 4)

    label('Mini meter rows')
    ImGui.SetNextItemWidth(220)
    local mr, ch3 = ImGui.SliderInt('##set_minirows', st.miniRows, 3, 24)
    if ch3 then st.miniRows = mr end
    local mp, chp = ImGui.Checkbox('Mini meter share pie', S.miniPie)
    if chp then S.miniPie = mp end
    ctext('fgFaint', 'Damage (or healing) share pie under the mini meter bars; also the pie toggle on its header.')
    ImGui.Dummy(0, 4)

    local sh, ch4 = ImGui.Checkbox('Group sharing over actors', st.share)
    if ch4 then st.share = sh; if S.group and S.group.setEnabled then S.group.setEnabled(sh) end end
    ctext('fgFaint', 'Broadcast your damage/healing so boxes merge into one group meter.')
    ImGui.Dummy(0, 4)

    local go, ch5 = ImGui.Checkbox('Group only (raid filter)', st.groupOnly)
    if ch5 then st.groupOnly = go end
    ctext('fgFaint', 'Meters show only you, your group members, your companion boxes and their pets.')
    ctext('fgFaint', 'Same switch as the all | group toggle on the mini meter and source cards.')
    ImGui.Separator()

    if ImGui.Button('Reset window position/size') then
        S._win = { x = 60, y = 60, w = 900, h = 560 }; S._winApply = true
    end
    ImGui.Dummy(0, 6)
    ctext('fgFaint', 'Commands: /companion  /companion mini  /companion export  /companion death  /companion reset  /companion stop')

    local sh = S.smartheal
    if sh and (sh.unknown or 0) > 0 then
        ImGui.Separator(); label('SmartHeals feed')
        ctext('red', string.format('%d message(s) of an unrecognized kind', sh.unknown))
        ctext('fgFaint', 'ma_healbridge.lua and companion/smartheal.lua have drifted.')
    end
    ImGui.EndChild()
end

-- ── public ─────────────────────────────────────────────────────────────
---@param opts table { combat, db, playerName }
function UI.setup(opts)
    S.combat = opts.combat
    S.db = opts.db
    S.playerName = opts.playerName or 'You'
    S.group = opts.group
end

--- Cache the SmartHeals snapshot. Called from the main loop; the render callback
--- only ever reads S.smartheal, per the no-work-in-render invariant.
---@param snap table|nil
function UI.setSmartheal(snap) S.smartheal = snap end

-- Cache my current group roster for the "group only" meter scope. Called from
-- the main loop with the black-box sample's group array ({ name = ... }, me
-- excluded) -- the render callback only reads S.roster. nil leaves it as is.
---@param members table|nil
function UI.setRoster(members)
    if type(members) ~= 'table' then return end
    local set = {}
    for _, m in ipairs(members) do
        local n = type(m) == 'table' and m.name or m
        if n and n ~= '' then set[tostring(n):lower()] = true end
    end
    S.roster = set
end

-- Test hooks for the meter scope (see tests/test_meter_scope.lua).
function UI.inGroupScope(row) return inGroupScope(row) end
function UI.pieSlices(rows, maxSlices) return pieSlices(rows, maxSlices) end
function UI.setGroupOnly(v) S.settings.groupOnly = v and true or false end
function UI.groupOnly() return S.settings.groupOnly end

-- The four history queries are nowhere near equally cheap. recentFights is a
-- 60-row walk down idx_fight_session; the two aggregates GROUP BY the whole
-- fight table, and recentDeaths reaches into event -- millions of rows on a
-- long-lived DB. Refreshing all four at the caller's cadence put ~150ms of
-- blocking SQLite on the game thread every 2s. The cheap one keeps the
-- caller's cadence; the rest run on a slow tier (or on demand via force).
local SLOW_TIER_MS = 10000
local lastSlowMs = -math.huge

-- Refresh cached history + apply a pending selection. Call from the main loop
-- (NOT from render) so no DB work happens inside the ImGui callback.
---@param sessionMeta table
---@param force boolean|nil  also refresh the slow tier now (new fight, first draw)
function UI.refreshHistory(sessionMeta, force)
    if not S.db then return end
    S.hist.fights = S.db:recentFights(60)
    local nowMs = mq.gettime()
    if force or (nowMs - lastSlowMs) >= SLOW_TIER_MS then
        lastSlowMs = nowMs
        S.hist.deaths = S.db:recentDeaths(40)
        S.hist.targets = S.db:targetAggregates(60)
        S.hist.weapons = S.db:weaponAggregates(60)
        S.hist.runs = S.db:zoneRuns(60)
    end
    S.hist.session = sessionMeta
    S.hist.sessionId = S.db.sessionId and S.db:sessionId() or nil
    -- zone run: load on request, and reload the CURRENT session's run when a
    -- fight just finished (force) so the open instance keeps accumulating
    local run = S.pendingRun
    S.pendingRun = nil
    if not run and force and S.selRun and S.selRun.run.session_id == S.hist.sessionId then
        run = S.selRun.run
    end
    if run then
        local id, zone = run.session_id, run.zone or ''
        S.selRun = { run = run, fights = S.db:runFights(id, zone),
            sources = S.db:runSources(id, zone), targets = S.db:runTargets(id, zone) }
        -- refresh the run's own totals from the aggregate list when it is there
        for _, r in ipairs(S.hist.runs or {}) do
            if r.session_id == id and (r.zone or '') == zone then S.selRun.run = r; S.runFilter = r end
        end
    end
    if S.pendingSel then
        local id = S.pendingSel
        S.pendingSel = nil
        local fight
        for _, f in ipairs(S.hist.fights) do if f.id == id then fight = f break end end
        if fight then
            S.sel = { fight = fight, abilities = S.db:fightAbilities(id),
                casts = S.db:fightCasts(id), events = S.db:fightEvents(id) }
            S.shDecisions = S.db:fightDecisions(id)
        end
    end
    if S.pendingDeath then
        local d = S.pendingDeath
        S.pendingDeath = nil
        local events = S.db:fightEvents(d.fight_id)
        local detail = d.death_id and S.db:deathDetail(d.death_id) or nil
        local verdict = nil
        if detail then
            local ok, v = pcall(Postmortem.analyze, { samples = detail.samples, events = events, deathT = d.t,
                playerName = S.playerName, killer = d.killer, window = 60 })
            if ok then verdict = v else printf('\ar[companion]\ax post-mortem failed: %s', tostring(v)) end
        end
        -- pruned events leave the analyzer with nothing to work from, which
        -- would otherwise mislabel the death (e.g. 'unknown'/'environmental')
        -- even though a cause was recorded at the time of death.
        if verdict and #events == 0 and type(detail and detail.row.cause) == 'string' and detail.row.cause ~= '' then
            verdict.cause = detail.row.cause
            verdict.narrative = { detail.row.narrative or '',
                '(combat events for this fight were pruned; showing the cause recorded at the time of death)' }
        end
        S.selDeath = { row = d, row_db = detail and detail.row or nil, events = events,
            samples = detail and detail.samples or nil, verdict = verdict }
    end
    if S.exportRequest then
        S.exportRequest = false
        if S.selDeath and S.selDeath.verdict then
            Export.runDeath(S.selDeath.verdict, S.selDeath.row, S.playerName)
        else
            printf('\ay[companion]\ax no post-mortem to export (select a death recorded with state samples).')
        end
    end
end

function UI.hasPendingSelect()
    return S.pendingSel ~= nil or S.pendingDeath ~= nil or S.pendingRun ~= nil or S.exportRequest
end

-- Test hooks for the zone-run selection (see tests/test_zone_runs.lua).
function UI.selectRun(run) S.pendingRun = run; S.runFilter = run; S.runView = true end
function UI.selectedRun() return S.selRun end
function UI.clearRun() S.runFilter = nil; S.selRun = nil; S.runView = false end

-- Visibility beacon. The history refresh only earns its cost while someone is
-- looking at it, but hosts gate drawing differently (standalone uses S.open,
-- medley's docked panel uses MedleyParseOpen, maui uses its tab), so "did a
-- draw path run in the last second" is the only portable signal. Both draw
-- entry points stamp it; the main loop reads UI.isVisible().
local lastDrawnMs = -math.huge
function UI.markDrawn() lastDrawnMs = mq.gettime() end
function UI.isVisible() return (mq.gettime() - lastDrawnMs) < 1000 end

function UI.isOpen() return S.open end
function UI.setOpen(v) S.open = v end
function UI.toggle() S.open = not S.open end

-- Restore persisted UI state (window geometry, filters, mode, sort). Call once
-- from the main loop after setup, NOT from render.
function UI.loadPrefs()
    if not S.db then return end
    local p = S.db:getAllPrefs()
    if p.tl_hidden then
        for k in tostring(p.tl_hidden):gmatch('[^,]+') do S.tlFilters[k] = false end
    end
    if p.hist_mode then S.histMode = p.hist_mode end
    if p.mini then S.mini = (p.mini == '1') end
    if p.mini_pie then S.miniPie = (p.mini_pie == '1') end
    -- settings
    local st = S.settings
    if p.set_timeout then st.timeout = tonumber(p.set_timeout) or st.timeout end
    if p.set_retention then st.retentionDays = tonumber(p.set_retention) or st.retentionDays end
    if p.set_minirows then st.miniRows = tonumber(p.set_minirows) or st.miniRows end
    if p.set_share then st.share = (p.set_share == '1') end
    if p.set_grouponly then st.groupOnly = (p.set_grouponly == '1') end
    if S.combat then S.combat.timeoutSec = st.timeout end
    if S.group and S.group.setEnabled then S.group.setEnabled(st.share) end
    if p.fight_sort then
        local k, d = tostring(p.fight_sort):match('([^:]+):([^:]+)')
        if k and d then S.fightSort = { key = k, dir = d } end
    end
    if p.win then
        local x, y, ww, hh = tostring(p.win):match('([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)')
        if x and tonumber(ww) and tonumber(ww) > 50 then
            S._win = { x = tonumber(x), y = tonumber(y), w = tonumber(ww), h = tonumber(hh) }
            S._winApply = true
        end
    end
end

-- Persist any changed UI state. Call from the main loop (does DB writes).
function UI.savePrefs()
    if not S.db then return end
    if S._winLive and (S._winLive.w or 0) > 50 then
        local s = string.format('%.0f,%.0f,%.0f,%.0f', S._winLive.x, S._winLive.y, S._winLive.w, S._winLive.h)
        if s ~= S._savedWin then S.db:setPref('win', s); S._savedWin = s end
    end
    local hidden = {}
    for _, f in ipairs(TL_FILTERS) do if S.tlFilters[f.key] == false then hidden[#hidden + 1] = f.key end end
    local hs = table.concat(hidden, ',')
    if hs ~= S._savedFilters then S.db:setPref('tl_hidden', hs); S._savedFilters = hs end
    if S.histMode ~= S._savedMode then S.db:setPref('hist_mode', S.histMode); S._savedMode = S.histMode end
    local ss = S.fightSort.key .. ':' .. S.fightSort.dir
    if ss ~= S._savedSort then S.db:setPref('fight_sort', ss); S._savedSort = ss end
    local mv = S.mini and '1' or '0'
    if mv ~= S._savedMini then S.db:setPref('mini', mv); S._savedMini = mv end
    local pv = S.miniPie and '1' or '0'
    if pv ~= S._savedMiniPie then S.db:setPref('mini_pie', pv); S._savedMiniPie = pv end
    -- settings (only write on change)
    local st = S.settings
    local sig = table.concat({ st.timeout, st.retentionDays, st.miniRows, st.share and 1 or 0, st.groupOnly and 1 or 0 }, ',')
    if sig ~= S._savedSettings then
        S.db:setPref('set_timeout', st.timeout)
        S.db:setPref('set_retention', st.retentionDays)
        S.db:setPref('set_minirows', st.miniRows)
        S.db:setPref('set_share', st.share and '1' or '0')
        S.db:setPref('set_grouponly', st.groupOnly and '1' or '0')
        S._savedSettings = sig
    end
end

-- Expose retention setting to the main loop's prune.
function UI.retentionDays() return S.settings.retentionDays or 14 end

-- Compact group meter: a ranked DPS row per contributor in the current fight.
-- Fixed/resizable (a stretch meter needs a defined width, so not auto-resize).
-- Double-click to expand to the full window.
-- Mini meter rows: my parse merged with peers' first-person broadcasts
-- (peers are authoritative for themselves; my rows stay from my parse; others
-- I only see third-person fill the rest), scoped and ranked. Cached per
-- snapshot object / mode / scope and refreshed at most every 500ms so peer
-- broadcasts (~1 Hz) still land -- not rebuilt and re-sorted every frame.
local miniCache = { rows = nil, snap = nil, hps = nil, scope = nil, t = -math.huge }
local function miniRows(snap, hps)
    local cache = miniCache
    local scope = S.settings.groupOnly
    local nowMs = mq.gettime()
    if cache.rows and cache.snap == snap and cache.hps == hps and cache.scope == scope
        and (nowMs - cache.t) < 500 then
        return cache.rows
    end
    local byName, order = {}, {}
    local function put(name, row)
        if not byName[name] then order[#order + 1] = name end
        byName[name] = row
    end
    if hps then
        for _, h in ipairs(snap.healSources or {}) do
            put(h.name, { name = h.name, total = h.total, rate = h.hps, mine = h.mine })
        end
        if S.group then
            for _, p in ipairs(S.group.freshPeers()) do
                if (p.healTotal or 0) > 0 then
                    put(p.player, { name = p.player, total = p.healTotal, rate = p.healDps, peer = true })
                end
            end
        end
    else
        for _, s in ipairs(snap.sources) do
            put(s.name, { name = s.name, total = s.total, rate = s.dps, mine = s.mine, isPet = s.isPet })
        end
        if S.group then
            for _, p in ipairs(S.group.freshPeers()) do
                if (p.playerDmg or 0) > 0 then
                    put(p.player, { name = p.player, total = p.playerDmg, rate = p.playerDps, peer = true })
                end
                if p.petName and p.petName ~= '' and (p.petDmg or 0) > 0 then
                    put(p.petName, { name = p.petName, total = p.petDmg, rate = p.petDps, isPet = true, peer = true })
                end
            end
        end
    end
    local rows = {}
    for _, name in ipairs(order) do rows[#rows + 1] = byName[name] end
    rows = scopeRows(rows)
    table.sort(rows, function(a, b) return a.total > b.total end)
    cache.rows, cache.snap, cache.hps, cache.scope, cache.t = rows, snap, hps, scope, nowMs
    return rows
end

-- Test hook (see tests/test_meter_scope.lua).
function UI.miniRows(snap, hps) return miniRows(snap, hps) end

local function drawMini()
    ImGui.SetNextWindowSize(250, 230, ImGuiCond.FirstUseEver)
    local visible = ImGui.Begin('Companion##mini###CompanionMini', S.open, ImGuiWindowFlags.NoCollapse)
    S.open = visible
    if visible then
        local snap = S.combat and S.combat.snapshot() or nil
        -- header: fight name (left) + expand-to-full button (right), always shown
        ctext('eqName', snap and snap.name or 'Companion')
        ImGui.SameLine()
        do
            local av = ImGui.GetContentRegionAvail()
            local bw = ImGui.CalcTextSize('full') + 12
            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, av - bw))
            if ImGui.SmallButton('full') then S.mini = false end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Expand to the full view') end
        end
        if not snap then
            ctext('fgFaint', 'no fight')
        else
            -- Damage / Healing toggle (left) + duration (right)
            local hps = (S.miniMode == 'hps')
            ctext(hps and 'fgFaint' or 'gold', 'dps')
            if ImGui.IsItemClicked(0) then S.miniMode = 'dps' end
            ImGui.SameLine(0, 8); ctext(hps and 'green' or 'fgFaint', 'hps')
            if ImGui.IsItemClicked(0) then S.miniMode = 'hps' end
            ImGui.SameLine(0, 6); ctext('fgFaint', '|')
            scopeToggle(6)
            ImGui.SameLine(0, 6); ctext('fgFaint', '|')
            ImGui.SameLine(0, 6); ctext(S.miniPie and 'gold' or 'fgFaint', 'pie')
            if ImGui.IsItemClicked(0) then S.miniPie = not S.miniPie end
            if ImGui.IsItemHovered() then ImGui.SetTooltip('Show/hide the share pie under the bars') end
            rightText('fgFaint', mmss(snap.duration) .. (snap.live and '' or ' [end]'))
            ImGui.Separator()

            local barColor = hps and 'green' or 'gold'
            local rows = miniRows(snap, hps)

            local top = (rows[1] and rows[1].total) or 1
            local grand = 0
            for _, r in ipairs(rows) do grand = grand + r.total end
            grand = grand > 0 and grand or 1
            if #rows == 0 then
                ctext('fgFaint', S.settings.groupOnly and 'nothing from your group yet'
                    or (hps and 'no healing yet' or 'no damage yet'))
            end
            local maxRows = S.settings.miniRows or 12
            for i, s in ipairs(rows) do
                if i > maxRows then break end
                local color = s.mine and 'you' or (s.isPet and 'pet' or (hps and 'green' or 'fg'))
                ctext(color, i .. '. ' .. s.name)
                if s.peer then ImGui.SameLine(0, 4); ctext('green', '*') end -- reported by that box
                rightText(hps and 'green' or 'gold', comma(s.rate))
                local pct = math.floor(s.total / grand * 100 + 0.5)
                ctext('fgFaint', pct .. '%  ' .. fmtK(s.total))
                local w = ImGui.GetContentRegionAvail()
                drawBar(s.mine and 'you' or (s.isPet and 'pet' or barColor), s.total / top, 4, w)
            end
            if S.miniPie and #rows > 0 then
                ImGui.Separator()
                local w = ImGui.GetContentRegionAvail()
                local r = math.max(24, math.min(40, math.floor(w / 5)))
                drawPie(pieSlices(rows, 6), r, w)
            end
            if not hps and (snap.incoming or 0) > 0 then
                ImGui.Separator()
                ctext('enemy', comma(snap.incomingDps) .. ' dps taken')
                if (snap.deaths or 0) > 0 then ImGui.SameLine(); ctext('resist', '  x' .. snap.deaths) end
            end
        end
        if ImGui.IsWindowHovered() and ImGui.IsMouseDoubleClicked(0) then S.mini = false end
    end
    ImGui.End()
end

-- The full view's tab bar, drawn into the CURRENT window. Shared by the
-- standalone overlay (drawFull) and hosts that dock the console into a
-- window of their own (maui's Parse panel via UI.drawDockedBody).
local function drawTabs()
    if ImGui.BeginTabBar('cmp_tabs') then
        if ImGui.BeginTabItem('Live Fight') then S.tab = 'live'; drawLive(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('Healing') then S.tab = 'healing'; drawHealing(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('History') then S.tab = 'history'; drawHistory(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('Deaths') then S.tab = 'deaths'; drawDeaths(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('Settings') then S.tab = 'settings'; drawSettings(); ImGui.EndTabItem() end
        ImGui.EndTabBar()
    end
end

local function drawFull()
    -- restore saved geometry on the first frame after load
    if S._winApply and S._win then
        ImGui.SetNextWindowPos(S._win.x, S._win.y, ImGuiCond.Always)
        ImGui.SetNextWindowSize(S._win.w, S._win.h, ImGuiCond.Always)
        S._winApply = false
    end
    local visible, showing = ImGui.Begin('Companion###CompanionOverlay', S.open)
    S.open = visible
    -- capture live geometry for persistence (read while the window is current)
    local wx, wy = ImGui.GetWindowPos()
    local ww, wh = ImGui.GetWindowSize()
    S._winLive = { x = wx, y = wy, w = ww, h = wh }
    if showing then
        -- shrink-to-mini button, right-aligned above the tabs
        local av = ImGui.GetContentRegionAvail()
        local bw = ImGui.CalcTextSize('compact') + 12
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + math.max(0, av - bw))
        if ImGui.SmallButton('compact') then S.mini = true end
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Shrink to the compact meter') end
        drawTabs()
    end
    ImGui.End()
end

-- Docked embedding: the full-view tabs drawn into the host's current
-- window (no own Begin/End). The host owns geometry and visibility --
-- S.open and the mini mode do not apply here.
function UI.drawDockedBody()
    UI.markDrawn()
    local nc, nv = Theme.push()
    drawTabs()
    Theme.pop(nc, nv)
end

function UI.toggleMini() S.mini = not S.mini end
function UI.setMini(v) S.mini = v and true or false end

function UI.render()
    if not S.open then return end
    UI.markDrawn()
    local nc, nv = Theme.push()
    if S.mini then drawMini() else drawFull() end
    Theme.pop(nc, nv)
end

return UI
