-- The streamed client files against the fake game (stubs/game.lua): the
-- hello and the record (protocol 2: ui / server / status), the CEI-shaped
-- window (QuickInfo, scale, the four tabs, a collapsing header per player
-- with the button row and the tree nodes), the exact wd:req frames the
-- buttons send, the replies and events that update the model, the actions
-- the permissions and the rank rule grey out, the platform gaps greyed with
-- their issue numbers, and the toggle paths (/warden's wd:event panel, the
-- action's global, the window's X, the hello state) -- no key anywhere.

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

local function record(perms, me, extra)
    local rec = {
        protocol = 2, version = "0.2.0-test", lang = "en", default_group = "default",
        me = me or { pid = 1, name = "Adm", group = "admin", level = 90, key = "acct:1" },
        perms = perms or ADMIN_PERMS,
        permissions = { { "players.view", "See the player list" }, { "mod.kick", "Kick a player" } },
        ui = { shown = true, scale = 1.0, theme = "cobalt" },
        server = { name = "Test server", map = "gridmap", version = "1.4.1", max_players = 16, max_cars = 10 },
        status = { whitelist = false, spawn = true, guests = true, votekick = false, theme = "cobalt", players = 3,
            max_players = 16, cars = 3, max_cars = 10 },
    }
    for k, v in pairs(extra or {}) do rec[k] = v end
    return rec
end

local function players()
    return {
        { pid = 1, name = "Adm", group = "admin", level = 90, vehicles = 1, ping = 0.031, connected = 125, guest = false,
            verified = true, muted = false, whitelisted = false },
        { pid = 2, name = "Bob", group = "default", level = 0, vehicles = 2, ping = 0.05, connected = 61, guest = true,
            verified = false, muted = false, whitelisted = false },
        { pid = 3, name = "Carl", group = "owner", level = 100, vehicles = 0, ping = 0.02, connected = 9000, guest = false,
            verified = true, muted = false, whitelisted = true },
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
    { key = "spawn.enabled", value = true, default = true, type = "bool", overridden = false },
    { key = "ui.default_shown", value = true, default = true, type = "bool", overridden = false },
    { key = "ui.welcome", value = true, default = true, type = "bool", overridden = false },
    { key = "ui.theme", value = "cobalt", default = "cobalt", type = "string", enum = { "cobalt", "game" },
        overridden = false },
}

local BANS = {
    { key = "acct:9", who = 9, name = "Zed", reason = "cheats", by = "Adm", at = 1700000000, ["until"] = 1700003600 },
    { key = "ip:10.0.0.7", who = "10.0.0.7", name = "Yan", reason = "spam", by = "Adm", at = 1699990000 },
}

local MUTES = {
    { key = "acct:7", name = "Gus", reason = "caps", by = "Adm", at = 1700000000, ["until"] = 1700003600 },
}

local WHITELIST = {
    { entry = "acct:3", name = "Carl", by = "Adm", at = 1700000000 },
    { entry = "acct:9", name = "Zed", by = "Adm", at = 1700000000 },
}

local AUDIT = {
    { seq = 1, ts = 1700000000, at = "2023-11-14T22:13:20Z", actor = { name = "Adm", key = "acct:1" }, op = "kick",
        target = { name = "Bob" }, result = "ok" },
    { seq = 2, ts = 1700000060, at = "2023-11-14T22:14:20Z", actor = { name = "Bob", key = "ip:1" }, op = "ban",
        target = { name = "Adm" }, result = "denied", reason = "denied" },
}

-- answers every frame of that op that has no reply yet
local function answer_all(op, data)
    for _, f in ipairs(game.frames()) do
        if f.op == op and not game.answered[f.id] then
            game.answered[f.id] = true
            game.reply(f.id, true, data)
        end
    end
end

-- a session with the panel open: the hello answered (shown = true opens the window by itself),
-- the subscription and the groups answered
local function boot(rec)
    local G = game.load()
    game.answered = {}
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    game.session(rec or record())
    answer_all("players.subscribe", { on = true, players = players() })
    answer_all("groups.list", { groups = GROUPS, permissions = {} })
    G.im.frame()
    -- every header is open in the fake: each player's record was asked for
    answer_all("players.get", {})
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

local function frames_of(op)
    local out = {}
    for _, f in ipairs(game.frames()) do
        if f.op == op then out[#out + 1] = f end
    end
    return out
end

local function count_calls(G, name, needle)
    local n = 0
    for _, c in ipairs(G.im.calls) do
        if c[1] == name and (needle == nil or tostring(c[2]):find(needle, 1, true)) then n = n + 1 end
    end
    return n
end

local tests = {}

-- the hello and the record ----------------------------------------------------

tests.hello_carries_protocol_2_and_the_record_opens_the_window = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    local frames = game.frames()
    t.eq(#frames, 1)
    t.eq(frames[1].op, "sys.hello")
    t.eq(frames[1].data.protocol, 2)
    t.eq(frames[1].data.uiVersion, "0.2.0")
    t.eq(frames[1].data.lang, "ru-RU", "the game's language travels with hello")
    game.session(record())
    t.eq(G.bridge.getState().connected, true)
    t.eq(G.state.S.me.group, "admin")
    t.eq(G.state.S.lang, "en", "the server's answer wins over the game's language")
    t.eq(G.state.S.ui, { shown = true, scale = 1.0, theme = "cobalt" })
    t.eq(G.state.S.server.name, "Test server")
    t.eq(G.state.S.status.players, 3)
    t.eq(G.state.S.default_group, "default")
    t.eq(G.panel.isOpen(), true, "shown = true: the window is up without a click")
    t.eq(#frames_of("ui.set"), 0, "the server's own state is not echoed back")
    -- players.view -> the subscription goes out at once; the groups always (the editor, the picker)
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
    game.reply(game.frames()[2].id, false, { code = "ui_outdated", params = { server = 3, ui = 2 } })
    t.eq(G.bridge.getState().outdated, true)
    G.im.frame(60)
    t.eq(#game.frames(), 2, "no retry after ui_outdated")
    G.panel.open()
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "no session, no window")
end

-- (a) the window and every tab render from a sample state ----------------------

tests.quick_info_scale_row_and_the_players_tab = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.frame()
    -- the title, the QuickInfo bar and the chips
    t.eq(count_calls(G, "Begin", "Warden v0.2.0-test"), 1)
    t.truthy(has_text(G, "Test server  |  Players 3/16  |  Cars 3/10  |  Adm · admin (90)"), shown_text(G))
    t.truthy(has_text(G, "Spawn"))
    t.truthy(has_text(G, ">>"))
    t.truthy(has_text(G, "Vote"))
    t.truthy(has_text(G, "/warden hides the panel"))
    t.eq(count_calls(G, "InputFloat", "##scale"), 1, "the UI scale input")
    t.truthy(G.im.buttons()["Reset UI scale"])
    t.eq(G.im.tabs(), { "Players", "Config", "Environment", "Database" })
    t.eq(count_calls(G, "SetWindowFontScale") > 0, true)
    -- one collapsing header per player, coloured by tier, the counts in the label
    t.eq(G.im.headers(), {
        "Adm (you)  ·  admin (90)  ·  1 car(s)", "Bob  ·  default (0)  ·  2 car(s)  ·  guest",
        "Carl  ·  owner (100)  ·  0 car(s)  ·  whitelisted",
    })
    t.truthy(has_text(G, "3 online"))
    -- the button row of an expanded player, in CEI's order
    local b = G.im.buttons()
    for _, label in ipairs({ "Vote kick", "Kick", "Ban", "TempBan", "Mute", "Whitelist", "Warn", "Focus", "Teleport To",
        "Teleport From" }) do
        t.truthy(b["p2/" .. label], "Bob has " .. label)
    end
    t.eq(b["p2/Unmute"], nil, "not muted: no Unmute")
    t.eq(b["p3/Unwhitelist"] ~= nil, true, "Carl is whitelisted: Unwhitelist instead of Whitelist")
    t.eq(b["p3/Whitelist"], nil)
    -- the tree nodes
    t.truthy(has_text(G, "vehicles: 2"))
    t.truthy(has_text(G, "info"))
    t.truthy(has_text(G, "permissions"))
    -- the record is asked for when a header is expanded (boot answered the first round with nothing)
    t.eq(#frames_of("players.get"), 3)
    local bob = "Bob  ·  default (0)  ·  2 car(s)  ·  guest"
    G.im.collapse(bob)
    G.im.frame()
    t.falsy(G.im.buttons()["p2/Kick"], "collapsed: no buttons")
    G.im.expand(bob)
    G.im.frame()
    t.eq(#frames_of("players.get"), 4)
    local get = game.last_frame("players.get")
    t.eq(get.data, { pid = 2 })
    game.reply(get.id, true, { player = { pid = 2, name = "Bob", group = "default", level = 0,
        vehicles = 2, ping = 0.05, connected = 61, guest = true, key = "ip:10.0.0.2", ip = "10.0.0.2", account = nil,
        joins = 3, warns = { { reason = "x" } }, cap = 1, mute = { ["until"] = 1700003600 },
        names = { "Bob", "Bobby" } } })
    G.im.frame()
    t.truthy(has_text(G, "Key: ip:10.0.0.2"), shown_text(G))
    t.truthy(has_text(G, "IP: 10.0.0.2"))
    t.truthy(has_text(G, "Joins: 3"))
    t.truthy(has_text(G, "Warnings: 1"))
    t.truthy(has_text(G, "Names seen: Bob, Bobby"))
    t.truthy(has_text(G, "50 ms"), "ping in ms")
    t.truthy(has_text(G, "Online: 1m 1s"), "connected time")
    -- the player leaves: the header goes
    game.event("players.changed", { players = { players()[1] } })
    G.im.frame()
    t.falsy(has_text(G, "Key: ip:10.0.0.2"))
    t.eq(#G.im.headers(), 1)
    t.truthy(has_text(G, "1 online"))
end

tests.greyed_platform_gaps_name_their_issues = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.hover("p2/Teleport To")
    G.im.hover("Freeze all")
    G.im.hover("Remote stop all")
    G.im.frame()
    local b = G.im.buttons()
    t.eq(b["p2/Teleport To"].disabled, true)
    t.eq(b["p2/Teleport From"].disabled, true)
    t.eq(b["Freeze all"].disabled, true)
    t.eq(b["Unfreeze all"].disabled, true)
    t.eq(b["Remote stop all"].disabled, true)
    t.eq(b["Remote start all"].disabled, true)
    t.truthy(has_text(G, "Needs server#53"), shown_text(G))
    t.truthy(has_text(G, "Needs server#58"))
    t.truthy(has_text(G, "Needs server#89"))
    -- a click on a greyed button sends nothing
    local n = #game.frames()
    G.im.click("p2/Teleport To")
    G.im.click("Freeze all")
    G.im.frame()
    t.eq(#game.frames(), n)
    -- Focus without the client mod's SDK is greyed and says so
    t.eq(b["p2/Focus"].disabled, true)
    G.im.hover("p2/Focus")
    G.im.frame()
    t.truthy(has_text(G, "vehicle list is not available"), shown_text(G))
    -- the Environment tab is the placeholder for server#52
    G.im.tab = "Environment"
    G.im.frame()
    t.truthy(has_text(G, "server#52"), shown_text(G))
    G.env.core_environment = { getTimeOfDay = function() return { time = 0.75 } end }
    G.im.frame()
    t.truthy(has_text(G, "time of day: 06:00"), shown_text(G))
    -- the Server header is read-only and names server#39
    G.im.tab = "Config"
    G.im.frame()
    t.truthy(has_text(G, "Name: Test server"), shown_text(G))
    t.truthy(has_text(G, "Map: gridmap"))
    t.truthy(has_text(G, "Max players: 16"))
    t.truthy(has_text(G, "server#39"))
end

tests.config_tab_renders_groups_whitelist_panel_and_runtime_settings = function()
    local G = boot()
    G.im.tab = "Config"
    G.im.frame()
    t.eq(G.im.headers(), { "Warden", "Server", "Interface" })
    t.truthy(has_text(G, "players.view mod.kick"), shown_text(G))
    t.truthy(has_text(G, "unlimited"))
    t.truthy(has_text(G, "Read-only: perms.manage"), "no perms.manage: no editor")
    t.eq(G.im.buttons()["cfg_groups/New group"], nil)
    -- the whitelist and the settings were asked for when their nodes were drawn
    answer_all("whitelist.list", { enabled = false, entries = WHITELIST })
    answer_all("settings.list", { settings = SETTINGS })
    G.im.frame()
    t.truthy(has_text(G, "acct:9"), shown_text(G))
    t.truthy(has_text(G, "2 entry(ies)"))
    t.truthy(has_text(G, "The whitelist is off."))
    t.truthy(has_text(G, "votekick.window_sec *"), "an overridden key is marked")
    t.truthy(has_text(G, "Panel shown by default for staff"))
    t.truthy(G.im.buttons()["cfg_runtime/s:votekick.window_sec/Reset"], "reset only where overridden")
    t.falsy(G.im.buttons()["cfg_runtime/s:votekick.min_players/Reset"])
    local calls = {}
    for _, c in ipairs(G.im.calls) do calls[c[1]] = (calls[c[1]] or 0) + 1 end
    t.eq(calls.InputFloat, 3, "number -> InputFloat, plus the two scale inputs")
    t.truthy(calls.Checkbox >= 4, "bool -> checkbox (the table and the Panel rows)")
    -- the Interface header: the theme row and the language picker
    t.truthy(has_text(G, "Theme"))
    t.eq(count_calls(G, "Combo1", "##lang"), 2, "the header row and the Interface header")
end

tests.database_tab_renders_bans_mutes_whitelist_and_audit = function()
    local G = boot()
    G.im.tab = "Database"
    G.im.frame()
    t.eq(G.im.headers(), { "Bans", "Mutes", "Whitelist", "Audit" })
    t.eq(game.last_frame("audit.tail").data, { limit = 30 })
    answer_all("mod.bans", { bans = BANS })
    answer_all("mod.mutes", { mutes = MUTES })
    answer_all("whitelist.list", { enabled = true, entries = WHITELIST })
    answer_all("audit.tail", { rows = AUDIT })
    G.im.frame()
    t.truthy(has_text(G, "acct:9"), shown_text(G))
    t.truthy(has_text(G, "permanent"))
    t.truthy(has_text(G, "2 ban(s)"))
    t.truthy(has_text(G, "1 mute(s)"))
    t.truthy(has_text(G, "Gus"))
    t.truthy(has_text(G, "kick"))
    t.truthy(has_text(G, "denied"))
    t.truthy(has_text(G, "2023-11-14T22:14:20Z"))
    t.truthy(G.im.buttons()["db_bans/b:acct:9/Unban"])
    t.truthy(G.im.buttons()["db_mutes/m:acct:7/Unmute"])
    t.truthy(G.im.buttons()["db_whitelist/w:acct:3/Remove"])
    -- the buttons send their frames
    G.im.click("db_bans/b:acct:9/Unban")
    G.im.frame()
    local f = game.last_frame("mod.unban")
    t.eq(f.data, { key = "acct:9" })
    game.reply(f.id, true, {})
    G.im.frame()
    t.falsy(has_text(G, "acct:9") and has_text(G, "Zed") and has_text(G, "cheats"), "the ban row goes on success")
    t.truthy(has_text(G, "1 ban(s)"))
    G.im.click("db_mutes/m:acct:7/Unmute")
    G.im.frame()
    f = game.last_frame("mod.unmute")
    t.eq(f.data, { key = "acct:7" })
    game.reply(f.id, true, {})
    G.im.frame()
    t.truthy(has_text(G, "Nobody is muted."), shown_text(G))
    G.im.click("db_whitelist/w:acct:3/Remove")
    G.im.frame()
    t.eq(game.last_frame("whitelist.remove").data, { entry = "acct:3" })
    G.im.int("db_audit/##n", 50)
    G.im.click("db_audit/Refresh")
    G.im.frame()
    t.eq(game.last_frame("audit.tail").data, { limit = 50 })
end

tests.all_tabs_render_from_an_empty_state_without_errors = function()
    local G = boot()
    game.event("players.changed", { players = {} })
    for _, tab in ipairs({ "Players", "Config", "Environment", "Database" }) do
        G.im.tab = tab
        G.im.frame()
        for _, f in ipairs(game.frames()) do
            if not game.answered[f.id] and f.op ~= "players.subscribe" and f.op ~= "sys.hello" then
                game.answered[f.id] = true
                game.reply(f.id, true, {})
            end
        end
        G.im.frame()
    end
    t.truthy(has_text(G, "No bans."))
    G.im.tab = "Players"
    G.im.frame()
    t.truthy(has_text(G, "Nobody here."))
end

-- (b) the buttons send the exact frames -----------------------------------------

tests.kick_with_a_reason_acts_at_once = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.type("p2/##reason", "spam")
    G.im.frame()
    G.im.click("p2/Kick")
    G.im.frame()
    local f = game.last_frame("mod.kick")
    t.eq(f.data, { pid = 2, reason = "spam" })
    G.im.frame()
    t.truthy(has_text(G, "Sending..."), shown_text(G))
    t.eq(G.im.buttons()["p2/Kick"].disabled, true, "one kick at a time")
    game.reply(f.id, true, { target = { pid = 2 } })
    G.im.frame()
    t.truthy(has_text(G, "Done."), shown_text(G))
    G.im.frame(G.panel.RESULT_TTL_S + 1)
    t.falsy(has_text(G, "Done."), "the outcome fades")
end

tests.ban_and_tempban_ask_for_a_second_click = function()
    local G = boot()
    G.im.tab = "Players"
    local n = #game.frames()
    G.im.click("p2/Ban")
    G.im.frame()
    t.eq(#game.frames(), n, "the first click arms the button")
    G.im.frame()
    t.truthy(G.im.buttons()["p2/Ban?"], "the label asks")
    G.im.click("p2/Ban?")
    G.im.frame()
    t.eq(game.last_frame("mod.ban").data, { pid = 2 })
    -- an armed button disarms after CONFIRM_S
    G.im.click("p2/TempBan")
    G.im.frame()
    G.im.frame()
    t.truthy(G.im.buttons()["p2/TempBan?"])
    G.im.frame(G.panel.CONFIRM_S + 1)
    G.im.frame()
    t.truthy(G.im.buttons()["p2/TempBan"])
    t.eq(G.im.buttons()["p2/TempBan?"], nil)
    -- the duration from the combo, then a custom one, then a bad one
    G.im.pick("p2/##duration", 1)
    G.im.type("p2/##reason", "  cheats ")
    G.im.frame()
    G.im.click("p2/TempBan")
    G.im.frame()
    G.im.click("p2/TempBan?")
    G.im.frame()
    t.eq(game.last_frame("mod.tempban").data, { pid = 2, duration = 7200, reason = "cheats" })
    game.reply(game.last_frame("mod.tempban").id, true, {})
    G.im.pick("p2/##duration", 4)
    G.im.frame()
    G.im.type("p2/##custom", "3h")
    G.im.type("p2/##reason", "")
    G.im.frame()
    G.im.click("p2/TempBan")
    G.im.frame()
    G.im.click("p2/TempBan?")
    G.im.frame()
    t.eq(game.last_frame("mod.tempban").data, { pid = 2, duration = 10800 })
    game.reply(game.last_frame("mod.tempban").id, true, {})
    n = #game.frames()
    G.im.type("p2/##custom", "soon")
    G.im.frame()
    G.im.click("p2/TempBan")
    G.im.frame()
    G.im.click("p2/TempBan?")
    G.im.frame()
    t.eq(#game.frames(), n, "nothing sent for a bad duration")
    t.truthy(has_text(G, "Bad value for duration"), shown_text(G))
end

tests.mute_unmute_whitelist_warn_group_cars_votekick = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.click("p2/Mute")
    G.im.frame()
    t.eq(game.last_frame("mod.mute").data, { pid = 2, duration = 1800 }, "the first duration is the default")
    game.reply(game.last_frame("mod.mute").id, true, {})
    -- the server's row says muted: the button alternates
    local list = players()
    list[2].muted = true
    game.event("players.changed", { players = list })
    G.im.frame()
    t.eq(G.im.buttons()["p2/Mute"], nil)
    G.im.click("p2/Unmute")
    G.im.frame()
    t.eq(game.last_frame("mod.unmute").data, { pid = 2 })
    -- whitelist / unwhitelist by #pid
    G.im.click("p2/Whitelist")
    G.im.frame()
    t.eq(game.last_frame("whitelist.add").data, { entry = "#2" })
    list[2].whitelisted = true
    game.event("players.changed", { players = list })
    G.im.frame()
    G.im.click("p2/Unwhitelist")
    G.im.frame()
    t.eq(game.last_frame("whitelist.remove").data, { entry = "#2" })
    -- warn needs a reason
    local n = #game.frames()
    G.im.click("p2/Warn")
    G.im.frame()
    t.eq(#game.frames(), n, "no warn without a reason")
    t.truthy(has_text(G, "Bad value for reason"))
    G.im.type("p2/##reason", "language")
    G.im.frame()
    G.im.click("p2/Warn")
    G.im.frame()
    t.eq(game.last_frame("mod.warn").data, { pid = 2, reason = "language" })
    -- the group picker offers only the groups below the actor's level; Apply and Remove
    local combo
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Combo1" and c[2] == "##group" then combo = c end
    end
    t.eq(combo[3], { "default (0)", "mod (50)" })
    G.im.pick("p2/##group", 1)
    G.im.click("p2/Apply")
    G.im.frame()
    t.eq(game.last_frame("groups.set").data, { pid = 2, group = "mod" })
    game.reply(game.last_frame("groups.set").id, true, {})
    G.im.click("p2/Remove")
    G.im.frame()
    t.eq(game.last_frame("groups.set").data, { pid = 2, group = "default" }, "back to the default group")
    -- delete cars, vote kick
    G.im.click("p2/Delete cars")
    G.im.frame()
    t.eq(game.last_frame("car.delete").data, { pid = 2 })
    G.im.type("p2/##reason", "ramming")
    G.im.frame()
    G.im.click("p2/Vote kick")
    G.im.frame()
    t.eq(game.last_frame("vote.start").data, { pid = 2, reason = "ramming" })
    -- a refusal is printed under the row
    local f = game.last_frame("vote.start")
    game.reply(f.id, false, { code = "vote.too_few", params = { min = 4 } })
    G.im.frame()
    t.truthy(has_text(G, "A vote needs at least 4 players"), shown_text(G))
end

tests.vehicles_node_and_focus_use_the_client_mods_view = function()
    local G = boot()
    local entered = {}
    G.env.NodeMP = {
        vehicles = { getAll = function()
            return {
                ["7"] = { spawnerID = 2, gameVehicleID = 1007, jbeam = "pickup", serverVehicleID = 7 },
                ["8"] = { spawnerID = 2, gameVehicleID = 1008, jbeam = "etk800", serverVehicleID = 8 },
                ["9"] = { spawnerID = 1, gameVehicleID = 1009, jbeam = "covet", serverVehicleID = 9 },
            }
        end },
        strict = { isActive = function() return G.env.strict_now == true end },
    }
    G.env.be = {
        getObjectByID = function(_, gid) return { gid = gid } end,
        enterVehicle = function(_, _, veh) entered[#entered + 1] = veh.gid end,
    }
    G.im.tab = "Players"
    G.im.frame()
    t.truthy(has_text(G, "7: pickup"), shown_text(G))
    t.truthy(has_text(G, "8: etk800"))
    t.truthy(G.im.buttons()["p1/v9/Delete"], "Adm's covet is under Adm")
    t.eq(G.im.buttons()["p2/v9/Delete"], nil, "and not under Bob")
    t.eq(G.im.buttons()["p2/v7/Delete"].disabled, false)
    t.eq(G.im.buttons()["p2/v7/Freeze"].disabled, true)
    t.eq(G.im.buttons()["p2/v7/Remote start"].disabled, true)
    G.im.click("p2/v7/Delete")
    G.im.frame()
    t.eq(game.last_frame("car.delete").data, { pid = 2, vid = 7 })
    -- Focus cycles through the player's vehicles, client side only: no frame
    local n = #game.frames()
    t.eq(G.im.buttons()["p2/Focus"].disabled, false)
    G.im.click("p2/Focus")
    G.im.frame()
    t.eq(entered, { 1007 })
    t.truthy(has_text(G, "Watching Bob."), shown_text(G))
    G.im.click("p2/Focus")
    G.im.frame()
    t.eq(entered, { 1007, 1008 })
    t.eq(#game.frames(), n, "nothing asked of the server")
    t.eq(G.im.buttons()["p3/Focus"].disabled, true, "Carl has no vehicle")
    -- a strict session: refused, as the mod refuses it
    G.env.strict_now = true
    G.im.hover("p2/Focus")
    G.im.frame()
    t.eq(G.im.buttons()["p2/Focus"].disabled, true)
    t.truthy(has_text(G, "strict session"), shown_text(G))
end

tests.quick_actions_spawn_whitelist_announce = function()
    local G = boot()
    G.im.tab = "Players"
    G.im.frame()
    t.truthy(G.im.buttons()["Disable spawning"], "spawning is on: the button turns it off")
    G.im.click("Disable spawning")
    G.im.frame()
    local f = game.last_frame("settings.set")
    t.eq(f.data, { key = "spawn.enabled", value = false })
    game.reply(f.id, true, { key = "spawn.enabled", value = false })
    game.event("status", { spawn = false })
    G.im.frame()
    t.truthy(G.im.buttons()["Enable spawning"], "the status says off: the button turns it on")
    t.truthy(has_text(G, "X"), "the chip shows it")
    G.im.click("Whitelist on")
    G.im.frame()
    t.eq(game.last_frame("whitelist.enable").data, { on = true })
    game.reply(game.last_frame("whitelist.enable").id, true, { enabled = true })
    G.im.frame()
    t.truthy(G.im.buttons()["Whitelist off"])
    G.im.type("##announce", "  hello all ")
    G.im.click("Announce")
    G.im.frame()
    f = game.last_frame("server.announce")
    t.eq(f.data, { text = "hello all" })
    game.reply(f.id, true, {})
    G.im.frame()
    t.truthy(has_text(G, "Done."), shown_text(G))
end

tests.groups_editor_saves_and_deletes_under_the_owners_rules = function()
    local G = boot(record({ "*" }, { pid = 1, name = "Own", group = "owner", level = 100, key = "acct:1" }))
    G.im.tab = "Config"
    G.im.frame()
    t.truthy(G.im.buttons()["cfg_groups/New group"])
    t.truthy(G.im.buttons()["cfg_groups/g:mod/Edit"])
    t.eq(G.im.buttons()["cfg_groups/g:owner/Edit"], nil, "not at or above one's own level")
    G.im.click("cfg_groups/New group")
    G.im.frame()
    t.truthy(has_text(G, "New group"), shown_text(G))
    G.im.type("cfg_groups/##gname", "VIP")
    G.im.int("cfg_groups/##glevel", 20)
    G.im.type("cfg_groups/##ginherits", "trusted, default")
    G.im.type("cfg_groups/##gperms", "mod.warn mod.mute")
    G.im.int("cfg_groups/##gcars", 4)
    G.im.frame()
    G.im.click("cfg_groups/Save")
    G.im.frame()
    local f = game.last_frame("groups.save")
    t.eq(f.data, { group = { name = "vip", level = 20, inherits = { "trusted", "default" },
        perms = { "mod.warn", "mod.mute" }, caps = { vehicles = 4 } } })
    game.reply(f.id, true, { group = { name = "vip" } })
    G.im.frame()
    t.truthy(game.last_frame("groups.list"), "the list is asked again")
    -- editing an existing group: prefilled, deletable
    G.im.click("cfg_groups/g:mod/Edit")
    G.im.frame()
    t.truthy(has_text(G, "Editing the group mod"), shown_text(G))
    local perms_buf
    for _, c in ipairs(G.im.calls) do
        if c[1] == "InputText" and c[2] == "##gperms" then perms_buf = true end
    end
    t.truthy(perms_buf)
    G.im.click("cfg_groups/Delete group")
    G.im.frame()
    t.eq(game.last_frame("groups.delete").data, { name = "mod" })
    f = game.last_frame("groups.delete")
    game.reply(f.id, false, { code = "in_use", params = { group = "mod" } })
    G.im.frame()
    t.truthy(has_text(G, "Another group inherits from mod"), shown_text(G))
    G.im.click("cfg_groups/Cancel")
    G.im.frame()
    G.im.frame()
    t.falsy(has_text(G, "Editing the group mod"))
end

tests.whitelist_and_panel_settings_from_the_config_tab = function()
    local G = boot()
    G.im.tab = "Config"
    G.im.frame()
    answer_all("whitelist.list", { enabled = false, entries = WHITELIST })
    answer_all("settings.list", { settings = SETTINGS })
    G.im.frame()
    G.im.type("cfg_whitelist/##wl_add", " acct:5 ")
    G.im.click("cfg_whitelist/Add")
    G.im.frame()
    local f = game.last_frame("whitelist.add")
    t.eq(f.data, { entry = "acct:5" })
    game.reply(f.id, true, { entry = "acct:5" })
    G.im.frame()
    t.truthy(game.last_frame("whitelist.list"), "the list is asked again")
    G.im.click("cfg_whitelist/Whitelist on")
    G.im.frame()
    t.eq(game.last_frame("whitelist.enable").data, { on = true })
    G.im.click("cfg_whitelist/w:acct:9/Remove")
    G.im.frame()
    t.eq(game.last_frame("whitelist.remove").data, { entry = "acct:9" })
    -- the Panel node: default state, welcome, spawning
    G.im.check("cfg_panel/s:ui.default_shown/##v", false)
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "ui.default_shown", value = false })
    game.reply(game.last_frame("settings.set").id, true, { key = "ui.default_shown", value = false })
    G.im.check("cfg_panel/s:ui.welcome/##v", false)
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "ui.welcome", value = false })
    game.reply(game.last_frame("settings.set").id, true, { key = "ui.welcome", value = false })
    -- the Interface header: the theme
    G.im.pick("cfg_interface/s:ui.theme/##v", 1)
    G.im.frame()
    G.im.click("cfg_interface/s:ui.theme/Set")
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "ui.theme", value = "game" })
    game.reply(game.last_frame("settings.set").id, true, { key = "ui.theme", value = "game" })
    -- the runtime settings table: set and reset, a refusal printed in the row
    G.im.int("cfg_runtime/s:votekick.min_players/##v", 6)
    G.im.frame()
    G.im.click("cfg_runtime/s:votekick.min_players/Set")
    G.im.frame()
    t.eq(game.last_frame("settings.set").data, { key = "votekick.min_players", value = 6 })
    game.reply(game.last_frame("settings.set").id, true, { key = "votekick.min_players", value = 6 })
    G.im.frame()
    t.truthy(has_text(G, "votekick.min_players *"))
    G.im.click("cfg_runtime/s:votekick.window_sec/Reset")
    G.im.frame()
    f = game.last_frame("settings.reset")
    t.eq(f.data, { key = "votekick.window_sec" })
    game.reply(f.id, false, { code = "denied", params = { perm = "settings.write" } })
    G.im.frame()
    t.truthy(has_text(G, "You may not do that (settings.write)"), shown_text(G))
end

-- (c) replies and events update the model ---------------------------------------

tests.events_update_players_groups_settings_status_vote_and_notices = function()
    local G = boot()
    game.event("players.changed", { players = { { pid = 5, name = "Eve", group = "default", level = 0 } } })
    t.eq(#G.state.S.players, 1)
    t.eq(G.state.S.players[1].name, "Eve")
    game.event("groups.changed", { groups = { { name = "default", level = 0 }, { name = "vip", level = 20 } } })
    t.eq(#G.state.S.groups, 2)
    t.eq(G.state.S.groups[2].name, "vip", "sorted by level")
    G.im.tab = "Config"
    G.im.frame()
    answer_all("settings.list", { settings = SETTINGS })
    answer_all("whitelist.list", { enabled = false, entries = {} })
    game.event("settings.changed", { key = "allow_guests", value = false })
    t.eq(G.state.setting("allow_guests").value, false)
    t.eq(G.state.setting("allow_guests").overridden, true)
    t.eq(G.state.S.status.guests, false, "the chip follows the setting")
    game.event("settings.changed", { key = "ui.theme", value = "game" })
    t.eq(G.state.S.ui.theme, "game")
    game.event("status", { players = 7, cars = 4, whitelist = true, theme = "cobalt" })
    t.eq(G.state.S.ui.theme, "cobalt")
    t.eq(G.state.S.whitelist.enabled, true)
    G.im.frame()
    t.truthy(has_text(G, "Players 7/16  |  Cars 4/10"), shown_text(G))
    game.event("vote.state", { event = "started", vote = { id = 1, target = { pid = 5, name = "Eve" },
        starter = { pid = 1, name = "Adm" }, yes = 0, no = 0, needed = 3, seconds_left = 30 } })
    t.eq(G.state.S.vote.id, 1)
    t.eq(G.state.vote_seconds_left(), 30)
    G.im.frame(10)
    t.eq(G.state.vote_seconds_left(), 20, "the countdown runs on the client clock")
    t.truthy(has_text(G, "//"), "the vote chip")
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

tests.vote_banner_buttons_and_the_language_picker = function()
    local G = boot()
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
    local f = game.last_frame("me.lang")
    t.eq(f.data, { lang = "ru" })
    game.reply(f.id, true, { lang = "ru" })
    G.im.frame()
    t.eq(G.i18n.lang(), "ru")
    t.eq(G.im.tabs()[1], "Игроки")
    t.truthy(has_text(G, "/warden скрывает панель"), shown_text(G))
end

-- (d) what the permissions and the rank rule hide -------------------------------

tests.a_mod_sees_fewer_sections_and_greyed_actions = function()
    local G = boot(record(MOD_PERMS, { pid = 1, name = "Modi", group = "mod", level = 50, key = "acct:1" }))
    G.im.tab = "Players"
    G.im.frame()
    t.eq(G.im.tabs(), { "Players", "Config", "Environment", "Database" })
    t.eq(G.im.buttons()["Disable spawning"], nil, "no settings.write: no spawn toggle")
    t.eq(G.im.buttons()["Whitelist on"], nil, "no mod.whitelist")
    t.eq(G.im.buttons()["Announce"], nil, "no server.announce")
    local b = G.im.buttons()
    t.eq(b["p2/Kick"].disabled, false)
    t.eq(b["p2/TempBan"].disabled, false)
    t.eq(b["p2/Ban"].disabled, true, "no mod.ban")
    t.eq(b["p2/Whitelist"].disabled, true, "no mod.whitelist")
    t.eq(b["p2/Vote kick"].disabled, false)
    t.eq(b["p2/Apply"], nil, "no perms.set: no group picker")
    t.truthy(has_text(G, "You cannot change this player's group."), shown_text(G))
    -- a click on a greyed button sends nothing
    local n = #game.frames()
    G.im.click("p2/Ban")
    G.im.frame()
    t.eq(#game.frames(), n)
    -- the owner outranks a mod: only the actions without the rank rule stay
    b = G.im.buttons()
    t.eq(b["p3/Kick"].disabled, true, "outranked")
    t.eq(b["p3/Delete cars"], nil, "no cars: no delete")
    t.eq(b["p3/Mute"].disabled, true)
    t.eq(b["p3/Vote kick"].disabled, false)
    -- oneself: only the self actions
    t.eq(b["p1/Kick"].disabled, true)
    t.eq(b["p1/Delete cars"].disabled, false, "own cars")
    t.eq(b["p1/Vote kick"].disabled, true, "not yourself")
    -- the Database tab of a mod: mutes and the audit, no bans, no whitelist
    G.im.tab = "Database"
    G.im.frame()
    t.eq(G.im.headers(), { "Mutes", "Audit" })
    -- the Config tab of a mod: no whitelist node, no runtime settings, the Panel rows need settings.read
    G.im.tab = "Config"
    G.im.frame()
    t.falsy(has_text(G, "Runtime settings"))
    t.truthy(has_text(G, "needs settings.read"), shown_text(G))
    -- the vote banner without votekick.vote has no buttons; a plain player has no Players tab
    local G2 = boot(record({ "votekick.cancel" }, { pid = 1, name = "Viewer", group = "default", level = 0 },
        { ui = { shown = false, scale = 1, theme = "cobalt" } }))
    t.eq(G2.panel.isOpen(), false, "hidden by default without players.view")
    G2.panel.open()
    G2.im.frame()
    t.eq(G2.im.tabs(), { "Config", "Environment" })
    game.event("vote.state", { event = "started", vote = { id = 1, target = { pid = 2, name = "Bob" },
        starter = { pid = 3, name = "Carl" }, yes = 0, no = 0, needed = 2, seconds_left = 30 } })
    G2.im.frame()
    t.truthy(has_text(G2, "Vote to kick Bob"))
    t.eq(G2.im.buttons()["Yes"], nil)
    t.truthy(G2.im.buttons()["Cancel vote"])
end

tests.has_and_can_target_follow_the_wildcards_and_the_rank_rule = function()
    local G = game.load()
    local S = G.state
    S.S.perms = { "mod.*", "settings.read" }
    t.eq(S.has("mod.kick"), true)
    t.eq(S.has("settings.read"), true)
    t.eq(S.has("settings.write"), false)
    t.eq(S.has_any({ "nothing", "settings.read" }), true)
    S.S.perms = { "*" }
    t.eq(S.has("anything.at.all"), true)
    S.S.me = { pid = 1, level = 50 }
    S.S.perms = { "mod.kick", "votekick.start", "car.delete", "perms.manage" }
    local kick = S.action_by_id("kick")
    t.eq(S.can_target({ pid = 2, level = 10 }, kick), true)
    t.eq((S.can_target({ pid = 2, level = 50 }, kick)), false, "equal level")
    t.eq((S.can_target({ pid = 1, level = 50 }, kick)), false, "self")
    t.eq((S.can_target({ pid = 1, level = 50 }, S.action_by_id("cars"))), true, "own cars")
    t.eq((S.can_target({ pid = 1, level = 50 }, S.action_by_id("votekick"))), false)
    t.eq((S.can_target({ pid = 2, level = 90 }, S.action_by_id("votekick"))), true, "no rank rule")
    t.eq(S.can_edit_group({ name = "mod", level = 50 }), false, "not at one's own level")
    t.eq(S.can_edit_group({ name = "trusted", level = 10 }), true)
    t.eq(S.action_visible({ muted = true }, S.action_by_id("mute")), false)
    t.eq(S.action_visible({ muted = true }, S.action_by_id("unmute")), true)
    t.eq(S.action_visible({}, S.action_by_id("unwhitelist")), false)
    t.eq(S.parse_duration("45m"), 2700)
    t.eq(S.parse_duration("2d"), 172800)
    t.eq(S.parse_duration("15"), 900, "bare number: minutes")
    t.eq(S.parse_duration("x"), nil)
    t.eq(S.format_duration(3661), "1h 1m")
    t.eq(S.clamp_scale(3), 1.5)
    t.eq(S.clamp_scale(0.1), 0.75)
    t.eq(S.clamp_scale("x"), 1.0)
    t.eq(S.clamp_scale(1.234), 1.23)
    t.eq(G.i18n.error_text({ code = "no_such_code" }), "no_such_code")
    t.eq(G.i18n.error_text({ code = "timeout" }), "The server did not answer.")
    local op, data = S.build(S.action_by_id("cars"), { pid = 2 }, { vid = "7" })
    t.eq(op, "car.delete")
    t.eq(data, { pid = 2, vid = 7 })
    t.eq((S.build(S.action_by_id("cars"), { pid = 2 }, { vid = "x" })), nil)
end

-- (e) the toggle paths ----------------------------------------------------------

tests.toggle_by_event_global_and_x_persists_the_state_and_no_key_is_read = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "no session yet")
    game.session(record(nil, nil, { ui = { shown = false, scale = 1.0, theme = "cobalt" } }))
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "hidden: the server remembered")
    G.im.press(G.im.Key_F9)
    G.im.frame()
    t.eq(G.panel.isOpen(), false, "no fixed key any more")
    t.eq(count_calls(G, "IsKeyPressed"), 0, "the panel does not read keys")
    -- /warden on the server: wd:event panel; the choice is told to the server
    game.event("panel", { toggle = true })
    t.eq(G.panel.isOpen(), true)
    t.eq(game.last_frame("ui.set").data, { shown = true })
    game.event("panel", { toggle = true })
    t.eq(G.panel.isOpen(), false)
    t.eq(game.last_frame("ui.set").data, { shown = false })
    game.event("panel", { open = true })
    t.eq(G.panel.isOpen(), true)
    G.im.frame()
    local begins = count_calls(G, "Begin", "Warden")
    t.eq(begins, 1, "the window is drawn")
    -- the global the game action and the console call
    local g = G.env.nodemp_wd
    t.truthy(g)
    t.eq(g.action, "toggleWarden")
    t.eq(g.key, nil)
    t.eq(g.version, "0.2.0")
    t.eq(g.toggle(), true)
    t.eq(g.isOpen(), false)
    G.im.frame()
    t.eq(count_calls(G, "Begin"), 0, "closed: nothing drawn")
    g.open()
    G.im.frame()
    local begin
    for _, c in ipairs(G.im.calls) do
        if c[1] == "Begin" and tostring(c[2]):find("Warden", 1, true) then begin = c end
    end
    local n = #frames_of("ui.set")
    begin[3][0] = false -- the X of the window
    G.im.frame()
    t.eq(G.panel.isOpen(), false)
    t.eq(#frames_of("ui.set"), n + 1, "the X is remembered too")
    t.eq(game.last_frame("ui.set").data, { shown = false })
    -- the server's answer (clamped, persisted) wins
    game.reply(game.last_frame("ui.set").id, true, { ui = { shown = false, scale = 1.25 } })
    t.eq(G.state.S.ui.scale, 1.25)
    -- leaving the server closes it and forgets the session
    g.open()
    G.bridge.onExtensionUnloaded()
    t.eq(G.panel.isOpen(), false)
    t.eq(G.state.S.session, nil)
    t.eq(#G.state.S.players, 0)
end

tests.a_toggle_before_hello_waits_and_shown_by_default_asks_nothing = function()
    local G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    t.eq(G.panel.open(), false, "no session: remembered")
    game.session(record(nil, nil, { ui = { shown = false, scale = 1.0, theme = "cobalt" } }))
    G.im.frame()
    t.eq(G.panel.isOpen(), true, "opened once the record arrived")
    t.eq(game.last_frame("ui.set").data, { shown = true }, "and the server is told: the player asked")
    -- shown by default: the window comes up and nothing is sent
    G = game.load()
    G.bridge.onExtensionLoaded()
    G.im.frame(0.2)
    game.session(record())
    G.im.frame()
    t.eq(G.panel.isOpen(), true)
    t.eq(#frames_of("ui.set"), 0)
end

tests.scale_is_clamped_and_sent_after_a_pause = function()
    local G = boot()
    G.im.float("##scale", 3.0)
    G.im.frame()
    t.eq(G.state.S.ui.scale, 1.5, "clamped at once")
    t.eq(#frames_of("ui.set"), 0, "not sent yet")
    G.im.frame(G.panel.SCALE_SEND_DELAY_S + 0.1)
    t.eq(game.last_frame("ui.set").data, { scale = 1.5 })
    game.reply(game.last_frame("ui.set").id, true, { ui = { shown = true, scale = 1.5 } })
    t.eq(count_calls(G, "SetWindowFontScale") > 0, true)
    local scaled = false
    for _, c in ipairs(G.im.calls) do
        if c[1] == "SetWindowFontScale" and c[2] == 1.5 then scaled = true end
    end
    t.truthy(scaled, "the window is drawn at the scale")
    G.im.click("Reset UI scale")
    G.im.frame()
    t.eq(G.state.S.ui.scale, 1.0)
    G.im.frame(G.panel.SCALE_SEND_DELAY_S + 0.1)
    t.eq(game.last_frame("ui.set").data, { scale = 1.0 })
end

tests.theme_cobalt_pushes_the_style_and_game_pushes_none = function()
    local G = boot()
    G.im.frame()
    t.truthy(#G.im.styles >= 20, "the translucent blue palette")
    t.eq(count_calls(G, "SetNextWindowBgAlpha"), 1)
    for _, c in ipairs(G.im.calls) do
        if c[1] == "SetNextWindowBgAlpha" then t.eq(c[2], 0.67) end
    end
    game.event("settings.changed", { key = "ui.theme", value = "game" })
    G.im.frame()
    t.eq(count_calls(G, "SetNextWindowBgAlpha"), 0, "the game's own colours")
    t.eq(#G.im.styles, 9, "only the three header colours per player stay")
end

tests.register_category_adds_the_warden_input_category_once = function()
    local G = game.load()
    t.eq(G.panel.register_category(), false, "no input module in the fake game")
    G.env.core_input_categories = { gameplay = { order = 4 } }
    t.eq(G.panel.register_category(), true)
    local cat = G.env.core_input_categories.warden
    t.truthy(cat)
    t.eq(cat.title, "Warden")
    t.truthy(cat.order > 100)
    cat.marker = true
    G.panel.onExtensionLoaded()
    t.eq(G.env.core_input_categories.warden.marker, true, "idempotent: the entry is kept")
end

tests.a_drawing_error_is_logged_and_repeated_ones_close_the_panel = function()
    local G = boot()
    G.im.BeginTabBar = function() error("boom") end
    for _ = 1, G.panel.MAX_DRAW_ERRORS - 1 do
        G.panel.onUpdate(0.016)
    end
    t.eq(G.panel.isOpen(), true)
    local logged = 0
    for _, l in ipairs(game.logs) do
        if l.msg:find("panel draw failed", 1, true) then logged = logged + 1 end
    end
    t.eq(logged, G.panel.MAX_DRAW_ERRORS - 1)
    local n = #frames_of("ui.set")
    G.panel.onUpdate(0.016)
    t.eq(G.panel.isOpen(), false, "closed after MAX_DRAW_ERRORS in a row")
    t.eq(#frames_of("ui.set"), n, "a crash is not the player's choice: the state is not touched")
end

return tests
