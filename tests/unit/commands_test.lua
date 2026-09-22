-- The chat commands end to end: permission, rank, target resolution, the
-- effect, the answer in the player's language, the audit row.

local boot = require("boot")

local function setup(overrides)
    local W = boot(overrides or {})
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

-- the command line as the chat resource publishes it
local function cmd(_, player, line)
    node.bus.emit("chat:command", { pid = player.id, name = line:match("^/(%S+)"), args = {}, raw = line })
end

local function last_audit(W)
    return W.audit.tail(1)[1]
end

local tests = {}

tests.kick_needs_permission_and_rank = function()
    local W, owner, admin, mod, bob = setup({ owner_ids = { 1 } })
    cmd(W, bob, "/kick Mod")
    t.match(node._told_text(4), "You may not do that %(mod%.kick%)")
    t.eq(#node._kicked, 0)
    t.eq(last_audit(W).result, "denied")
    t.eq(last_audit(W).reason, "denied")
    node._told = {}
    cmd(W, mod, "/kick Adm afk")
    t.match(node._told_text(3), "Adm is not below your level")
    t.eq(last_audit(W).reason, "outranked")
    node._told = {}
    cmd(W, mod, "/kick Bob too fast")
    t.eq(#node._kicked, 1)
    t.eq(node._kicked[1].reason, "too fast")
    t.match(node._told_text(3), "Kicked Bob: too fast")
    t.match(node._told_text(4), "You are being kicked by Mod: too fast")
    local row = last_audit(W)
    t.eq(row.op, "kick")
    t.eq(row.result, "ok")
    t.eq(row.actor.name, "Mod")
    t.eq(row.target.name, "Bob")
    t.eq(row.args.reason, "too fast")
    -- owner outranks admin, admin does not outrank owner
    node._told = {}
    cmd(W, admin, "/kick Own")
    t.match(node._told_text(2), "not below your level")
    cmd(W, owner, "/kick #2")
    t.eq(#node._kicked, 2)
    t.eq(node._kicked[2].name, "Adm")
end

tests.target_resolution_and_errors = function()
    local W, _, _, mod = setup()
    cmd(W, mod, "/kick Nobody")
    t.match(node._told_text(3), "No player matches 'Nobody'")
    node._told = {}
    cmd(W, mod, "/kick")
    t.match(node._told_text(3), "Usage: /kick <player> %[reason%]")
    node._told = {}
    cmd(W, mod, "/frobnicate")
    t.match(node._told_text(3), "Unknown command /frobnicate")
    node._told = {}
    cmd(W, mod, '/kick "bob"')
    t.eq(#node._kicked, 1, "case-insensitive name")
end

tests.ban_tempban_unban = function()
    local W, _, admin, mod = setup()
    cmd(W, mod, "/ban Bob")
    t.match(node._told_text(3), "You may not do that %(mod%.ban%)")
    cmd(W, admin, "/ban Bob cheating")
    t.eq(#node._banned, 1)
    t.truthy(node.bans.has(4), "the account is banned")
    t.truthy(W.bans.meta("acct:4"))
    t.eq(W.bans.meta("acct:4").reason, "cheating")
    t.eq(W.bans.meta("acct:4").by_name, "Adm")
    t.eq(#W.bans.list(), 1)
    -- offline unban by name (from the history)
    node._told = {}
    cmd(W, admin, "/unban Bob")
    t.match(node._told_text(2), "Unbanned Bob")
    t.falsy(node.bans.has(4))
    t.eq(W.bans.meta("acct:4"), nil)
    cmd(W, admin, "/unban Bob")
    t.match(node._told_text(2), "Not banned")
    -- tempban: the mod may; it expires
    node._join(4, { name = "Bob", accountId = 4 })
    node._told = {}
    cmd(W, mod, "/tempban Bob 2h griefing")
    t.match(node._told_text(3), "Banned Bob for 2h: griefing")
    t.truthy(node.bans.has(4))
    t.eq(W.bans.meta("acct:4")["until"], 1700000000 + 7200)
    node._advance(3600 * 1000)
    t.truthy(node.bans.has(4), "still banned after an hour")
    node._advance(3601 * 1000)
    t.falsy(node.bans.has(4), "lifted by the timer")
    t.eq(W.bans.meta("acct:4"), nil)
    -- a bad duration is a usage error
    node._told = {}
    cmd(W, mod, "/tempban Gus soon")
    t.match(node._told_text(3), "Usage: /tempban")
    -- a guest is banned by ip
    cmd(W, mod, "/tempban Gus 30m")
    t.truthy(node.bans.has("5.5.5.5"))
    t.eq(W.bans.meta("ip:5.5.5.5").who, "5.5.5.5")
end

tests.mute_warn_and_the_notice = function()
    local W, _, _, mod, bob = setup()
    cmd(W, mod, "/mute Bob 30m spam")
    t.match(node._told_text(3), "Muted Bob %(30m%): spam")
    t.match(node._told_text(4), "You are muted %(30m%) by Mod: spam")
    t.truthy(W.mutes.is_muted("acct:4"))
    -- a chat line: told once per NOTICE_S
    node._told = {}
    node._emit("chat:send", bob, '{"text":"hello"}')
    node._emit("chat:send", bob, '{"text":"hello again"}')
    t.eq(#node._told, 1)
    node._emit("chat:send", bob, '{"text":"/help"}')
    t.eq(#node._told, 1, "a command line is not a chat line")
    node._advance(1800 * 1000 + 1000)
    t.falsy(W.mutes.is_muted("acct:4"), "expired")
    -- without a duration: until unmuted
    cmd(W, mod, "/mute Bob")
    t.truthy(W.mutes.is_muted("acct:4"))
    node._told = {}
    cmd(W, mod, "/unmute Bob")
    t.match(node._told_text(3), "Unmuted Bob")
    t.match(node._told_text(4), "You may speak again")
    t.falsy(W.mutes.is_muted("acct:4"))
    -- warn
    node._told = {}
    cmd(W, mod, "/warn Bob no ramming")
    cmd(W, mod, "/warn Bob again")
    t.match(node._told_text(3), "Warned Bob %(#2%): again")
    t.match(node._told_text(4), "Warning #1 from Mod: no ramming")
    t.eq(#W.mutes.warns("acct:4"), 2)
    cmd(W, mod, "/warn Bob")
    t.match(node._told_text(3), "Usage: /warn")
end

tests.mute_veto_when_the_platform_has_the_event = function()
    local W, _, _, mod, bob = setup({ chat_veto_event = "chatMessageRequest" })
    t.eq(node._handler_count("chatMessageRequest"), 1)
    cmd(W, mod, "/mute Bob")
    local ok, reason = node._emit("chatMessageRequest", bob, nil, "hi")
    t.eq(ok, false)
    t.eq(reason, "")
    cmd(W, mod, "/unmute Bob")
    t.eq(node._emit("chatMessageRequest", bob, nil, "hi"), true)
end

tests.whitelist_and_guests_at_the_gate = function()
    local W, _, admin, _, bob, guest = setup()
    t.eq(node._emit("playerConnectRequest", bob, -1, "Bob"), true)
    cmd(W, admin, "/whitelist on")
    t.truthy(W.whitelist.enabled())
    local ok, reason = node._emit("playerConnectRequest", bob, -1, "Bob")
    t.eq(ok, false)
    t.eq(reason, "You are not on this server's whitelist.")
    t.eq(W.audit.tail(1)[1].reason, "whitelist")
    cmd(W, admin, "/whitelist add Bob")
    t.match(node._told_text(2), "Whitelisted acct:4")
    t.eq(node._emit("playerConnectRequest", bob, -1, "Bob"), true)
    -- a name not seen yet is kept as a name and promoted at the first join
    cmd(W, admin, "/whitelist add Newcomer")
    local newcomer = node._join(9, { name = "Newcomer", accountId = 99 })
    t.eq(node._emit("playerConnectRequest", newcomer, -1, "Newcomer"), true)
    t.truthy(W.whitelist.list()[1])
    local entries = {}
    for _, e in ipairs(W.whitelist.list()) do entries[e.entry] = true end
    t.truthy(entries["acct:99"], "promoted to the key")
    t.falsy(entries["name:newcomer"])
    cmd(W, admin, "/whitelist remove Bob")
    t.eq(node._emit("playerConnectRequest", bob, -1, "Bob"), false)
    cmd(W, admin, "/whitelist off")
    t.eq(node._emit("playerConnectRequest", bob, -1, "Bob"), true)
    -- guests
    t.eq(node._emit("playerConnectRequest", guest, -1, "Gus"), true)
    cmd(W, admin, "/settings set allow_guests false")
    ok, reason = node._emit("playerConnectRequest", guest, -1, "Gus")
    t.eq(ok, false)
    t.match(reason, "signed%-in accounts only")
    t.eq(node._emit("playerConnectRequest", bob, -1, "Bob"), true)
end

tests.group_set_rules = function()
    local W, _, admin, mod, bob = setup()
    cmd(W, mod, "/group Bob trusted")
    t.match(node._told_text(3), "You may not do that %(perms%.set%)")
    cmd(W, admin, "/group Bob trusted")
    t.eq(W.perms.group_of(bob), "trusted")
    t.match(node._told_text(4), "Adm put you in the group trusted")
    node._told = {}
    cmd(W, admin, "/group Bob admin")
    t.match(node._told_text(2), "The group admin is not below your level")
    cmd(W, admin, "/group Bob owner")
    t.match(node._told_text(2), "not below your level")
    cmd(W, admin, "/group Bob nope")
    t.match(node._told_text(2), "No group 'nope'")
    cmd(W, admin, "/group Mod default")
    t.eq(W.perms.group_of(mod), "default", "demoted")
    -- an offline player by name
    node._leave(4)
    cmd(W, admin, "/group Bob mod")
    t.eq(W.perms.group_of_key("acct:4"), "mod")
    node._told = {}
    cmd(W, admin, "/groups")
    t.match(node._told_text(2), "5 group%(s%)")
    t.match(node._told_text(2), "admin %(90%) cars:%-1 <%- mod")
end

tests.vehicle_caps = function()
    local W, _, admin, _, bob = setup()
    t.eq(node._emit("vehicleSpawnRequest", bob, 1, "{}"), true)
    node._vehicle(100, 4)
    local ok, reason = node._emit("vehicleSpawnRequest", bob, 2, "{}")
    t.eq(ok, false)
    t.eq(reason, "Vehicle limit reached (1). Delete one first.")
    W.perms.set_group(bob, "trusted")
    t.eq(node._emit("vehicleSpawnRequest", bob, 2, "{}"), true, "trusted: 3")
    node._vehicle(101, 4)
    node._vehicle(102, 4)
    t.eq(node._emit("vehicleSpawnRequest", bob, 3, "{}"), false)
    t.eq(node._emit("vehicleSpawnRequest", admin, 3, "{}"), true, "admin: bypass")
    -- /car delete on oneself needs no permission; on others car.delete + rank
    cmd(W, bob, "/car delete")
    t.eq(node.vehicles.count(), 0)
    t.match(node._told_text(4), "Deleted 3 vehicle%(s%) of Bob")
    node._vehicle(103, 4)
    node._told = {}
    cmd(W, bob, "/car delete Adm")
    t.match(node._told_text(4), "You may not do that %(car%.delete%)")
    cmd(W, admin, "/car delete Bob")
    t.eq(node.vehicles.count(), 0)
    t.match(node._told_text(4), "Adm deleted your vehicles")
end

tests.settings_from_chat = function()
    local W, _, admin, mod = setup()
    cmd(W, mod, "/settings list")
    t.match(node._told_text(3), "You may not do that %(settings%.read%)")
    node._told = {}
    cmd(W, admin, "/settings set votekick.threshold 0.8")
    t.match(node._told_text(2), "votekick%.threshold = 0%.8")
    t.eq(W.settings.get("votekick.threshold"), 0.8)
    node._advance(1000)
    t.match(node._files["data/settings.json"], '"votekick%.threshold": 0%.8')
    node._told = {}
    cmd(W, admin, "/settings set votekick.threshold 2")
    t.match(node._told_text(2), "Bad value for votekick%.threshold: above 1")
    cmd(W, admin, "/settings set ui.key F1")
    t.match(node._told_text(2), "No runtime setting 'ui%.key'")
    node._told = {}
    cmd(W, admin, "/settings get votekick.threshold")
    t.match(node._told_text(2), "votekick%.threshold = 0%.8 %(default 0%.6%)")
    cmd(W, admin, "/settings reset votekick.threshold")
    t.eq(W.settings.get("votekick.threshold"), 0.6)
    node._told = {}
    cmd(W, admin, "/settings list")
    t.match(node._told_text(2), "runtime setting%(s%)")
    t.match(node._told_text(2), "allow_guests = true")
    -- language switches the default dictionary
    cmd(W, admin, "/settings set language ru")
    node._told = {}
    cmd(W, admin, "/whitelist zzz")
    t.match(node._told_text(2), "Использование")
end

tests.lang_help_version_whoami = function()
    local W, owner, _, mod, bob = setup()
    cmd(W, bob, "/lang ru")
    node._told = {}
    cmd(W, bob, "/kick Mod")
    t.match(node._told_text(4), "Вам это нельзя")
    cmd(W, bob, "/lang de")
    t.match(node._told_text(4), "Неверное значение lang")
    node._told = {}
    cmd(W, bob, "/help")
    local help = node._told_text(4)
    t.match(help, "/help")
    t.match(help, "/vote yes|no|cancel")
    t.match(help, "/car delete")
    t.falsy(help:find("/kick", 1, true), "no kick for the default group")
    node._told = {}
    cmd(W, mod, "/help")
    t.match(node._told_text(3), "/kick <player>")
    t.falsy(node._told_text(3):find("/ban <", 1, true))
    node._told = {}
    cmd(W, owner, "/version")
    t.match(node._told_text(1), "warden 0%.0%.0%-test")
    cmd(W, mod, "/whoami")
    t.match(node._told_text(3), "Mod: group mod %(level 50%), id acct:3, vehicle limit 5")
    node._told = {}
    cmd(W, mod, "/players")
    t.match(node._told_text(3), "5/16 player%(s%)")
    t.match(node._told_text(3), "#5 Gus %[default 0%] cars:0 guest")
end

tests.rate_limit_and_audit_tail = function()
    local W, _, admin, mod = setup()
    for _ = 1, 8 do cmd(W, mod, "/whoami") end
    node._told = {}
    cmd(W, mod, "/whoami")
    t.match(node._told_text(3), "Too many commands; wait")
    node._advance(10 * 1000)
    node._told = {}
    cmd(W, mod, "/whoami")
    t.match(node._told_text(3), "Mod: group mod")
    cmd(W, admin, "/kick Bob")
    cmd(W, admin, "/warn Gus hi")
    cmd(W, admin, "/whitelist add Gus")
    node._told = {}
    cmd(W, mod, "/audit 2")
    local text = node._told_text(3)
    t.match(text, "Last 2 audit row%(s%)")
    t.match(text, "Adm warn %-> Gus ok")
    t.match(text, "Adm whitelist_add ok")
    t.falsy(text:find("kick", 1, true), "only the last two")
    cmd(W, mod, "/announce hi")
    t.match(node._told_text(3), "You may not do that %(server%.announce%)")
    node._told = {}
    cmd(W, admin, "/announce hello all")
    t.eq(#node._told, 4, "everyone connected, once")
    t.match(node._told_text(3), "%[Adm%] hello all")
end

tests.reload_and_fallback_chat_source = function()
    local W, owner = setup({ chat_fallback = true, owner_ids = { 1 } })
    node._emit("chat:send", owner, '{"text":"/reload"}')
    t.match(node._told_text(1), "Reloading warden")
    node._advance(200)
    t.eq(node._reloads, { "warden" })
    -- the bus is not read in fallback mode
    cmd(W, owner, "/whoami")
    t.falsy(node._told_text(1):find("group owner", 1, true))
end

return tests
