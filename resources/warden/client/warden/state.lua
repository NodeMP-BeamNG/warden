-- warden/state: what the panel knows and what it may ask -- the model behind
-- warden/panel.lua, with no imgui in it so the tests can drive it.
--
-- Everything here is a convenience for the drawing code: the permission and
-- rank checks only decide which buttons to show. The server runs its own
-- (commands.registry) on every wd:req and answers with an error the panel
-- prints; nothing the client believes about itself grants anything.
--
--   state.S                      the model: session, me, perms, players, details, groups, permissions,
--                                settings, bans, mutes, whitelist, audit, vote, notices, status, server,
--                                ui (shown / scale / theme -- the player's own, kept by the server),
--                                busy, results
--   state.ACTIONS / TABS / DURATIONS / GAPS
--   state.has(perm)              the actor's effective perms include perm ("*" and "mod.*" wildcards)
--   state.tab_allowed(tab)
--   state.can_target(row, action) -> bool, why   the rank rule the server applies, for greying
--   state.build(action, target, fields) -> op, data | nil, bad_field
--   state.parse_duration("2h") -> seconds | nil
--   state.run(action, target, fields, cb)        one wd:req for a row action
--   state.load_players / subscribe / load_player / load_groups / save_group / delete_group
--   state.load_settings / set_setting / reset_setting
--   state.load_bans / unban / load_mutes / unmute_key / load_whitelist / whitelist_add / whitelist_remove
--   state.whitelist_enable / announce / load_audit / vote / vote_cancel / set_lang
--   state.set_ui { shown?, scale? }              the player's own panel state (ui.set)
--   state.focus(pid) -> ok, why                  the camera onto one of the player's vehicles (client side)
--   state.vehicles_of(pid) -> array              the player's vehicles the client mod knows
--   state.on_event(ev, data)     the wd:event dispatch (bridge wires it)
--   state.reset()                back to nothing known (leaving the server; the tests)

local bridge = require("warden/bridge")
local i18n = require("warden/i18n")

local M = {}

-- the row of small buttons under a player, in the order the CobaltEssentials
-- Interface has them: vote kick, kick, ban, tempban, mute / unmute, whitelist /
-- unwhitelist, then warden's own warn, group and cars. `confirm`: the button
-- asks for a second click (a ban is not a misclick away).
M.ACTIONS = {
    { id = "votekick", op = "vote.start", perm = "votekick.start", rank = false, fields = { "reason" },
        label = "ui.action.votekick" },
    { id = "kick", op = "mod.kick", perm = "mod.kick", rank = true, fields = { "reason" }, label = "ui.action.kick" },
    { id = "ban", op = "mod.ban", perm = "mod.ban", rank = true, fields = { "reason" }, label = "ui.action.ban",
        confirm = true },
    { id = "tempban", op = "mod.tempban", perm = "mod.tempban", rank = true, fields = { "duration", "reason" },
        required = { "duration" }, label = "ui.action.tempban", confirm = true },
    { id = "mute", op = "mod.mute", perm = "mod.mute", rank = true, fields = { "duration", "reason" },
        label = "ui.action.mute", hide_when = "muted" },
    { id = "unmute", op = "mod.unmute", perm = "mod.mute", rank = false, fields = {}, label = "ui.action.unmute",
        show_when = "muted" },
    { id = "whitelist", op = "whitelist.add", perm = "mod.whitelist", rank = false, self = true, fields = {},
        label = "ui.action.whitelist", hide_when = "whitelisted" },
    { id = "unwhitelist", op = "whitelist.remove", perm = "mod.whitelist", rank = false, self = true, fields = {},
        label = "ui.action.unwhitelist", show_when = "whitelisted" },
    { id = "warn", op = "mod.warn", perm = "mod.warn", rank = true, fields = { "reason" }, required = { "reason" },
        label = "ui.action.warn" },
    { id = "group", op = "groups.set", perm = "perms.set", rank = true, fields = { "group" }, required = { "group" },
        label = "ui.action.group" },
    { id = "cars", op = "car.delete", perm = "car.delete", rank = true, self = true, fields = { "vid" },
        label = "ui.action.cars" },
}

-- the tabs, the CEI's four; a tab with perm = nil is always there
M.TABS = {
    { id = "players", perm = "players.view", label = "ui.tab.players" },
    { id = "config", perm = nil, label = "ui.tab.config" },
    { id = "environment", perm = nil, label = "ui.tab.environment" },
    { id = "database", perm = nil, any = { "mod.ban", "mod.mute", "mod.whitelist", "audit.view" },
        label = "ui.tab.database" },
}

M.DURATIONS = {
    { label = "30m", sec = 1800 }, { label = "2h", sec = 7200 }, { label = "1d", sec = 86400 },
    { label = "7d", sec = 604800 }, { label = "ui.field.custom", sec = nil },
}

-- what the platform has no call for yet: the button is there, greyed, and its
-- tooltip names the server issue (docs/dev.md "Platform gaps")
M.GAPS = {
    teleport = { issue = "server#53", label = "ui.gap.teleport" },
    freeze = { issue = "server#58", label = "ui.gap.freeze" },
    ignition = { issue = "server#89", label = "ui.gap.ignition" },
    environment = { issue = "server#52", label = "ui.gap.environment" },
    server_settings = { issue = "server#39", label = "ui.gap.server_settings" },
}

M.NOTICES_MAX = 8
M.AUDIT_DEFAULT = 30
M.SCALE_MIN = 0.75
M.SCALE_MAX = 1.5

local function fresh()
    return {
        session = nil, me = nil, perms = {}, lang = "en", version = nil, default_group = "default",
        ui = { shown = false, scale = 1.0, theme = "cobalt" },
        status = {}, server = {},
        players = {}, players_at = nil, subscribed = false,
        details = {},   -- pid -> the full row (players.get), for the expanded header
        groups = {}, permissions = {}, groups_at = nil,
        settings = {}, settings_at = nil,
        bans = {}, bans_at = nil,
        mutes = {}, mutes_at = nil,
        whitelist = { enabled = nil, entries = {}, at = nil },
        audit = {}, audit_at = nil,
        vote = nil, vote_deadline = nil, vote_last = nil,
        notices = {},
        busy = {},      -- op -> true while a request is out
        results = {},   -- id -> { ok, text, at } the last outcome shown by the panel
    }
end

M.S = fresh()

-- in place: warden/panel keeps a reference to the table
function M.reset()
    for k in pairs(M.S) do M.S[k] = nil end
    for k, v in pairs(fresh()) do M.S[k] = v end
end

-- permissions ---------------------------------------------------------------

function M.has(perm)
    local perms = M.S.perms
    if type(perms) ~= "table" then return false end
    for _, p in ipairs(perms) do
        if p == "*" or p == perm then return true end
    end
    local parts = {}
    for part in tostring(perm):gmatch("[^%.]+") do parts[#parts + 1] = part end
    for i = #parts - 1, 1, -1 do
        local prefix = table.concat(parts, ".", 1, i) .. ".*"
        for _, p in ipairs(perms) do
            if p == prefix then return true end
        end
    end
    return false
end

function M.has_any(list)
    for _, p in ipairs(list or {}) do
        if M.has(p) then return true end
    end
    return false
end

function M.tab_allowed(tab)
    if tab.perm ~= nil and not M.has(tab.perm) then return false end
    if tab.any ~= nil and not M.has_any(tab.any) then return false end
    return true
end

function M.action_by_id(id)
    for _, a in ipairs(M.ACTIONS) do
        if a.id == id then return a end
    end
    return nil
end

-- the button is shown for this row (mute / unmute and whitelist / unwhitelist alternate)
function M.action_visible(row, action)
    if action.show_when and not row[action.show_when] then return false end
    if action.hide_when and row[action.hide_when] then return false end
    return true
end

-- the rank rule the server applies (registry: level(actor) > level(target)), so a
-- button that would only be refused is greyed; the server decides anyway
function M.can_target(row, action)
    local me = M.S.me
    if me == nil or row == nil then return false, "no_session" end
    if not M.has(action.perm) then return false, "denied" end
    if row.pid == me.pid then
        if action.self then return true end
        return false, action.id == "votekick" and "vote.self" or "self"
    end
    if action.rank and (tonumber(me.level) or 0) <= (tonumber(row.level) or 0) then return false, "outranked" end
    return true
end

-- groups the actor may put a player in: below the actor's own level
function M.assignable_groups()
    local out = {}
    local me = M.S.me
    local mine = me and tonumber(me.level) or 0
    for _, g in ipairs(M.S.groups) do
        if (tonumber(g.level) or 0) < mine then out[#out + 1] = g end
    end
    return out
end

-- may the actor edit this group definition? (the server's H1 rule, for greying)
function M.can_edit_group(g)
    local me = M.S.me
    if me == nil or not M.has("perms.manage") then return false end
    if g == nil then return true end
    return (tonumber(g.level) or 0) < (tonumber(me.level) or 0)
end

-- durations -----------------------------------------------------------------

function M.parse_duration(text)
    local n, unit = tostring(text or ""):match("^%s*(%d+)%s*([smhdwSMHDW]?)%s*$")
    if n == nil then return nil end
    local mult = { [""] = 60, s = 1, m = 60, h = 3600, d = 86400, w = 604800 }
    return tonumber(n) * mult[unit:lower()]
end

function M.format_duration(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec <= 0 then return "0s" end
    local parts = {}
    for _, u in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" }, { 1, "s" } }) do
        if sec >= u[1] then
            parts[#parts + 1] = math.floor(sec / u[1]) .. u[2]
            sec = sec % u[1]
            if #parts == 2 then break end
        end
    end
    return table.concat(parts, " ")
end

function M.format_time(unix)
    unix = tonumber(unix)
    if unix == nil or unix <= 0 then return "" end
    local ok, s = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(unix))
    if ok and type(s) == "string" then return s end
    return tostring(unix)
end

-- the wd:req data of a row action; nil + the field's name when a required field is empty or bad
function M.build(action, target, fields)
    fields = fields or {}
    local data = {}
    if action.op == "whitelist.add" or action.op == "whitelist.remove" then
        data.entry = "#" .. tostring(target.pid)
        return action.op, data
    end
    data.pid = target.pid
    for _, f in ipairs(action.fields) do
        local raw = fields[f]
        local v = raw ~= nil and tostring(raw):gsub("^%s+", ""):gsub("%s+$", "") or ""
        local required = false
        for _, r in ipairs(action.required or {}) do
            if r == f then required = true end
        end
        if f == "duration" then
            if v == "" then
                if required then return nil, "duration" end
            else
                local sec = M.parse_duration(v)
                if sec == nil or sec < 60 then return nil, "duration" end
                data.duration = sec
            end
        elseif f == "vid" then
            if v ~= "" then
                local n = tonumber(v)
                if n == nil or n < 0 or n ~= math.floor(n) then return nil, "vid" end
                data.vid = n
            end
        elseif v ~= "" then
            data[f] = v
        elseif required then
            return nil, f
        end
    end
    return action.op, data
end

-- requests ------------------------------------------------------------------

local function busy(op, on)
    M.S.busy[op] = on and true or nil
end

function M.is_busy(op)
    return M.S.busy[op] == true
end

local function note_result(id, ok, text)
    M.S.results[id] = { ok = ok, text = text, at = bridge.now() }
end
M.note_result = note_result

function M.result(id)
    return M.S.results[id]
end

function M.clear_result(id)
    M.S.results[id] = nil
end

local function ask(op, data, cb)
    busy(op, true)
    return bridge.request(op, data, function(ok, payload)
        busy(op, false)
        if cb then cb(ok, payload) end
    end)
end

-- the result id of a row action: one line per player, whatever the button
function M.result_id(action, target)
    return action.id .. ":" .. tostring(target and target.pid or "")
end

function M.run(action, target, fields, cb)
    local rid = M.result_id(action, target)
    local op, data = M.build(action, target, fields)
    if op == nil then
        local err = { code = "bad_arg", params = { field = data } }
        note_result(rid, false, i18n.error_text(err))
        if cb then cb(false, err) end
        return nil, data
    end
    note_result(rid, nil, i18n.t("ui.form.sending"))
    return ask(op, data, function(ok, payload)
        if ok then
            note_result(rid, true, i18n.t("ui.form.done"))
        else
            note_result(rid, false, i18n.error_text(payload))
        end
        if cb then cb(ok, payload) end
    end)
end

-- a request whose outcome is printed under `rid` (the quick actions, the config editors)
function M.act(rid, op, data, cb)
    note_result(rid, nil, i18n.t("ui.form.sending"))
    return ask(op, data, function(ok, payload)
        if ok then
            note_result(rid, true, i18n.t("ui.form.done"))
        else
            note_result(rid, false, i18n.error_text(payload))
        end
        if cb then cb(ok, payload) end
    end)
end

local function set_players(list)
    if type(list) ~= "table" then return end
    table.sort(list, function(a, b) return (tonumber(a.pid) or 0) < (tonumber(b.pid) or 0) end)
    M.S.players = list
    M.S.players_at = bridge.now()
    local alive = {}
    for _, row in ipairs(list) do alive[row.pid] = true end
    for pid in pairs(M.S.details) do
        if not alive[pid] then M.S.details[pid] = nil end
    end
end

function M.load_players(cb)
    return ask("players.list", {}, function(ok, d)
        if ok and type(d) == "table" then set_players(d.players) end
        if cb then cb(ok, d) end
    end)
end

function M.subscribe(on, cb)
    if on == false then
        M.S.subscribed = false
        return ask("players.subscribe", { on = false }, cb)
    end
    return ask("players.subscribe", { on = true }, function(ok, d)
        if ok and type(d) == "table" then
            M.S.subscribed = true
            set_players(d.players)
        end
        if cb then cb(ok, d) end
    end)
end

function M.load_player(pid, cb)
    return ask("players.get", { pid = pid }, function(ok, d)
        if ok and type(d) == "table" and type(d.player) == "table" then
            M.S.details[d.player.pid] = d.player
            for i, row in ipairs(M.S.players) do
                if row.pid == d.player.pid then M.S.players[i] = d.player end
            end
        end
        if cb then cb(ok, d) end
    end)
end

function M.player_row(pid)
    for _, row in ipairs(M.S.players) do
        if row.pid == pid then return row end
    end
    return nil
end

local function set_groups(list, permissions)
    if type(list) ~= "table" then return end
    table.sort(list, function(a, b) return (tonumber(a.level) or 0) < (tonumber(b.level) or 0) end)
    M.S.groups = list
    if type(permissions) == "table" then M.S.permissions = permissions end
    M.S.groups_at = bridge.now()
end

function M.load_groups(cb)
    return ask("groups.list", {}, function(ok, d)
        if ok and type(d) == "table" then set_groups(d.groups, d.permissions) end
        if cb then cb(ok, d) end
    end)
end

function M.group_by_name(name)
    for _, g in ipairs(M.S.groups) do
        if g.name == name then return g end
    end
    return nil
end

function M.save_group(def, cb)
    return M.act("group:" .. tostring(def.name), "groups.save", { group = def }, function(ok, d)
        if ok then M.load_groups() end
        if cb then cb(ok, d) end
    end)
end

function M.delete_group(name, cb)
    return M.act("group:" .. tostring(name), "groups.delete", { name = name }, function(ok, d)
        if ok then M.load_groups() end
        if cb then cb(ok, d) end
    end)
end

function M.load_settings(cb)
    return ask("settings.list", {}, function(ok, d)
        if ok and type(d) == "table" and type(d.settings) == "table" then
            M.S.settings = d.settings
            M.S.settings_at = bridge.now()
        end
        if cb then cb(ok, d) end
    end)
end

local function apply_setting(key, value)
    for _, s in ipairs(M.S.settings) do
        if s.key == key then
            s.value = value
            s.overridden = value ~= s.default
        end
    end
end

function M.setting(key)
    for _, s in ipairs(M.S.settings) do
        if s.key == key then return s end
    end
    return nil
end

function M.set_setting(key, value, cb)
    return M.act("setting:" .. key, "settings.set", { key = key, value = value }, function(ok, d)
        if ok and type(d) == "table" then apply_setting(d.key, d.value) end
        if cb then cb(ok, d) end
    end)
end

function M.reset_setting(key, cb)
    return M.act("setting:" .. key, "settings.reset", { key = key }, function(ok, d)
        if ok and type(d) == "table" then apply_setting(d.key, d.value) end
        if cb then cb(ok, d) end
    end)
end

function M.load_bans(cb)
    return ask("mod.bans", {}, function(ok, d)
        if ok and type(d) == "table" and type(d.bans) == "table" then
            M.S.bans = d.bans
            M.S.bans_at = bridge.now()
        end
        if cb then cb(ok, d) end
    end)
end

function M.unban(key, cb)
    return M.act("unban:" .. key, "mod.unban", { key = key }, function(ok, d)
        if ok then
            for i = #M.S.bans, 1, -1 do
                if M.S.bans[i].key == key then table.remove(M.S.bans, i) end
            end
            M.clear_result("unban:" .. key)
        end
        if cb then cb(ok, d) end
    end)
end

function M.load_mutes(cb)
    return ask("mod.mutes", {}, function(ok, d)
        if ok and type(d) == "table" and type(d.mutes) == "table" then
            M.S.mutes = d.mutes
            M.S.mutes_at = bridge.now()
        end
        if cb then cb(ok, d) end
    end)
end

function M.unmute_key(key, cb)
    return M.act("unmute:" .. key, "mod.unmute", { key = key }, function(ok, d)
        if ok then
            for i = #M.S.mutes, 1, -1 do
                if M.S.mutes[i].key == key then table.remove(M.S.mutes, i) end
            end
            M.clear_result("unmute:" .. key)
        end
        if cb then cb(ok, d) end
    end)
end

function M.load_whitelist(cb)
    return ask("whitelist.list", {}, function(ok, d)
        if ok and type(d) == "table" and type(d.entries) == "table" then
            M.S.whitelist.entries = d.entries
            M.S.whitelist.enabled = d.enabled == true
            M.S.whitelist.at = bridge.now()
        end
        if cb then cb(ok, d) end
    end)
end

function M.whitelist_add(entry, cb)
    return M.act("whitelist:add", "whitelist.add", { entry = entry }, function(ok, d)
        if ok then M.load_whitelist() end
        if cb then cb(ok, d) end
    end)
end

function M.whitelist_remove(entry, cb)
    return M.act("whitelist:" .. tostring(entry), "whitelist.remove", { entry = entry }, function(ok, d)
        if ok then
            for i = #M.S.whitelist.entries, 1, -1 do
                if M.S.whitelist.entries[i].entry == entry then table.remove(M.S.whitelist.entries, i) end
            end
            M.clear_result("whitelist:" .. tostring(entry))
        end
        if cb then cb(ok, d) end
    end)
end

function M.whitelist_enable(on, cb)
    return M.act("whitelist:enable", "whitelist.enable", { on = on == true }, function(ok, d)
        if ok and type(d) == "table" then
            M.S.whitelist.enabled = d.enabled == true
            M.S.status.whitelist = d.enabled == true
        end
        if cb then cb(ok, d) end
    end)
end

function M.announce(text, cb)
    return M.act("announce", "server.announce", { text = text }, cb)
end

function M.load_audit(limit, cb)
    limit = math.floor(tonumber(limit) or M.AUDIT_DEFAULT)
    if limit < 1 then limit = 1 end
    if limit > 200 then limit = 200 end
    return ask("audit.tail", { limit = limit }, function(ok, d)
        if ok and type(d) == "table" and type(d.rows) == "table" then
            M.S.audit = d.rows
            M.S.audit_at = bridge.now()
        end
        if cb then cb(ok, d) end
    end)
end

function M.vote(yes, cb)
    return ask("vote.cast", { yes = yes == true }, function(ok, d)
        if ok then
            M.S.vote_last = { text = i18n.t("ui.vote.voted"), at = bridge.now() }
        else
            M.S.vote_last = { text = i18n.error_text(d), at = bridge.now() }
        end
        if cb then cb(ok, d) end
    end)
end

function M.vote_cancel(cb)
    return ask("vote.cancel", {}, function(ok, d)
        if not ok then M.S.vote_last = { text = i18n.error_text(d), at = bridge.now() } end
        if cb then cb(ok, d) end
    end)
end

function M.set_lang(lang, cb)
    return ask("me.lang", { lang = lang }, function(ok, d)
        if ok and type(d) == "table" and d.lang then
            M.S.lang = i18n.set_lang(d.lang)
        end
        if cb then cb(ok, d) end
    end)
end

-- the player's own panel state ----------------------------------------------

function M.clamp_scale(v)
    local n = tonumber(v)
    if n == nil or n ~= n then return 1.0 end
    if n < M.SCALE_MIN then n = M.SCALE_MIN end
    if n > M.SCALE_MAX then n = M.SCALE_MAX end
    return math.floor(n * 100 + 0.5) / 100
end

local function apply_ui(ui)
    if type(ui) ~= "table" then return end
    local s = M.S.ui
    if type(ui.shown) == "boolean" then s.shown = ui.shown end
    if ui.scale ~= nil then s.scale = M.clamp_scale(ui.scale) end
    if type(ui.theme) == "string" then s.theme = ui.theme end
end

-- fields: { shown = bool } and/or { scale = number }; applied locally at once,
-- the server's answer (clamped, persisted) wins when it comes
function M.set_ui(fields, cb)
    if type(fields) ~= "table" then return nil end
    local data = {}
    if type(fields.shown) == "boolean" then data.shown = fields.shown end
    if fields.scale ~= nil then data.scale = M.clamp_scale(fields.scale) end
    if data.shown == nil and data.scale == nil then return nil end
    apply_ui(data)
    if M.S.session == nil then return nil end
    return ask("ui.set", data, function(ok, d)
        if ok and type(d) == "table" then apply_ui(d.ui) end
        if cb then cb(ok, d) end
    end)
end

-- the client mod's view of the world ------------------------------------------

local function sdk()
    local s = rawget(_G, "NodeMP")
    if type(s) ~= "table" then return nil end
    return s
end

function M.strict_active()
    local s = sdk()
    if s == nil or type(s.strict) ~= "table" or type(s.strict.isActive) ~= "function" then return false end
    local ok, v = pcall(s.strict.isActive)
    return ok and v == true
end

-- the vehicles the client mod knows for a player: { vid, gid, jbeam }, sorted by vid
function M.vehicles_of(pid)
    local s = sdk()
    if s == nil or type(s.vehicles) ~= "table" or type(s.vehicles.getAll) ~= "function" then return {} end
    local ok, all = pcall(s.vehicles.getAll)
    if not ok or type(all) ~= "table" then return {} end
    local out = {}
    for vid, v in pairs(all) do
        if type(v) == "table" and tonumber(v.spawnerID) == tonumber(pid) and v.isDeleted ~= true then
            out[#out + 1] = {
                vid = tonumber(v.serverVehicleID or v.vehicleId or vid) or 0, gid = v.gameVehicleID,
                jbeam = v.jbeam or "?",
            }
        end
    end
    table.sort(out, function(a, b) return a.vid < b.vid end)
    return out
end

function M.focus_available()
    local s = sdk()
    local be = rawget(_G, "be")
    return s ~= nil and type(s.vehicles) == "table" and type(s.vehicles.getAll) == "function"
        and (type(be) == "table" or type(be) == "userdata")
end

local focus_idx = {}   -- pid -> the vehicle shown last (Focus cycles through them)

-- the camera onto the next of the player's vehicles (the client mod seats the
-- viewer as a spectator: be:enterVehicle on a remote car, what NodeMP.debug.
-- focusOnPlayer does); refused in a strict session, as the mod refuses it
function M.focus(pid)
    if M.strict_active() then return false, "strict" end
    local list = M.vehicles_of(pid)
    if #list == 0 then return false, "no_vehicle" end
    local be = rawget(_G, "be")
    if be == nil then return false, "no_game" end
    local i = (focus_idx[pid] or 0) % #list + 1
    focus_idx[pid] = i
    local gid = list[i].gid
    local ok, veh = pcall(function() return be:getObjectByID(gid) end)
    if not ok or veh == nil then return false, "no_vehicle" end
    local okp = pcall(function() be:enterVehicle(0, veh) end)
    if not okp then return false, "no_game" end
    return true
end

-- the hello record and the events -------------------------------------------

local function set_vote(vote)
    if type(vote) == "table" and vote.id ~= nil then
        M.S.vote = vote
        M.S.vote_deadline = bridge.now() + (tonumber(vote.seconds_left) or 0)
    else
        M.S.vote = nil
        M.S.vote_deadline = nil
    end
end

function M.vote_seconds_left()
    if M.S.vote == nil or M.S.vote_deadline == nil then return 0 end
    return math.max(0, math.floor(M.S.vote_deadline - bridge.now() + 0.5))
end

local function set_status(st)
    if type(st) ~= "table" then return end
    for k, v in pairs(st) do M.S.status[k] = v end
    if type(st.theme) == "string" then M.S.ui.theme = st.theme end
    if st.whitelist ~= nil then M.S.whitelist.enabled = st.whitelist == true end
end

function M.apply_session(rec)
    if type(rec) ~= "table" then return end
    local s = M.S
    s.session = rec
    s.me = type(rec.me) == "table" and rec.me or nil
    s.perms = type(rec.perms) == "table" and rec.perms or {}
    s.lang = i18n.set_lang(rec.lang)
    s.version = rec.version
    s.default_group = type(rec.default_group) == "string" and rec.default_group or "default"
    s.permissions = type(rec.permissions) == "table" and rec.permissions or s.permissions
    s.server = type(rec.server) == "table" and rec.server or {}
    apply_ui(rec.ui)
    set_status(rec.status)
    set_vote(rec.vote)
    if M.has("players.view") and not s.subscribed then M.subscribe(true) end
    -- the group picker of the players tab and the groups editor need the groups before the tab is visited
    M.load_groups()
end

local function push_notice(data)
    if type(data) ~= "table" or type(data.text) ~= "string" then return end
    local list = M.S.notices
    list[#list + 1] = { text = data.text, code = data.code, at = bridge.now() }
    while #list > M.NOTICES_MAX do table.remove(list, 1) end
end

function M.on_event(ev, data)
    if ev == "players.changed" and type(data) == "table" then
        set_players(data.players)
    elseif ev == "groups.changed" and type(data) == "table" then
        set_groups(data.groups)
    elseif ev == "settings.changed" and type(data) == "table" and data.key ~= nil then
        apply_setting(data.key, data.value)
        if data.key == "ui.theme" and type(data.value) == "string" then M.S.ui.theme = data.value end
        if data.key == "whitelist.enabled" then M.S.status.whitelist = data.value == true end
        if data.key == "spawn.enabled" then M.S.status.spawn = data.value == true end
        if data.key == "allow_guests" then M.S.status.guests = data.value == true end
        if data.key == "votekick.enabled" then M.S.status.votekick = data.value == true end
    elseif ev == "status" then
        set_status(data)
    elseif ev == "vote.state" and type(data) == "table" then
        local v = data.vote
        local event = data.event
        if event == "passed" or event == "failed" or event == "cancelled" then
            local target = type(v) == "table" and type(v.target) == "table" and v.target.name or "?"
            M.S.vote_last = { text = i18n.t("ui.vote." .. event, { target = target }), at = bridge.now() }
            set_vote(nil)
        else
            set_vote(v)
        end
    elseif ev == "notice" then
        push_notice(data)
    end
end

-- leaving the server takes everything with it
function M.disconnected()
    M.reset()
end

bridge.on("session", function(rec) M.apply_session(rec) end)
bridge.on("event", function(msg) M.on_event(msg.ev, msg.data) end)
bridge.on("connected", function(up) if not up then M.disconnected() end end)

return M
