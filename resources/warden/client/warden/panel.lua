-- warden/panel: the admin panel, drawn with the game's Dear ImGui binding
-- (ui_imgui) every frame the window is open, and the vote banner.
--
-- The control model and the window structure follow the CobaltEssentials
-- Interface (CEI), reproduced from its behaviour: one window with a QuickInfo
-- bar (server, counts, status chips), the UI scale with its Reset, then the
-- tabs Players / Config / Environment / Database; under Players a collapsing
-- header per player with a row of small buttons, the reason and duration
-- fields, and the vehicles / info / permissions tree nodes; the window is
-- shown by default and every player's choice (shown, scale) is kept by the
-- server (ui.get / ui.set). There is no fixed key: the chat command /warden
-- (or /wd), the bindable game action "Toggle Warden panel" (Options >
-- Controls > Warden, shipped as content/warden.zip; it calls the global
-- nodemp_wd.toggle()) and the console toggle the window.
--
-- The client mod registers this table as a game extension because it has
-- onUpdate (net/resources.lua: a streamed ge file returning on* functions ->
-- newExtensionProxy), so onUpdate(dt) runs each frame. Everything the panel
-- shows comes from warden/state; every button is one wd:req the server judges.
--
--   panel.toggle() / open(silent) / close(silent) / isOpen()   also the global nodemp_wd (the action, the console)
--   panel.draw()                                                one frame (the tests call it with a fake ui_imgui)
--   panel.register_category()                                   the "Warden" input category, for the Controls screen
--
-- Lua 5.1 semantics (LuaJIT): text buffers are im.ArrayChar, read with
-- ffi.string and written with ffi.copy, the way the game's own tools do.

local bridge = require("warden/bridge")
local i18n = require("warden/i18n")
local state = require("warden/state")

local M = {}

M.WINDOW = "Warden"
M.SIZE = { w = 940, h = 620 }
M.BANNER_Y = 40
M.RESULT_TTL_S = 6
M.CONFIRM_S = 5
M.MAX_DRAW_ERRORS = 5
M.BUF_TEXT = 200
M.BUF_SHORT = 32
M.BUF_LONG = 512
M.SCALE_SEND_DELAY_S = 0.5
M.BG_ALPHA = 0.67
M.ACTION = "toggleWarden"
M.CATEGORY = { id = "warden", order = 9998, icon = "security", title = "Warden", desc = "Warden admin panel" }

-- the translucent blue style ("cobalt"): our own palette, pushed around the
-- window; skipped entirely with the "game" theme
M.THEME = {
    { "Col_WindowBg", 0.03, 0.04, 0.12, 1.00 }, { "Col_ChildBg", 0.05, 0.07, 0.25, 0.35 },
    { "Col_Border", 0.30, 0.40, 0.95, 0.55 },
    { "Col_TitleBg", 0.10, 0.14, 0.55, 0.75 }, { "Col_TitleBgActive", 0.12, 0.18, 0.70, 0.90 },
    { "Col_TitleBgCollapsed", 0.05, 0.07, 0.35, 0.60 },
    { "Col_Tab", 0.20, 0.28, 0.80, 0.60 }, { "Col_TabHovered", 0.35, 0.45, 0.95, 0.80 },
    { "Col_TabActive", 0.25, 0.35, 0.95, 0.90 }, { "Col_TabUnfocused", 0.12, 0.16, 0.45, 0.50 },
    { "Col_TabUnfocusedActive", 0.18, 0.24, 0.62, 0.70 },
    { "Col_FrameBg", 0.08, 0.10, 0.40, 0.55 }, { "Col_FrameBgHovered", 0.12, 0.16, 0.55, 0.65 },
    { "Col_FrameBgActive", 0.06, 0.08, 0.30, 0.75 },
    { "Col_Header", 0.18, 0.24, 0.62, 0.55 }, { "Col_HeaderHovered", 0.26, 0.34, 0.78, 0.70 },
    { "Col_HeaderActive", 0.30, 0.40, 0.90, 0.80 },
    { "Col_Button", 0.16, 0.22, 0.72, 0.45 }, { "Col_ButtonHovered", 0.20, 0.28, 0.85, 0.65 },
    { "Col_ButtonActive", 0.10, 0.14, 0.60, 0.95 },
    { "Col_Separator", 0.55, 0.62, 0.95, 0.70 },
    { "Col_SliderGrab", 0.45, 0.55, 1.00, 0.95 }, { "Col_SliderGrabActive", 0.65, 0.75, 1.00, 1.00 },
    { "Col_CheckMark", 0.75, 0.85, 1.00, 1.00 },
    { "Col_ResizeGrip", 0.20, 0.28, 0.80, 0.40 }, { "Col_ResizeGripHovered", 0.30, 0.40, 0.90, 0.60 },
    { "Col_ResizeGripActive", 0.35, 0.45, 1.00, 0.80 },
    { "Col_TableHeaderBg", 0.12, 0.16, 0.50, 0.70 }, { "Col_TableBorderStrong", 0.30, 0.38, 0.80, 0.60 },
    { "Col_TableBorderLight", 0.22, 0.28, 0.60, 0.40 },
}

-- the header colour of a player by group tier (guest, default, trusted, mod, admin, owner)
M.TIERS = {
    { min = 100, r = 0.55, g = 0.08, b = 0.10 }, { min = 90, r = 0.80, g = 0.30, b = 0.05 },
    { min = 50, r = 0.75, g = 0.55, b = 0.05 }, { min = 10, r = 0.10, g = 0.50, b = 0.45 },
    { min = 0, r = 0.18, g = 0.24, b = 0.62 },
}
M.GUEST_TIER = { r = 0.30, g = 0.30, b = 0.34 }

local im = nil
local ffi = nil
local S = state.S

local open = nil            -- im.BoolPtr, the window's close box writes it
local ui = {
    tab = nil, rows = {}, lang_idx = nil, audit_n = nil, scale_ptr = nil, scale_dirty_at = nil,
    settings_edit = {}, draw_errors = 0, want_players = false, announce = nil, wl_add = nil, gedit = nil,
    confirm = {}, category = false, drawn_open = false,
}
local wanted = false        -- a toggle before the session record: open once hello answers

local function t(code, params)
    return i18n.t(code, params)
end

-- imgui helpers ---------------------------------------------------------------

local function gui()
    if im ~= nil then return im end
    local g = rawget(_G, "ui_imgui")
    if type(g) ~= "table" then return nil end
    im = g
    return im
end

local function get_ffi()
    if ffi ~= nil then return ffi end
    local f = rawget(_G, "ffi")
    if f == nil then
        local ok, mod = pcall(require, "ffi")
        if ok then f = mod end
    end
    ffi = f or false
    return ffi
end

local function buf_new(len, text)
    return im.ArrayChar(len, text or "")
end

local function buf_read(buf)
    local f = get_ffi()
    if f and type(f.string) == "function" then
        local ok, s = pcall(f.string, buf)
        if ok and type(s) == "string" then return s end
    end
    return tostring(buf)
end

local function buf_set(buf, text)
    local f = get_ffi()
    if f and type(f.copy) == "function" then pcall(f.copy, buf, tostring(text or "")) end
end

local function text(s)
    im.TextUnformatted(tostring(s == nil and "" or s))
end

local function text_dim(s)
    im.TextDisabled("%s", tostring(s == nil and "" or s))
end

local function text_col(r, g, b, s)
    im.TextColored(im.ImVec4(r, g, b, 1), "%s", tostring(s == nil and "" or s))
end

local function flags(...)
    local sum = 0
    for _, f in ipairs({ ... }) do sum = sum + (tonumber(f) or 0) end
    return sum
end

local function items(list)
    return im.ArrayCharPtrByTbl(list)
end

local function count(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

local function scale()
    return tonumber(S.ui.scale) or 1
end

local function font_scale()
    if type(im.SetWindowFontScale) == "function" then im.SetWindowFontScale(scale()) end
end

-- a tooltip on the item just drawn, disabled items included
local function tooltip(s)
    if type(im.IsItemHovered) ~= "function" then return end
    if not im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled or 0) then return end
    if type(im.BeginTooltip) == "function" and type(im.EndTooltip) == "function" then
        im.BeginTooltip()
        im.TextUnformatted(tostring(s))
        im.EndTooltip()
    elseif type(im.SetTooltip) == "function" then
        im.SetTooltip("%s", tostring(s))
    end
end

local function result_line(id)
    local r = state.result(id)
    if r == nil then return false end
    if r.ok == true and bridge.now() - r.at > M.RESULT_TTL_S then
        state.clear_result(id)
        return false
    end
    if r.ok == true then
        text_col(0.5, 0.9, 0.5, r.text)
    elseif r.ok == false then
        text_col(1, 0.45, 0.45, r.text)
    else
        text_dim(r.text)
    end
    return true
end

local function cell(s)
    im.TableNextColumn()
    text(s)
end

-- a button the platform has no call for yet: greyed, the tooltip names the issue
local function gap_button(label, gap, small)
    im.BeginDisabled(true)
    if small then im.SmallButton(label) else im.Button(label) end
    im.EndDisabled()
    tooltip(t(gap.label, { issue = gap.issue }))
end

-- the theme -------------------------------------------------------------------

local function push_theme()
    if S.ui.theme ~= "cobalt" or type(im.PushStyleColor2) ~= "function" then return 0 end
    local n = 0
    for _, e in ipairs(M.THEME) do
        local col = im[e[1]]
        if col ~= nil then
            im.PushStyleColor2(col, im.ImVec4(e[2], e[3], e[4], e[5]))
            n = n + 1
        end
    end
    if type(im.SetNextWindowBgAlpha) == "function" then im.SetNextWindowBgAlpha(M.BG_ALPHA) end
    return n
end

local function pop_theme(n)
    if n > 0 then im.PopStyleColor(n) end
end

local function tier_of(row)
    if row.guest then return M.GUEST_TIER end
    local level = tonumber(row.level) or 0
    for _, tier in ipairs(M.TIERS) do
        if level >= tier.min then return tier end
    end
    return M.TIERS[#M.TIERS]
end

local function push_header_tier(row)
    if type(im.PushStyleColor2) ~= "function" or im.Col_Header == nil then return 0 end
    local c = tier_of(row)
    im.PushStyleColor2(im.Col_Header, im.ImVec4(c.r, c.g, c.b, 0.55))
    im.PushStyleColor2(im.Col_HeaderHovered, im.ImVec4(c.r + 0.1, c.g + 0.1, c.b + 0.1, 0.70))
    im.PushStyleColor2(im.Col_HeaderActive, im.ImVec4(c.r + 0.15, c.g + 0.15, c.b + 0.15, 0.80))
    return 3
end

-- the input category (Options > Controls > Warden) -----------------------------

-- The action itself is a JSON file the game reads from disk (content/warden.zip,
-- lua/ge/extensions/core/input/actions/warden.json); its category is a plain
-- table entry, so the streamed code adds it at runtime, as the zip's modScript
-- does at game start. Idempotent; false when the game's input module is absent.
function M.register_category()
    local cats = rawget(_G, "core_input_categories")
    if type(cats) ~= "table" then
        local ext = rawget(_G, "extensions")
        if type(ext) == "table" then
            if type(ext.load) == "function" then pcall(ext.load, "core_input_categories") end
            cats = rawget(_G, "core_input_categories")
            if type(cats) ~= "table" and type(rawget(ext, "core_input_categories")) == "table" then
                cats = ext.core_input_categories
            end
        end
    end
    if type(cats) ~= "table" then return false end
    if type(cats[M.CATEGORY.id]) ~= "table" then
        cats[M.CATEGORY.id] = {
            order = M.CATEGORY.order, icon = M.CATEGORY.icon, title = M.CATEGORY.title, desc = M.CATEGORY.desc,
        }
    end
    ui.category = true
    return true
end

-- open / close ----------------------------------------------------------------

function M.isOpen()
    return open ~= nil and open[0] == true
end

local function ensure_ptrs()
    if open == nil then open = im.BoolPtr(false) end
    if ui.audit_n == nil then ui.audit_n = im.IntPtr(state.AUDIT_DEFAULT) end
    if ui.scale_ptr == nil then ui.scale_ptr = im.FloatPtr(scale()) end
end

-- silent: the server's own state (the hello record) opens the window; a
-- player's action is told to the server (ui.set { shown }) so it is remembered
function M.open(silent)
    if not gui() then return false end
    if bridge.getState().session == nil then
        wanted = true
        return false
    end
    ensure_ptrs()
    if open[0] then return false end
    open[0] = true
    ui.want_players = true
    if not silent then state.set_ui({ shown = true }) end
    return true
end

function M.close(silent)
    if open == nil or not open[0] then return false end
    open[0] = false
    ui.drawn_open = false
    ui.confirm = {}
    if not silent then state.set_ui({ shown = false }) end
    return true
end

function M.toggle()
    if M.isOpen() then return M.close() end
    return M.open()
end

-- the players tab -------------------------------------------------------------

local function new_row_state()
    return {
        reason = buf_new(M.BUF_TEXT), custom = buf_new(M.BUF_SHORT), dur_idx = im.IntPtr(0),
        group_idx = im.IntPtr(0), expanded = false,
    }
end

local function row_state(pid)
    local r = ui.rows[pid]
    if r == nil then
        r = new_row_state()
        ui.rows[pid] = r
    end
    return r
end

local function duration_labels()
    local out = {}
    for i, d in ipairs(state.DURATIONS) do out[i] = d.sec and d.label or t(d.label) end
    return out
end

-- the fields of a row action, read from the row's own inputs
local function row_fields(rs)
    local fields = { reason = buf_read(rs.reason) }
    local d = state.DURATIONS[rs.dur_idx[0] + 1]
    if d and d.sec then
        fields.duration = tostring(d.sec) .. "s"
    else
        fields.duration = buf_read(rs.custom)
    end
    return fields
end

-- a click on a confirm action arms it; the second click within CONFIRM_S runs it
local function confirmed(rid)
    local at = ui.confirm[rid]
    if at ~= nil and bridge.now() - at <= M.CONFIRM_S then
        ui.confirm[rid] = nil
        return true
    end
    ui.confirm[rid] = bridge.now()
    return false
end

local function confirm_armed(rid)
    local at = ui.confirm[rid]
    if at == nil then return false end
    if bridge.now() - at > M.CONFIRM_S then
        ui.confirm[rid] = nil
        return false
    end
    return true
end

local function action_button(row, rs, action)
    local allowed = state.can_target(row, action)
    local rid = state.result_id(action, row)
    local label = t(action.label)
    if action.confirm and confirm_armed(rid) then label = t("ui.confirm", { label = label }) end
    im.BeginDisabled(not allowed or state.is_busy(action.op))
    if im.SmallButton(label) then
        if not action.confirm or confirmed(rid) then
            state.run(action, row, row_fields(rs))
        end
    end
    im.EndDisabled()
end

local function focus_button(row)
    local rid = "focus:" .. tostring(row.pid)
    local available = state.focus_available()
    local strict = state.strict_active()
    local vehicles = tonumber(row.vehicles) or 0
    im.BeginDisabled(not available or strict or vehicles == 0)
    if im.SmallButton(t("ui.action.focus")) then
        local ok, why = state.focus(row.pid)
        if ok then
            state.note_result(rid, true, t("ui.focus.done", { name = row.name or "" }))
        else
            state.note_result(rid, false, t("ui.focus." .. tostring(why)))
        end
    end
    im.EndDisabled()
    if strict then
        tooltip(t("ui.focus.strict"))
    elseif not available then
        tooltip(t("ui.focus.no_game"))
    else
        tooltip(t("ui.focus.hint"))
    end
end

local function draw_action_row(row, rs)
    local first = true
    for _, action in ipairs(state.ACTIONS) do
        if action.id ~= "group" and action.id ~= "cars" and state.action_visible(row, action) then
            if not first then im.SameLine() end
            first = false
            action_button(row, rs, action)
        end
    end
    im.SameLine()
    focus_button(row)
    im.SameLine()
    gap_button(t("ui.action.teleport_to"), state.GAPS.teleport, true)
    im.SameLine()
    gap_button(t("ui.action.teleport_from"), state.GAPS.teleport, true)
end

local function draw_row_fields(rs)
    text_dim(t("ui.field.reason"))
    im.SameLine()
    im.PushItemWidth(260 * scale())
    im.InputText("##reason", rs.reason, M.BUF_TEXT)
    im.PopItemWidth()
    im.SameLine()
    text_dim(t("ui.field.duration"))
    im.SameLine()
    im.PushItemWidth(90 * scale())
    im.Combo1("##duration", rs.dur_idx, items(duration_labels()), #state.DURATIONS)
    im.PopItemWidth()
    local d = state.DURATIONS[rs.dur_idx[0] + 1]
    if d and d.sec == nil then
        im.SameLine()
        im.PushItemWidth(80 * scale())
        im.InputText("##custom", rs.custom, M.BUF_SHORT)
        im.PopItemWidth()
        im.SameLine()
        text_dim(t("ui.field.custom_hint"))
    end
end

local function draw_row_results(row)
    for _, action in ipairs(state.ACTIONS) do result_line(state.result_id(action, row)) end
    result_line("focus:" .. tostring(row.pid))
end

local function draw_vehicles_node(row)
    local n = tonumber(row.vehicles) or 0
    local cars = state.action_by_id("cars")
    if im.TreeNode1(t("ui.node.vehicles", { n = n })) then
        local list = state.vehicles_of(row.pid)
        if #list == 0 then
            text_dim(n > 0 and t("ui.vehicles.no_list") or t("ui.vehicles.none"))
        end
        for _, v in ipairs(list) do
            im.PushID1("v" .. tostring(v.vid))
            text(tostring(v.vid) .. ": " .. tostring(v.jbeam))
            im.SameLine()
            im.BeginDisabled(not state.can_target(row, cars) or state.is_busy(cars.op))
            if im.SmallButton(t("ui.vehicles.delete")) then
                state.run(cars, row, { vid = tostring(v.vid) })
            end
            im.EndDisabled()
            im.SameLine()
            gap_button(t("ui.vehicles.freeze"), state.GAPS.freeze, true)
            im.SameLine()
            gap_button(t("ui.vehicles.ignition"), state.GAPS.ignition, true)
            im.PopID()
        end
        if n > 0 then
            im.BeginDisabled(not state.can_target(row, cars) or state.is_busy(cars.op))
            if im.SmallButton(t("ui.action.cars")) then state.run(cars, row, {}) end
            im.EndDisabled()
        end
        im.TreePop()
    end
end

local function draw_info_node(row)
    if not im.TreeNode1(t("ui.node.info")) then return end
    local full = S.details[row.pid]
    local function line(label, value)
        if value == nil or value == "" then return end
        text(t(label) .. ": " .. tostring(value))
    end
    line("ui.col.pid", row.pid)
    line("ui.card.account", row.guest and t("ui.players.guest")
        or ((full and full.account) and tostring(full.account) or (row.verified and t("ui.players.verified") or "-")))
    if full then
        line("ui.card.key", full.key)
        line("ui.card.ip", full.ip)
        line("ui.card.joins", full.joins)
        if full.first_seen then line("ui.card.first_seen", state.format_time(full.first_seen)) end
        line("ui.card.warns", count(full.warns))
        if full.cap then
            line("ui.card.cap", tonumber(full.cap) == -1 and t("ui.card.unlimited") or tostring(full.cap))
        end
        if type(full.mute) == "table" then
            line("ui.card.mute", full.mute["until"] and state.format_time(full.mute["until"]) or t("ui.bans.permanent"))
        end
        if type(full.names) == "table" and #full.names > 1 then
            line("ui.card.names", table.concat(full.names, ", "))
        end
    else
        text_dim(t("ui.players.loading"))
    end
    if row.ping then line("ui.col.ping", string.format("%d ms", math.floor((tonumber(row.ping) or 0) * 1000 + 0.5))) end
    if row.connected then line("ui.col.online", state.format_duration(row.connected)) end
    im.TreePop()
end

local function draw_permissions_node(row, rs)
    if not im.TreeNode1(t("ui.node.permissions")) then return end
    text(t("ui.card.group") .. ": " .. tostring(row.group or "") .. " (" .. tostring(row.level or 0) .. ")")
    local action = state.action_by_id("group")
    if state.can_target(row, action) then
        local groups = state.assignable_groups()
        local labels = {}
        for i, g in ipairs(groups) do labels[i] = g.name .. " (" .. tostring(g.level) .. ")" end
        if #labels == 0 then
            text_dim(t("ui.groups.none_below"))
        else
            if rs.group_idx[0] >= #labels then rs.group_idx[0] = 0 end
            im.PushItemWidth(160 * scale())
            im.Combo1("##group", rs.group_idx, items(labels), #labels)
            im.PopItemWidth()
            im.SameLine()
            im.BeginDisabled(state.is_busy(action.op))
            if im.SmallButton(t("ui.groups.apply")) then
                local g = groups[rs.group_idx[0] + 1]
                state.run(action, row, { group = g and g.name or "" })
            end
            im.SameLine()
            if im.SmallButton(t("ui.groups.remove")) then
                state.run(action, row, { group = S.default_group })
            end
            im.EndDisabled()
            tooltip(t("ui.groups.remove_hint", { group = S.default_group }))
        end
    else
        text_dim(t("ui.groups.cannot"))
    end
    im.TreePop()
end

local function header_label(row)
    local you = (S.me and row.pid == S.me.pid) and (" (" .. t("ui.players.you") .. ")") or ""
    local bits = {
        tostring(row.name or "") .. you, tostring(row.group or "") .. " (" .. tostring(row.level or 0) .. ")",
        t("ui.players.cars", { n = tonumber(row.vehicles) or 0 }),
    }
    if row.guest then bits[#bits + 1] = t("ui.players.guest") end
    if row.muted then bits[#bits + 1] = t("ui.players.muted") end
    if row.whitelisted then bits[#bits + 1] = t("ui.players.whitelisted") end
    return table.concat(bits, "  ·  ") .. "###p" .. tostring(row.pid)
end

local function draw_player(row)
    local rs = row_state(row.pid)
    local pushed = push_header_tier(row)
    local shown = im.CollapsingHeader1(header_label(row))
    pop_theme(pushed)
    if not shown then
        rs.expanded = false
        return
    end
    if not rs.expanded then
        rs.expanded = true
        if state.has("players.view") then state.load_player(row.pid) end
    end
    im.PushID1("p" .. tostring(row.pid))
    im.Indent()
    draw_action_row(row, rs)
    draw_row_fields(rs)
    draw_row_results(row)
    im.Separator()
    draw_vehicles_node(row)
    draw_info_node(row)
    draw_permissions_node(row, rs)
    im.Unindent()
    im.PopID()
end

local function draw_quick_actions()
    local st = S.status
    local first = true
    local function sep()
        if not first then im.SameLine() end
        first = false
    end
    if state.has("settings.write") then
        sep()
        local on = st.spawn ~= false
        im.BeginDisabled(state.is_busy("settings.set"))
        if im.SmallButton(t(on and "ui.quick.spawn_off" or "ui.quick.spawn_on")) then
            state.set_setting("spawn.enabled", not on)
        end
        im.EndDisabled()
        tooltip(t("ui.quick.spawn_hint"))
    end
    if state.has("mod.whitelist") then
        sep()
        local on = st.whitelist == true
        im.BeginDisabled(state.is_busy("whitelist.enable"))
        if im.SmallButton(t(on and "ui.quick.whitelist_off" or "ui.quick.whitelist_on")) then
            state.whitelist_enable(not on)
        end
        im.EndDisabled()
    end
    sep()
    gap_button(t("ui.quick.freeze_all"), state.GAPS.freeze, true)
    im.SameLine()
    gap_button(t("ui.quick.unfreeze_all"), state.GAPS.freeze, true)
    im.SameLine()
    gap_button(t("ui.quick.stop_all"), state.GAPS.ignition, true)
    im.SameLine()
    gap_button(t("ui.quick.start_all"), state.GAPS.ignition, true)
    if state.has("server.announce") then
        if ui.announce == nil then ui.announce = buf_new(M.BUF_TEXT) end
        im.PushItemWidth(320 * scale())
        im.InputText("##announce", ui.announce, M.BUF_TEXT)
        im.PopItemWidth()
        im.SameLine()
        im.BeginDisabled(state.is_busy("server.announce"))
        if im.SmallButton(t("ui.quick.announce")) then
            local msg = buf_read(ui.announce):gsub("^%s+", ""):gsub("%s+$", "")
            if msg ~= "" then
                state.announce(msg, function(ok) if ok then buf_set(ui.announce, "") end end)
            end
        end
        im.EndDisabled()
    end
    result_line("setting:spawn.enabled")
    result_line("whitelist:enable")
    result_line("announce")
end

local function draw_players()
    if ui.want_players then
        ui.want_players = false
        if not S.subscribed then state.load_players() end
    end
    text(t("ui.players.count", { n = #S.players }))
    im.SameLine()
    im.BeginDisabled(state.is_busy("players.list"))
    if im.SmallButton(t("ui.refresh")) then state.load_players() end
    im.EndDisabled()
    im.Separator()
    draw_quick_actions()
    im.Separator()
    im.BeginChild1("wd_players_list", im.ImVec2(0, 0), false)
    font_scale()
    if #S.players == 0 then text_dim(t("ui.players.empty")) end
    local alive = {}
    for _, row in ipairs(S.players) do
        alive[row.pid] = true
        draw_player(row)
    end
    for pid in pairs(ui.rows) do
        if not alive[pid] then ui.rows[pid] = nil end
    end
    im.EndChild()
end

-- the config tab: groups --------------------------------------------------------

local function gedit_new()
    return {
        name = buf_new(M.BUF_SHORT), level = im.IntPtr(0), inherits = buf_new(M.BUF_TEXT), perms = buf_new(M.BUF_LONG),
        cars = im.IntPtr(1), existing = nil,
    }
end

local function gedit_load(g)
    local e = ui.gedit or gedit_new()
    ui.gedit = e
    e.existing = g and g.name or nil
    buf_set(e.name, g and g.name or "")
    e.level[0] = g and (tonumber(g.level) or 0) or 0
    buf_set(e.inherits, g and type(g.inherits) == "table" and table.concat(g.inherits, ", ") or "")
    buf_set(e.perms, g and type(g.perms) == "table" and table.concat(g.perms, " ") or "")
    local cap = g and type(g.caps) == "table" and g.caps.vehicles or nil
    e.cars[0] = cap ~= nil and (tonumber(cap) or 1) or 1
end

local function split_words(s, sep)
    local out = {}
    for w in tostring(s or ""):gmatch("[^" .. sep .. "%s]+") do out[#out + 1] = w end
    return out
end

local function gedit_def()
    local e = ui.gedit
    return {
        name = (buf_read(e.name):gsub("^%s+", ""):gsub("%s+$", "")):lower(), level = e.level[0],
        inherits = split_words(buf_read(e.inherits), ","), perms = split_words(buf_read(e.perms), ","),
        caps = { vehicles = e.cars[0] },
    }
end

local function draw_group_editor()
    local e = ui.gedit
    if e == nil then return end
    im.Separator()
    text(e.existing and t("ui.groups.editing", { name = e.existing }) or t("ui.groups.new"))
    text_dim(t("ui.col.name"))
    im.SameLine()
    im.PushItemWidth(140 * scale())
    im.BeginDisabled(e.existing ~= nil)
    im.InputText("##gname", e.name, M.BUF_SHORT)
    im.EndDisabled()
    im.PopItemWidth()
    im.SameLine()
    text_dim(t("ui.col.level"))
    im.SameLine()
    im.PushItemWidth(100 * scale())
    im.InputInt("##glevel", e.level, 1, 10)
    im.PopItemWidth()
    im.SameLine()
    text_dim(t("ui.col.cars"))
    im.SameLine()
    im.PushItemWidth(100 * scale())
    im.InputInt("##gcars", e.cars, 1, 1)
    im.PopItemWidth()
    text_dim(t("ui.groups.inherits"))
    im.SameLine()
    im.PushItemWidth(300 * scale())
    im.InputText("##ginherits", e.inherits, M.BUF_TEXT)
    im.PopItemWidth()
    text_dim(t("ui.groups.perms"))
    im.SameLine()
    im.PushItemWidth(500 * scale())
    im.InputText("##gperms", e.perms, M.BUF_LONG)
    im.PopItemWidth()
    local def = gedit_def()
    im.BeginDisabled(state.is_busy("groups.save") or def.name == "")
    if im.Button(t("ui.groups.save")) then state.save_group(def) end
    im.EndDisabled()
    im.SameLine()
    if e.existing then
        local g = state.group_by_name(e.existing)
        im.BeginDisabled(state.is_busy("groups.delete") or g == nil or g.name == "default" or g.name == "owner")
        if im.Button(t("ui.groups.delete")) then state.delete_group(e.existing) end
        im.EndDisabled()
        im.SameLine()
    end
    if im.Button(t("ui.form.cancel")) then ui.gedit = nil end
    im.SameLine()
    result_line("group:" .. def.name)
    if e.existing and e.existing ~= def.name then result_line("group:" .. e.existing) end
end

local function draw_groups()
    if S.groups_at == nil and not state.is_busy("groups.list") then state.load_groups() end
    local editable = state.can_edit_group(nil)
    im.BeginDisabled(state.is_busy("groups.list"))
    if im.SmallButton(t("ui.refresh")) then state.load_groups() end
    im.EndDisabled()
    im.SameLine()
    if editable then
        if im.SmallButton(t("ui.groups.new")) then gedit_load(nil) end
    else
        text_dim(t("ui.groups.readonly"))
    end
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_groups", 6, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.col.level"), im.TableColumnFlags_WidthFixed, 50)
        im.TableSetupColumn(t("ui.groups.inherits"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.col.cars"), im.TableColumnFlags_WidthFixed, 50)
        im.TableSetupColumn(t("ui.groups.perms"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn("", im.TableColumnFlags_WidthFixed, 60)
        im.TableHeadersRow()
        for _, g in ipairs(S.groups) do
            im.TableNextRow()
            im.PushID1("g:" .. tostring(g.name))
            cell(g.name)
            cell(tostring(g.level or 0))
            cell(type(g.inherits) == "table" and #g.inherits > 0 and table.concat(g.inherits, ", ") or "-")
            local cap = type(g.caps) == "table" and g.caps.vehicles or nil
            cell(cap == nil and "-" or (tonumber(cap) == -1 and t("ui.card.unlimited") or tostring(cap)))
            im.TableNextColumn()
            im.TextWrapped("%s", type(g.perms) == "table" and #g.perms > 0 and table.concat(g.perms, " ") or "-")
            im.TableNextColumn()
            if state.can_edit_group(g) then
                if im.SmallButton(t("ui.groups.edit")) then gedit_load(g) end
            end
            im.PopID()
        end
        im.EndTable()
    end
    if editable then draw_group_editor() end
end

-- the config tab: whitelist -------------------------------------------------------

local function draw_whitelist(with_toggle)
    local wl = S.whitelist
    if wl.at == nil and not state.is_busy("whitelist.list") then state.load_whitelist() end
    if with_toggle then
        local on = wl.enabled == true
        im.BeginDisabled(state.is_busy("whitelist.enable"))
        if im.SmallButton(t(on and "ui.quick.whitelist_off" or "ui.quick.whitelist_on")) then
            state.whitelist_enable(not on)
        end
        im.EndDisabled()
        im.SameLine()
        text(on and t("ui.whitelist.on") or t("ui.whitelist.off"))
        im.SameLine()
        result_line("whitelist:enable")
    end
    if ui.wl_add == nil then ui.wl_add = buf_new(M.BUF_SHORT * 2) end
    im.PushItemWidth(220 * scale())
    im.InputText("##wl_add", ui.wl_add, M.BUF_SHORT * 2)
    im.PopItemWidth()
    im.SameLine()
    im.BeginDisabled(state.is_busy("whitelist.add"))
    if im.SmallButton(t("ui.whitelist.add")) then
        local entry = buf_read(ui.wl_add):gsub("^%s+", ""):gsub("%s+$", "")
        if entry ~= "" then
            state.whitelist_add(entry, function(ok) if ok then buf_set(ui.wl_add, "") end end)
        end
    end
    im.EndDisabled()
    im.SameLine()
    text_dim(t("ui.whitelist.add_hint"))
    result_line("whitelist:add")
    im.BeginDisabled(state.is_busy("whitelist.list"))
    if im.SmallButton(t("ui.refresh")) then state.load_whitelist() end
    im.EndDisabled()
    im.SameLine()
    text(t("ui.whitelist.count", { n = #wl.entries }))
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_whitelist", 4, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.whitelist.entry"), im.TableColumnFlags_WidthFixed, 170)
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(t("ui.bans.by"), im.TableColumnFlags_WidthFixed, 100)
        im.TableSetupColumn("", im.TableColumnFlags_WidthFixed, 80)
        im.TableHeadersRow()
        for _, e in ipairs(wl.entries) do
            im.TableNextRow()
            im.PushID1("w:" .. tostring(e.entry))
            cell(e.entry or "")
            cell(e.name or "-")
            cell(e.by or "-")
            im.TableNextColumn()
            im.BeginDisabled(state.is_busy("whitelist.remove"))
            if im.SmallButton(t("ui.whitelist.remove")) then state.whitelist_remove(e.entry) end
            im.EndDisabled()
            local r = state.result("whitelist:" .. tostring(e.entry))
            if r and r.ok == false then
                im.SameLine()
                text_col(1, 0.45, 0.45, r.text)
            end
            im.PopID()
        end
        im.EndTable()
    end
    if #wl.entries == 0 then text_dim(t("ui.whitelist.empty")) end
end

-- the config tab: runtime settings --------------------------------------------------

local function edit_of(s)
    local e = ui.settings_edit[s.key]
    if e == nil or e.synced ~= s.value then
        e = { synced = s.value }
        if s.type == "int" or s.type == "number" then
            local n = tonumber(s.value) or 0
            e.ptr = s.type == "int" and im.IntPtr(math.floor(n)) or im.FloatPtr(n)
        elseif s.type == "bool" then
            e.ptr = im.BoolPtr(s.value == true)
        elseif type(s.enum) == "table" then
            local idx = 0
            for i, v in ipairs(s.enum) do
                if v == s.value then idx = i - 1 end
            end
            e.ptr = im.IntPtr(idx)
        else
            e.buf = buf_new(M.BUF_TEXT, tostring(s.value == nil and "" or s.value))
        end
        ui.settings_edit[s.key] = e
    end
    return e
end

local function draw_setting_editor(s, e)
    if s.type == "bool" then
        if im.Checkbox("##v", e.ptr) then state.set_setting(s.key, e.ptr[0] == true) end
        return nil
    end
    local pending
    if s.type == "int" then
        im.SetNextItemWidth(120)
        im.InputInt("##v", e.ptr, 1, 10)
        pending = math.floor(tonumber(e.ptr[0]) or 0)
    elseif s.type == "number" then
        im.SetNextItemWidth(120)
        im.InputFloat("##v", e.ptr, 0.05, 0.1, "%.2f")
        pending = tonumber(e.ptr[0]) or 0
    elseif type(s.enum) == "table" then
        im.SetNextItemWidth(120)
        im.Combo1("##v", e.ptr, items(s.enum), #s.enum)
        pending = s.enum[e.ptr[0] + 1]
    else
        im.SetNextItemWidth(160)
        im.InputText("##v", e.buf, M.BUF_TEXT)
        pending = buf_read(e.buf)
    end
    return pending
end

-- one setting as a labelled row (the Panel and Interface headers)
local function draw_setting_row(key, label)
    local s = state.setting(key)
    if s == nil then
        text_dim(t(label) .. ": " .. t("ui.settings.need_read"))
        return
    end
    text(t(label))
    im.SameLine()
    im.PushID1("s:" .. key)
    if state.has("settings.write") then
        local e = edit_of(s)
        local pending = draw_setting_editor(s, e)
        if pending ~= nil then
            im.SameLine()
            im.BeginDisabled(state.is_busy("settings.set") or pending == s.value)
            if im.SmallButton(t("ui.settings.set")) then state.set_setting(s.key, pending) end
            im.EndDisabled()
        end
        im.SameLine()
        result_line("setting:" .. key)
    else
        text(tostring(s.value))
    end
    im.PopID()
end

local function draw_settings_table()
    if S.settings_at == nil and not state.is_busy("settings.list") then state.load_settings() end
    local writable = state.has("settings.write")
    im.BeginDisabled(state.is_busy("settings.list"))
    if im.SmallButton(t("ui.refresh")) then state.load_settings() end
    im.EndDisabled()
    if not writable then
        im.SameLine()
        text_dim(t("ui.settings.readonly"))
    end
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_settings", 4, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.settings.key"), im.TableColumnFlags_WidthFixed, 190)
        im.TableSetupColumn(t("ui.settings.value"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(t("ui.settings.default"), im.TableColumnFlags_WidthFixed, 90)
        im.TableSetupColumn("", im.TableColumnFlags_WidthFixed, 60)
        im.TableHeadersRow()
        for _, s in ipairs(S.settings) do
            im.TableNextRow()
            im.PushID1("s:" .. tostring(s.key))
            cell(tostring(s.key) .. (s.overridden and " *" or ""))
            im.TableNextColumn()
            if writable then
                local e = edit_of(s)
                local pending = draw_setting_editor(s, e)
                if pending ~= nil then
                    im.SameLine()
                    im.BeginDisabled(state.is_busy("settings.set") or pending == s.value)
                    if im.SmallButton(t("ui.settings.set")) then state.set_setting(s.key, pending) end
                    im.EndDisabled()
                end
                im.SameLine()
                result_line("setting:" .. s.key)
            else
                text(tostring(s.value))
            end
            cell(tostring(s.default))
            im.TableNextColumn()
            if writable and s.overridden then
                im.BeginDisabled(state.is_busy("settings.reset"))
                if im.SmallButton(t("ui.settings.reset")) then state.reset_setting(s.key) end
                im.EndDisabled()
            end
            im.PopID()
        end
        im.EndTable()
    end
    if #S.settings == 0 then text_dim(state.has("settings.read") and t("ui.waiting") or t("ui.settings.need_read")) end
end

-- the scale input and its reset (the QuickInfo row and the Interface header)
local function draw_scale_control()
    ensure_ptrs()
    if ui.scale_dirty_at == nil and math.abs(ui.scale_ptr[0] - scale()) > 0.001 then ui.scale_ptr[0] = scale() end
    im.PushItemWidth(110 * scale())
    if im.InputFloat("##scale", ui.scale_ptr, 0.05, 0.1, "%.2f") then
        local v = state.clamp_scale(ui.scale_ptr[0])
        ui.scale_ptr[0] = v
        S.ui.scale = v
        ui.scale_dirty_at = bridge.now()
    end
    im.PopItemWidth()
    im.SameLine()
    if im.SmallButton(t("ui.scale.reset")) then
        ui.scale_ptr[0] = 1.0
        S.ui.scale = 1.0
        ui.scale_dirty_at = bridge.now()
    end
    im.SameLine()
    text_dim(t("ui.scale"))
end

local function draw_lang_picker()
    if ui.lang_idx == nil then ui.lang_idx = im.IntPtr(S.lang == "ru" and 1 or 0) end
    local want = S.lang == "ru" and 1 or 0
    if not state.is_busy("me.lang") then ui.lang_idx[0] = want end
    im.SetNextItemWidth(70)
    if im.Combo1("##lang", ui.lang_idx, items({ "EN", "RU" }), 2) then
        local pick = ui.lang_idx[0] == 1 and "ru" or "en"
        if pick ~= S.lang then state.set_lang(pick) end
    end
end

local function draw_config()
    im.BeginChild1("wd_config", im.ImVec2(0, 0), false)
    font_scale()
    -- each section under its own id: the same button labels appear in several of them
    local function section(id, fn, ...)
        im.PushID1(id)
        fn(...)
        im.PopID()
    end
    if im.CollapsingHeader1(t("ui.config.warden"), im.TreeNodeFlags_DefaultOpen or 0) then
        im.Indent()
        if im.TreeNode1(t("ui.config.groups")) then
            section("cfg_groups", draw_groups)
            im.TreePop()
        end
        if state.has("mod.whitelist") and im.TreeNode1(t("ui.config.whitelist")) then
            section("cfg_whitelist", draw_whitelist, true)
            im.TreePop()
        end
        if im.TreeNode1(t("ui.config.panel")) then
            section("cfg_panel", function()
                draw_setting_row("ui.default_shown", "ui.config.default_shown")
                draw_setting_row("ui.welcome", "ui.config.welcome")
                draw_setting_row("spawn.enabled", "ui.config.spawn")
            end)
            im.TreePop()
        end
        if state.has("settings.read") and im.TreeNode1(t("ui.config.runtime")) then
            section("cfg_runtime", draw_settings_table)
            im.TreePop()
        end
        im.Unindent()
    end
    if im.CollapsingHeader1(t("ui.config.server")) then
        im.Indent()
        local sv = S.server or {}
        local function line(label, v) text(t(label) .. ": " .. tostring(v == nil and "-" or v)) end
        line("ui.server.name", sv.name)
        line("ui.server.map", sv.map)
        line("ui.server.version", sv.version)
        line("ui.server.max_players", sv.max_players)
        line("ui.server.max_cars", sv.max_cars)
        text_dim(t(state.GAPS.server_settings.label, { issue = state.GAPS.server_settings.issue }))
        im.Unindent()
    end
    if im.CollapsingHeader1(t("ui.config.interface")) then
        im.Indent()
        section("cfg_interface", function()
            draw_setting_row("ui.theme", "ui.config.theme")
            draw_scale_control()
            text(t("ui.config.language"))
            im.SameLine()
            draw_lang_picker()
        end)
        im.Unindent()
    end
    im.EndChild()
end

-- the environment tab ----------------------------------------------------------------

local function draw_environment()
    text_dim(t(state.GAPS.environment.label, { issue = state.GAPS.environment.issue }))
    local env = rawget(_G, "core_environment")
    if type(env) == "table" and type(env.getTimeOfDay) == "function" then
        local ok, tod = pcall(env.getTimeOfDay)
        if ok and type(tod) == "table" and tonumber(tod.time) then
            local secs = (tonumber(tod.time) * 86400 + 43200) % 86400
            text(t("ui.env.local_time", { time = string.format("%02d:%02d", math.floor(secs / 3600),
                math.floor(secs % 3600 / 60)) }))
        end
    end
end

-- the database tab -----------------------------------------------------------------

local function draw_bans()
    if S.bans_at == nil and not state.is_busy("mod.bans") then state.load_bans() end
    im.BeginDisabled(state.is_busy("mod.bans"))
    if im.SmallButton(t("ui.refresh")) then state.load_bans() end
    im.EndDisabled()
    im.SameLine()
    text(t("ui.bans.count", { n = #S.bans }))
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_bans", 6, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.col.key"), im.TableColumnFlags_WidthFixed, 150)
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.field.reason"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(t("ui.bans.by"), im.TableColumnFlags_WidthFixed, 100)
        im.TableSetupColumn(t("ui.bans.until"), im.TableColumnFlags_WidthFixed, 120)
        im.TableSetupColumn("", im.TableColumnFlags_WidthFixed, 70)
        im.TableHeadersRow()
        for _, b in ipairs(S.bans) do
            im.TableNextRow()
            im.PushID1("b:" .. tostring(b.key))
            cell(b.key or "")
            cell(b.name or "-")
            cell(b.reason or "-")
            cell(b.by or "-")
            cell(b["until"] and state.format_time(b["until"]) or t("ui.bans.permanent"))
            im.TableNextColumn()
            im.BeginDisabled(state.is_busy("mod.unban"))
            if im.SmallButton(t("ui.bans.unban")) then state.unban(b.key) end
            im.EndDisabled()
            local r = state.result("unban:" .. tostring(b.key))
            if r and r.ok == false then
                im.SameLine()
                text_col(1, 0.45, 0.45, r.text)
            end
            im.PopID()
        end
        im.EndTable()
    end
    if #S.bans == 0 then text_dim(t("ui.bans.empty")) end
end

local function draw_mutes()
    if S.mutes_at == nil and not state.is_busy("mod.mutes") then state.load_mutes() end
    im.BeginDisabled(state.is_busy("mod.mutes"))
    if im.SmallButton(t("ui.refresh")) then state.load_mutes() end
    im.EndDisabled()
    im.SameLine()
    text(t("ui.mutes.count", { n = #S.mutes }))
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_mutes", 6, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.col.key"), im.TableColumnFlags_WidthFixed, 150)
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.field.reason"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(t("ui.bans.by"), im.TableColumnFlags_WidthFixed, 100)
        im.TableSetupColumn(t("ui.bans.until"), im.TableColumnFlags_WidthFixed, 120)
        im.TableSetupColumn("", im.TableColumnFlags_WidthFixed, 80)
        im.TableHeadersRow()
        for _, m in ipairs(S.mutes) do
            im.TableNextRow()
            im.PushID1("m:" .. tostring(m.key))
            cell(m.key or "")
            cell(m.name or "-")
            cell(m.reason ~= "" and m.reason or "-")
            cell(m.by or "-")
            cell(m["until"] and state.format_time(m["until"]) or t("ui.bans.permanent"))
            im.TableNextColumn()
            im.BeginDisabled(state.is_busy("mod.unmute"))
            if im.SmallButton(t("ui.action.unmute")) then state.unmute_key(m.key) end
            im.EndDisabled()
            local r = state.result("unmute:" .. tostring(m.key))
            if r and r.ok == false then
                im.SameLine()
                text_col(1, 0.45, 0.45, r.text)
            end
            im.PopID()
        end
        im.EndTable()
    end
    if #S.mutes == 0 then text_dim(t("ui.mutes.empty")) end
end

local function draw_audit()
    if S.audit_at == nil and not state.is_busy("audit.tail") then state.load_audit(ui.audit_n[0]) end
    im.SetNextItemWidth(100)
    im.InputInt("##n", ui.audit_n, 10, 50)
    if ui.audit_n[0] < 1 then ui.audit_n[0] = 1 end
    if ui.audit_n[0] > 200 then ui.audit_n[0] = 200 end
    im.SameLine()
    im.BeginDisabled(state.is_busy("audit.tail"))
    if im.SmallButton(t("ui.refresh")) then state.load_audit(ui.audit_n[0]) end
    im.EndDisabled()
    local tflags = flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_Resizable)
    if im.BeginTable("wd_audit", 6, tflags, im.ImVec2(0, 0)) then
        im.TableSetupColumn(t("ui.audit.at"), im.TableColumnFlags_WidthFixed, 150)
        im.TableSetupColumn(t("ui.audit.actor"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.audit.op"), im.TableColumnFlags_WidthFixed, 100)
        im.TableSetupColumn(t("ui.audit.target"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.audit.result"), im.TableColumnFlags_WidthFixed, 60)
        im.TableSetupColumn(t("ui.audit.reason"), im.TableColumnFlags_WidthStretch)
        im.TableHeadersRow()
        for i = #S.audit, 1, -1 do
            local r = S.audit[i]
            im.TableNextRow()
            cell(r.at or (r.ts and state.format_time(r.ts)) or "")
            cell(type(r.actor) == "table" and (r.actor.name or r.actor.key) or "?")
            cell(r.op or "")
            cell(type(r.target) == "table" and (r.target.name or r.target.key) or "")
            im.TableNextColumn()
            if r.result == "ok" then text(r.result) else text_col(1, 0.6, 0.4, r.result or "") end
            cell(r.reason or "")
        end
        im.EndTable()
    end
    if #S.audit == 0 then text_dim(t("ui.audit.empty")) end
end

local function draw_database()
    im.BeginChild1("wd_database", im.ImVec2(0, 0), false)
    font_scale()
    local function section(perm, label, id, fn, ...)
        if not state.has(perm) then return end
        if not im.CollapsingHeader1(t(label), im.TreeNodeFlags_DefaultOpen or 0) then return end
        im.Indent()
        im.PushID1(id)
        fn(...)
        im.PopID()
        im.Unindent()
    end
    section("mod.ban", "ui.db.bans", "db_bans", draw_bans)
    section("mod.mute", "ui.db.mutes", "db_mutes", draw_mutes)
    section("mod.whitelist", "ui.db.whitelist", "db_whitelist", draw_whitelist, false)
    section("audit.view", "ui.db.audit", "db_audit", draw_audit)
    im.EndChild()
end

-- the window -------------------------------------------------------------------

local TAB_DRAW = {
    players = draw_players, config = draw_config, environment = draw_environment, database = draw_database,
}

-- a status chip: ">>" green (open / allowed), "X" red (closed / off), "//" yellow (in progress)
local function chip(label, kind, extra, first)
    if not first then
        im.SameLine()
        text_dim("|")
        im.SameLine()
    end
    text(label)
    im.SameLine()
    if kind == "ok" then
        text_col(0.2, 0.95, 0.3, ">>")
    elseif kind == "wait" then
        text_col(1.0, 0.85, 0.1, "//")
    else
        text_col(1.0, 0.25, 0.25, "X")
    end
    if extra then
        im.SameLine()
        text(extra)
    end
end

local function draw_quick_info()
    im.BeginChild1("wd_quick", im.ImVec2(0, 66 * scale()), true)
    font_scale()
    local st = S.status or {}
    local sv = S.server or {}
    local bits = {}
    if sv.name then bits[#bits + 1] = tostring(sv.name) end
    bits[#bits + 1] = t("ui.quick.players", { n = st.players or #S.players, max = st.max_players or "?" })
    bits[#bits + 1] = t("ui.quick.cars", { n = st.cars or 0, max = st.max_cars or "?" })
    if S.me then
        bits[#bits + 1] = t("ui.me", { name = S.me.name or "", group = S.me.group or "", level = S.me.level or 0 })
    end
    text(table.concat(bits, "  |  "))
    chip(t("ui.chip.spawn"), st.spawn == false and "off" or "ok", nil, true)
    chip(t("ui.chip.whitelist"), st.whitelist == true and "off" or "ok")
    chip(t("ui.chip.guests"), st.guests == false and "off" or "ok")
    if S.vote then
        chip(t("ui.chip.vote"), "wait", tostring(state.vote_seconds_left()) .. "s")
    else
        chip(t("ui.chip.vote"), st.votekick == true and "ok" or "off")
    end
    local last = S.notices[#S.notices]
    if last and bridge.now() - last.at < 15 then text_col(0.9, 0.85, 0.5, last.text) end
    im.EndChild()
end

local function draw_header_row()
    draw_scale_control()
    im.SameLine()
    draw_lang_picker()
    im.SameLine()
    text_dim(t("ui.help"))
end

local function draw_window()
    local pushed = push_theme()
    im.SetNextWindowSize(im.ImVec2(M.SIZE.w, M.SIZE.h), im.Cond_FirstUseEver)
    local title = M.WINDOW .. (S.version and (" v" .. tostring(S.version)) or "") .. "###wd_panel"
    if im.Begin(title, open, im.WindowFlags_NoCollapse) then
        font_scale()
        if bridge.getState().outdated then
            text_col(1, 0.45, 0.45, t("ui.outdated"))
        elseif S.session == nil then
            text_dim(t("ui.waiting"))
        else
            draw_quick_info()
            draw_header_row()
            im.BeginChild1("wd_tabs", im.ImVec2(0, 0), false)
            font_scale()
            if im.BeginTabBar("wd_tabs", im.TabBarFlags_None) then
                for _, tab in ipairs(state.TABS) do
                    if state.tab_allowed(tab) and im.BeginTabItem(t(tab.label)) then
                        ui.tab = tab.id
                        TAB_DRAW[tab.id]()
                        im.EndTabItem()
                    end
                end
                im.EndTabBar()
            end
            im.EndChild()
        end
    end
    im.End()
    pop_theme(pushed)
end

-- the vote banner --------------------------------------------------------------

local function draw_banner()
    local v = S.vote
    local last = S.vote_last
    if v == nil and (last == nil or bridge.now() - last.at > 8) then return end
    local io = im.GetIO()
    local w = io and io.DisplaySize and io.DisplaySize.x or 1920
    local pushed = push_theme()
    im.SetNextWindowPos(im.ImVec2(w * 0.5, M.BANNER_Y), im.Cond_Always, im.ImVec2(0.5, 0))
    local wflags = flags(im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize, im.WindowFlags_AlwaysAutoResize,
        im.WindowFlags_NoMove, im.WindowFlags_NoSavedSettings, im.WindowFlags_NoFocusOnAppearing)
    if im.Begin("###wd_vote", nil, wflags) then
        font_scale()
        if v then
            local target = type(v.target) == "table" and v.target.name or "?"
            local starter = type(v.starter) == "table" and v.starter.name or "?"
            text(t("ui.vote.title", { target = target }))
            local why = v.reason and ("  ·  " .. t("ui.vote.reason", { reason = v.reason })) or ""
            text_dim(t("ui.vote.by", { starter = starter }) .. why)
            text(t("ui.vote.count", {
                yes = v.yes or 0, needed = v.needed or 0, no = v.no or 0, sec = state.vote_seconds_left(),
            }))
            local mine = S.me and S.me.pid == (type(v.target) == "table" and v.target.pid or nil)
            if state.has("votekick.vote") and not mine then
                im.BeginDisabled(state.is_busy("vote.cast"))
                if im.Button(t("ui.vote.yes")) then state.vote(true) end
                im.SameLine()
                if im.Button(t("ui.vote.no")) then state.vote(false) end
                im.EndDisabled()
            end
            if state.has("votekick.cancel") then
                im.SameLine()
                im.BeginDisabled(state.is_busy("vote.cancel"))
                if im.SmallButton(t("ui.vote.cancel")) then state.vote_cancel() end
                im.EndDisabled()
            end
            if last and bridge.now() - last.at < 8 then text_dim(last.text) end
        else
            text(last.text)
        end
    end
    im.End()
    pop_theme(pushed)
end

-- one frame ----------------------------------------------------------------------

local function flush_scale()
    if ui.scale_dirty_at == nil then return end
    if bridge.now() - ui.scale_dirty_at < M.SCALE_SEND_DELAY_S then return end
    ui.scale_dirty_at = nil
    state.set_ui({ scale = S.ui.scale })
end

function M.draw()
    if not gui() then return false end
    ensure_ptrs()
    if wanted and bridge.getState().session ~= nil then
        wanted = false
        M.open()
    end
    flush_scale()
    if bridge.getState().session ~= nil or bridge.getState().outdated then draw_banner() end
    if open[0] then
        draw_window()
        ui.drawn_open = true
    elseif ui.drawn_open then
        -- the window's X (im.Begin wrote false into the pointer): the player hid it, the server remembers
        ui.drawn_open = false
        ui.confirm = {}
        state.set_ui({ shown = false })
    end
    return true
end

function M.onUpdate(dt) -- luacheck: ignore 212
    if not gui() then return end
    local ok, err = pcall(M.draw)
    if ok then
        ui.draw_errors = 0
        return
    end
    ui.draw_errors = ui.draw_errors + 1
    bridge.say("E", "panel draw failed: " .. tostring(err))
    if ui.draw_errors >= M.MAX_DRAW_ERRORS then
        bridge.say("E", "panel closed after " .. ui.draw_errors .. " errors in a row")
        M.close(true)
        ui.draw_errors = 0
    end
end

function M.onExtensionLoaded()
    M.register_category()
end

function M.onExtensionUnloaded()
    M.close(true)
    wanted = false
end

-- the server's /warden (and /wd) sends wd:event panel { toggle | open }
bridge.on("panel", function(data)
    if type(data) == "table" and data.open ~= nil then
        if data.open then M.open() else M.close() end
    else
        M.toggle()
    end
end)

-- the hello record: the player's own state says whether the window is up
bridge.on("session", function()
    if S.ui.shown then
        M.open(true)
        wanted = false
    end
end)

-- leaving the server: the panel goes with the session
bridge.on("connected", function(up)
    if not up then
        M.close(true)
        wanted = false
        ui.rows, ui.settings_edit, ui.gedit, ui.confirm = {}, {}, nil, {}
        ui.scale_dirty_at = nil
    end
end)

M.register_category()

-- the resource env writes globals into the game's _G: the action's onDown and the console call it
nodemp_wd = { -- luacheck: ignore 111
    toggle = M.toggle, open = function() return M.open(false) end, close = function() return M.close(false) end,
    isOpen = M.isOpen, action = M.ACTION, version = bridge.VERSION,
}

return M
