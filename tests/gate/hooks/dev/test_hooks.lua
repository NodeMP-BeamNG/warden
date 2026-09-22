-- dev.test_hooks: probes for the gate tests, behind WD_TEST_HOOKS=1.
--
-- NOT part of the resource: it lives under tests/gate/hooks and the harness
-- copies it into the scratch server's resources/warden/server/dev/ for a
-- server started with env=TEST_HOOKS_ENV, appending the one require line to
-- that copy of main.lua. A release archive has neither the probes nor a
-- loader for them (the shipped main.lua never mentions this file).
--
--   client -> server  wd:_test.query  { id, what, args }
--   server -> client  wd:_test.reply  { id, ok = true, data } | { id, ok = false, error = { code } }
--
-- The probes exist because a gate server has no directory: every player is
-- a guest keyed by ip, so nobody can be an owner through owner_ids. The
-- writing probe (group.set) is the fixture that puts a player into a group
-- without the rank rule; everything else is read-only.

local identity = require("identity.identity")
local perms = require("perms.perms")
local groups = require("perms.groups")
local bans = require("moderation.bans")
local audit = require("core.audit")
local mutes = require("moderation.mutes")

local M = {}

local probes = {}

local function pid_of(player, args)
    if args.pid ~= nil then return math.tointeger(tonumber(args.pid)) end
    return player.id
end

-- the fixture: player <pid> (default: the caller) into <group>, no checks
probes["group.set"] = function(player, args)
    local target = node.players.get(pid_of(player, args))
    if target == nil or not target:isConnected() then return nil, "offline" end
    local rec = identity.record_of(target)
    rec.group = args.group
    identity.mark()
    perms.apply_tag(target)
    return { pid = target.id, group = perms.group_of(target), level = perms.level_of(target) }
end

probes["me"] = function(player)
    return {
        pid = player.id, key = identity.key(player), group = perms.group_of(player), level = perms.level_of(player),
        perms = perms.perms_of(player), role = player.role, cap = require("vehicles.caps").limit(player),
    }
end

probes["perms.has"] = function(player, args)
    local target = node.players.get(pid_of(player, args))
    return { ok = perms.has(target, tostring(args.perm)) }
end

probes["groups.all"] = function()
    return { groups = groups.all() }
end

probes["bans.list"] = function()
    return { bans = bans.list() }
end

probes["mute.of"] = function(player, args)
    local key = args.key or identity.key(node.players.get(pid_of(player, args)))
    local muted, m = mutes.is_muted(key)
    return { muted = muted, mute = m }
end

probes["audit.tail"] = function(_, args)
    return { rows = audit.tail(args.n or 10) }
end

probes["record"] = function(player, args)
    local key = args.key or identity.key(node.players.get(pid_of(player, args)))
    return { key = key, record = identity.record(key) }
end

function M.install()
    node.on("wd:_test.query", function(player, raw)
        local q = node.json.decode(raw)
        if type(q) ~= "table" or q.id == nil then return end
        local fn = probes[q.what]
        local reply = { id = q.id }
        if fn == nil then
            reply.ok, reply.error = false, { code = "unknown_probe" }
        else
            local ok, data, err = pcall(fn, player, type(q.args) == "table" and q.args or {})
            if not ok then
                reply.ok, reply.error = false, { code = "internal", message = tostring(data) }
            elseif data == nil then
                reply.ok, reply.error = false, { code = tostring(err or "failed") }
            else
                reply.ok, reply.data = true, data
            end
        end
        player:send("wd:_test.reply", reply)
    end)
    node.log("[warden] test hooks installed (WD_TEST_HOOKS=1): never in a release")
end

return M
