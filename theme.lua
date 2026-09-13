-- companion/theme.lua
-- Visual identity for the Companion overlay. Palette + typography roles are
-- lifted 1:1 from the EQ Legends Companion web app (jmoyers.github.io) so the
-- in-game ImGui port reads as the same tool.
--
-- Exposes:
--   Theme.C[name]            -> {r,g,b} floats 0..1
--   Theme.rgba(name[, a])    -> r,g,b,a  (for PushStyleColor / TextColored)
--   Theme.vec(name[, a])     -> ImVec4   (for APIs that want a vector)
--   Theme.u32(name[, a])     -> packed ABGR uint32 (for DrawList)
--   Theme.push() / pop(n,v)  -> apply/remove the ImGui style for a window
--   Theme.drawlist(dl)       -> crash-safe DrawList proxy (raw-coord fallback)

local ImGui = require('ImGui')

local Theme = {}

-- ── palette ───────────────────────────────────────────────────────────
local HEX = {
    bg       = '#0f1017', bg2      = '#12141c', panel    = '#171a21', panel2   = '#1b1f28',
    line     = '#262a35', lineSoft = '#1e222c',
    fg       = '#e7e9ef', fgDim    = '#a4abbb', fgFaint  = '#7c8493',
    gold     = '#d9b25f', goldDim  = '#8a713a', green    = '#5fe08a',
    you      = '#d9b25f', pet      = '#6fb3d2', enemy    = '#cf6679',
    melee    = '#d9b25f', slay     = '#f6f0da', spell    = '#a98fe0', dot = '#6fb3d2', ds = '#cf6679',
    resist   = '#e05663',
    eqBorder = '#8a6f24', eqName   = '#5fe08a', eqEffect = '#f08ae0', eqRatio = '#ff8079', eqLabel = '#a8b0c6',
    black    = '#000000', white    = '#ffffff',
}

local function hexToRgb(h)
    return tonumber(h:sub(2, 3), 16) / 255,
        tonumber(h:sub(4, 5), 16) / 255,
        tonumber(h:sub(6, 7), 16) / 255
end

Theme.C = {}
for name, h in pairs(HEX) do
    local r, g, b = hexToRgb(h)
    Theme.C[name] = { r, g, b }
end

-- Category color for a normalized damage kind.
Theme.KIND = { melee = 'melee', nuke = 'spell', spell = 'spell', dot = 'dot', ds = 'ds', heal = 'green' }
function Theme.kindColor(kind) return Theme.KIND[kind] or 'fgDim' end

---@param name string
---@param a? number
---@return number, number, number, number
function Theme.rgba(name, a)
    local c = Theme.C[name] or Theme.C.fg
    return c[1], c[2], c[3], a or 1.0
end

---@return any ImVec4 (falls back to a {r,g,b,a} table if ImVec4 is unavailable)
function Theme.vec(name, a)
    local r, g, b, aa = Theme.rgba(name, a)
    local ok, v = pcall(function() return ImVec4(r, g, b, aa) end)
    if ok then return v end
    return { r, g, b, aa }
end

-- Pack to the ABGR uint32 DrawList expects (R in the low byte -> 0xAABBGGRR).
---@return integer
function Theme.u32(name, a)
    local r, g, b, aa = Theme.rgba(name, a)
    return math.floor(r * 255 + 0.5)
        + math.floor(g * 255 + 0.5) * 0x100
        + math.floor(b * 255 + 0.5) * 0x10000
        + math.floor(aa * 255 + 0.5) * 0x1000000
end

-- ── window style ──────────────────────────────────────────────────────
-- Push a curated dark style so every Companion window is consistent. Returns
-- the (colorCount, varCount) to hand back to Theme.pop().
function Theme.push()
    local col = {
        { ImGuiCol.WindowBg,        'bg' },
        { ImGuiCol.ChildBg,         'panel' },
        { ImGuiCol.PopupBg,         'bg2' },
        { ImGuiCol.Border,          'line' },
        { ImGuiCol.Text,            'fg' },
        { ImGuiCol.TextDisabled,    'fgFaint' },
        { ImGuiCol.FrameBg,         'bg2' },
        { ImGuiCol.FrameBgHovered,  'panel2' },
        { ImGuiCol.FrameBgActive,   'panel2' },
        { ImGuiCol.Button,          'panel2' },
        { ImGuiCol.ButtonHovered,   'line' },
        { ImGuiCol.ButtonActive,    'goldDim' },
        { ImGuiCol.Header,          'panel2' },
        { ImGuiCol.HeaderHovered,   'line' },
        { ImGuiCol.HeaderActive,    'line' },
        { ImGuiCol.Separator,       'lineSoft' },
        { ImGuiCol.Tab,             'bg2' },
        { ImGuiCol.TabHovered,      'panel2' },
        { ImGuiCol.TabActive,       'panel' },
        { ImGuiCol.TabUnfocused,    'bg2' },
        { ImGuiCol.TabUnfocusedActive, 'panel' },
        { ImGuiCol.TitleBg,         'bg2' },
        { ImGuiCol.TitleBgActive,   'panel2' },
        { ImGuiCol.TitleBgCollapsed, 'bg' },
        { ImGuiCol.ScrollbarBg,     'bg' },
        { ImGuiCol.TableHeaderBg,   'bg2' },
        { ImGuiCol.TableBorderLight, 'lineSoft' },
        { ImGuiCol.TableBorderStrong, 'line' },
        { ImGuiCol.TableRowBg,      'panel' },
        { ImGuiCol.TableRowBgAlt,   'panel2' },
        { ImGuiCol.PlotLines,       'gold' },
        { ImGuiCol.PlotHistogram,   'gold' },
    }
    local nCol = 0
    for _, c in ipairs(col) do
        if c[1] ~= nil then
            ImGui.PushStyleColor(c[1], Theme.rgba(c[2]))
            nCol = nCol + 1
        end
    end

    local nVar = 0
    local function var1(idx, v) if idx ~= nil then ImGui.PushStyleVar(idx, v); nVar = nVar + 1 end end
    local function var2(idx, x, y) if idx ~= nil then ImGui.PushStyleVar(idx, x, y); nVar = nVar + 1 end end
    var1(ImGuiStyleVar.WindowRounding, 6)
    var1(ImGuiStyleVar.ChildRounding, 10)
    var1(ImGuiStyleVar.FrameRounding, 6)
    var1(ImGuiStyleVar.TabRounding, 6)
    var1(ImGuiStyleVar.GrabRounding, 4)
    var1(ImGuiStyleVar.ScrollbarRounding, 6)
    var1(ImGuiStyleVar.PopupRounding, 6)
    var1(ImGuiStyleVar.WindowBorderSize, 1)
    var1(ImGuiStyleVar.ChildBorderSize, 1)
    var2(ImGuiStyleVar.WindowPadding, 12, 12)
    var2(ImGuiStyleVar.FramePadding, 8, 4)
    var2(ImGuiStyleVar.ItemSpacing, 8, 7)
    var2(ImGuiStyleVar.CellPadding, 8, 5)

    return nCol, nVar
end

function Theme.pop(nCol, nVar)
    if nVar and nVar > 0 then ImGui.PopStyleVar(nVar) end
    if nCol and nCol > 0 then ImGui.PopStyleColor(nCol) end
end

-- ── crash-safe DrawList ───────────────────────────────────────────────
-- MQ's ImDrawList methods take ImVec2 parameters (see
-- mq-imgui-definitions/datatypes/_ImDrawList.lua), but on some builds ImVec2()
-- returns a Lua table that crashes them (group/DRAWLIST_NOTES.md). Detect the
-- working call form on first use — ImVec2 first, raw coordinates as fallback —
-- cache it, and wrap every call in pcall.
local Safe = {}
Safe.__index = Safe

local drawMode = nil -- nil = undetected, 'vec' | 'raw'

-- Run the working call form; detect and lock it in on first success.
local function attempt(vecFn, rawFn)
    if drawMode == 'raw' then pcall(rawFn) return end
    if pcall(vecFn) then drawMode = 'vec' return end
    if pcall(rawFn) then drawMode = 'raw' end
end

function Theme.drawlist(dl)
    if not dl then return nil end
    return setmetatable({ _dl = dl }, Safe)
end

function Safe:rect(x1, y1, x2, y2, col, rounding, thickness)
    local dl = self._dl
    attempt(
        function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding or 0, 0, thickness or 1) end,
        function() dl:AddRect(x1, y1, x2, y2, col, rounding or 0, 0, thickness or 1) end)
end

function Safe:rectFilled(x1, y1, x2, y2, col, rounding)
    local dl = self._dl
    attempt(
        function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding or 0) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col, rounding or 0) end)
end

function Safe:line(x1, y1, x2, y2, col, thickness)
    local dl = self._dl
    attempt(
        function() dl:AddLine(ImVec2(x1, y1), ImVec2(x2, y2), col, thickness or 1) end,
        function() dl:AddLine(x1, y1, x2, y2, col, thickness or 1) end)
end

function Safe:text(x, y, col, str)
    local dl = self._dl
    attempt(
        function() dl:AddText(ImVec2(x, y), col, str) end,
        function() dl:AddText(x, y, col, str) end)
end

function Safe:circleFilled(cx, cy, r, col, seg)
    local dl = self._dl
    attempt(
        function() dl:AddCircleFilled(ImVec2(cx, cy), r, col, seg or 12) end,
        function() dl:AddCircleFilled(cx, cy, r, col, seg or 12) end)
end

return Theme
