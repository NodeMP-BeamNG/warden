-- wd:req / wd:reply / wd:event: the envelope, hello, the ops, the pushes,
-- the limiter; and the warden:* bus API.

local boot = require("boot")

local function setup(overrides)
    local W = boot(overrides or {})
    local admin = node._join(1, { name = "Adm", accountId = 1 })
    local bob = node._join(2, { name = "Bob", accountId = 2 })
    W.perms.set_group(admin, "admin")
    for _, p in ipairs({ admin, bob }) do node._emit("playerJoined", p) end
    node._told, node._sent = {}, {}
    return W, admin, bob
end

local function req(W, player, id, op, data)
    W.protocol.handle(player, node.json.encode({ id = id, op = op, data = data }))
    local replies = node._sent_of("wd:reply", player.id)
    for _, r in ipairs(replies) do
        if r.id == id then return r end
    end
    return nil
end

local function events(pid, ev)
    local out = {}
    for _, e in ipairs(node._sent_of("wd:event", pid)) do
        if ev == nil or e.ev == ev then out[#out + 1] = e end
    end
    return out
end

local tests = {}

tests.hello = function()
    local W, admin, bob = setup()
    node._told = {}
    local r = req(W, admin, 1, "sys.hello", { protocol = 2, uiVersion = "0.2.0", lang = "ru" })
    t.eq(r.ok, true)
    t.eq(r.data.protocol, 2)
    t.eq(r.data.version, "0.0.0-test")
    t.eq(r.data.key, nil, "no fixed key since 0.2.0")
    t.eq(r.data.lang, "ru", "the game's language is the default until /lang")
    t.eq(r.data.me.group, "admin")
    t.eq(r.data.me.level, 90)
    t.eq(r.data.me.key, "acct:1")
    t.eq(r.data.me.muted, false)
    t.eq(r.data.me.whitelisted, false)
    t.truthy(#r.data.perms > 5)
    t.eq(r.data.vote, nil)
    t.truthy(#r.data.permissions > 10, "the permission catalogue")
    t.eq(r.data.default_group, "default")
    -- the player's own panel state, the server's facts and the status chips
    t.eq(r.data.ui, { shown = true, scale = 1.0, theme = "cobalt" }, "shown by default: the admin has players.view")
    t.eq(r.data.server, { name = "stub", version = "1.4.1", max_players = 16, max_cars = 4 })
    t.eq(r.data.status.whitelist, false)
    t.eq(r.data.status.spawn, true)
    t.eq(r.data.status.guests, true)
    t.eq(r.data.status.votekick, false)
    t.eq(r.data.status.theme, "cobalt")
    t.eq(r.data.status.players, 2)
    t.eq(r.data.status.max_players, 16)
    t.eq(r.data.status.cars, 0)
    t.eq(r.data.status.max_cars, 4)
    -- the welcome line, once per session, for staff (players.view) only
    t.match(node._told_text(1), "/warden")
    t.match(node._told_text(1), "Options > Controls > Warden")
    node._told = {}
    req(W, admin, 2, "sys.hello", { protocol = 2 })
    t.eq(node._told_text(1), "", "a second hello of the session says nothing")
    -- a wrong protocol is refused
    r = req(W, bob, 3, "sys.hello", { protocol = 1 })
    t.eq(r.ok, false)
    t.eq(r.error.code, "ui_outdated")
    t.eq(r.error.params.server, 2)
    t.eq(r.error.params.ui, 1)
    -- a plain player: hidden by default, no welcome
    node._told = {}
    r = req(W, bob, 4, "sys.hello", { protocol = 2 })
    t.eq(r.ok, true)
    t.eq(r.data.ui.shown, false, "no players.view: the window stays hidden until asked")
    t.eq(node._told_text(2), "")
    -- after hello, notices reach the panel too
    node._sent = {}
    W.say.tell(admin, "done.unban", { target = "X" })
    local n = events(1, "notice")
    t.eq(#n, 1)
    t.eq(n[1].data.text, "Разбанен X.", "in the language hello set")
    t.eq(n[1].data.code, "done.unban")
    local carl = node._join(3, { name = "Carl", accountId = 3 })
    W.say.tell(carl, "done.unban", { target = "X" })
    t.eq(#events(3, "notice"), 0, "no hello, no notice push")
end

tests.hello_welcome_and_default_state_follow_the_settings = function()
    local W, admin = setup({ ui = { welcome = false, default_shown = false, theme = "game" } })
    node._told = {}
    local r = req(W, admin, 1, "sys.hello", { protocol = 2 })
    t.eq(r.data.ui, { shown = false, scale = 1.0, theme = "game" })
    t.eq(node._told_text(1), "", "ui.welcome = false")
    -- the runtime keys switch it on again
    W.settings.set("ui.welcome", true)
    W.settings.set("ui.default_shown", true)
    local carl = node._join(3, { name = "Carl", accountId = 3 })
    W.perms.set_group(carl, "mod")
    node._told = {}
    r = req(W, carl, 2, "sys.hello", { protocol = 2 })
    t.eq(r.data.ui.shown, true)
    t.match(node._told_text(3), "warden 0%.0%.0%-test")
end

tests.ui_get_and_ui_set_act_on_the_caller_only = function()
    local W, admin, bob = setup()
    local r = req(W, bob, 1, "ui.get")
    t.eq(r.ok, true)
    t.eq(r.data.ui, { shown = false, scale = 1.0 })
    -- hide / show and the scale, clamped, persisted under the caller's key
    r = req(W, bob, 2, "ui.set", { shown = true, scale = 9 })
    t.eq(r.ok, true)
    t.eq(r.data.ui, { shown = true, scale = 1.5 })
    r = req(W, bob, 3, "ui.set", { scale = 0.1 })
    t.eq(r.data.ui, { shown = true, scale = 0.75 })
    r = req(W, bob, 4, "ui.set", { scale = 1.234 })
    t.eq(r.data.ui.scale, 1.23, "two decimals")
    node._advance(1000)
    local file = node.json.decode(node._files["data/ui.json"])
    t.eq(file["acct:2"].shown, true)
    t.eq(file["acct:2"].scale, 1.23)
    t.eq(file["acct:1"], nil, "nobody else's record was touched")
    -- the hello carries it back
    r = req(W, bob, 5, "sys.hello", { protocol = 2 })
    t.eq(r.data.ui.shown, true)
    t.eq(r.data.ui.scale, 1.23)
    -- an admin who hid the panel stays hidden whatever the default says
    r = req(W, admin, 6, "ui.set", { shown = false })
    t.eq(r.data.ui.shown, false)
    r = req(W, admin, 7, "sys.hello", { protocol = 2 })
    t.eq(r.data.ui.shown, false)
    -- the shape: nothing to set, a bad scale, junk keys are not stored
    r = req(W, bob, 8, "ui.set", {})
    t.eq(r.error.code, "bad_arg")
    r = req(W, bob, 9, "ui.set", { scale = "big" })
    t.eq(r.error.code, "bad_arg")
    r = req(W, bob, 10, "ui.set", { scale = -1 })
    t.eq(r.error.code, "bad_arg")
    r = req(W, bob, 11, "ui.set", { shown = false, pid = 1, key = "acct:1", evil = string.rep("x", 100) })
    t.eq(r.ok, true)
    node._advance(1000)
    file = node.json.decode(node._files["data/ui.json"])
    t.eq(file["acct:1"].shown, false, "the admin's own record from #6")
    t.eq(file["acct:2"].evil, nil)
    t.eq(file["acct:2"].shown, false)
    -- not audited: no row for what went through (a refusal is written like any other kind's)
    for _, row in ipairs(W.audit.tail(50)) do
        if row.op == "ui_set" or row.op == "ui_get" then t.eq(row.result, "denied", row.op) end
    end
    -- the console has no panel
    t.eq(W.registry.run(W.perms.CONSOLE, "ui_set", { shown = true }).error.code, "console_cannot")
    t.eq(W.registry.run(W.perms.CONSOLE, "ui_get", {}).error.code, "console_cannot")
end

tests.ui_store_is_bounded = function()
    local W = setup()
    local uistate = require("ui.uistate")
    uistate.MAX_RECORDS = 3
    for i = 1, 3 do
        node._now_ms = i * 1000
        uistate.set("acct:" .. i, { shown = false })
    end
    t.eq(uistate.count(), 3)
    node._now_ms = 10000
    uistate.set("acct:1", { scale = 1.2 })    -- touched: no longer the oldest
    node._now_ms = 11000
    uistate.set("acct:9", { shown = true })
    t.eq(uistate.count(), 3)
    t.eq(uistate.get("acct:2").shown, nil, "the least recently touched record went")
    t.eq(uistate.get("acct:1").scale, 1.2)
    t.eq(uistate.get("acct:9").shown, true)
    t.truthy(W)
end

tests.mutes_list_and_car_delete_one = function()
    local W, admin, bob = setup()
    local r = req(W, bob, 1, "mod.mutes")
    t.eq(r.error.code, "denied")
    r = req(W, admin, 2, "mod.mute", { pid = 2, duration = 600, reason = "spam" })
    t.eq(r.ok, true)
    r = req(W, admin, 3, "mod.mutes")
    t.eq(r.ok, true)
    t.eq(#r.data.mutes, 1)
    t.eq(r.data.mutes[1].key, "acct:2")
    t.eq(r.data.mutes[1].name, "Bob")
    t.eq(r.data.mutes[1].reason, "spam")
    t.truthy(r.data.mutes[1]["until"])
    r = req(W, admin, 4, "players.list")
    t.eq(r.data.players[2].muted, true, "the row says so for the Mute / Unmute button")
    r = req(W, admin, 5, "mod.unmute", { key = "acct:2" })
    t.eq(r.ok, true)
    t.eq(#req(W, admin, 6, "mod.mutes").data.mutes, 0)
    -- one vehicle of the target by its id; a stranger's id is refused
    node._vehicle(10, 2)
    node._vehicle(11, 2)
    node._vehicle(12, 1)
    r = req(W, admin, 7, "car.delete", { pid = 2, vid = 12 })
    t.eq(r.error.code, "bad_arg")
    t.eq(r.error.params.field, "vid")
    t.eq(node.vehicles.count(), 3)
    r = req(W, admin, 8, "car.delete", { pid = 2, vid = 11 })
    t.eq(r.ok, true)
    t.eq(r.data.deleted, 1)
    t.eq(r.data.vid, 11)
    t.eq(node.vehicles.count(), 2)
    r = req(W, admin, 9, "car.delete", { pid = 2 })
    t.eq(r.data.deleted, 1, "the rest")
    t.eq(node.vehicles.count(), 1)
end

tests.spawn_toggle_vetoes_spawns = function()
    local W, admin, bob = setup()
    t.eq(node._emit("vehicleSpawnRequest", bob), true)
    local r = req(W, admin, 1, "settings.set", { key = "spawn.enabled", value = false })
    t.eq(r.ok, true)
    local ok, why = node._emit("vehicleSpawnRequest", bob)
    t.eq(ok, false)
    t.match(why, "switched off")
    t.eq(node._emit("vehicleSpawnRequest", admin), true, "car.cap.bypass still spawns")
    W.settings.set("spawn.enabled", true)
    t.eq(node._emit("vehicleSpawnRequest", bob), true)
end

tests.status_push_reaches_every_panel = function()
    local W, admin, bob = setup()
    req(W, admin, 1, "sys.hello", { protocol = 2 })
    req(W, bob, 2, "sys.hello", { protocol = 2 })
    node._sent = {}
    W.settings.set("spawn.enabled", false)
    W.settings.set("whitelist.enabled", true)
    t.eq(#events(1, "status"), 0, "coalesced")
    node._advance(1000)
    local a, b = events(1, "status"), events(2, "status")
    t.eq(#a, 1)
    t.eq(#b, 1, "bob has no players.view but has a panel")
    t.eq(a[1].data.spawn, false)
    t.eq(a[1].data.whitelist, true)
    t.eq(a[1].data.players, 2)
    -- a join and a leave, a spawn and a delete
    node._sent = {}
    local carl = node._join(3, { name = "Carl", accountId = 3 })
    node._emit("playerJoined", carl)
    node._emit("vehicleSpawned", 5)
    node._advance(1000)
    t.eq(#events(1, "status"), 1)
    t.eq(events(1, "status")[1].data.players, 3)
    node._sent = {}
    W.settings.set("language", "ru")
    node._advance(1000)
    t.eq(#events(1, "status"), 0, "a key that is not shown does not push")
end

tests.envelope_and_unknown_ops = function()
    local W, admin = setup()
    t.eq(W.protocol.handle(admin, "not json"), nil)
    t.eq(W.protocol.handle(admin, '{"op":"players.list"}'), nil, "no id: no reply")
    t.eq(W.protocol.handle(admin, '{"id":"x","op":"players.list"}'), nil)
    local r = req(W, admin, 1, 5, nil)
    t.eq(r.error.code, "bad_op")
    r = req(W, admin, 2, "no.such", {})
    t.eq(r.error.code, "unknown_op")
    t.eq(r.error.params.op, "no.such")
    t.eq(W.protocol.handle(admin, string.rep("x", 17000)), nil, "oversize dropped")
end

tests.ops_run_the_same_checks_as_the_chat = function()
    local W, admin, bob = setup()
    local r = req(W, bob, 1, "players.list")
    t.eq(r.ok, false)
    t.eq(r.error.code, "denied")
    t.eq(r.error.params.perm, "players.view")
    r = req(W, admin, 2, "players.list")
    t.eq(r.ok, true)
    t.eq(r.data.count, 2)
    t.eq(r.data.players[2].name, "Bob")
    t.eq(r.data.players[2].group, "default")
    r = req(W, admin, 3, "players.get", { pid = 2 })
    t.eq(r.data.player.key, "acct:2")
    t.eq(r.data.player.cap, 1)
    t.eq(r.data.player.ip, "10.0.0.2")
    r = req(W, admin, 4, "mod.kick", { pid = 2, reason = "bye" })
    t.eq(r.ok, true)
    t.eq(r.data.target.name, "Bob")
    t.eq(#node._kicked, 1)
    r = req(W, admin, 5, "mod.kick", { pid = 2 })
    t.eq(r.error.code, "offline")
    r = req(W, admin, 6, "mod.kick", { pid = "abc" })
    t.eq(r.error.code, "bad_arg")
    -- by key, offline
    r = req(W, admin, 7, "mod.ban", { key = "acct:2", reason = "x" })
    t.eq(r.ok, true)
    t.truthy(node.bans.has(2))
    r = req(W, admin, 8, "mod.bans")
    t.eq(#r.data.bans, 1)
    t.eq(r.data.bans[1].name, "Bob")
    r = req(W, admin, 9, "mod.unban", { key = "acct:2" })
    t.eq(r.ok, true)
    -- the audit rows carry the actor from the panel too
    local rows = W.audit.tail(1)
    t.eq(rows[1].op, "unban")
    t.eq(rows[1].actor.pid, 1)
end

tests.groups_and_settings_ops = function()
    local W, admin, bob = setup({ limits = { ui_per_sec = 100 } })
    W.perms.set_group(admin, "admin")
    local r = req(W, admin, 1, "groups.list")
    t.eq(#r.data.groups, 5)
    t.eq(r.data.groups[1].name, "default")
    -- perms.manage is the owner's by default: an admin may not edit groups
    r = req(W, admin, 2, "groups.save", { group = { name = "vip", level = 20 } })
    t.eq(r.error.code, "denied")
    -- give the admin group the permission (from disk, as the hoster would)
    t.truthy(W.groups.save({ name = "admin", level = 90, inherits = { "mod" },
        perms = { "perms.manage", "perms.set", "mod.ban", "settings.read", "settings.write" }, caps = { vehicles = -1 } }))
    r = req(W, admin, 3, "groups.save", { group = { name = "vip", level = 20, inherits = { "trusted" },
        perms = { "mod.ban" }, caps = { vehicles = 4 } } })
    t.eq(r.ok, true)
    t.eq(r.data.group.level, 20)
    t.eq(W.groups.cap("vip"), 4)
    t.truthy(W.groups.allows("vip", "votekick.start"))
    -- not a permission the admin has themselves; not at or above their level; not "*"
    r = req(W, admin, 4, "groups.save", { group = { name = "vip", level = 20, perms = { "server.reload" } } })
    t.eq(r.error.code, "perm_not_yours")
    r = req(W, admin, 5, "groups.save", { group = { name = "vip", level = 90 } })
    t.eq(r.error.code, "group_too_high")
    r = req(W, admin, 6, "groups.save", { group = { name = "mod", level = 10, perms = { "*" } } })
    t.eq(r.error.code, "bad_perm")
    r = req(W, admin, 7, "groups.save", { group = { name = "owner", level = 5 } })
    t.eq(r.error.code, "group_too_high")
    -- assign, then delete: the player falls back to default
    r = req(W, admin, 8, "groups.set", { pid = 2, group = "vip" })
    t.eq(r.ok, true)
    t.eq(W.perms.group_of(bob), "vip")
    t.eq(bob.role, "vip")
    r = req(W, admin, 9, "groups.delete", { name = "vip" })
    t.eq(r.ok, true)
    t.eq(W.perms.group_of(bob), "default")
    t.eq(bob.role, "")
    r = req(W, admin, 10, "groups.delete", { name = "default" })
    t.eq(r.error.code, "protected")
    -- settings
    r = req(W, admin, 11, "settings.list")
    t.eq(r.ok, true)
    local by_key = {}
    for _, s in ipairs(r.data.settings) do by_key[s.key] = s end
    t.eq(by_key["votekick.threshold"].value, 0.6)
    t.eq(by_key["votekick.threshold"].type, "number")
    t.eq(by_key["votekick.threshold"].max, 1.0)
    t.eq(by_key["language"].enum, { "en", "ru" })
    t.eq(by_key["limits.ui_per_sec"], nil, "not runtime")
    t.eq(by_key["ui.theme"].enum, { "cobalt", "game" })
    t.eq(by_key["ui.default_shown"].value, true)
    t.eq(by_key["spawn.enabled"].value, true)
    r = req(W, admin, 12, "settings.set", { key = "votekick.min_players", value = 3 })
    t.eq(r.ok, true)
    t.eq(W.settings.get("votekick.min_players"), 3)
    r = req(W, admin, 13, "settings.set", { key = "votekick.min_players", value = "many" })
    t.eq(r.error.code, "bad_value")
    r = req(W, admin, 14, "settings.reset", { key = "votekick.min_players" })
    t.eq(r.data.value, 4)
    r = req(W, admin, 15, "audit.tail", { limit = 3 })
    t.eq(r.ok, true, "audit.view inherited from mod")
    t.eq(#r.data.rows, 3)
    t.eq(r.data.rows[1].op, "settings_reset")
end

tests.pushes = function()
    local W, admin, bob = setup()
    local r = req(W, bob, 1, "players.subscribe", { on = true })
    t.eq(r.error.code, "denied")
    r = req(W, admin, 2, "players.subscribe", { on = true })
    t.eq(r.ok, true)
    t.eq(#r.data.players, 2)
    node._sent = {}
    local carl = node._join(3, { name = "Carl", accountId = 3 })
    node._emit("playerJoined", carl)
    W.perms.set_group(carl, "trusted")
    node._emit("playerJoined", node._join(4, { name = "Dee", accountId = 4 }))
    t.eq(#events(1, "players.changed"), 0, "coalesced")
    node._advance(1000)
    local pushes = events(1, "players.changed")
    t.eq(#pushes, 1, "three changes, one push")
    t.eq(#pushes[1].data.players, 4)
    t.eq(pushes[1].data.players[3].group, "trusted")
    t.eq(#events(2, "players.changed"), 0, "bob is not subscribed")
    -- groups.changed and settings.changed
    node._sent = {}
    W.groups.save({ name = "vip", level = 20 })
    t.eq(#events(1, "groups.changed"), 1)
    W.settings.set("allow_guests", false)
    t.eq(#events(1, "settings.changed"), 1)
    t.eq(events(1, "settings.changed")[1].data.value, false)
    -- unsubscribe; a leaving subscriber is dropped
    req(W, admin, 3, "players.subscribe", { on = false })
    node._sent = {}
    node._emit("playerLeft", carl)
    node._leave(3)
    node._advance(1000)
    t.eq(#events(1, "players.changed"), 0)
end

tests.limiter_on_frames = function()
    local W, admin = setup({ limits = { ui_per_sec = 3 } })
    for i = 1, 3 do req(W, admin, i, "me.get") end
    t.eq(#node._sent_of("wd:reply", 1), 3)
    W.protocol.handle(admin, '{"id":4,"op":"me.get"}')
    t.eq(#node._sent_of("wd:reply", 1), 3, "the fourth frame in the second is dropped")
    t.match(node._log_text("info"), "over the limit")
    node._advance(1000)
    req(W, admin, 5, "me.get")
    t.eq(#node._sent_of("wd:reply", 1), 4)
end

tests.bus_api = function()
    local W, admin, bob = setup()
    node._bus = {}
    node.bus.emit("warden:getGroup", { pid = 1, tag = "q1" })
    local answers = node._bus_of("warden:group")
    t.eq(#answers, 1)
    t.eq(answers[1].group, "admin")
    t.eq(answers[1].level, 90)
    t.eq(answers[1].tag, "q1")
    t.eq(answers[1].key, "acct:1")
    t.truthy(#answers[1].perms > 5)
    node.bus.emit("warden:getGroup", { key = "acct:2" })
    t.eq(node._bus_of("warden:group")[2].group, "default")
    node.bus.emit("warden:getGroup", { pid = 77 })
    t.eq(node._bus_of("warden:group")[3].error, "unknown")
    node.bus.emit("warden:hasPerm", { pid = 1, perm = "mod.kick" })
    node.bus.emit("warden:hasPerm", { pid = 2, perm = "mod.kick", tag = "b" })
    local perms = node._bus_of("warden:perm")
    t.eq(perms[1].ok, true)
    t.eq(perms[2].ok, false)
    t.eq(perms[2].tag, "b")
    W.perms.set_group(bob, "mod")
    t.eq(node._bus_of("warden:groupChanged")[1].key, "acct:2")
    -- a JSON string payload works the same (what another resource's emit is on the wire)
    node.bus.emit("warden:hasPerm", '{"pid":2,"perm":"mod.kick"}')
    t.eq(node._bus_of("warden:perm")[3].ok, true)
    t.truthy(admin)
end

return tests
