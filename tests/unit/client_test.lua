-- The streamed client files against the fake game (stubs/game.lua): the
-- hello and the record, every tab drawn from a sample state, the exact
-- wd:req frames the buttons send, the replies and events that update the
-- model, the actions the permissions and the rank rule grey out, and the
-- toggle (the key the server names, /wd's wd:event panel, the global).

local game = require("game")

local ADMIN_PERMS = {
    "players.view", "mod.kick", "mod.ban", "mod.tempban", "mod.mute", "mod.warn", "mod.whitelist", "car.delete",
    "perms.set", "settings.read", "settings.write", "audit.view", "votekick.start", "votekick.vote",
    "votekick.cancel", "server.announce",
}
local MOD_PERMS = {
    "players.view", "mod.kick", "mod.tempban", "mod.mute", "mod.warn", "car.delete", "audit.view",
    "votekick.cancel", "votekick.vote", "votekick.start",
}

local function record(perms, me)
    return {
        protocol = 1, version = "0.1.0-test", lang = "en", key = "F9",
        me = me or { pid = 1, name = "Adm", group = "admin", level = 90, key = "acct:1" },
        perms = perms or ADMIN_PERMS,
        permissions = { { "players.view", "See the player list" }, { "mod.kick", "Kick a player" } },
    }
end

local function players()
    return {
        { pid = 1, name = "Adm", group = "admin", level = 90, vehicles = 1, ping = 0.031, connected = 125, guest = false,
            verified = true },
        { pid = 2, name = "Bob", group = "default", level = 0, vehicles = 2, ping = 0.05, connected = 61, guest = true,
            verified = false },
        { pid = 3, name = "Carl", group = "owner", level = 100, vehicles = 0, ping = 0.02, connected = 9000, guest = false,
            verified = true },
    }
end

local GROUPS = {
    { name = "default", level = 0, inherits = {}, perms = { "votekick.vote" }, caps = { vehicles = 1 } },
    { name = "mod", level = 50, inherits = { "default" }, perms = { "players.view", "mod.kick" }, caps = { vehicles = 5 } },
    { name = "admin", level = 90, inherits = { "mod" }, perms = { "mod.ban" }, caps = { vehicles = -1 } },
    { name = "owner", level = 100, inherits = { "admin" }, perms = { "*" }, caps = { vehicles = -1 } },
}

local SETTINGS = {
    { key = "language", value = "en", default = "en", type = "string", enum = { "en", "ru" }, overridden = false },
    { key = "allow_guests", value = true, default = true, type = "bool", overridden = false },
    { key = "votekick.threshold", value = 0.6, default = 0.6, type = "number", min = 0.5, max = 1.0, overridden = false },
    { key = "votekick.min_players", value = 4, default = 4, type = "int", min = 2, max = 200, overridden = false },
    { key = "votekick.window_sec", value = 90, default = 60, type = "int", min = 15, max = 600, overridden = true },
}

local BANS = {
    { key = "acct:9", who = 9, name = "Zed", reason = "cheats", by = "Adm", at = 1700000000, ["until"] = 1700003600 },
    { key = "ip:10.0.0.7", who = "10.0.0.7", name = "Yan", reason = "spam", by = "Adm", at = 1699990000 },
}

local AUDIT = {
    { seq = 1, ts = 1700000000, at = "2023-11-14T22:13:20Z", actor = { name = "Adm", key = "acct:1" }, op = "kick",
        target = { name = "Bob" }, result = "ok" },
    { seq = 2, ts = 1700000060, at = "2023-11-14T22:14:20Z", actor = { name = "Bob", key = "ip:1" }, op = "ban",
        target = { name = "Adm" }, result = "denied", reason = "denied" },
}

-- a session with the panel open: the hello answered, the subscription answered with the players
local function boot(rec)
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    game.session(rec or record())
    local sub = game.last_frame("players.subscribe")
    if sub then game.reply(sub.id, true, { on = true, players = players() }) end
    local gl = game.last_frame("groups.list")
    if gl then game.reply(gl.id, true, { groups = GROUPS, permissions = {} }) end
    G.panel.open()
    G.im.frame()
    return G
end

local function has_text(G, needle)
    for _, s in ipairs(G.im.shown()) do
        if s:find(needle, 1, true) then return true end
    end
    return false
end

local function shown_text(G)
    return table.concat(G.im.shown(), " | ")
end

-- opens a tab and answers the request it sends with `data`
local function visit(G, tab, op, data)
    G.im.tab = tab
    G.im.frame()
    local f = game.last_frame(op)
    t.truthy(f, tab .. " asked " .. op)
    game.reply(f.id, true, data)
    G.im.frame()
    return f
end

local function select_player(G, pid)
    G.im.tab = "Players"
    G.im.click(tostring(pid))
    G.im.frame()
    local get = game.last_frame("players.get")
    t.eq(get.data, { pid = pid })
    return get
end

local tests = {}

-- the hello and the record ----------------------------------------------------

tests.hello_carries_the_protocol_and_the_record_sets_the_session = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    local frames = game.frames()
    t.eq(#frames, 1)
    t.eq(frames[1].op, "sys.hello")
    t.eq(frames[1].data.protocol, 1)
    t.eq(frames[1].data.uiVersion, G.bridge.VERSION)
    t.eq(frames[1].data.lang, "ru-RU", "the game's language travels with hello")
    game.session(record())
    t.eq(G.bridge.getState().connected, true)
    t.eq(G.state.S.me.group, "admin")
    t.eq(G.state.S.lang, "en", "the server's answer wins over the game's language")
    t.eq(G.i18n.lang(), "en")
    -- players.view -> the subscription goes out at once; perms.set -> the groups
    t.truthy(game.last_frame("players.subscribe"))
    t.eq(game.last_frame("players.subscribe").data, { on = true })
    t.truthy(game.last_frame("groups.list"))
    -- the retry after a timeout, and no retry once the server says ui_outdated
    G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    G.im.frame(G.bridge.TIMEOUT_S + 1)
    G.im.frame(G.bridge.HELLO_RETRY_S + 0.1)
    t.eq(#game.frames(), 2, "a hello that timed out is sent again")
    game.reply(game.frames()[2].id, false, { code = "ui_outdated", params = { server = 2, ui = 1 } })
    t.eq(G.bridge.getState().outdated, true)
    G.im.frame(60)
    t.eq(#game.frames(), 2, "no retry after ui_outdated")
    G.panel.open()
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "no session, no window")
end

-- (a) every tab renders from a sample state -----------------------------------

tests.players_tab_renders_the_list_and_the_card = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.frame()
    t.truthy(has_text(G, "3 online"))
    t.truthy(has_text(G, "Bob"), shown_text(G))
    t.truthy(has_text(G, "Adm (you)"))
    t.truthy(has_text(G, "owner (100)"))
    t.truthy(has_text(G, "50 ms"), "ping in ms")
    t.truthy(has_text(G, "1m 1s"), "connected time")
    t.truthy(has_text(G, "Select a player"))
    -- a row selected: the full record is asked and shown
    local get = select_player(G, 2)
    game.reply(get.id, true, { player = { pid = 2, name = "Bob", group = "default", level = 0, vehicles = 2, guest = true,
        key = "ip:10.0.0.2", ip = "10.0.0.2", joins = 3, warns = { { reason = "x" } }, cap = 1,
        mute = { ["until"] = 1700003600 }, names = { "Bob", "Bobby" } } })
    G.im.frame()
    t.truthy(has_text(G, "ip:10.0.0.2"), shown_text(G))
    t.truthy(has_text(G, "Joins: 3"))
    t.truthy(has_text(G, "Warnings: 1"))
    t.truthy(has_text(G, "Bob, Bobby"))
    t.truthy(G.im.buttons()["Kick"], "the action bar")
    -- the player leaves: the selection goes
    game.event("players.changed", { players = { players()[1] } })
    G.im.frame()
    t.falsy(has_text(G, "ip:10.0.0.2"))
    t.truthy(has_text(G, "1 online"))
end

tests.groups_tab_renders = function()
    local G = boot()
    G.im.tab = "Groups"
    G.im.frame()
    t.truthy(has_text(G, "mod"), shown_text(G))
    t.truthy(has_text(G, "players.view mod.kick"))
    t.truthy(has_text(G, "unlimited"))
    t.truthy(has_text(G, "Read-only"))
    -- refresh asks again and the answer replaces the list
    G.im.click("Refresh")
    G.im.frame()
    local f = game.last_frame("groups.list")
    game.reply(f.id, true, { groups = { { name = "default", level = 0, inherits = {}, perms = {}, caps = {} } } })
    G.im.frame()
    t.falsy(has_text(G, "owner"))
end

tests.settings_tab_renders_typed_rows = function()
    local G = boot()
    visit(G, "Settings", "settings.list", { settings = SETTINGS })
    t.truthy(has_text(G, "votekick.threshold"), shown_text(G))
    t.truthy(has_text(G, "votekick.window_sec *"), "an overridden key is marked")
    local calls = {}
    for _, c in ipairs(G.im.calls) do calls[c[1]] = (calls[c[1]] or 0) + 1 end
    t.eq(calls.Checkbox, 1, "bool -> checkbox")
    t.eq(calls.InputInt, 2, "int -> InputInt")
    t.eq(calls.InputFloat, 1, "number -> InputFloat")
    t.eq(calls.Combo1, 2, "enum -> combo, plus the language picker")
    t.truthy(G.im.buttons()["s:votekick.window_sec/Reset"], "reset only where overridden")
    t.falsy(G.im.buttons()["s:votekick.min_players/Reset"])
end

tests.audit_and_bans_tabs_render = function()
    local G = boot()
    local f = visit(G, "Audit", "audit.tail", { rows = AUDIT })
    t.eq(f.data, { limit = 30 })
    t.truthy(has_text(G, "kick"), shown_text(G))
    t.truthy(has_text(G, "denied"))
    t.truthy(has_text(G, "2023-11-14T22:14:20Z"))
    visit(G, "Bans", "mod.bans", { bans = BANS })
    t.truthy(has_text(G, "acct:9"), shown_text(G))
    t.truthy(has_text(G, "permanent"))
    t.truthy(has_text(G, "2 ban(s)"))
    t.truthy(G.im.buttons()["b:acct:9/Unban"])
end

tests.all_tabs_render_from_an_empty_state_without_errors = function()
    local G = boot()
    game.event("players.changed", { players = {} })
    for _, tab in ipairs({ "Players", "Groups", "Settings", "Audit", "Bans" }) do
        G.im.tab = tab
        G.im.frame()
        local f = game.last_frame()
        if f and f.op ~= "players.subscribe" then game.reply(f.id, true, {}) end
        G.im.frame()
    end
    t.truthy(has_text(G, "No bans."))
end

-- (b) the buttons send the exact frames -----------------------------------------

tests.kick_with_a_reason = function()
    local G = boot()
    select_player(G, 2)
    G.im.click("Kick")
    G.im.frame()
    t.truthy(has_text(G, "Kick: Bob"), "the inline form")
    G.im.type("##reason", "spam")
    G.im.click("Confirm")
    G.im.frame()
    local f = game.last_frame("mod.kick")
    t.eq(f.data, { pid = 2, reason = "spam" })
    t.truthy(has_text(G, "Sending..."))
    game.reply(f.id, true, { target = { pid = 2 } })
    G.im.frame()
    t.truthy(has_text(G, "Done."), shown_text(G))
    t.falsy(has_text(G, "Kick: Bob"), "the form closes on success")
end

tests.tempban_duration_from_the_combo_and_custom = function()
    local G = boot()
    select_player(G, 2)
    G.im.click("Temp-ban")
    G.im.frame()
    G.im.pick("##duration", 1)
    G.im.type("##reason", "  cheats ")
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.tempban").data, { pid = 2, duration = 7200, reason = "cheats" })
    G.im.frame()
    t.eq(G.im.buttons()["Confirm"].disabled, true, "the form waits for the answer")
    game.reply(game.last_frame("mod.tempban").id, true, {})
    -- the custom entry: typed text, parsed; a bad one is refused before it is sent
    G.im.click("Temp-ban")
    G.im.frame()
    G.im.pick("##duration", 4)
    G.im.frame()
    G.im.type("##custom", "3h")
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.tempban").data, { pid = 2, duration = 10800 })
    game.reply(game.last_frame("mod.tempban").id, true, {})
    local n = #game.frames()
    G.im.click("Temp-ban")
    G.im.frame()
    G.im.pick("##duration", 4)
    G.im.frame()
    G.im.type("##custom", "soon")
    G.im.click("Confirm")
    G.im.frame()
    t.eq(#game.frames(), n, "nothing sent for a bad duration")
    t.truthy(has_text(G, "Bad value for duration"), shown_text(G))
end

tests.mute_warn_ban_group_cars_whitelist_votekick = function()
    local G = boot()
    select_player(G, 2)
    G.im.click("Mute")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.mute").data, { pid = 2, duration = 1800 }, "the first duration is the default")
    G.im.click("Unmute")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.unmute").data, { pid = 2 })
    -- warn needs a reason
    local n = #game.frames()
    G.im.click("Warn")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(#game.frames(), n, "no warn without a reason")
    t.truthy(has_text(G, "Bad value for reason"))
    G.im.type("##reason", "language")
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.warn").data, { pid = 2, reason = "language" })
    G.im.click("Ban")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("mod.ban").data, { pid = 2 })
    -- the group picker offers only the groups below the actor's level
    G.im.click("Set group")
    G.im.frame()
    local combo
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Combo1" and c[2] == "##group" then combo = c end
    end
    t.eq(combo[3], { "default (0)", "mod (50)" })
    G.im.pick("##group", 1)
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("groups.set").data, { pid = 2, group = "mod" })
    G.im.click("Delete cars")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("car.delete").data, { pid = 2 })
    G.im.click("Whitelist")
    G.im.frame()
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("whitelist.add").data, { entry = "#2" })
    G.im.click("Vote-kick")
    G.im.frame()
    G.im.type("##reason", "ramming")
    G.im.click("Confirm")
    G.im.frame()
    t.eq(game.last_frame("vote.start").data, { pid = 2, reason = "ramming" })
    -- a refusal is printed where the form was
    local f = game.last_frame("vote.start")
    game.reply(f.id, false, { code = "vote.too_few", params = { min = 4 } })
    G.im.frame()
    t.truthy(has_text(G, "A vote needs at least 4 players"), shown_text(G))
end

tests.settings_set_and_reset = function()
    local G = boot()
    visit(G, "Settings", "settings.list", { settings = SETTINGS })
    G.im.check("s:allow_guests/##v", false)
    G.im.frame()
    local f = game.last_frame("settings.set")
    t.eq(f.data, { key = "allow_guests", value = false }, "a checkbox sets at once")
    G.im.int("s:votekick.min_players/##v", 6)
    G.im.click("s:votekick.min_players/Set")
    G.im.frame()
    t.eq(G.im.buttons()["s:votekick.min_players/Set"].disabled, true, "one settings.set at a time")
    game.reply(f.id, true, { key = "allow_guests", value = false })
    G.im.click("s:votekick.min_players/Set")
    G.im.frame()
    f = game.last_frame("settings.set")
    t.eq(f.data, { key = "votekick.min_players", value = 6 })
    game.reply(f.id, true, { key = "votekick.min_players", value = 6 })
    G.im.frame()
    t.eq(G.state.S.settings[4].value, 6)
    t.eq(G.state.S.settings[4].overridden, true)
    t.truthy(has_text(G, "votekick.min_players *"))
    G.im.float("s:votekick.threshold/##v", 0.75)
    G.im.click("s:votekick.threshold/Set")
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "votekick.threshold", value = 0.75 })
    game.reply(game.last_frame("settings.set").id, true, { key = "votekick.threshold", value = 0.75 })
    G.im.pick("s:language/##v", 1)
    G.im.click("s:language/Set")
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "language", value = "ru" })
    G.im.click("s:votekick.window_sec/Reset")
    G.im.frame()
    f = game.last_frame("settings.reset")
    t.eq(f.data, { key = "votekick.window_sec" })
    game.reply(f.id, false, { code = "denied", params = { perm = "settings.write" } })
    G.im.frame()
    t.truthy(has_text(G, "You may not do that (settings.write)"), shown_text(G))
end

tests.unban_audit_limit_vote_and_language = function()
    local G = boot()
    visit(G, "Bans", "mod.bans", { bans = BANS })
    G.im.click("b:acct:9/Unban")
    G.im.frame()
    local f = game.last_frame("mod.unban")
    t.eq(f.data, { key = "acct:9" })
    game.reply(f.id, true, {})
    G.im.frame()
    t.falsy(has_text(G, "acct:9"), "the row goes on success")
    t.truthy(has_text(G, "1 ban(s)"))
    visit(G, "Audit", "audit.tail", { rows = AUDIT })
    G.im.int("##n", 50)
    G.im.click("Refresh")
    G.im.frame()
    t.eq(game.last_frame("audit.tail").data, { limit = 50 })
    -- the banner: yes / no / cancel
    game.event("vote.state", { event = "started", vote = { id = 7, target = { pid = 2, name = "Bob" },
        starter = { pid = 3, name = "Carl" }, reason = "ramming", yes = 1, no = 0, needed = 2, seconds_left = 45 } })
    G.im.frame()
    t.truthy(has_text(G, "Vote to kick Bob"), shown_text(G))
    t.truthy(has_text(G, "1 of 2 yes"))
    G.im.click("Yes")
    G.im.frame()
    t.eq(game.last_frame("vote.cast").data, { yes = true })
    game.reply(game.last_frame("vote.cast").id, true, { vote = { yes = 2 } })
    G.im.frame()
    t.truthy(has_text(G, "Your vote is in."), shown_text(G))
    G.im.click("No")
    G.im.frame()
    t.eq(game.last_frame("vote.cast").data, { yes = false })
    G.im.click("Cancel vote")
    G.im.frame()
    t.eq(game.last_frame("vote.cancel").op, "vote.cancel")
    -- the language picker: the server confirms, the labels switch
    G.im.pick("##lang", 1)
    G.im.frame()
    f = game.last_frame("me.lang")
    t.eq(f.data, { lang = "ru" })
    game.reply(f.id, true, { lang = "ru" })
    G.im.frame()
    t.eq(G.i18n.lang(), "ru")
    t.eq(G.im.tabs()[1], "Игроки")
    t.truthy(has_text(G, "F9 или /wd"), shown_text(G))
end

-- (c) replies and events update the model ---------------------------------------

tests.events_update_players_groups_settings_vote_and_notices = function()
    local G = boot()
    game.event("players.changed", { players = { { pid = 5, name = "Eve", group = "default", level = 0 } } })
    t.eq(#G.state.S.players, 1)
    t.eq(G.state.S.players[1].name, "Eve")
    game.event("groups.changed", { groups = { { name = "default", level = 0 }, { name = "vip", level = 20 } } })
    t.eq(#G.state.S.groups, 2)
    t.eq(G.state.S.groups[2].name, "vip", "sorted by level")
    visit(G, "Settings", "settings.list", { settings = SETTINGS })
    game.event("settings.changed", { key = "allow_guests", value = false })
    t.eq(G.state.S.settings[2].value, false)
    t.eq(G.state.S.settings[2].overridden, true)
    game.event("vote.state", { event = "started", vote = { id = 1, target = { pid = 5, name = "Eve" },
        starter = { pid = 1, name = "Adm" }, yes = 0, no = 0, needed = 3, seconds_left = 30 } })
    t.eq(G.state.S.vote.id, 1)
    t.eq(G.state.vote_seconds_left(), 30)
    G.im.frame(10)
    t.eq(G.state.vote_seconds_left(), 20, "the countdown runs on the client clock")
    game.event("vote.state", { event = "passed", vote = { id = 1, target = { pid = 5, name = "Eve" } } })
    t.eq(G.state.S.vote, nil)
    G.im.frame()
    t.truthy(has_text(G, "Vote passed: Eve was kicked."), shown_text(G))
    G.im.frame(9)
    t.falsy(has_text(G, "Vote passed"), "the outcome fades")
    game.event("notice", { text = "Kicked Bob: spam", code = "done.kick" })
    t.eq(#G.state.S.notices, 1)
    G.im.frame()
    t.truthy(has_text(G, "Kicked Bob: spam"))
    game.event("garbage", nil)
    G.im.frame()
    -- a reply nobody waits for, and a timeout
    game.reply(9999, true, {})
    G.state.load_players()
    G.im.frame(G.bridge.TIMEOUT_S + 1)
    t.eq(G.bridge.pendingCount(), 0)
    t.eq(G.state.is_busy("players.list"), false, "a timed-out request is not busy any more")
end

-- (d) what the permissions and the rank rule hide -------------------------------

tests.a_mod_sees_fewer_tabs_and_greyed_actions = function()
    local G = boot(record(MOD_PERMS, { pid = 1, name = "Modi", group = "mod", level = 50, key = "acct:1" }))
    G.im.frame()
    t.eq(G.im.tabs(), { "Players", "Groups", "Audit" }, "no Settings, no Bans")
    t.eq(game.last_frame("groups.list"), nil, "no perms.set: the groups are not fetched")
    select_player(G, 2)
    local b = G.im.buttons()
    t.eq(b["Kick"].disabled, false)
    t.eq(b["Temp-ban"].disabled, false)
    t.eq(b["Ban"].disabled, true, "no mod.ban")
    t.eq(b["Set group"].disabled, true, "no perms.set")
    t.eq(b["Whitelist"].disabled, true, "no mod.whitelist")
    t.eq(b["Vote-kick"].disabled, false)
    -- a click on a greyed button sends nothing
    local n = #game.frames()
    G.im.click("Ban")
    G.im.frame()
    t.eq(#game.frames(), n)
    -- the owner outranks a mod: only the actions without the rank rule stay
    select_player(G, 3)
    b = G.im.buttons()
    t.eq(b["Kick"].disabled, true, "outranked")
    t.eq(b["Delete cars"].disabled, true)
    t.eq(b["Unmute"].disabled, false, "no rank rule on unmute")
    t.eq(b["Vote-kick"].disabled, false)
    -- oneself: only the self actions
    select_player(G, 1)
    b = G.im.buttons()
    t.eq(b["Kick"].disabled, true)
    t.eq(b["Delete cars"].disabled, false, "own cars")
    t.eq(b["Vote-kick"].disabled, true, "not yourself")
    -- the vote banner without votekick.vote has no buttons
    local G2 = boot(record({ "players.view" }, { pid = 1, name = "Viewer", group = "default", level = 0 }))
    game.event("vote.state", { event = "started", vote = { id = 1, target = { pid = 2, name = "Bob" },
        starter = { pid = 3, name = "Carl" }, yes = 0, no = 0, needed = 2, seconds_left = 30 } })
    G2.im.frame()
    t.truthy(has_text(G2, "Vote to kick Bob"))
    t.eq(G2.im.buttons()["Yes"], nil)
    t.eq(G2.im.buttons()["Cancel vote"], nil)
end

tests.has_and_can_target_follow_the_wildcards_and_the_rank_rule = function()
    local G = game.load()
    local S = G.state
    S.S.perms = { "mod.*", "settings.read" }
    t.eq(S.has("mod.kick"), true)
    t.eq(S.has("settings.read"), true)
    t.eq(S.has("settings.write"), false)
    S.S.perms = { "*" }
    t.eq(S.has("anything.at.all"), true)
    S.S.me = { pid = 1, level = 50 }
    S.S.perms = { "mod.kick", "votekick.start", "car.delete" }
    local kick = S.action_by_id("kick")
    t.eq(S.can_target({ pid = 2, level = 10 }, kick), true)
    t.eq((S.can_target({ pid = 2, level = 50 }, kick)), false, "equal level")
    t.eq((S.can_target({ pid = 1, level = 50 }, kick)), false, "self")
    t.eq((S.can_target({ pid = 1, level = 50 }, S.action_by_id("cars"))), true, "own cars")
    t.eq((S.can_target({ pid = 1, level = 50 }, S.action_by_id("votekick"))), false)
    t.eq((S.can_target({ pid = 2, level = 90 }, S.action_by_id("votekick"))), true, "no rank rule")
    t.eq(S.parse_duration("45m"), 2700)
    t.eq(S.parse_duration("2d"), 172800)
    t.eq(S.parse_duration("15"), 900, "bare number: minutes")
    t.eq(S.parse_duration("x"), nil)
    t.eq(S.format_duration(3661), "1h 1m")
    t.eq(G.i18n.error_text({ code = "no_such_code" }), "no_such_code")
    t.eq(G.i18n.error_text({ code = "timeout" }), "The server did not answer.")
end

-- (e) the toggle -------------------------------------------------------------------

tests.toggle_by_key_event_and_global = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "no session yet: the key does nothing")
    game.session(record())
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), true)
    local begins = 0
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Begin" and tostring(c[2]):find("Warden", 1, true) then begins = begins + 1 end
    end
    t.eq(begins, 1, "the window is drawn")
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), false)
    G.im.frame()
    begins = 0
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Begin" then begins = begins + 1 end
    end
    t.eq(begins, 0, "closed: nothing drawn")
    -- /wd on the server: wd:event panel
    game.event("panel", { toggle = true })
    t.eq(G.panel.isOpen(), true)
    game.event("panel", { toggle = true })
    t.eq(G.panel.isOpen(), false)
    game.event("panel", { open = true })
    t.eq(G.panel.isOpen(), true)
    -- the global for the console, and the close box
    local g = G.env.nodemp_wd
    t.truthy(g)
    t.eq(g.toggle(), true)
    t.eq(g.isOpen(), false)
    t.eq(g.key(), "F9")
    g.open()
    G.im.frame()
    local begin
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Begin" and tostring(c[2]):find("Warden", 1, true) then begin = c end
    end
    begin[3][0] = false -- the X of the window
    G.im.frame()
    t.eq(G.panel.isOpen(), false)
    -- leaving the server closes it and forgets the session
    g.open()
    G.bridge.onExtensionUnloaded()
    t.eq(G.panel.isOpen(), false)
    t.eq(G.state.S.session, nil)
    t.eq(#G.state.S.players, 0)
end

tests.the_key_comes_from_the_server_and_a_toggle_before_hello_waits = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    t.eq(G.panel.open(), false, "no session: remembered")
    local rec = record()
    rec.key = "F7"
    game.session(rec)
    G.im.frame()
    t.eq(G.panel.isOpen(), true, "opened once the record arrived")
    t.eq(G.panel.key_name(), "F7")
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), true, "F9 is not the key now")
    G.im.press(G.im.Key_F7)
    G.im.frame()
    t.eq(G.panel.isOpen(), false)
    -- an unknown key name falls back to F9
    rec.key = "NoSuchKey"
    G.state.apply_session(rec)
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), true)
end

tests.a_drawing_error_is_logged_and_repeated_ones_close_the_panel = function()
    local G = boot()
    G.im.BeginTable = function() error("boom") end
    for _ = 1, G.panel.MAX_DRAW_ERRORS - 1 do
        G.panel.onUpdate(0.016)
    end
    t.eq(G.panel.isOpen(), true)
    local logged = 0
    for _, l in ipairs(game.logs) do
        if l.msg:find("panel draw failed", 1, true) then logged = logged + 1 end
    end
    t.eq(logged, G.panel.MAX_DRAW_ERRORS - 1)
    G.panel.onUpdate(0.016)
    t.eq(G.panel.isOpen(), false, "closed after MAX_DRAW_ERRORS in a row")
end

return tests
