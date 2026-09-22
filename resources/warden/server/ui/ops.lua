-- ui.ops: the operations the panel may ask for -- each a kind of
-- commands.registry (the same checks as the chat commands) or one of the
-- few panel-only ops (sys.hello, players.subscribe). The op names are what
-- warden-ui's protocol.mjs mirrors.
--
--   ops.run(actor, op, data) -> result
--   ops.OPS -> op -> { kind } | { fn }

local builtin = require("commands.builtin")
local groups = require("perms.groups")
local perms = require("perms.perms")
local push = require("ui.push")
local registry = require("commands.registry")
local say = require("core.say")
local settings = require("core.settings")
local votekick = require("votekick.votekick")

local M = {}

M.VERSION = nil   -- set by init from the manifest
M.PROTOCOL = 1

M.OPS = {
    ["sys.hello"] = { fn = function(actor, data)
        if actor.console then return { ok = false, error = { code = "console_cannot" } } end
        local player = actor.player
        if type(data.lang) == "string" then
            local rec = require("identity.identity").record_of(player)
            if rec.lang == nil then say.set_lang(player, data.lang) end
        end
        local proto = math.tointeger(tonumber(data.protocol)) or 0
        if proto ~= M.PROTOCOL then
            return { ok = false, error = { code = "ui_outdated", params = { server = M.PROTOCOL, ui = proto } } }
        end
        push.hello(player.id)
        return { ok = true, data = {
            protocol = M.PROTOCOL, version = M.VERSION, lang = say.lang_of(player),
            key = settings.config().ui.key,
            me = builtin.player_row(player, true, actor), perms = perms.perms_of(player),
            vote = votekick.state(), permissions = groups.PERMISSIONS,
        } }
    end },
    ["players.subscribe"] = { fn = function(actor, data)
        if actor.console then return { ok = false, error = { code = "console_cannot" } } end
        if data.on == false then
            push.unsubscribe(actor.pid)
            return { ok = true, data = { on = false } }
        end
        if not perms.has(actor.player, "players.view") then
            return { ok = false, error = { code = "denied", params = { perm = "players.view" } } }
        end
        push.subscribe(actor.pid)
        return { ok = true, data = { on = true, players = push.snapshot() } }
    end },
    ["players.list"] = { kind = "players" },
    ["players.get"] = { kind = "player_get" },
    ["me.get"] = { kind = "whoami" },
    ["me.lang"] = { kind = "lang" },
    ["mod.kick"] = { kind = "kick" },
    ["mod.ban"] = { kind = "ban" },
    ["mod.tempban"] = { kind = "tempban" },
    ["mod.unban"] = { kind = "unban" },
    ["mod.bans"] = { kind = "bans" },
    ["mod.mute"] = { kind = "mute" },
    ["mod.unmute"] = { kind = "unmute" },
    ["mod.warn"] = { kind = "warn" },
    ["whitelist.add"] = { kind = "whitelist_add" },
    ["whitelist.remove"] = { kind = "whitelist_remove" },
    ["whitelist.list"] = { kind = "whitelist_list" },
    ["whitelist.enable"] = { kind = "whitelist_enable" },
    ["groups.list"] = { kind = "groups" },
    ["groups.set"] = { kind = "group_set" },
    ["groups.save"] = { kind = "group_save" },
    ["groups.delete"] = { kind = "group_delete" },
    ["car.delete"] = { kind = "car_delete" },
    ["vote.start"] = { kind = "votekick_start" },
    ["vote.cast"] = { kind = "vote_cast" },
    ["vote.cancel"] = { kind = "vote_cancel" },
    ["vote.state"] = { kind = "vote_state" },
    ["settings.list"] = { kind = "settings_list" },
    ["settings.set"] = { kind = "settings_set" },
    ["settings.reset"] = { kind = "settings_reset" },
    ["audit.tail"] = { kind = "audit_tail" },
    ["server.announce"] = { kind = "announce" },
    ["server.reload"] = { kind = "reload" },
}

function M.run(actor, op, data)
    local spec = M.OPS[op]
    if spec == nil then return { ok = false, error = { code = "unknown_op", params = { op = op } } } end
    if spec.fn then return spec.fn(actor, data) end
    return registry.run(actor, spec.kind, data)
end

function M.init()
    local m = node.resources.manifest and node.resources.manifest() or {}
    M.VERSION = m.version or "0.0.0"
end

return M
