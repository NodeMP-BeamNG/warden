-- Regression tests for the 0.1.0 security review (infra sdd/warden-review.md):
-- H1 inherits in group_save, H2 the rank of an offline owner and ip: keys,
-- H3 names on a server with guests, M1 the audit rows, M2 vote weight and
-- cooldown, M4 prefixes, L1 the limiter, L2 addresses, L3 read-only stores,
-- L4 guest records, L5 no test-hook loader.

local boot = require("boot")

local function setup(overrides)
    -- the scenarios type more than 8 commands per 10 s; the limiter has its own test (l1)
    overrides = overrides or { owner_ids = { 1 } }
    overrides.limits = overrides.limits or {}
    overrides.limits.commands_per_10s = overrides.limits.commands_per_10s or 100
    local W = boot(overrides)
    local owner = node._join(1, { name = "Own", accountId = 1 })
    local admin = node._join(2, { name = "Adm", accountId = 2 })
    local mod = node._join(3, { name = "Mod", accountId = 3 })
    local bob = node._join(4, { name = "Bob", accountId = 4 })
    local guest = node._join(5, { name = "Gus", ip = "5.5.5.5" })
    W.perms.set_group(admin, "admin")
    W.perms.set_group(mod, "mod")
    for _, p in ipairs({ owner, admin, mod, bob, guest }) do node._emit("playerJoined", p) end
    node._told = {}
    return W, owner, admin, mod, bob, guest
end

local function cmd(player, line)
    node.bus.emit("chat:command", { pid = player.id, name = line:match("^/(%S+)"), args = {}, raw = line })
end

local function req(W, player, id, op, data)
    W.protocol.handle(player, node.json.encode({ id = id, op = op, data = data }))
    for _, r in ipairs(node._sent_of("wd:reply", player.id)) do
        if r.id == id then return r end
    end
    return nil
end

local function last_audit(W)
    return W.audit.tail(1)[1]
end

-- a server restart: the data files stay, every module and the stub's live
-- state (timers, handlers, players) start afresh
local DOMAINS = { "core", "identity", "perms", "moderation", "vehicles", "votekick", "commands", "ui", "integration" }

local function restart(W, overrides)
    W.store._reset()
    node._timers, node._handlers, node._bus_handlers, node._watches, node._players = {}, {}, {}, {}, {}
    node._sent, node._told = {}, {}
    for name in pairs(package.loaded) do
        for _, d in ipairs(DOMAINS) do
            if name:sub(1, #d + 1) == d .. "." then package.loaded[name] = nil end
        end
    end
    return boot(overrides)
end

-- the hoster gives the admin group perms.manage (an edit of groups.json)
local function admins_manage_groups(W)
    t.truthy(W.groups.save({ name = "admin", level = 90, inherits = { "mod" },
        perms = { "perms.manage", "perms.set", "mod.ban", "mod.whitelist", "settings.read", "settings.write" },
        caps = { vehicles = -1 } }))
end

local tests = {}

-- ---------------------------------------------------------------------------
-- H1: group_save validates inherits
-- ---------------------------------------------------------------------------

tests.h1_group_save_validates_inherits = function()
    local W, _, admin, _, bob = setup()
    admins_manage_groups(W)
    local actor = W.perms.actor(admin)
    local function save(def) return W.registry.run(actor, "group_save", { group = def }) end
    -- the escalation of the review: a low group inheriting owner
    local r = save({ name = "helper", level = 1, inherits = { "owner" } })
    t.eq(r.error.code, "group_too_high")
    t.eq(r.error.params.group, "owner")
    t.eq(W.groups.get("helper"), nil, "nothing saved")
    -- a parent at the actor's own level is not below it
    r = save({ name = "helper", level = 1, inherits = { "admin" } })
    t.eq(r.error.code, "group_too_high")
    -- a hoster-made low group carrying a permission the admin lacks: inheriting it is granting it
    t.truthy(W.groups.save({ name = "sneaky", level = 5, perms = { "server.reload" } }))
    r = save({ name = "helper", level = 1, inherits = { "sneaky" } })
    t.eq(r.error.code, "perm_not_yours")
    t.eq(r.error.params.perm, "server.reload")
    -- "*" through a parent is refused as "*"
    t.truthy(W.groups.save({ name = "wild", level = 5, perms = { "*" } }))
    r = save({ name = "helper", level = 1, inherits = { "wild" } })
    t.eq(r.error.code, "bad_perm")
    r = save({ name = "helper", level = 1, inherits = { "ghost" } })
    t.eq(r.error.code, "unknown_parent")
    -- what the admin holds may be inherited and granted
    r = save({ name = "helper", level = 1, inherits = { "trusted" }, perms = { "mod.kick" } })
    t.eq(r.ok, true)
    t.truthy(W.groups.allows("helper", "votekick.start"), "inherited from trusted")
    t.truthy(W.groups.allows("helper", "mod.kick"))
    t.falsy(W.groups.allows("helper", "server.reload"))
    local row = last_audit(W)
    t.eq(row.op, "group_save")
    t.eq(row.detail.group.name, "helper", "the validated definition is the row's detail")
    t.match(tostring(row.args.group), "^<table:%d+>$", "the raw table is not copied into the row")
    -- the same rules when editing: an existing group may not gain a parent at or above the actor
    r = save({ name = "helper", level = 1, inherits = { "admin" } })
    t.eq(r.error.code, "group_too_high")
    -- nor may an existing group at or above the actor be touched at all
    r = save({ name = "owner", level = 5, inherits = {} })
    t.eq(r.error.code, "group_too_high")
    r = save({ name = "admin", level = 10 })
    t.eq(r.error.code, "group_too_high")
    -- a cycle is refused
    r = save({ name = "mod", level = 50, inherits = { "helper" }, perms = { "mod.kick" } })
    t.eq(r.ok, true)
    r = save({ name = "helper", level = 1, inherits = { "mod" } })
    t.eq(r.error.code, "cycle")
    -- and Bob in helper never got more than the admin could give
    W.perms.set_group(bob, "helper")
    t.falsy(W.perms.has(bob, "server.reload"))
    t.falsy(W.perms.has(bob, "perms.manage"))
    -- the console is not bound by any of it
    r = W.registry.run(W.perms.CONSOLE, "group_save", { group = { name = "helper", level = 1, inherits = { "sneaky" } } })
    t.eq(r.ok, true)
end

-- ---------------------------------------------------------------------------
-- H2: the rank of an offline owner; ip: keys are literals
-- ---------------------------------------------------------------------------

tests.h2_offline_owner_keeps_rank = function()
    local W, owner, admin = setup({ owner_ids = { 1 } })
    local dadm = node._join(7, { name = "Dir", accountId = 7, accountRoles = "ADM" })
    node._emit("playerJoined", dadm)
    t.eq(W.perms.group_of(dadm), "owner")
    local rec = W.identity.record("acct:7")
    t.eq(rec.owner_role, true, "the directory's ADM flag is remembered")
    t.eq(rec.level, 100)
    t.eq(W.identity.record("acct:2").level, 90, "the level is written at the join")
    -- online: outranked; offline: still outranked (the review banned the owner here)
    cmd(admin, "/ban Own")
    t.match(node._told_text(2), "Own is not below your level")
    node._leave(1)
    node._told = {}
    cmd(admin, "/ban Own")
    t.match(node._told_text(2), "Own is not below your level")
    t.falsy(node.bans.has(1))
    cmd(admin, "/group acct:1 default")
    t.match(node._told_text(2), "not below your level")
    t.eq(W.perms.group_of_key("acct:1"), "owner")
    t.eq(W.perms.level_of_key("acct:1"), 100)
    -- the directory admin, offline, through the remembered flag
    node._leave(7)
    node._told = {}
    cmd(admin, "/ban Dir")
    t.match(node._told_text(2), "Dir is not below your level")
    t.falsy(node.bans.has(7))
    t.eq(last_audit(W).reason, "outranked")
    -- the flag goes at the first join without the role
    dadm = node._join(7, { name = "Dir", accountId = 7 })
    node._emit("playerJoined", dadm)
    t.eq(W.identity.record("acct:7").owner_role, nil)
    t.eq(W.identity.record("acct:7").level, 0)
    node._leave(7)
    node._told = {}
    cmd(admin, "/ban Dir")
    t.match(node._told_text(2), "Banned Dir")
    -- even the console does not move an owner into a group: the config owns that
    local r = W.registry.run(W.perms.CONSOLE, "group_set", { target = "acct:1", group = "mod" })
    t.eq(r.error.code, "owner_is_config")
    t.eq(select(2, W.perms.set_group(owner, "mod")), "owner_is_config")
    -- and the switch off means the flag is not honoured
    local W2 = boot({ directory_admin_is_owner = false })
    node._join(7, { name = "Dir", accountId = 7, accountRoles = "ADM" })
    node._emit("playerJoined", node.players.get(7))
    t.eq(W2.identity.record("acct:7").owner_role, nil)
    t.eq(W2.perms.group_of_key("acct:7"), "default")
end

tests.h2_ip_keys_are_literals = function()
    local W, _, admin, _, _, _ = setup()
    local id = W.identity
    for _, ok in ipairs({ "1.2.3.4", "255.255.255.255", "::1", "::", "fe80::1", "2001:db8::ff00:42:8329",
        "::ffff:192.168.1.1", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:1.2.3.4" }) do
        t.truthy(id.is_ip(ok), ok)
    end
    for _, bad in ipairs({ "nodemp:1", "1.2.3", "1.2.3.256", "1.2.3.4.5", "dead:beef", ":1", "1::2::3", "1:::2",
        "1:2:3:4:5:6:7:8:9", "12345::", "fe80::1%eth0", "[::1]", "abc", "", "1.2.3.4:5" }) do
        t.falsy(id.is_ip(bad), bad)
    end
    t.eq(id.parse_key("acct:007"), "acct:7")
    t.eq(id.parse_key("acct:x"), nil)
    t.eq(id.parse_key("ip:1.2.3.4"), "ip:1.2.3.4")
    t.eq(id.parse_key("ip:nodemp:1"), nil)
    t.eq(id.ban_target("ip:nodemp:1"), nil)
    -- the review's bypass: an account ban smuggled in as an "ip"
    cmd(admin, "/ban ip:nodemp:1")
    t.match(node._told_text(2), "'ip:nodemp:1' is not a key")
    t.eq(node._bans["nodemp:1"], nil)
    t.eq(last_audit(W).reason, "bad_key")
    node._told = {}
    cmd(admin, "/whitelist add ip:nodemp:1")
    t.match(node._told_text(2), "is not a key")
    node._told = {}
    cmd(admin, "/unban acct:abc")
    t.match(node._told_text(2), "is not a key")
    -- a literal nobody is behind is a ban all the same (a pre-emptive one)
    node._told = {}
    cmd(admin, "/ban ip:1.2.3.4 known proxy")
    t.match(node._told_text(2), "Banned ip:1.2.3.4: known proxy")
    t.truthy(node.bans.has("1.2.3.4"))
    -- the address the owner sits behind ranks as the owner does
    node._told = {}
    cmd(admin, "/ban ip:10.0.0.1")
    t.match(node._told_text(2), "not below your level")
    t.falsy(node.bans.has("10.0.0.1"))
    -- a guest's address is theirs
    cmd(admin, "/tempban ip:5.5.5.5 1h")
    t.truthy(node.bans.has("5.5.5.5"))
    -- unban: a key stored from before the check comes off through what was banned
    local meta = W.store.open("bans_meta")
    meta.data["ip:nodemp:1"] = { who = "nodemp:1", name = "Own", at = 1 }
    node._bans["nodemp:1"] = { reason = "x", account = 1 }
    node._told = {}
    cmd(admin, "/unban ip:nodemp:1")
    t.match(node._told_text(2), "Unbanned ip:nodemp:1")
    t.eq(node._bans["nodemp:1"], nil)
    t.eq(meta.data["ip:nodemp:1"], nil)
    node._told = {}
    cmd(admin, "/unban ip:nodemp:1")
    t.match(node._told_text(2), "is not a key", "gone from the store, it is a bad key again")
    cmd(admin, "/unban acct:4")
    t.match(node._told_text(2), "Not banned")
end

-- ---------------------------------------------------------------------------
-- H3: names on a server with guests
-- ---------------------------------------------------------------------------

tests.h3_names_never_hand_privileges_to_guests = function()
    local W, _, admin, mod, bob, guest = setup()
    -- a guest signs in under an account holder's name
    local impostor = node._join(6, { name = "Bob", ip = "6.6.6.6" })
    node._emit("playerJoined", impostor)
    -- the connected, signed-in Bob wins the name
    cmd(admin, "/group Bob trusted")
    t.match(node._told_text(2), "Bob is now in trusted")
    t.eq(W.perms.group_of(bob), "trusted")
    t.eq(W.perms.group_of(impostor), "default", "the guest got nothing")
    -- the account holder leaves: the name is now in doubt, nobody guesses
    node._leave(4)
    node._told = {}
    cmd(admin, "/group Bob mod")
    t.match(node._told_text(2), "'Bob' matches several players: ip:6%.6%.6%.6 #6 guest, acct:4%. Use #pid or the key")
    t.eq(W.perms.group_of_key("acct:4"), "trusted", "unchanged")
    t.eq(W.perms.group_of(impostor), "default")
    t.eq(last_audit(W).reason, "ambiguous")
    node._told = {}
    cmd(admin, "/ban Bob")
    t.match(node._told_text(2), "matches several players")
    t.eq(#node._banned, 0)
    -- the pid and the key are never in doubt
    cmd(admin, "/group #6 trusted")
    t.eq(W.perms.group_of(impostor), "trusted")
    cmd(admin, "/group acct:4 mod")
    t.eq(W.perms.group_of_key("acct:4"), "mod")
    -- a lone guest by name: moderation yes, privileges no
    node._told = {}
    cmd(admin, "/group Gus trusted")
    t.match(node._told_text(2), "'Gus' is a guest's name and proves nothing; use #pid or the key %(ip:5%.5%.5%.5%)")
    t.eq(W.perms.group_of(guest), "default")
    t.eq(last_audit(W).reason, "guest_by_name")
    node._told = {}
    cmd(admin, "/whitelist add Gus")
    t.match(node._told_text(2), "is a guest's name")
    node._told = {}
    cmd(mod, "/mute Gus 30m")
    t.match(node._told_text(3), "Muted Gus")
    cmd(admin, "/ban Gus")
    t.truthy(node.bans.has("5.5.5.5"))
    -- the addresses in a refusal are for mod.ban and up
    node._join(7, { name = "Zed", ip = "7.7.7.7" })
    node._emit("playerJoined", node.players.get(7))
    local rec = W.identity.record("acct:8", true)
    rec.names = { "Zed" }
    node._told = {}
    cmd(mod, "/mute Zed")
    t.match(node._told_text(3), "'Zed' matches several players: ip:7%.7%.%*%.%* #7 guest, acct:8")
    node._told = {}
    cmd(admin, "/mute Zed")
    t.match(node._told_text(2), "ip:7%.7%.7%.7 #7 guest")
    -- the permission is checked before the name: a refusal tells nothing about who exists
    bob = node._join(4, { name = "Bob", accountId = 4 })
    W.perms.set_group(bob, "default")
    node._told = {}
    cmd(bob, "/ban Nobody")
    t.match(node._told_text(4), "You may not do that %(mod%.ban%)")
    t.falsy(node._told_text(4):find("No player", 1, true))
    cmd(bob, "/ban Zed")
    t.falsy(node._told_text(4):find("matches several", 1, true), "nor which keys share a name")
    -- two connected signed-in players whose names differ in case only
    node._join(9, { name = "bob", accountId = 9 })
    node._told = {}
    cmd(mod, "/kick bob")
    t.eq(node._kicked[#node._kicked].id, 9, "the exact spelling wins")
    node._join(9, { name = "bob", accountId = 9 })
    node._told = {}
    cmd(mod, "/kick BOB")
    t.match(node._told_text(3), "matches several players: acct:4 #4, ip:6%.6%.%*%.%* #6 guest, acct:9 #9")
    -- acting on oneself by name is oneself, whoever else shares the name
    node._told = {}
    node._vehicle(100, 9)
    cmd(node.players.get(9), "/car delete Bob")
    t.match(node._told_text(9), "Deleted 1 vehicle%(s%) of bob")
end

tests.h3_name_whitelist_admits_signed_in_accounts_only = function()
    local W, _, admin, _, _, guest = setup()
    cmd(admin, "/whitelist on")
    node._told = {}
    cmd(admin, "/whitelist add Carl")
    t.match(node._told_text(2), "Whitelisted name:carl: a name entry admits a signed%-in account of that name at its "
        .. "first join, never a guest")
    -- a guest of that name is refused; the entry stays as it was
    local guest_carl = node._join(8, { name = "Carl", ip = "9.9.9.9" })
    t.eq(node._emit("playerConnectRequest", guest_carl, -1, "Carl"), false)
    node._leave(8)
    local entries = {}
    for _, e in ipairs(W.whitelist.list()) do entries[e.entry] = true end
    t.truthy(entries["name:carl"], "not consumed by the guest")
    t.falsy(entries["ip:9.9.9.9"])
    -- a signed-in account of that name is admitted and the entry becomes the key
    local carl = node._join(8, { name = "Carl", accountId = 99 })
    t.eq(node._emit("playerConnectRequest", carl, -1, "Carl"), true)
    entries = {}
    for _, e in ipairs(W.whitelist.list()) do entries[e.entry] = true end
    t.truthy(entries["acct:99"])
    t.falsy(entries["name:carl"])
    -- verified but a guest (a Test Drive session): still not an account
    cmd(admin, "/whitelist add Dora")
    local dora = node._join(10, { name = "Dora", ip = "10.10.10.10", verified = true, guest = true })
    t.eq(node._emit("playerConnectRequest", dora, -1, "Dora"), false)
    -- guests go on the list by pid or key, never by name
    node._told = {}
    cmd(admin, "/whitelist add Gus")
    t.match(node._told_text(2), "is a guest's name")
    cmd(admin, "/whitelist add #5")
    t.eq(node._emit("playerConnectRequest", guest, -1, "Gus"), true)
    node._told = {}
    cmd(admin, "/whitelist remove Gus")
    t.match(node._told_text(2), "is a guest's name")
    cmd(admin, "/whitelist remove ip:5.5.5.5")
    t.eq(node._emit("playerConnectRequest", guest, -1, "Gus"), false)
    -- a name entry is removed by its name even while a guest of that name is connected
    node._told = {}
    cmd(admin, "/whitelist remove Dora")
    t.match(node._told_text(2), "Removed name:dora")
end

-- ---------------------------------------------------------------------------
-- M1: the audit rows
-- ---------------------------------------------------------------------------

tests.m1_audit_rows_carry_shape_fields_only_and_are_capped = function()
    local W, _, admin, _, bob = setup({ limits = { ui_per_sec = 100 } })
    -- the review's stuffing: a refused frame with 15 KB of junk
    local r = req(W, bob, 1, "mod.kick", { pid = 1, junk = string.rep("x", 15000) })
    t.eq(r.error.code, "denied")
    local row = last_audit(W)
    t.eq(row.args, { pid = 1 })
    t.eq(row.dropped, 1)
    t.truthy(#node.json.encode(row) < 512, "a small row")
    -- strings the shape allows are cut to the row's limit even when refused
    req(W, bob, 2, "mod.kick", { pid = 1, reason = string.rep("r", 5000) })
    t.truthy(#last_audit(W).args.reason <= 200)
    -- a success keeps the validated fields; a table field is not copied
    admins_manage_groups(W)
    r = req(W, admin, 3, "groups.save", { group = { name = "vip", level = 20, perms = { "mod.kick" }, junk = "x" } })
    t.eq(r.ok, true)
    row = last_audit(W)
    t.eq(row.args.group, "<table:4>")
    t.eq(row.detail.group.name, "vip")
    -- a row past MAX_ROW_BYTES loses args and detail, marked
    local big = W.audit.log({ actor = { name = "a", key = "acct:1" }, op = "x", args = { s = string.rep("y", 2000) } })
    t.eq(big.truncated, true)
    t.eq(big.args, nil)
    node._advance(1000)
    for line in node._files["data/audit/2023-11-14.jsonl"]:gmatch("[^\n]+") do
        t.truthy(#line <= W.audit.MAX_ROW_BYTES, "every line within the cap")
    end
end

tests.m1_audit_is_appended_in_bounded_parts = function()
    local W = boot({})
    local audit = require("core.audit")
    audit.MAX_FILE_BYTES = 250
    for i = 1, 4 do
        audit.log({ actor = { name = "a" }, op = "op" .. i, result = "ok" })
        node._advance(1000)
    end
    -- rows go to the day's file until it is full, then to .2, .3 ...
    local names = {}
    for _, e in ipairs(node.fs.list("data/audit")) do names[#names + 1] = e.name end
    t.eq(names, { "2023-11-14.2.jsonl", "2023-11-14.jsonl" })
    t.truthy(#node._files["data/audit/2023-11-14.jsonl"] <= 250 + 150, "the first part stopped growing")
    t.match(node._files["data/audit/2023-11-14.2.jsonl"], '"op":"op4"')
    -- a flush writes the buffer only; nothing of the day is kept in memory
    t.eq(audit.pending(), 0)
    audit.log({ actor = { name = "a" }, op = "op5" })
    t.eq(audit.pending(), 1)
    -- a disk that refuses keeps the buffer for the next flush
    local write = node.fs.write
    node.fs.write = function() return false end
    node._advance(1000)
    t.eq(audit.pending(), 1)
    t.match(node._log_text("error"), "kept for the next flush")
    node.fs.write = write
    audit.log({ actor = { name = "a" }, op = "op6" })
    node._advance(1000)
    t.eq(audit.pending(), 0)
    -- a restart warms the tail from every part, in order, and the sequence continues
    W = restart(W, {})
    local tail = W.audit.tail(10)
    t.eq(tail[1].op, "op6")
    t.eq(tail[6].op, "op1")
    t.eq(W.audit.log({ op = "op7" }).seq, 7)
    -- old parts are pruned like old days
    node._files["data/audit/2000-01-01.3.jsonl"] = "{}\n"
    restart(W, {})
    t.eq(node._files["data/audit/2000-01-01.3.jsonl"], nil)
end

-- ---------------------------------------------------------------------------
-- M2: vote weight by identity, the default, the cooldown store, immunity
-- ---------------------------------------------------------------------------

tests.m2_votes_weigh_by_identity = function()
    local W = boot({ votekick = { enabled = true, cooldown_sec = 0 } })
    local P = {}
    for i = 1, 4 do P[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    W.perms.set_group(P[1], "trusted")
    -- two guests behind one address: one voter
    local g1 = node._join(5, { name = "G1", ip = "7.7.7.7" })
    local g2 = node._join(6, { name = "G2", ip = "7.7.7.7" })
    for _, p in ipairs({ P[1], P[2], P[3], P[4], g1, g2 }) do node._emit("playerJoined", p) end
    cmd(P[1], "/votekick P3")
    local s = W.votekick.state()
    t.eq(s.eligible, 4, "P1, P2, P4 and the address, not six heads less one")
    t.eq(s.needed, 3)
    cmd(g1, "/vote yes")
    cmd(g2, "/vote yes")
    t.eq(W.votekick.state().yes, 2, "the starter and the address: the second guest changed nothing")
    t.eq(#node._kicked, 0)
    cmd(g2, "/vote no")
    t.eq(W.votekick.state().yes, 1, "the address's last word counts")
    t.eq(W.votekick.state().no, 1)
    cmd(g1, "/vote yes")
    cmd(P[2], "/vote yes")
    t.eq(#node._kicked, 1)
    t.eq(node._kicked[1].name, "P3")
    -- min_players counts identities: three accounts and two same-address guests are four
    local W2 = restart(W, { votekick = { enabled = true, cooldown_sec = 0 } })
    for i = 1, 2 do P[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    node._join(5, { name = "G1", ip = "7.7.7.7" })
    g2 = node._join(6, { name = "G2", ip = "7.7.7.7" })
    W2.perms.set_group(P[1], "trusted")
    node._told = {}
    cmd(P[1], "/votekick P2")
    t.match(node._told_text(1), "at least 4 players")
    node._join(3, { name = "P3", accountId = 3 })
    node._told = {}
    cmd(P[1], "/votekick G1")
    t.truthy(W2.votekick.running())
    t.eq(W2.votekick.state().eligible, 3, "P1, P2, P3: the target's address is out, G2 with it")
    -- a guest cannot vote against the identity they share
    node._told = {}
    cmd(g2, "/vote yes")
    t.match(node._told_text(6), "The target does not vote")
end

tests.m2_off_by_default_cooldown_persists_immunity_at_the_end = function()
    local W = boot({})
    t.eq(W.settings.get("votekick.enabled"), false, "the spec: off unless the hoster turns it on")
    local P = {}
    for i = 1, 5 do P[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    W.perms.set_group(P[1], "trusted")
    cmd(P[1], "/votekick P3")
    t.match(node._told_text(1), "Vote%-kick is off")
    -- on: a finished vote puts the target and the starter on cooldown, in the store
    W = boot({ votekick = { enabled = true, cooldown_sec = 600 } })
    for i = 1, 5 do P[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    W.perms.set_group(P[1], "trusted")
    cmd(P[1], "/votekick P3")
    cmd(P[2], "/vote no")
    cmd(P[4], "/vote no")
    cmd(P[5], "/vote no")
    t.falsy(W.votekick.running())
    node._advance(1000)
    local saved = node.json.decode(node._files["data/votekick.json"])
    t.eq(saved.cooldown["acct:3"], 1700000000 + 600)
    t.eq(saved.cooldown["acct:1"], 1700000000 + 600)
    -- a restart (the files stay) keeps the cooldown
    W = restart(W, { votekick = { enabled = true, cooldown_sec = 600 } })
    for i = 1, 5 do P[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    W.perms.set_group(P[1], "trusted")
    W.perms.set_group(P[2], "trusted")
    node._told = {}
    cmd(P[1], "/votekick P4")
    t.match(node._told_text(1), "Wait 599 s before another vote", "the starter's cooldown survived")
    node._told = {}
    cmd(P[2], "/votekick P3")
    t.match(node._told_text(2), "Wait 599 s before another vote", "the target's too")
    t.eq(W.votekick.cooldown_left("acct:3"), 599)
    node._advance(600 * 1000)
    t.eq(W.votekick.cooldown_left("acct:3"), 0)
    -- a target who becomes immune while the vote runs is not kicked
    cmd(P[2], "/votekick P3")
    t.truthy(W.votekick.running())
    W.perms.set_group(P[3], "mod")
    cmd(P[4], "/vote yes")
    cmd(P[5], "/vote yes")
    t.falsy(W.votekick.running())
    t.eq(#node._kicked, 0)
    t.match(node._told_text(1), "Vote to kick P3 failed")
    node._advance(1000)
    saved = node.json.decode(node._files["data/votekick.json"])
    t.eq(saved.cooldown["acct:3"], 1700000000 + 601 + 600, "a failed vote is a vote: cooldown")
end

-- ---------------------------------------------------------------------------
-- M4: prefixes only for the read-only kinds
-- ---------------------------------------------------------------------------

tests.m4_prefixes_only_for_read_kinds = function()
    local W, _, admin, mod = setup()
    local alex = node._join(6, { name = "Alexander", accountId = 6 })
    node._emit("playerJoined", alex)
    cmd(admin, "/tempban al 1h")
    t.match(node._told_text(2), "No player matches 'al'")
    t.falsy(node.bans.has(6))
    node._told = {}
    cmd(mod, "/kick Alex")
    t.match(node._told_text(3), "No player matches 'Alex'")
    cmd(mod, "/warn Alexand hi")
    t.match(node._told_text(3), "No player matches 'Alexand'")
    t.eq(#node._kicked, 0)
    -- the exact name, case-insensitively; the pid; the key
    local r = W.registry.run(W.perms.actor(mod), "player_get", { target = "alex" })
    t.eq(r.ok, true, "read-only: a unique prefix of a connected name is fine")
    t.eq(r.data.player.pid, 6)
    node._join(7, { name = "Alexis", accountId = 7 })
    r = W.registry.run(W.perms.actor(mod), "player_get", { target = "alex" })
    t.eq(r.error.code, "ambiguous")
    node._told = {}
    cmd(mod, "/mute alexander")
    t.match(node._told_text(3), "Muted Alexander")
    cmd(mod, "/kick #6 bye")
    t.eq(node._kicked[1].name, "Alexander")
    node._join(6, { name = "Alexander", accountId = 6 })
    cmd(mod, "/kick acct:6 bye")
    t.eq(#node._kicked, 2)
end

-- ---------------------------------------------------------------------------
-- L1: the limiter covers unknown commands
-- ---------------------------------------------------------------------------

tests.l1_limiter_covers_unknown_commands = function()
    setup({ limits = { commands_per_10s = 8 } })
    local bob = node.players.get(4)
    for _ = 1, 50 do cmd(bob, "/zzz") end
    local unknown, limited = 0, 0
    for _, m in ipairs(node._told) do
        if m.id == 4 and m.text:find("Unknown command", 1, true) then unknown = unknown + 1 end
        if m.id == 4 and m.text:find("Too many commands", 1, true) then limited = limited + 1 end
    end
    t.eq(unknown, 8, "commands_per_10s")
    t.eq(limited, 42)
end

-- ---------------------------------------------------------------------------
-- L2: addresses for mod.ban and up
-- ---------------------------------------------------------------------------

tests.l2_addresses_only_for_mod_ban = function()
    local W, _, admin, mod = setup({ limits = { ui_per_sec = 100 } })
    local id = W.identity
    t.eq(id.mask_ip("10.0.0.4"), "10.0.*.*")
    t.eq(id.mask_ip("2001:db8::ff00:42:8329"), "2001:db8:*")
    t.eq(id.mask_key("ip:5.5.5.5"), "ip:5.5.*.*")
    t.eq(id.mask_key("acct:4"), "acct:4")
    t.eq(id.mask({ a = "ip:5.5.5.5", b = { c = "5.5.5.5", d = "Gus" } }), { a = "ip:5.5.*.*", b = { c = "5.5.*.*", d = "Gus" } })
    -- a mod has players.view but not mod.ban
    local r = req(W, mod, 1, "players.get", { pid = 4 })
    t.eq(r.data.player.ip, "10.0.*.*")
    t.eq(r.data.player.key, "acct:4")
    r = req(W, mod, 2, "players.get", { pid = 5 })
    t.eq(r.data.player.ip, "5.5.*.*")
    t.eq(r.data.player.key, "ip:5.5.*.*")
    r = req(W, mod, 3, "players.get", { pid = 3 })
    t.eq(r.data.player.ip, "10.0.0.3", "one's own address")
    r = req(W, mod, 4, "me.get")
    t.eq(r.data.me.ip, "10.0.0.3")
    r = req(W, mod, 5, "sys.hello", { protocol = W.protocol.PROTOCOL })
    t.eq(r.data.me.ip, "10.0.0.3")
    -- an admin sees them
    r = req(W, admin, 6, "players.get", { pid = 5 })
    t.eq(r.data.player.ip, "5.5.5.5")
    t.eq(r.data.player.key, "ip:5.5.5.5")
    -- the audit tail: the keys and addresses in the rows
    cmd(admin, "/ban Gus")
    r = req(W, mod, 7, "audit.tail", { limit = 1 })
    t.eq(r.data.rows[1].target.key, "ip:5.5.*.*")
    r = req(W, admin, 8, "audit.tail", { limit = 1 })
    t.eq(r.data.rows[1].target.key, "ip:5.5.5.5")
    t.eq(r.data.rows[1].actor.key, "acct:2")
end

-- ---------------------------------------------------------------------------
-- L3: a read-only store is reported, not a silent drop
-- ---------------------------------------------------------------------------

tests.l3_readonly_store_is_reported = function()
    local W, _, admin, _, bob = setup()
    node._advance(4000)
    -- the hoster saves half a file: memory is kept, the file is left alone, writes stop
    node._files["data/players.json"] = "{ \"acct:4\": { \"group\": "
    node._touch("data/players.json")
    t.truthy(W.identity.record("acct:2"), "the records in memory survived the broken file")
    t.match(node._log_text("warn"), "does not parse any more; keeping the state in memory")
    node._told = {}
    cmd(admin, "/group Bob trusted")
    t.match(node._told_text(2), "Applied for now but NOT saved: data/players%.json does not parse")
    t.eq(W.perms.group_of(bob), "trusted", "in memory")
    local row = W.audit.tail(1)[1]
    t.eq(row.op, "group_set")
    t.eq(row.reason, "store_readonly")
    t.match(node._log_text("error"), "players: a change was not saved")
    t.match(node._log_text("info"), "group_set by Adm: not saved, data/players.json is read%-only")
    node._advance(5000)
    t.eq(node._files["data/players.json"], "{ \"acct:4\": { \"group\": ", "never overwritten")
    t.eq(W.store.readonly_stores(), { "players" })
    -- the panel gets the same code
    W.protocol.handle(admin, '{"id":1,"op":"mod.warn","data":{"pid":4,"reason":"x"}}')
    t.eq(node._sent_of("wd:reply", 2)[1].error.code, "store_readonly")
    -- fixed: writes resume and the next change is saved
    node._files["data/players.json"] = node.json.encode(W.identity.all())
    node._touch("data/players.json")
    t.eq(W.store.readonly_stores(), {})
    node._told = {}
    cmd(admin, "/group Bob mod")
    t.match(node._told_text(2), "Bob is now in mod")
    node._advance(1000)
    t.match(node._files["data/players.json"], '"group": "mod"')
end

-- ---------------------------------------------------------------------------
-- L4: guest records are bounded
-- ---------------------------------------------------------------------------

tests.l4_guest_records_are_bounded = function()
    local W = boot({})
    W.identity.MAX_GUEST_RECORDS = 20
    for i = 1, 25 do
        local g = node._join(100 + i, { name = "G" .. i, ip = "10.1." .. i .. ".1" })
        node._emit("playerJoined", g)
        if i == 3 then W.mutes.warn({ key = "ip:10.1.3.1" }, W.perms.CONSOLE, "kept") end
        node._leave(100 + i)
        node._advance(1000)
    end
    t.eq(W.identity.guest_count(), 20)
    t.eq(W.identity.record("ip:10.1.1.1"), nil, "the oldest bare record went")
    t.eq(W.identity.record("ip:10.1.6.1"), nil)
    t.truthy(W.identity.record("ip:10.1.7.1"))
    t.truthy(W.identity.record("ip:10.1.3.1"), "a record with a warning is kept whatever its age")
    t.truthy(W.identity.record("ip:10.1.25.1"))
    -- accounts are never counted or evicted
    for i = 1, 30 do
        node._emit("playerJoined", node._join(200 + i, { name = "A" .. i, accountId = 500 + i }))
    end
    t.eq(W.identity.guest_count(), 20)
    t.truthy(W.identity.record("acct:501"))
    -- a start with too many trims them
    node._advance(1000)
    local data = node.json.decode(node._files["data/players.json"])
    for i = 1, 30 do data["ip:10.2." .. i .. ".1"] = { names = { "X" }, last_seen = i, joins = 1 } end
    node._files["data/players.json"] = node.json.encode(data)
    local W2 = restart(W, {})
    t.eq(W2.identity.guest_count(), 50, "read back from the file")
    W2.identity.MAX_GUEST_RECORDS = 20
    t.eq(W2.identity.trim_guests(), 30)
    t.eq(W2.identity.guest_count(), 20)
end

-- ---------------------------------------------------------------------------
-- L5: no test-hook loader in the release main.lua
-- ---------------------------------------------------------------------------

tests.l5_no_test_hook_loader_in_main = function()
    local sep = package.config:sub(1, 1)
    local path = table.concat({ WD_ROOT, "resources", "warden", "server", "main.lua" }, sep)
    local f = assert(io.open(path, "rb"))
    local text = f:read("a")
    f:close()
    t.falsy(text:find("require%s*%(?%s*[\"']dev%.test_hooks"), "main.lua requires no dev.test_hooks")
    t.falsy(text:find("WD_TEST_HOOKS", 1, true), "and reads no such variable")
    boot({})
    t.eq(node._handler_count("wd:_test.query"), 0)
end

return tests
