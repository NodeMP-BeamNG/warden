-- The fake game for the client-file tests: a recording ui_imgui, the client
-- `node` table (on / emitServer recorded), jsonEncode/jsonDecode (tools/lib
-- json), log, settings, ffi (for the text buffers). game.load() runs
-- resources/warden/client/warden/*.lua the way the client mod does: each file
-- compiled in one shared environment with a `require` that resolves
-- "warden/bridge" to the sibling file (net/resources.lua: makeRequire).
--
--   local game = require("game")
--   local G = game.load()              -- G.bridge, G.state, G.panel, G.i18n, G.im, G.env
--   game.reply(id, true, data)         -- a wd:reply from the server
--   game.event("players.changed", d)   -- a wd:event
--   game.frames() -> { { id, op, data }, ... }   the wd:req frames sent, decoded
--   G.im.click("Kick") / G.im.click("p2/2")      a button or selectable the next frame consumes
--   G.im.type("##reason", "spam")                text typed into an InputText
--   G.im.pick("##duration", 1)                   a Combo1 choice (0-based)
--   G.im.check("##v", false) / G.im.int("##v", 5) / G.im.float("##v", 0.7)
--   G.im.tab = "Players"                         the tab BeginTabItem says is selected
--   G.im.collapse("Bans") / G.im.expand("Bans")  a CollapsingHeader1 / TreeNode1 closed or open (open by default)
--   G.im.hover("Teleport To")                    IsItemHovered is true for that item (its tooltip is drawn)
--   G.im.frame(dt)                               one onUpdate of bridge + panel, with the balance checks
--   G.im.shown() -> { text, ... }                 every text drawn in the last frame (tooltips included)
--   G.im.buttons() -> { label -> { disabled } }   the buttons of the last frame, keyed "idpath/label" and "label"
--   G.im.headers() -> { label, ... }              the collapsing headers of the last frame (the visible part)
--   G.im.styles                                  PushStyleColor2 calls of the last frame: { { col, vec4 }, ... }

local sep = package.config:sub(1, 1)
local json = require("json")

local M = {}

local CLIENT = table.concat({ WD_ROOT or ".", "resources", "warden", "client", "warden" }, sep)
local FILES = { "bridge", "i18n", "lang", "state", "panel" }

-- the fake imgui ----------------------------------------------------------------

local FLAGS = {
    "WindowFlags_NoCollapse", "WindowFlags_NoTitleBar", "WindowFlags_NoResize", "WindowFlags_AlwaysAutoResize",
    "WindowFlags_NoMove", "WindowFlags_NoSavedSettings", "WindowFlags_NoFocusOnAppearing", "TableFlags_RowBg",
    "TableFlags_BordersInnerV", "TableFlags_ScrollY", "TableFlags_Resizable", "TableColumnFlags_WidthFixed",
    "TableColumnFlags_WidthStretch", "SelectableFlags_SpanAllColumns", "Cond_FirstUseEver", "Cond_Always",
    "TreeNodeFlags_DefaultOpen", "HoveredFlags_AllowWhenDisabled",
}

-- the visible part of a label: "Bob  ·  default (0)###p2" -> "Bob  ·  default (0)", "##reason" -> ""
local function visible(label)
    label = tostring(label)
    local cut = label:find("###", 1, true) or label:find("##", 1, true)
    if cut then return label:sub(1, cut - 1) end
    return label
end

local function make_imgui(game)
    local im = { TabBarFlags_None = 0 }
    for i, name in ipairs(FLAGS) do im[name] = 2 ^ i end
    for i = 1, 12 do im["Key_F" .. i] = 500 + i end
    im.Key_Insert = 520
    im.Key_Escape = 521
    -- every Col_* name is a colour slot; the numbers only have to be distinct
    local colours = {}
    setmetatable(im, { __index = function(_, k)
        if type(k) == "string" and k:sub(1, 4) == "Col_" then
            if colours[k] == nil then
                local n = 0
                for _ in pairs(colours) do n = n + 1 end
                colours[k] = 1000 + n
            end
            return colours[k]
        end
        return nil
    end })

    -- scripted input, consumed by the widget that matches
    local clicks, texts, picks, checks, ints, floats, pressed, hovers = {}, {}, {}, {}, {}, {}, {}, {}
    local closed = {}   -- visible header / tree label -> true when the test collapsed it
    local id_stack = {}
    local depth = { window = 0, table = 0, tabbar = 0, tabitem = 0, disabled = 0, child = 0, tree = 0, indent = 0,
        itemwidth = 0, style = 0, tooltip = 0 }
    local last = { texts = {}, buttons = {}, tabs = {}, headers = {} }
    local last_item = nil   -- the path of the item drawn last, for IsItemHovered

    im.calls = {}
    im.styles = {}
    im.tab = nil

    local function rec(name, ...)
        im.calls[#im.calls + 1] = { name, ... }
    end

    local function path(label)
        if #id_stack == 0 then return label end
        return table.concat(id_stack, "/") .. "/" .. label
    end

    local function consume(bucket, label)
        local p = path(label)
        if bucket[p] ~= nil then
            local v = bucket[p]
            bucket[p] = nil
            return true, v
        end
        if bucket[label] ~= nil then
            local v = bucket[label]
            bucket[label] = nil
            return true, v
        end
        return false
    end

    local function item(label)
        last_item = { path = path(label), label = label }
    end

    function im.click(label) clicks[label] = true end
    function im.type(label, text) texts[label] = text end
    function im.pick(label, idx) picks[label] = idx end
    function im.check(label, v) checks[label] = v end
    function im.int(label, v) ints[label] = v end
    function im.float(label, v) floats[label] = v end
    function im.press(key) pressed[key] = true end
    function im.hover(label) hovers[label] = true end
    function im.collapse(label) closed[label] = true end
    function im.expand(label) closed[label] = nil end
    function im.shown() return last.texts end
    function im.buttons() return last.buttons end
    function im.tabs() return last.tabs end
    function im.headers() return last.headers end
    function im.unconsumed()
        local out = {}
        for label in pairs(clicks) do out[#out + 1] = "click " .. label end
        for label in pairs(texts) do out[#out + 1] = "type " .. label end
        for label in pairs(picks) do out[#out + 1] = "pick " .. label end
        return out
    end

    function im.begin_frame()
        im.calls = {}
        im.styles = {}
        last = { texts = {}, buttons = {}, tabs = {}, headers = {} }
        last_item = nil
    end

    function im.end_frame()
        for k, v in pairs(depth) do
            if v ~= 0 then error("imgui " .. k .. " depth " .. v .. " at the end of the frame") end
        end
        if #id_stack ~= 0 then error("imgui id stack not empty at the end of the frame") end
    end

    local function button(kind, label)
        rec(kind, label)
        item(label)
        local disabled = depth.disabled > 0
        local entry = { disabled = disabled, kind = kind }
        last.buttons[path(label)] = entry
        if last.buttons[label] == nil then last.buttons[label] = entry end
        -- a disabled button swallows the click, as the real one would (the script stays unconsumed)
        if disabled then return false end
        return (consume(clicks, label))
    end

    local function shown(s)
        last.texts[#last.texts + 1] = tostring(s)
    end

    -- types
    im.ImVec2 = function(x, y) return { x = x, y = y } end
    im.ImVec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
    im.BoolPtr = function(v) return { [0] = v == true } end
    im.IntPtr = function(v) return { [0] = v or 0 } end
    im.FloatPtr = function(v) return { [0] = v or 0 } end
    im.ArrayChar = function(len, val) return { fake_buffer = true, len = len, text = val or "" } end
    im.ArrayCharPtrByTbl = function(tbl) return tbl end
    im.GetIO = function() return { DisplaySize = { x = 1920, y = 1080 } } end

    -- windows
    im.SetNextWindowPos = function(...) rec("SetNextWindowPos", ...) end
    im.SetNextWindowSize = function(...) rec("SetNextWindowSize", ...) end
    im.SetNextWindowBgAlpha = function(a) rec("SetNextWindowBgAlpha", a) end
    im.SetWindowFontScale = function(s) rec("SetWindowFontScale", s) end
    im.SetNextItemWidth = function(w) rec("SetNextItemWidth", w) end
    im.PushItemWidth = function(w)
        rec("PushItemWidth", w)
        depth.itemwidth = depth.itemwidth + 1
    end
    im.PopItemWidth = function() depth.itemwidth = depth.itemwidth - 1 end
    im.Begin = function(name, p_open, flags)
        rec("Begin", name, p_open, flags)
        depth.window = depth.window + 1
        return true
    end
    im.End = function()
        rec("End")
        depth.window = depth.window - 1
    end
    im.BeginChild1 = function(id, size, border)
        rec("BeginChild1", id, size, border)
        depth.child = depth.child + 1
        return true
    end
    im.EndChild = function() depth.child = depth.child - 1 end

    -- style
    im.PushStyleColor2 = function(col, vec)
        im.styles[#im.styles + 1] = { col, vec }
        depth.style = depth.style + 1
    end
    im.PopStyleColor = function(n)
        depth.style = depth.style - (n or 1)
        if depth.style < 0 then error("PopStyleColor below zero") end
    end

    -- headers and trees (open unless the test collapsed them)
    im.CollapsingHeader1 = function(label, flags)
        rec("CollapsingHeader1", label, flags)
        item(label)
        local v = visible(label)
        last.headers[#last.headers + 1] = v
        shown(v)
        return closed[v] ~= true
    end
    im.TreeNode1 = function(label)
        rec("TreeNode1", label)
        item(label)
        local v = visible(label)
        shown(v)
        if closed[v] then return false end
        depth.tree = depth.tree + 1
        return true
    end
    im.TreePop = function()
        depth.tree = depth.tree - 1
        if depth.tree < 0 then error("TreePop without TreeNode") end
    end
    im.Indent = function() depth.indent = depth.indent + 1 end
    im.Unindent = function() depth.indent = depth.indent - 1 end

    -- tooltips: only for the item the test hovers
    im.IsItemHovered = function()
        if last_item == nil then return false end
        return hovers[last_item.path] == true or hovers[last_item.label] == true
    end
    im.BeginTooltip = function()
        rec("BeginTooltip")
        depth.tooltip = depth.tooltip + 1
    end
    im.EndTooltip = function() depth.tooltip = depth.tooltip - 1 end
    im.SetTooltip = function(fmt, ...)
        local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        rec("SetTooltip", s)
        shown(s)
    end

    -- tabs
    im.BeginTabBar = function(id, flags)
        rec("BeginTabBar", id, flags)
        depth.tabbar = depth.tabbar + 1
        return true
    end
    im.EndTabBar = function() depth.tabbar = depth.tabbar - 1 end
    im.BeginTabItem = function(label)
        rec("BeginTabItem", label)
        last.tabs[#last.tabs + 1] = label
        if im.tab == nil then im.tab = label end
        if label ~= im.tab then return false end
        depth.tabitem = depth.tabitem + 1
        return true
    end
    im.EndTabItem = function() depth.tabitem = depth.tabitem - 1 end

    -- tables
    im.BeginTable = function(id, cols, flags, size)
        rec("BeginTable", id, cols, flags, size)
        depth.table = depth.table + 1
        return true
    end
    im.EndTable = function() depth.table = depth.table - 1 end
    im.TableSetupScrollFreeze = function(...) rec("TableSetupScrollFreeze", ...) end
    im.TableSetupColumn = function(label, ...) rec("TableSetupColumn", label, ...) end
    im.TableHeadersRow = function() rec("TableHeadersRow") end
    im.TableNextRow = function() rec("TableNextRow") end
    im.TableNextColumn = function() rec("TableNextColumn") end

    -- text
    im.TextUnformatted = function(s) rec("TextUnformatted", s); shown(s) end
    im.Text = function(fmt, ...) local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt; shown(s) end
    im.TextDisabled = im.Text
    im.TextWrapped = im.Text
    im.TextColored = function(_, fmt, ...) im.Text(fmt, ...) end
    im.Separator = function() rec("Separator") end
    im.SameLine = function() rec("SameLine") end
    im.Spacing = function() rec("Spacing") end

    -- ids and disabling
    im.PushID1 = function(id) id_stack[#id_stack + 1] = tostring(id) end
    im.PopID = function()
        if #id_stack == 0 then error("PopID without PushID") end
        id_stack[#id_stack] = nil
    end
    im.BeginDisabled = function(d)
        if d == nil or d then depth.disabled = depth.disabled + 1 end
        rec("BeginDisabled", d)
        -- EndDisabled must know whether this one counted
        id_stack.disabled_marks = id_stack.disabled_marks or {}
        table.insert(id_stack.disabled_marks, d == nil or d)
    end
    im.EndDisabled = function()
        local marks = id_stack.disabled_marks or {}
        local counted = table.remove(marks)
        if counted == nil then error("EndDisabled without BeginDisabled") end
        if counted then depth.disabled = depth.disabled - 1 end
    end

    -- widgets
    im.Button = function(label) return button("Button", label) end
    im.SmallButton = function(label) return button("SmallButton", label) end
    im.Selectable1 = function(label, selected, flags)
        rec("Selectable1", label, selected, flags)
        item(label)
        return (consume(clicks, label))
    end
    im.InputText = function(label, buf, size, flags)
        rec("InputText", label, size, flags)
        item(label)
        local hit, v = consume(texts, label)
        if hit then
            if #v > (size or #v) then error("typed text longer than the buffer for " .. label) end
            buf.text = v
        end
        return hit
    end
    im.Combo1 = function(label, ptr, list, n)
        rec("Combo1", label, list, n)
        item(label)
        local hit, v = consume(picks, label)
        if hit then
            if v < 0 or v >= n then error("combo index " .. v .. " out of range for " .. label) end
            ptr[0] = v
        end
        return hit
    end
    im.Checkbox = function(label, ptr)
        rec("Checkbox", label)
        item(label)
        local hit, v = consume(checks, label)
        if hit then ptr[0] = v end
        return hit
    end
    im.InputInt = function(label, ptr, ...)
        rec("InputInt", label, ...)
        item(label)
        local hit, v = consume(ints, label)
        if hit then ptr[0] = v end
        return hit
    end
    im.InputFloat = function(label, ptr, ...)
        rec("InputFloat", label, ...)
        item(label)
        local hit, v = consume(floats, label)
        if hit then ptr[0] = v end
        return hit
    end
    -- the game feeds keys to imgui; the panel does not read them any more (0.2.0), the
    -- fake keeps the call so a test can prove nothing listens
    im.IsKeyPressed = function(key)
        rec("IsKeyPressed", key)
        if pressed[key] then
            pressed[key] = nil
            return true
        end
        return false
    end

    -- one frame: bridge then panel, as the game's hook order would (registration order)
    function im.frame(dt)
        dt = dt or 0.016
        im.begin_frame()
        local before = #game.logs
        game.G.bridge.onUpdate(dt)
        game.G.panel.onUpdate(dt)
        -- a drawing error is caught by the panel and logged: the test must see it first
        for i = before + 1, #game.logs do
            local l = game.logs[i]
            if l.level == "E" and l.tag == "warden" and l.msg:find("panel draw failed") then error(l.msg) end
        end
        im.end_frame()
    end

    return im
end

-- the game --------------------------------------------------------------------------

function M.reset()
    M.sent = {}
    M.logs = {}
    M.handlers = {}
end

local function make_env()
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.jsonEncode = function(v) return json.encode(v) end
    env.jsonDecode = function(s) return json.decode(s) end
    env.log = function(level, tag, msg) M.logs[#M.logs + 1] = { level = level, tag = tag, msg = tostring(msg) } end
    env.settings = { getValue = function(k) if k == "uiLanguage" then return "ru-RU" end end }
    env.ffi = {
        string = function(buf) return buf.text or "" end,
        copy = function(buf, s) buf.text = s end,
    }
    env.node = {
        on = function(name, fn) M.handlers[name] = fn end,
        emitServer = function(name, data) M.sent[#M.sent + 1] = { event = name, data = data } end,
        log = function(msg) M.logs[#M.logs + 1] = { level = "I", tag = "node", msg = tostring(msg) } end,
    }
    env.ui_imgui = make_imgui(M)
    return env
end

-- loads client/warden/*.lua into one environment with the client mod's require
function M.load()
    M.reset()
    local env = make_env()
    local modules = {}
    local loaded = {}
    local function res_require(name)
        local key = tostring(name):gsub("%.lua$", "")
        if loaded[key] ~= nil then return loaded[key] end
        local fn = modules[key]
        if fn == nil then return require(name) end
        local result = fn()
        if result == nil then result = true end
        loaded[key] = result
        return result
    end
    env.require = res_require
    for _, name in ipairs(FILES) do
        local p = CLIENT .. sep .. name .. ".lua"
        local fn, err = loadfile(p, "t", env)
        if not fn then error(err) end
        modules["warden/" .. name] = fn
    end
    local G = {}
    for _, name in ipairs(FILES) do G[name] = res_require("warden/" .. name) end
    G.env = env
    G.im = env.ui_imgui
    M.G = G
    return G
end

-- a wire event from the server into the loaded bridge
local function deliver(name, data)
    local fn = M.handlers[name]
    if fn == nil then error("no handler for " .. name) end
    fn(type(data) == "table" and json.encode(data) or data)
end

function M.reply(id, ok, payload)
    local msg = { id = id, ok = ok }
    if ok then msg.data = payload else msg.error = payload end
    deliver("wd:reply", msg)
end

function M.event(ev, data)
    deliver("wd:event", { ev = ev, data = data })
end

function M.frames()
    local out = {}
    for _, s in ipairs(M.sent) do
        if s.event == "wd:req" then
            local f = json.decode(s.data)
            out[#out + 1] = f
        end
    end
    return out
end

function M.last_frame(op)
    local frames = M.frames()
    for i = #frames, 1, -1 do
        if op == nil or frames[i].op == op then return frames[i] end
    end
    return nil
end

-- answers the pending hello (the last sys.hello frame) with a record
function M.session(record)
    local f = M.last_frame("sys.hello")
    if f == nil then error("no sys.hello was sent") end
    M.reply(f.id, true, record)
end

M.reset()

return M
