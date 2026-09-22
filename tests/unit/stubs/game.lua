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
--   G.im.press(G.im.Key_F9)                      a key IsKeyPressed reports once
--   G.im.frame(dt)                               one onUpdate of bridge + panel, with the balance checks
--   G.im.shown() -> { text, ... }                 every text drawn in the last frame
--   G.im.buttons() -> { label -> { disabled } }   the buttons of the last frame, keyed "idpath/label" and "label"

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
}

local function make_imgui(game)
    local im = { TabBarFlags_None = 0 }
    for i, name in ipairs(FLAGS) do im[name] = 2 ^ i end
    for i = 1, 12 do im["Key_F" .. i] = 500 + i end
    im.Key_Insert = 520
    im.Key_Escape = 521

    -- scripted input, consumed by the widget that matches
    local clicks, texts, picks, checks, ints, floats, pressed = {}, {}, {}, {}, {}, {}, {}
    local id_stack = {}
    local depth = { window = 0, table = 0, tabbar = 0, tabitem = 0, disabled = 0 }
    local last = { texts = {}, buttons = {}, tabs = {} }

    im.calls = {}
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

    function im.click(label) clicks[label] = true end
    function im.type(label, text) texts[label] = text end
    function im.pick(label, idx) picks[label] = idx end
    function im.check(label, v) checks[label] = v end
    function im.int(label, v) ints[label] = v end
    function im.float(label, v) floats[label] = v end
    function im.press(key) pressed[key] = true end
    function im.shown() return last.texts end
    function im.buttons() return last.buttons end
    function im.tabs() return last.tabs end
    function im.unconsumed()
        local out = {}
        for label in pairs(clicks) do out[#out + 1] = "click " .. label end
        for label in pairs(texts) do out[#out + 1] = "type " .. label end
        for label in pairs(picks) do out[#out + 1] = "pick " .. label end
        return out
    end

    function im.begin_frame()
        im.calls = {}
        last = { texts = {}, buttons = {}, tabs = {} }
    end

    function im.end_frame()
        for k, v in pairs(depth) do
            if v ~= 0 then error("imgui " .. k .. " depth " .. v .. " at the end of the frame") end
        end
        if #id_stack ~= 0 then error("imgui id stack not empty at the end of the frame") end
    end

    local function button(kind, label)
        rec(kind, label)
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
    im.SetNextItemWidth = function(w) rec("SetNextItemWidth", w) end
    im.Begin = function(name, p_open, flags)
        rec("Begin", name, p_open, flags)
        depth.window = depth.window + 1
        return true
    end
    im.End = function()
        rec("End")
        depth.window = depth.window - 1
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
        return (consume(clicks, label))
    end
    im.InputText = function(label, buf, size, flags)
        rec("InputText", label, size, flags)
        local hit, v = consume(texts, label)
        if hit then
            if #v > (size or #v) then error("typed text longer than the buffer for " .. label) end
            buf.text = v
        end
        return hit
    end
    im.Combo1 = function(label, ptr, list, n)
        rec("Combo1", label, list, n)
        local hit, v = consume(picks, label)
        if hit then
            if v < 0 or v >= n then error("combo index " .. v .. " out of range for " .. label) end
            ptr[0] = v
        end
        return hit
    end
    im.Checkbox = function(label, ptr)
        rec("Checkbox", label)
        local hit, v = consume(checks, label)
        if hit then ptr[0] = v end
        return hit
    end
    im.InputInt = function(label, ptr, ...)
        rec("InputInt", label, ...)
        local hit, v = consume(ints, label)
        if hit then ptr[0] = v end
        return hit
    end
    im.InputFloat = function(label, ptr, ...)
        rec("InputFloat", label, ...)
        local hit, v = consume(floats, label)
        if hit then ptr[0] = v end
        return hit
    end
    im.IsKeyPressed = function(key)
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
