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
    local r = req(W, admin, 1, "sys.hello", { protocol = 1, uiVersion = "0.1.0", lang = "ru" })
    t.eq(r.ok, true)
    t.eq(r.data.protocol, 1)
    t.eq(r.data.version, "0.0.0-test")
    t.eq(r.data.key, "F9")
    t.eq(r.data.lang, "ru", "the game's language is the default until /lang")
    t.eq(r.data.me.group, "admin")
    t.eq(r.data.me.level, 90)
    t.eq(r.data.me.key, "acct:1")
    t.truthy(#r.data.perms > 5)
    t.eq(r.data.vote, nil)
    t.truthy(#r.data.permissions > 10, "the permission catalogue")
    -- a wrong protocol is refused
    r = req(W, bob, 2, "sys.hello", { protocol = 99 })
    t.eq(r.ok, false)
    t.eq(r.error.code, "ui_outdated")
    t.eq(r.error.params.server, 1)
    -- after hello, notices reach the panel too
    node._sent = {}
    W.say.tell(admin, "done.unban", { target = "X" })
    local n = events(1, "notice")
    t.eq(#n, 1)
    t.eq(n[1].data.text, "Разбанен X.", "in the language hello set")
    t.eq(n[1].data.code, "done.unban")
    W.say.tell(bob, "done.unban", { target = "X" })
    t.eq(#events(2, "notice"), 0, "no hello, no notice push")
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
    t.eq(by_key["ui.key"], nil, "not runtime")
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
