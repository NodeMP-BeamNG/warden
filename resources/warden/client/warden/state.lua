-- warden/state: what the panel knows and what it may ask -- the model behind
-- warden/panel.lua, with no imgui in it so the tests can drive it.
--
-- Everything here is a convenience for the drawing code: the permission and
-- rank checks only decide which buttons to show. The server runs its own
-- (commands.registry) on every wd:req and answers with an error the panel
-- prints; nothing the client believes about itself grants anything.
--
--   state.S                      the model: session, me, perms, players, groups, permissions,
--                                settings, bans, audit, vote, notices, busy, results
--   state.ACTIONS / TABS / DURATIONS
--   state.has(perm)              the actor's effective perms include perm ("*" and "mod.*" wildcards)
--   state.tab_allowed(tab)
--   state.can_target(row, action) -> bool, why   the rank rule the server applies, for greying
--   state.build(action, target, fields) -> op, data | nil, bad_field
--   state.parse_duration("2h") -> seconds | nil
--   state.run(action, target, fields, cb)        one wd:req for a row action
--   state.load_players / subscribe / load_groups / load_settings / set_setting / reset_setting
--   state.load_bans / unban / load_audit / vote / vote_cancel / set_lang
--   state.on_event(ev, data)     the wd:event dispatch (bridge wires it)
--   state.reset()                back to nothing known (leaving the server; the tests)

local bridge = require("warden/bridge")
local i18n = require("warden/i18n")

local M = {}

M.ACTIONS = {
    { id = "kick", op = "mod.kick", perm = "mod.kick", rank = true, fields = { "reason" }, label = "ui.action.kick" },
    { id = "warn", op = "mod.warn", perm = "mod.warn", rank = true, fields = { "reason" }, required = { "reason" },
        label = "ui.action.warn" },
    { id = "mute", op = "mod.mute", perm = "mod.mute", rank = true, fields = { "duration", "reason" },
        label = "ui.action.mute" },
    { id = "unmute", op = "mod.unmute", perm = "mod.mute", rank = false, fields = {}, label = "ui.action.unmute" },
    { id = "tempban", op = "mod.tempban", perm = "mod.tempban", rank = true, fields = { "duration", "reason" },
        required = { "duration" }, label = "ui.action.tempban" },
    { id = "ban", op = "mod.ban", perm = "mod.ban", rank = true, fields = { "reason" }, label = "ui.action.ban" },
    { id = "group", op = "groups.set", perm = "perms.set", rank = true, fields = { "group" }, required = { "group" },
        label = "ui.action.group" },
    { id = "cars", op = "car.delete", perm = "car.delete", rank = true, self = true, fields = {},
        label = "ui.action.cars" },
    { id = "whitelist", op = "whitelist.add", perm = "mod.whitelist", rank = false, self = true, fields = {},
        label = "ui.action.whitelist" },
    { id = "votekick", op = "vote.start", perm = "votekick.start", rank = false, fields = { "reason" },
        label = "ui.action.votekick" },
}

M.TABS = {
    { id = "players", perm = "players.view", label = "ui.tab.players" },
    { id = "groups", perm = nil, label = "ui.tab.groups" },
    { id = "settings", perm = "settings.read", label = "ui.tab.settings" },
    { id = "audit", perm = "audit.view", label = "ui.tab.audit" },
    { id = "bans", perm = "mod.ban", label = "ui.tab.bans" },
}

M.DURATIONS = {
    { label = "30m", sec = 1800 }, { label = "2h", sec = 7200 }, { label = "1d", sec = 86400 },
    { label = "7d", sec = 604800 }, { label = "ui.field.custom", sec = nil },
}

M.NOTICES_MAX = 8
M.AUDIT_DEFAULT = 30

local function fresh()
    return {
        session = nil, me = nil, perms = {}, lang = "en", key = "F9", version = nil,
        players = {}, players_at = nil, subscribed = false,
        groups = {}, permissions = {}, groups_at = nil,
        settings = {}, settings_at = nil,
        bans = {}, bans_at = nil,
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

function M.tab_allowed(tab)
    if tab.perm == nil then return true end
    return M.has(tab.perm)
end

function M.action_by_id(id)
    for _, a in ipairs(M.ACTIONS) do
        if a.id == id then return a end
    end
    return nil
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
    if action.op == "whitelist.add" then
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

function M.run(action, target, fields, cb)
    local op, data = M.build(action, target, fields)
    if op == nil then
        local err = { code = "bad_arg", params = { field = data } }
        note_result(action.id, false, i18n.error_text(err))
        if cb then cb(false, err) end
        return nil, data
    end
    note_result(action.id, nil, i18n.t("ui.form.sending"))
    return ask(op, data, function(ok, payload)
        if ok then
            note_result(action.id, true, i18n.t("ui.form.done"))
        else
            note_result(action.id, false, i18n.error_text(payload))
        end
        if cb then cb(ok, payload) end
    end)
end

local function set_players(list)
    if type(list) ~= "table" then return end
    table.sort(list, function(a, b) return (tonumber(a.pid) or 0) < (tonumber(b.pid) or 0) end)
    M.S.players = list
    M.S.players_at = bridge.now()
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
            for i, row in ipairs(M.S.players) do
                if row.pid == d.player.pid then M.S.players[i] = d.player end
            end
        end
        if cb then cb(ok, d) end
    end)
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

function M.set_setting(key, value, cb)
    note_result("setting:" .. key, nil, i18n.t("ui.form.sending"))
    return ask("settings.set", { key = key, value = value }, function(ok, d)
        if ok and type(d) == "table" then
            apply_setting(d.key, d.value)
            note_result("setting:" .. key, true, i18n.t("ui.form.done"))
        else
            note_result("setting:" .. key, false, i18n.error_text(d))
        end
        if cb then cb(ok, d) end
    end)
end

function M.reset_setting(key, cb)
    return ask("settings.reset", { key = key }, function(ok, d)
        if ok and type(d) == "table" then
            apply_setting(d.key, d.value)
            note_result("setting:" .. key, true, i18n.t("ui.form.done"))
        else
            note_result("setting:" .. key, false, i18n.error_text(d))
        end
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
    note_result("unban:" .. key, nil, i18n.t("ui.form.sending"))
    return ask("mod.unban", { key = key }, function(ok, d)
        if ok then
            for i = #M.S.bans, 1, -1 do
                if M.S.bans[i].key == key then table.remove(M.S.bans, i) end
            end
            M.clear_result("unban:" .. key)
        else
            note_result("unban:" .. key, false, i18n.error_text(d))
        end
        if cb then cb(ok, d) end
    end)
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

function M.apply_session(rec)
    if type(rec) ~= "table" then return end
    local s = M.S
    s.session = rec
    s.me = type(rec.me) == "table" and rec.me or nil
    s.perms = type(rec.perms) == "table" and rec.perms or {}
    s.lang = i18n.set_lang(rec.lang)
    s.key = type(rec.key) == "string" and rec.key or "F9"
    s.version = rec.version
    s.permissions = type(rec.permissions) == "table" and rec.permissions or s.permissions
    set_vote(rec.vote)
    if M.has("players.view") and not s.subscribed then M.subscribe(true) end
    -- the group picker of the players tab needs the groups before the tab is visited
    if M.has("perms.set") then M.load_groups() end
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
    local key = M.S.key
    M.reset()
    M.S.key = key
end

bridge.on("session", function(rec) M.apply_session(rec) end)
bridge.on("event", function(msg) M.on_event(msg.ev, msg.data) end)
bridge.on("connected", function(up) if not up then M.disconnected() end end)

return M
