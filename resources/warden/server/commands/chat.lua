-- commands.chat: the chat commands. Lines come from the `chat` resource's
-- bus event chat:command (the resource has already decided the line is a
-- command and not chat); with chat_fallback the wire event chat:send is read
-- directly. Each command turns its words into a kind + data for
-- commands.registry.run and answers the player in their language.
--
--   chat.init(cfg)
--   chat.handle(player, line) -> handled       the whole path, for the tests
--   chat.COMMANDS                              name -> { kind | run, usage, perm }
--   chat.help(actor) -> array of { name, usage }

local i18n = require("core.i18n")
local limiter = require("core.limiter")
local parser = require("commands.parser")
local perms = require("perms.perms")
local registry = require("commands.registry")
local say = require("core.say")
local settings = require("core.settings")
local util = require("core.util")

local builtin = require("commands.builtin") -- luacheck: ignore 211 (registers the kinds)

local M = {}

local lim = nil
local cfg = nil

-- ---------------------------------------------------------------------------
-- answering
-- ---------------------------------------------------------------------------

local function reply_error(player, err)
    local code = err.code
    local params = err.params or {}
    if code == "vote.too_few" or code == "vote.cooldown" then
        say.tell(player, "err." .. code, params)
    elseif code == "bad_arg" then
        say.tell(player, "err.bad_arg", { field = tostring(params.field) })
    else
        say.tell(player, "err." .. code, params)
    end
end

local function done(player, code, params)
    say.tell(player, "done." .. code, params or {})
end

-- runs a kind and answers; `on_ok(data)` may format the success line itself
local function run(player, actor, kind, data, on_ok)
    local result = registry.run(actor, kind, data)
    if not result.ok then
        reply_error(player, result.error)
        return result
    end
    if on_ok then
        on_ok(result.data)
    else
        local d = result.data or {}
        done(player, kind, {
            target = d.target and d.target.name or "", reason = d.reason or "-", group = d.group or "",
            entry = d.entry or "", n = d.deleted or d.count or 0,
            time = d.duration and util.format_duration(d.duration) or "-", key = d.key or "", value = d.value ~= nil
            and settings.render(d.value) or "",
        })
    end
    return result
end

local function usage(player, name)
    local spec = M.COMMANDS[name]
    say.tell(player, "err.usage", { usage = "/" .. name .. " " .. (spec and spec.usage or "") })
end

local function ts(sec)
    if not sec then return "-" end
    return os.date("!%Y-%m-%d %H:%M", sec)
end

-- ---------------------------------------------------------------------------
-- the commands
-- ---------------------------------------------------------------------------

M.COMMANDS = {}

local function command(name, spec)
    M.COMMANDS[name] = spec
end

command("help", { usage = "", run = function(player, actor)
    local lines = M.help(actor)
    say.tell(player, "help.header", { n = #lines, key = cfg.ui.key })
    for _, c in ipairs(lines) do
        pcall(player.tell, player, "/" .. c.name .. (c.usage ~= "" and (" " .. c.usage) or ""))
    end
end })

command("version", { usage = "", run = function(player)
    local m = node.resources.manifest and node.resources.manifest() or {}
    say.tell(player, "version", { version = m.version or "?" })
end })

command("whoami", { usage = "", kind = "whoami", run = function(player, actor)
    run(player, actor, "whoami", {}, function(d)
        local me = d.me or {}
        say.tell(player, "whoami", { name = me.name or "", group = me.group or "", level = me.level or 0,
            key = me.key or "", cap = me.cap or 0 })
    end)
end })

command("lang", { usage = "en|ru", kind = "lang", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "lang") end
    run(player, actor, "lang", { lang = c.words[1]:lower() }, function(d)
        say.tell(player, "done.lang", { lang = d.lang })
    end)
end })

command("players", { usage = "", kind = "players", run = function(player, actor)
    run(player, actor, "players", {}, function(d)
        say.tell(player, "players.header", { n = d.count, max = d.max or "?" })
        for _, p in ipairs(d.players) do
            pcall(player.tell, player, string.format("#%d %s [%s %d] cars:%d%s", p.pid, p.name, p.group, p.level,
                p.vehicles, p.guest and " guest" or ""))
        end
    end)
end })

command("kick", { usage = "<player> [reason]", kind = "kick", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "kick") end
    run(player, actor, "kick", { target = c.words[1], reason = c.rest(2) })
end })

command("ban", { usage = "<player> [reason]", kind = "ban", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "ban") end
    run(player, actor, "ban", { target = c.words[1], reason = c.rest(2) })
end })

command("tempban", { usage = "<player> <30m|2h|7d> [reason]", kind = "tempban", run = function(player, actor, c)
    local dur = util.parse_duration(c.words[2] or "")
    if c.words[1] == nil or dur == nil then return usage(player, "tempban") end
    run(player, actor, "tempban", { target = c.words[1], duration = dur, reason = c.rest(3) })
end })

command("unban", { usage = "<player|acct:id|ip:addr>", kind = "unban", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "unban") end
    run(player, actor, "unban", { target = c.words[1] })
end })

command("bans", { usage = "", kind = "bans", run = function(player, actor)
    run(player, actor, "bans", {}, function(d)
        say.tell(player, "bans.header", { n = #d.bans })
        for i, b in ipairs(d.bans) do
            if i > 20 then break end
            pcall(player.tell, player, string.format("%s (%s) %s%s -- %s", tostring(b.name or "?"), tostring(b.key),
                b.reason or "-", b["until"] and (" until " .. ts(b["until"])) or "", tostring(b.by or "server")))
        end
    end)
end })

command("mute", { usage = "<player> [30m|2h] [reason]", kind = "mute", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "mute") end
    local dur = util.parse_duration(c.words[2] or "")
    local reason = dur and c.rest(3) or c.rest(2)
    run(player, actor, "mute", { target = c.words[1], duration = dur, reason = reason })
end })

command("unmute", { usage = "<player>", kind = "unmute", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "unmute") end
    run(player, actor, "unmute", { target = c.words[1] })
end })

command("warn", { usage = "<player> <reason>", kind = "warn", run = function(player, actor, c)
    if c.words[1] == nil or c.words[2] == nil then return usage(player, "warn") end
    run(player, actor, "warn", { target = c.words[1], reason = c.rest(2) })
end })

command("whitelist", { usage = "add|remove <player> | list | on | off", kind = "whitelist_list",
    run = function(player, actor, c)
        local sub = (c.words[1] or ""):lower()
        if sub == "add" and c.words[2] then
            run(player, actor, "whitelist_add", { entry = c.words[2] }, function(d)
                -- a name entry admits a signed-in account of that name only, never a guest: say so
                local code = d.name_entry and "done.whitelist_add_name" or "done.whitelist_add"
                say.tell(player, code, { entry = d.entry })
            end)
        elseif sub == "remove" and c.words[2] then
            run(player, actor, "whitelist_remove", { entry = c.words[2] })
        elseif sub == "on" or sub == "off" then
            run(player, actor, "whitelist_enable", { on = sub == "on" }, function(d)
                say.tell(player, d.enabled and "done.whitelist_on" or "done.whitelist_off", {})
            end)
        elseif sub == "list" or sub == "" then
            run(player, actor, "whitelist_list", {}, function(d)
                say.tell(player, "whitelist.header", { n = #d.entries, state = d.enabled and "on" or "off" })
                for i, e in ipairs(d.entries) do
                    if i > 30 then break end
                    pcall(player.tell, player, string.format("%s (%s)", e.entry, tostring(e.name)))
                end
            end)
        else
            usage(player, "whitelist")
        end
    end })

command("group", { usage = "<player> <group> | list", kind = "group_set", run = function(player, actor, c)
    local sub = (c.words[1] or ""):lower()
    if sub == "list" or sub == "" then return M.COMMANDS.groups.run(player, actor, c) end
    if c.words[2] == nil then return usage(player, "group") end
    run(player, actor, "group_set", { target = c.words[1], group = c.words[2]:lower() })
end })

command("groups", { usage = "", kind = "groups", run = function(player, actor)
    run(player, actor, "groups", {}, function(d)
        say.tell(player, "groups.header", { n = #d.groups })
        for _, g in ipairs(d.groups) do
            pcall(player.tell, player, string.format("%s (%d) cars:%s <- %s", g.name, g.level,
                tostring(g.caps.vehicles ~= nil and g.caps.vehicles or "inherit"),
                #g.inherits > 0 and table.concat(g.inherits, ",") or "-"))
        end
    end)
end })

command("car", { usage = "delete [player]", kind = "car_delete", run = function(player, actor, c)
    local sub = (c.words[1] or ""):lower()
    if sub ~= "delete" then return usage(player, "car") end
    local data = c.words[2] and { target = c.words[2] } or { pid = player.id }
    run(player, actor, "car_delete", data)
end })

command("votekick", { usage = "<player> [reason]", kind = "votekick_start", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "votekick") end
    run(player, actor, "votekick_start", { target = c.words[1], reason = c.rest(2) }, function() end)
end })

command("vote", { usage = "yes|no|cancel", kind = "vote_cast", run = function(player, actor, c)
    local sub = (c.words[1] or ""):lower()
    if sub == "yes" or sub == "no" or sub == "y" or sub == "n" then
        run(player, actor, "vote_cast", { yes = sub:sub(1, 1) == "y" }, function(d)
            local v = d.vote
            if v then say.tell(player, "done.vote", { yes = v.yes, needed = v.needed }) end
        end)
    elseif sub == "cancel" then
        run(player, actor, "vote_cancel", {}, function() say.tell(player, "done.vote_cancel", {}) end)
    else
        usage(player, "vote")
    end
end })

command("settings", { usage = "list | get <key> | set <key> <value> | reset <key>", kind = "settings_list",
    run = function(player, actor, c)
        local sub = (c.words[1] or "list"):lower()
        if sub == "list" then
            run(player, actor, "settings_list", {}, function(d)
                say.tell(player, "settings.header", { n = #d.settings })
                for _, s in ipairs(d.settings) do
                    pcall(player.tell, player, string.format("%s = %s%s", s.key, settings.render(s.value),
                        s.overridden and " *" or ""))
                end
            end)
        elseif sub == "get" and c.words[2] then
            run(player, actor, "settings_list", {}, function(d)
                for _, s in ipairs(d.settings) do
                    if s.key == c.words[2] then
                        say.tell(player, "settings.one", { key = s.key, value = settings.render(s.value),
                            default = settings.render(s.default) })
                        return
                    end
                end
                say.tell(player, "err.unknown_setting", { key = c.words[2] })
            end)
        elseif sub == "set" and c.words[2] and c.words[3] then
            run(player, actor, "settings_set", { key = c.words[2], value = c.rest(3) })
        elseif sub == "reset" and c.words[2] then
            run(player, actor, "settings_reset", { key = c.words[2] })
        else
            usage(player, "settings")
        end
    end })

command("audit", { usage = "[n]", kind = "audit_tail", run = function(player, actor, c)
    run(player, actor, "audit_tail", { limit = c.words[1] }, function(d)
        say.tell(player, "audit.header", { n = #d.rows })
        for _, r in ipairs(d.rows) do
            pcall(player.tell, player, string.format("%s %s %s%s %s%s", r.at or "", r.actor and r.actor.name or "?",
                r.op, r.target and (" -> " .. tostring(r.target.name)) or "", r.result,
                r.reason and (" (" .. r.reason .. ")") or ""))
        end
    end)
end })

command("announce", { usage = "<text>", kind = "announce", run = function(player, actor, c)
    if c.words[1] == nil then return usage(player, "announce") end
    run(player, actor, "announce", { text = c.rest(1) }, function() end)
end })

command("reload", { usage = "", kind = "reload", run = function(player, actor)
    run(player, actor, "reload", {}, function() say.tell(player, "done.reload", {}) end)
end })

-- ---------------------------------------------------------------------------
-- dispatch
-- ---------------------------------------------------------------------------

function M.help(actor)
    local out = {}
    for name, spec in pairs(M.COMMANDS) do
        local kind = spec.kind and registry.KINDS[spec.kind]
        if kind == nil or kind.self or registry.allowed(actor, spec.kind) then
            out[#out + 1] = { name = name, usage = spec.usage }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.handle(player, line)
    local c = parser.parse(line, "/")
    if c == nil then return false end
    -- the limiter first: an unknown command is a line answered like any other
    local ok, retry = lim:allow(player.id, util.now())
    if not ok then
        say.tell(player, "err.rate_limited", { sec = retry })
        return true
    end
    local spec = M.COMMANDS[c.name]
    if spec == nil then
        say.tell(player, "err.unknown_command", { name = c.name })
        return true
    end
    local actor = perms.actor(player)
    local okr, err = xpcall(spec.run, debug.traceback, player, actor, c)
    if not okr then
        node.log("[warden] command /" .. c.name .. " failed: " .. tostring(err))
        say.tell(player, "err.internal", {})
    end
    return true
end

local function on_bus_command(_, data)
    local d = util.decode(data)
    if d == nil or d.pid == nil then return end
    local player = node.players.get(math.tointeger(tonumber(d.pid)) or -1)
    if player == nil or not player:isConnected() then return end
    -- re-parsed from the raw line: the bus payload split on spaces, quotes are ours
    local line = d.raw
    if type(line) ~= "string" then line = "/" .. tostring(d.name) .. " " .. table.concat(d.args or {}, " ") end
    M.handle(player, line)
end

local function on_chat_send(player, data)
    local d = util.decode(data)
    if d == nil or type(d.text) ~= "string" then return end
    if d.text:sub(1, 1) ~= "/" then return end
    M.handle(player, d.text)
end

function M.init(loaded)
    cfg = loaded
    lim = limiter.simple(cfg.limits.commands_per_10s, 10)
    -- one source only: the bus (a chat resource is installed) or the wire
    -- (chat_fallback, no chat resource) -- both would run every command twice
    if cfg.chat_fallback then
        node.on("chat:send", on_chat_send)
    else
        node.bus.on("chat:command", on_bus_command)
    end
end

function M.forget(pid)
    if lim then lim:forget(pid) end
end

M.i18n = i18n

return M
