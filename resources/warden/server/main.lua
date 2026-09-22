-- warden -- server entry point.
--
-- Load order: core (config, i18n, store, settings, audit) -> identity ->
-- perms (groups, perms) -> moderation (bans, whitelist, mutes) -> vehicles
-- (caps) -> votekick -> commands (registry, builtin, chat) -> ui (ops, push,
-- protocol) -> integration (bus). Then the engine events: the connect gate
-- (whitelist, guests), join / leave bookkeeping, the vehicle cap, the mute
-- notice, the shutdown flush.
--
-- Everything a player can trigger -- a chat line, a wd:req frame -- ends in
-- commands.registry.run, the one place that checks permission, target, rank
-- and shape and writes the audit row.

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")
package.path = here .. "/?.lua;" .. package.path

local log = require("core.log")
local config = require("core.config")
local i18n = require("core.i18n")
local store = require("core.store")
local settings = require("core.settings")
local audit = require("core.audit")
local say = require("core.say")
local util = require("core.util")

local manifest = node.resources.manifest and node.resources.manifest() or {}
local VERSION = manifest.version or "0.0.0"

-- core
local cfg, warnings = config.load(node.config)
for _, w in ipairs(warnings) do log.warn(w) end
i18n.init(cfg.language)
settings.init(cfg)
audit.init(cfg)
settings.on_change(function(key)
    if key == "language" then i18n.init(settings.get("language")) end
end)

-- identity and permissions
local identity = require("identity.identity")
local groups = require("perms.groups")
local perms = require("perms.perms")
identity.init()
groups.init()
perms.init(cfg)

-- moderation, vehicles, votes
local bans = require("moderation.bans")
local whitelist = require("moderation.whitelist")
local mutes = require("moderation.mutes")
local caps = require("vehicles.caps")
local votekick = require("votekick.votekick")
bans.init()
whitelist.init()
mutes.init()
votekick.init()

-- commands and the panel protocol
local chat = require("commands.chat")
local ops = require("ui.ops")
local push = require("ui.push")
local protocol = require("ui.protocol")
chat.init(cfg)
ops.init()
push.init()
protocol.init(cfg)

-- other resources
require("integration.bus").init(VERSION)

-- ---------------------------------------------------------------------------
-- the vote in the chat (the panel gets wd:event vote.state from ui.push)
-- ---------------------------------------------------------------------------

votekick.on(function(event, state)
    if state == nil then return end
    local params = { target = state.target.name, starter = state.starter.name, reason = state.reason ~= "" and
        state.reason or "-", yes = state.yes, needed = state.needed, sec = state.seconds_left }
    if event == "started" then
        say.all("vote.started", params)
    elseif event == "passed" then
        say.all("vote.passed", params)
    elseif event == "failed" then
        say.all("vote.failed", params)
    elseif event == "cancelled" then
        say.all("vote.cancelled", params)
    end
end)

-- ---------------------------------------------------------------------------
-- engine events
-- ---------------------------------------------------------------------------

-- The connect gate. Bans are the server's (checked before this fires).
node.on("playerConnectRequest", function(player, _, name)
    if identity.is_guest(player) and not settings.get("allow_guests") then
        audit.log({ actor = { name = tostring(name), key = identity.key(player) }, op = "connect", result = "denied",
            reason = "guests_off" })
        return false, i18n.t(i18n.DEFAULT, "join.no_guests")
    end
    if not whitelist.allowed(player) then
        audit.log({ actor = { name = tostring(name), key = identity.key(player) }, op = "connect", result = "denied",
            reason = "whitelist" })
        return false, i18n.t(i18n.DEFAULT, "join.whitelist")
    end
end)

node.on("playerJoined", function(player)
    identity.touch(player)
    perms.apply_tag(player)
    push.players()
    local muted, m = mutes.is_muted(identity.key(player))
    if muted then
        say.tell(player, "you.muted", { by = m.by or "-", reason = m.reason ~= "" and m.reason or "-",
            time = m["until"] and util.format_duration(m["until"] - util.now()) or "-" })
    end
end)

node.on("playerLeft", function(player)
    votekick.player_left(player.id)
    push.player_left(player.id)
    protocol.forget(player.id)
    chat.forget(player.id)
    mutes.forget(player.id)
    push.players()
end)

-- the vehicle cap of the player's group
node.on("vehicleSpawnRequest", function(player)
    local ok, code, params = caps.check(player)
    if not ok then
        return false, say.text(player, code, params)
    end
end)

-- a muted player's line: told they are muted (the line itself still goes
-- through the chat resource until server issue #43; see moderation.mutes)
node.on("chat:send", function(player, data)
    local d = util.decode(data)
    if d == nil or type(d.text) ~= "string" or d.text:sub(1, 1) == "/" then return end
    local muted, m = mutes.is_muted(identity.key(player))
    if muted and mutes.notice(player) then
        say.tell(player, "you.muted", { by = m.by or "-", reason = m.reason ~= "" and m.reason or "-",
            time = m["until"] and util.format_duration(m["until"] - util.now()) or "-" })
    end
end)
if cfg.chat_veto_event ~= "" then
    if mutes.install_veto(cfg.chat_veto_event) then log.info("mutes veto chat through %s", cfg.chat_veto_event) end
end

local function flush(reason)
    local n = store.flush_all()
    audit.flush()
    log.info("%s: %d store(s) written", reason, n)
end
node.on("serverShutdown", function() flush("shutdown") end)
node.on("resourceUnload", function() flush("unload") end)

-- players already in (a reload while the server runs)
for _, p in ipairs(node.players.all()) do
    identity.touch(p)
    perms.apply_tag(p)
end

-- the gate tests' probes (tests/gate/hooks/dev/test_hooks.lua), copied in by
-- the harness for a server started with WD_TEST_HOOKS=1; never in a release
local getenv_ok, hooks_env = pcall(os.getenv, "WD_TEST_HOOKS")
if getenv_ok and hooks_env == "1" then
    if package.searchpath("dev.test_hooks", package.path) ~= nil then
        require("dev.test_hooks").install()
    else
        log.warn("WD_TEST_HOOKS=1 but there is no server/dev/test_hooks.lua; no probes registered")
    end
end

log.info("warden %s ready: %d group(s), %d player record(s), whitelist %s, votekick %s", VERSION,
    #groups.all(), util.count(identity.all()), whitelist.enabled() and "on" or "off",
    settings.get("votekick.enabled") and "on" or "off")
