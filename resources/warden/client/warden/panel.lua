-- warden/panel: the admin panel, drawn with the game's Dear ImGui binding
-- (ui_imgui) every frame the window is open, and the vote banner.
--
-- The client mod registers this table as a game extension because it has
-- onUpdate (net/resources.lua: a streamed ge file returning on* functions ->
-- newExtensionProxy), so onUpdate(dt) runs each frame: it reads the toggle
-- key (im.IsKeyPressed(im.Key_F9)), draws the banner while a vote runs and
-- the window while it is open. Everything the panel shows comes from
-- warden/state; every button is one wd:req the server judges.
--
--   panel.toggle() / open() / close() / isOpen()      also the global nodemp_wd (the console: nodemp_wd.toggle())
--   panel.draw()                                       one frame (the tests call it with a fake ui_imgui)
--   panel.key_name() -> "F9"                           the toggle key the server named (ui.key)
--
-- Lua 5.1 semantics (LuaJIT): text buffers are im.ArrayChar, read with
-- ffi.string and written with ffi.copy, the way the game's own tools do.

local bridge = require("warden/bridge")
local i18n = require("warden/i18n")
local state = require("warden/state")

local M = {}

M.WINDOW = "Warden"
M.SIZE = { w = 920, h = 560 }
M.BANNER_Y = 40
M.RESULT_TTL_S = 6
M.MAX_DRAW_ERRORS = 5
M.BUF_TEXT = 200
M.BUF_SHORT = 32

local im = nil
local ffi = nil
local S = state.S

local open = nil            -- im.BoolPtr, the window's close box writes it
local ui = {
    tab = "players", selected_pid = nil, action = nil, form = nil, lang_idx = nil, audit_n = nil,
    settings_edit = {}, draw_errors = 0, want_players = false, custom_dur = false,
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

local function table_flags()
    return flags(im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_ScrollY, im.TableFlags_Resizable)
end

local function items(list)
    return im.ArrayCharPtrByTbl(list)
end

local function result_line(id)
    local r = state.result(id)
    if r == nil then return end
    if r.ok == true and bridge.now() - r.at > M.RESULT_TTL_S then
        state.clear_result(id)
        return
    end
    if r.ok == true then
        text_col(0.5, 0.9, 0.5, r.text)
    elseif r.ok == false then
        text_col(1, 0.45, 0.45, r.text)
    else
        text_dim(r.text)
    end
end

local function cell(s)
    im.TableNextColumn()
    text(s)
end

local function count(tbl)
    local n = 0
    for _ in pairs(tbl or {}) do n = n + 1 end
    return n
end

-- the toggle key --------------------------------------------------------------

function M.key_name()
    return S.key or "F9"
end

local function key_code()
    local name = M.key_name()
    local k = im["Key_" .. tostring(name)]
    if k == nil then k = im.Key_F9 end
    return k
end

-- open / close ----------------------------------------------------------------

function M.isOpen()
    return open ~= nil and open[0] == true
end

local function ensure_ptrs()
    if open == nil then open = im.BoolPtr(false) end
    if ui.audit_n == nil then ui.audit_n = im.IntPtr(state.AUDIT_DEFAULT) end
end

function M.open()
    if not gui() then return false end
    if bridge.getState().session == nil then
        wanted = true
        return false
    end
    ensure_ptrs()
    if open[0] then return false end
    open[0] = true
    ui.want_players = true
    return true
end

function M.close()
    if open == nil or not open[0] then return false end
    open[0] = false
    ui.action = nil
    return true
end

function M.toggle()
    if M.isOpen() then return M.close() end
    return M.open()
end

-- the players tab -------------------------------------------------------------

local function player_row(pid)
    for _, row in ipairs(S.players) do
        if row.pid == pid then return row end
    end
    return nil
end

local function new_form()
    return {
        reason = buf_new(M.BUF_TEXT), custom = buf_new(M.BUF_SHORT), dur_idx = im.IntPtr(0), group_idx = im.IntPtr(0),
    }
end

local function start_action(action)
    ui.action = action.id
    ui.form = new_form()
    state.clear_result(action.id)
end

local function duration_labels()
    local out = {}
    for i, d in ipairs(state.DURATIONS) do out[i] = d.sec and d.label or t(d.label) end
    return out
end

local function form_fields(action)
    local f = ui.form
    local fields = {}
    for _, name in ipairs(action.fields) do
        if name == "reason" then
            im.InputText("##reason", f.reason, M.BUF_TEXT)
            im.SameLine()
            text_dim(t("ui.field.reason"))
            fields.reason = buf_read(f.reason)
        elseif name == "duration" then
            im.Combo1("##duration", f.dur_idx, items(duration_labels()), #state.DURATIONS)
            im.SameLine()
            text_dim(t("ui.field.duration"))
            local d = state.DURATIONS[f.dur_idx[0] + 1]
            if d and d.sec then
                fields.duration = tostring(d.sec) .. "s"
            else
                im.InputText("##custom", f.custom, M.BUF_SHORT)
                im.SameLine()
                text_dim(t("ui.field.custom_hint"))
                fields.duration = buf_read(f.custom)
            end
        elseif name == "group" then
            local groups = state.assignable_groups()
            local labels = {}
            for i, g in ipairs(groups) do labels[i] = g.name .. " (" .. tostring(g.level) .. ")" end
            if #labels == 0 then
                text_dim(t("ui.groups.none_below"))
            else
                if f.group_idx[0] >= #labels then f.group_idx[0] = 0 end
                im.Combo1("##group", f.group_idx, items(labels), #labels)
                im.SameLine()
                text_dim(t("ui.field.group"))
                local g = groups[f.group_idx[0] + 1]
                fields.group = g and g.name or ""
            end
        end
    end
    return fields
end

local function draw_action_form(row)
    local action = state.action_by_id(ui.action)
    if action == nil then
        ui.action = nil
        return
    end
    im.Separator()
    text(t("ui.form.title", { action = t(action.label), name = row.name or ("#" .. tostring(row.pid)) }))
    local fields = form_fields(action)
    local busy = state.is_busy(action.op)
    im.BeginDisabled(busy)
    if im.Button(t("ui.form.confirm")) then
        state.run(action, row, fields, function(ok)
            if ok then ui.action = nil end
        end)
    end
    im.EndDisabled()
    im.SameLine()
    if im.Button(t("ui.form.cancel")) then
        ui.action = nil
        state.clear_result(action.id)
    end
    im.SameLine()
    result_line(action.id)
end

local function draw_card(row)
    local bits = {}
    if row.key then bits[#bits + 1] = t("ui.card.key") .. ": " .. tostring(row.key) end
    if row.account then bits[#bits + 1] = t("ui.card.account") .. ": " .. tostring(row.account) end
    if row.ip then bits[#bits + 1] = "IP: " .. tostring(row.ip) end
    if row.joins then bits[#bits + 1] = t("ui.card.joins") .. ": " .. tostring(row.joins) end
    if row.warns then bits[#bits + 1] = t("ui.card.warns") .. ": " .. tostring(count(row.warns)) end
    if row.cap then
        local cap = tonumber(row.cap) == -1 and t("ui.card.unlimited") or tostring(row.cap)
        bits[#bits + 1] = t("ui.card.cap") .. ": " .. cap
    end
    if type(row.mute) == "table" then
        local until_s = row.mute["until"] and state.format_time(row.mute["until"]) or t("ui.bans.permanent")
        bits[#bits + 1] = t("ui.card.mute") .. ": " .. until_s
    end
    if type(row.names) == "table" and #row.names > 1 then
        bits[#bits + 1] = t("ui.card.names") .. ": " .. table.concat(row.names, ", ")
    end
    if #bits > 0 then im.TextWrapped("%s", table.concat(bits, "  ·  ")) end
end

local function draw_actions(row)
    for i, action in ipairs(state.ACTIONS) do
        local allowed = state.can_target(row, action)
        im.BeginDisabled(not allowed)
        if im.Button(t(action.label)) then start_action(action) end
        im.EndDisabled()
        if i < #state.ACTIONS then im.SameLine() end
    end
    -- the result of an action whose form is closed already (e.g. done)
    for _, action in ipairs(state.ACTIONS) do
        if action.id ~= ui.action then result_line(action.id) end
    end
end

local function draw_players()
    if ui.want_players then
        ui.want_players = false
        if not S.subscribed then state.load_players() end
    end
    text(t("ui.players.count", { n = #S.players }))
    im.SameLine()
    im.BeginDisabled(state.is_busy("players.list"))
    if im.Button(t("ui.refresh")) then state.load_players() end
    im.EndDisabled()
    if ui.selected_pid ~= nil and player_row(ui.selected_pid) == nil then
        ui.selected_pid = nil
        ui.action = nil
    end
    local table_h = ui.selected_pid and -150 or -4
    local tflags = table_flags()
    if im.BeginTable("wd_players", 7, tflags, im.ImVec2(0, table_h)) then
        im.TableSetupScrollFreeze(0, 1)
        im.TableSetupColumn(t("ui.col.pid"), im.TableColumnFlags_WidthFixed, 36)
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(t("ui.col.account"), im.TableColumnFlags_WidthFixed, 90)
        im.TableSetupColumn(t("ui.col.group"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.col.cars"), im.TableColumnFlags_WidthFixed, 44)
        im.TableSetupColumn(t("ui.col.ping"), im.TableColumnFlags_WidthFixed, 56)
        im.TableSetupColumn(t("ui.col.online"), im.TableColumnFlags_WidthFixed, 70)
        im.TableHeadersRow()
        for _, row in ipairs(S.players) do
            im.TableNextRow()
            im.TableNextColumn()
            im.PushID1("p" .. tostring(row.pid))
            local selected = ui.selected_pid == row.pid
            if im.Selectable1(tostring(row.pid), selected, im.SelectableFlags_SpanAllColumns) then
                if selected then
                    ui.selected_pid = nil
                    ui.action = nil
                else
                    ui.selected_pid = row.pid
                    ui.action = nil
                    if state.has("players.view") then state.load_player(row.pid) end
                end
            end
            im.PopID()
            local name = tostring(row.name or "")
            if S.me and row.pid == S.me.pid then name = name .. " (" .. t("ui.players.you") .. ")" end
            cell(name)
            cell(row.guest and t("ui.players.guest") or (row.verified and t("ui.players.verified") or "-"))
            cell(tostring(row.group or "") .. " (" .. tostring(row.level or 0) .. ")")
            cell(tostring(row.vehicles or 0))
            cell(row.ping and string.format("%d ms", math.floor((tonumber(row.ping) or 0) * 1000 + 0.5)) or "-")
            cell(row.connected and state.format_duration(row.connected) or "-")
        end
        im.EndTable()
    end
    if #S.players == 0 then text_dim(t("ui.players.empty")) end
    local row = ui.selected_pid and player_row(ui.selected_pid) or nil
    if row == nil then
        text_dim(t("ui.players.select"))
        return
    end
    im.Separator()
    text(tostring(row.name or "") .. "  ·  " .. tostring(row.group or "") .. " (" .. tostring(row.level or 0) .. ")")
    draw_card(row)
    draw_actions(row)
    if ui.action then draw_action_form(row) end
end

-- the groups tab ---------------------------------------------------------------

local function draw_groups()
    if S.groups_at == nil and not state.is_busy("groups.list") then state.load_groups() end
    im.BeginDisabled(state.is_busy("groups.list"))
    if im.Button(t("ui.refresh")) then state.load_groups() end
    im.EndDisabled()
    im.SameLine()
    text_dim(t("ui.groups.readonly"))
    local tflags = table_flags()
    if im.BeginTable("wd_groups", 5, tflags, im.ImVec2(0, -4)) then
        im.TableSetupScrollFreeze(0, 1)
        im.TableSetupColumn(t("ui.col.name"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.col.level"), im.TableColumnFlags_WidthFixed, 50)
        im.TableSetupColumn(t("ui.groups.inherits"), im.TableColumnFlags_WidthFixed, 110)
        im.TableSetupColumn(t("ui.col.cars"), im.TableColumnFlags_WidthFixed, 50)
        im.TableSetupColumn(t("ui.groups.perms"), im.TableColumnFlags_WidthStretch)
        im.TableHeadersRow()
        for _, g in ipairs(S.groups) do
            im.TableNextRow()
            cell(g.name)
            cell(tostring(g.level or 0))
            cell(type(g.inherits) == "table" and #g.inherits > 0 and table.concat(g.inherits, ", ") or "-")
            local cap = type(g.caps) == "table" and g.caps.vehicles or nil
            cell(cap == nil and "-" or (tonumber(cap) == -1 and t("ui.card.unlimited") or tostring(cap)))
            im.TableNextColumn()
            im.TextWrapped("%s", type(g.perms) == "table" and #g.perms > 0 and table.concat(g.perms, " ") or "-")
        end
        im.EndTable()
    end
end

-- the settings tab -------------------------------------------------------------

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

local function draw_settings()
    if S.settings_at == nil and not state.is_busy("settings.list") then state.load_settings() end
    local writable = state.has("settings.write")
    im.BeginDisabled(state.is_busy("settings.list"))
    if im.Button(t("ui.refresh")) then state.load_settings() end
    im.EndDisabled()
    if not writable then
        im.SameLine()
        text_dim(t("ui.settings.readonly"))
    end
    local tflags = table_flags()
    if im.BeginTable("wd_settings", 4, tflags, im.ImVec2(0, -4)) then
        im.TableSetupScrollFreeze(0, 1)
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
                    if im.Button(t("ui.settings.set")) then state.set_setting(s.key, pending) end
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
end

-- the audit tab ----------------------------------------------------------------

local function draw_audit()
    if S.audit_at == nil and not state.is_busy("audit.tail") then state.load_audit(ui.audit_n[0]) end
    im.SetNextItemWidth(100)
    im.InputInt("##n", ui.audit_n, 10, 50)
    if ui.audit_n[0] < 1 then ui.audit_n[0] = 1 end
    if ui.audit_n[0] > 200 then ui.audit_n[0] = 200 end
    im.SameLine()
    im.BeginDisabled(state.is_busy("audit.tail"))
    if im.Button(t("ui.refresh")) then state.load_audit(ui.audit_n[0]) end
    im.EndDisabled()
    local tflags = table_flags()
    if im.BeginTable("wd_audit", 6, tflags, im.ImVec2(0, -4)) then
        im.TableSetupScrollFreeze(0, 1)
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

-- the bans tab -----------------------------------------------------------------

local function draw_bans()
    if S.bans_at == nil and not state.is_busy("mod.bans") then state.load_bans() end
    im.BeginDisabled(state.is_busy("mod.bans"))
    if im.Button(t("ui.refresh")) then state.load_bans() end
    im.EndDisabled()
    im.SameLine()
    text(t("ui.bans.count", { n = #S.bans }))
    local tflags = table_flags()
    if im.BeginTable("wd_bans", 6, tflags, im.ImVec2(0, -4)) then
        im.TableSetupScrollFreeze(0, 1)
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

-- the window -------------------------------------------------------------------

local TAB_DRAW = {
    players = draw_players, groups = draw_groups, settings = draw_settings, audit = draw_audit, bans = draw_bans,
}

local function draw_header()
    local me = S.me
    if me then
        text(t("ui.me", { name = me.name or "", group = me.group or "", level = me.level or 0 }))
    end
    im.SameLine()
    if ui.lang_idx == nil then ui.lang_idx = im.IntPtr(S.lang == "ru" and 1 or 0) end
    local want = S.lang == "ru" and 1 or 0
    if not state.is_busy("me.lang") then ui.lang_idx[0] = want end
    im.SetNextItemWidth(70)
    if im.Combo1("##lang", ui.lang_idx, items({ "EN", "RU" }), 2) then
        local pick = ui.lang_idx[0] == 1 and "ru" or "en"
        if pick ~= S.lang then state.set_lang(pick) end
    end
    im.SameLine()
    text_dim(t("ui.help", { key = M.key_name() }))
    local last = S.notices[#S.notices]
    if last and bridge.now() - last.at < 15 then text_col(0.9, 0.85, 0.5, last.text) end
end

local function draw_window()
    im.SetNextWindowSize(im.ImVec2(M.SIZE.w, M.SIZE.h), im.Cond_FirstUseEver)
    local title = M.WINDOW .. (S.version and (" " .. tostring(S.version)) or "") .. "###wd_panel"
    if im.Begin(title, open, im.WindowFlags_NoCollapse) then
        if bridge.getState().outdated then
            text_col(1, 0.45, 0.45, t("ui.outdated"))
        elseif S.session == nil then
            text_dim(t("ui.waiting"))
        else
            draw_header()
            im.Separator()
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
        end
    end
    im.End()
end

-- the vote banner --------------------------------------------------------------

local function draw_banner()
    local v = S.vote
    local last = S.vote_last
    if v == nil and (last == nil or bridge.now() - last.at > 8) then return end
    local io = im.GetIO()
    local w = io and io.DisplaySize and io.DisplaySize.x or 1920
    im.SetNextWindowPos(im.ImVec2(w * 0.5, M.BANNER_Y), im.Cond_Always, im.ImVec2(0.5, 0))
    local wflags = flags(im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize, im.WindowFlags_AlwaysAutoResize,
        im.WindowFlags_NoMove, im.WindowFlags_NoSavedSettings, im.WindowFlags_NoFocusOnAppearing)
    if im.Begin("###wd_vote", nil, wflags) then
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
end

-- one frame ----------------------------------------------------------------------

function M.draw()
    if not gui() then return false end
    ensure_ptrs()
    if wanted and bridge.getState().session ~= nil then
        wanted = false
        M.open()
    end
    if bridge.getState().session ~= nil or bridge.getState().outdated then draw_banner() end
    if open[0] then draw_window() end
    return true
end

local function poll_key()
    if bridge.getState().session == nil then return end
    if type(im.IsKeyPressed) ~= "function" then return end
    local ok, pressed = pcall(im.IsKeyPressed, key_code(), false)
    if ok and pressed then M.toggle() end
end

function M.onUpdate(dt) -- luacheck: ignore 212
    if not gui() then return end
    local ok, err = pcall(function()
        poll_key()
        M.draw()
    end)
    if ok then
        ui.draw_errors = 0
        return
    end
    ui.draw_errors = ui.draw_errors + 1
    bridge.say("E", "panel draw failed: " .. tostring(err))
    if ui.draw_errors >= M.MAX_DRAW_ERRORS then
        bridge.say("E", "panel closed after " .. ui.draw_errors .. " errors in a row")
        M.close()
        ui.draw_errors = 0
    end
end

function M.onExtensionUnloaded()
    M.close()
    wanted = false
end

-- the server's /wd sends wd:event panel { toggle | open }
bridge.on("panel", function(data)
    if type(data) == "table" and data.open ~= nil then
        if data.open then M.open() else M.close() end
    else
        M.toggle()
    end
end)

-- leaving the server: the panel goes with the session
bridge.on("connected", function(up)
    if not up then
        M.close()
        wanted = false
        ui.selected_pid, ui.action, ui.settings_edit = nil, nil, {}
    end
end)

nodemp_wd = { -- luacheck: ignore 111 (the resource env writes globals into the game's _G: the console can call it)
    toggle = M.toggle, open = M.open, close = M.close, isOpen = M.isOpen, key = M.key_name,
}

return M
