-- ui.ops: the operations the panel may ask for -- each a kind of
-- commands.registry (the same checks as the chat commands) or one of the
-- few panel-only ops (sys.hello, players.subscribe). The op names are what
-- client/warden/state.lua mirrors.
--
--   ops.run(actor, op, data) -> result
--   ops.OPS -> op -> { kind } | { fn }
--   ops.hello_record(player) -> the sys.hello reply data (the tests read it too)
--
-- The hello record (protocol 2): protocol, version, lang, me, perms, vote,
-- permissions, default_group, ui { shown, scale, theme }, server { name,
-- map, version, max_players, max_cars }, status (ui.push.status_snapshot:
-- whitelist / spawn / guests / players / cars). No key: the panel has no
-- fixed key since 0.2.0 -- /warden, the bindable game action, or the console.

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
M.PROTOCOL = 2

local function server_info()
    local s = node.server or {}
    local function call(name)
        local fn = s[name]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn)
        if ok then return v end
        return nil
    end
    return {
        name = call("name"), map = call("map"), version = call("version"),
        max_players = call("maxPlayers"), max_cars = call("maxCars"),
    }
end

function M.hello_record(player, actor)
    return {
        protocol = M.PROTOCOL, version = M.VERSION, lang = say.lang_of(player),
        me = builtin.player_row(player, true, actor), perms = perms.perms_of(player),
        vote = votekick.state(), permissions = groups.PERMISSIONS,
        default_group = settings.config().default_group,
        ui = M.ui_of(player),
        server = server_info(),
        status = push.status_snapshot(),
    }
end

function M.ui_of(player)
    local ui = builtin.ui_state(player)
    ui.theme = settings.get("ui.theme")
    return ui
end

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
        local first = not push.has_panel(player.id)
        push.hello(player.id)
        if first and settings.get("ui.welcome") and perms.has(player, "players.view") then
            -- one line per session, once the panel is there (so the chat is up too)
            say.tell(player, "welcome", { version = tostring(M.VERSION) })
        end
        return { ok = true, data = M.hello_record(player, actor) }
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
    ["ui.get"] = { kind = "ui_get" },
    ["ui.set"] = { kind = "ui_set" },
    ["mod.kick"] = { kind = "kick" },
    ["mod.ban"] = { kind = "ban" },
    ["mod.tempban"] = { kind = "tempban" },
    ["mod.unban"] = { kind = "unban" },
    ["mod.bans"] = { kind = "bans" },
    ["mod.mute"] = { kind = "mute" },
    ["mod.unmute"] = { kind = "unmute" },
    ["mod.mutes"] = { kind = "mutes" },
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
    if spec.fn then
        -- the two panel-only ops are guarded like the kinds: an exception is a reply, not a timeout
        local ok, res = xpcall(spec.fn, debug.traceback, actor, data)
        if ok then return res end
        node.log("[warden] " .. tostring(op) .. " failed: " .. tostring(res))
        return { ok = false, error = { code = "internal" } }
    end
    return registry.run(actor, spec.kind, data)
end

function M.init()
    local m = node.resources.manifest and node.resources.manifest() or {}
    M.VERSION = m.version or "0.0.0"
end

return M
