-- commands.builtin: the kinds -- what warden can do, with their permission,
-- target rule, argument shape and effect. Registered into commands.registry;
-- chat (commands.chat) and the panel (ui.ops) only translate their input
-- into a kind and data. A handler returns the reply data (a table), or a
-- refusal as `"code", params`.

local audit = require("core.audit")
local bans = require("moderation.bans")
local caps = require("vehicles.caps")
local groups = require("perms.groups")
local identity = require("identity.identity")
local mutes = require("moderation.mutes")
local perms = require("perms.perms")
local registry = require("commands.registry")
local say = require("core.say")
local settings = require("core.settings")
local uistate = require("ui.uistate")
local util = require("core.util")
local votekick = require("votekick.votekick")
local whitelist = require("moderation.whitelist")

local M = {}

local REASON = { type = "string", max = 200, optional = true }

local function target_info(t)
    return { pid = t.pid, key = t.key, name = t.name, group = t.group, level = t.level }
end

-- may this actor see addresses? (spec 4.7: IPs are for mod.ban and up)
local function reveals(actor)
    return actor.console == true or perms.has(actor.player or actor, "mod.ban")
end

-- ---------------------------------------------------------------------------
-- moderation
-- ---------------------------------------------------------------------------

registry.define("kick", {
    perm = "mod.kick", target = "player", rank = true, shape = { reason = REASON },
    fn = function(ctx)
        local t = ctx.target
        say.tell(t.player, "you.kicked", { by = ctx.actor.name, reason = ctx.data.reason or "-" })
        t.player:kick(ctx.data.reason or say.text(t.player, "reason.kicked"))
        return { target = target_info(t), reason = ctx.data.reason }
    end,
})

registry.define("ban", {
    perm = "mod.ban", target = "key", rank = true, shape = { reason = REASON },
    fn = function(ctx)
        local t = ctx.target
        if t.player then say.tell(t.player, "you.banned", { by = ctx.actor.name, reason = ctx.data.reason or "-" }) end
        local ok, err = bans.ban(t, ctx.actor, ctx.data.reason)
        if not ok then return err end
        return { target = target_info(t), reason = ctx.data.reason }
    end,
})

registry.define("tempban", {
    perm = "mod.tempban", target = "key", rank = true,
    shape = { duration = { type = "int", min = 60, max = 365 * 86400 }, reason = REASON },
    fn = function(ctx)
        local t = ctx.target
        if t.player then
            say.tell(t.player, "you.tempbanned", { by = ctx.actor.name, reason = ctx.data.reason or "-",
                time = util.format_duration(ctx.data.duration) })
        end
        local ok, err = bans.ban(t, ctx.actor, ctx.data.reason, ctx.data.duration)
        if not ok then return err end
        return { target = target_info(t), reason = ctx.data.reason, duration = ctx.data.duration }
    end,
})

registry.define("unban", {
    perm = "mod.ban", target = "key",
    fn = function(ctx)
        local ok, err = bans.unban(ctx.target.key)
        if not ok then return err end
        return { target = target_info(ctx.target) }
    end,
})

registry.define("bans", {
    perm = "mod.ban", audit = false,
    fn = function() return { bans = bans.list() } end,
})

registry.define("mute", {
    perm = "mod.mute", target = "key", rank = true,
    shape = { duration = { type = "int", min = 60, max = 365 * 86400, optional = true }, reason = REASON },
    fn = function(ctx)
        local t = ctx.target
        mutes.mute(t, ctx.actor, ctx.data.reason, ctx.data.duration)
        if t.player then
            say.tell(t.player, "you.muted", { by = ctx.actor.name, reason = ctx.data.reason or "-",
                time = ctx.data.duration and util.format_duration(ctx.data.duration) or "-" })
        end
        return { target = target_info(t), reason = ctx.data.reason, duration = ctx.data.duration }
    end,
})

registry.define("unmute", {
    perm = "mod.mute", target = "key",
    fn = function(ctx)
        local ok, err = mutes.unmute(ctx.target.key)
        if not ok then return err end
        if ctx.target.player then say.tell(ctx.target.player, "you.unmuted", {}) end
        return { target = target_info(ctx.target) }
    end,
})

-- the mutes in force (the panel's Database tab); addresses for mod.ban and up
registry.define("mutes", {
    perm = "mod.mute", audit = false,
    fn = function(ctx)
        local list = mutes.list()
        if not reveals(ctx.actor) then list = identity.mask(list) end
        return { mutes = list }
    end,
})

registry.define("warn", {
    perm = "mod.warn", target = "player", rank = true, shape = { reason = { type = "string", max = 200 } },
    fn = function(ctx)
        local n = mutes.warn(ctx.target, ctx.actor, ctx.data.reason)
        say.tell(ctx.target.player, "you.warned", { by = ctx.actor.name, reason = ctx.data.reason, n = n })
        return { target = target_info(ctx.target), reason = ctx.data.reason, count = n }
    end,
})

-- ---------------------------------------------------------------------------
-- whitelist
-- ---------------------------------------------------------------------------

-- a whitelist refusal that names candidates: addresses only for mod.ban and up
local function whitelist_refusal(ctx, err, params)
    params = params or {}
    if err == "ambiguous" then
        params.keys = identity.describe(params.candidates, reveals(ctx.actor))
        params.candidates = nil
    elseif err == "guest_by_name" and not reveals(ctx.actor) then
        params.key = identity.mask_key(params.key)
    end
    return err, params
end

-- a plain name that nobody has yet becomes a name entry: it admits a signed-in
-- account of that name at its first join, never a guest (name_entry = true in the reply)
registry.define("whitelist_add", {
    perm = "mod.whitelist", shape = { entry = { type = "string", max = 64 } },
    fn = function(ctx)
        local norm, err, params = whitelist.add(ctx.data.entry, ctx.actor)
        if not norm then return whitelist_refusal(ctx, err, params) end
        return { entry = norm, name_entry = norm:sub(1, 5) == "name:" or nil }
    end,
})

registry.define("whitelist_remove", {
    perm = "mod.whitelist", shape = { entry = { type = "string", max = 64 } },
    fn = function(ctx)
        local norm, err, params = whitelist.remove(ctx.data.entry)
        if not norm then return whitelist_refusal(ctx, err, params) end
        return { entry = norm }
    end,
})

registry.define("whitelist_list", {
    perm = "mod.whitelist", audit = false,
    fn = function() return { enabled = whitelist.enabled(), entries = whitelist.list() } end,
})

registry.define("whitelist_enable", {
    perm = "mod.whitelist", shape = { on = { type = "bool" } },
    fn = function(ctx)
        settings.set("whitelist.enabled", ctx.data.on)
        return { enabled = ctx.data.on }
    end,
})

-- ---------------------------------------------------------------------------
-- groups
-- ---------------------------------------------------------------------------

registry.define("group_set", {
    perm = "perms.set", target = "key", rank = true, privileged = true,
    shape = { group = { type = "string", max = 24 } },
    fn = function(ctx)
        local g = groups.get(ctx.data.group)
        if g == nil then return "unknown_group", { group = ctx.data.group } end
        if not ctx.actor.console and g.level >= ctx.actor.level then return "group_too_high", { group = g.name } end
        local ok, err = perms.set_group(ctx.target.player or ctx.target.key, g.name)
        if not ok then return err end
        if ctx.target.player then say.tell(ctx.target.player, "you.group", { group = g.name, by = ctx.actor.name }) end
        return { target = target_info(ctx.target), group = g.name, level = g.level }
    end,
})

registry.define("groups", {
    audit = false,
    fn = function() return { groups = groups.all(), permissions = groups.PERMISSIONS } end,
})

-- the permissions a group defined as `def` would end up with: its own and
-- everything its parents carry (what the actor must hold themselves)
local function candidate_perms(def)
    local set = {}
    for _, p in ipairs(type(def.perms) == "table" and def.perms or {}) do set[tostring(p)] = true end
    for _, parent in ipairs(type(def.inherits) == "table" and def.inherits or {}) do
        if type(parent) == "string" then
            for p in pairs(groups.effective_perms(parent)) do set[p] = true end
        end
    end
    return set
end

registry.define("group_save", {
    perm = "perms.manage", shape = { group = { type = "table" } },
    fn = function(ctx)
        local def = ctx.data.group
        -- nobody edits a group at or above their own level, inherits from one, grants "*",
        -- or ends up granting -- directly or through a parent -- what they do not hold
        if not ctx.actor.console then
            local level = math.tointeger(tonumber(def.level)) or 0
            if level >= ctx.actor.level then return "group_too_high", { group = tostring(def.name) } end
            local existing = groups.get(def.name)
            if existing and existing.level >= ctx.actor.level then return "group_too_high", { group = def.name } end
            for _, parent in ipairs(type(def.inherits) == "table" and def.inherits or {}) do
                if type(parent) ~= "string" or not groups.exists(parent) then
                    return "unknown_parent", { group = tostring(def.name) }
                end
                if groups.level(parent) >= ctx.actor.level then return "group_too_high", { group = parent } end
            end
            for _, p in ipairs(util.keys(candidate_perms(def))) do
                if p == "*" then return "bad_perm", { perm = p } end
                if not perms.has(ctx.actor.player, p) then return "perm_not_yours", { perm = p } end
            end
        end
        local g, err = groups.save(def)
        if not g then return err, { group = tostring(def.name) } end
        ctx.detail = { group = g }
        return { group = g }
    end,
})

registry.define("group_delete", {
    perm = "perms.manage", shape = { name = { type = "string", max = 24 } },
    fn = function(ctx)
        local existing = groups.get(ctx.data.name)
        if existing == nil then return "unknown_group", { group = ctx.data.name } end
        if not ctx.actor.console and existing.level >= ctx.actor.level then
            return "group_too_high", { group = ctx.data.name }
        end
        local ok, err = groups.remove(ctx.data.name)
        if not ok then return err, { group = ctx.data.name } end
        -- players of the removed group fall back to the default
        for key, rec in pairs(identity.all()) do
            if rec.group == ctx.data.name then
                rec.group = nil
                rec.level = perms.level_of_key(key)
                identity.mark()
                for _, p in ipairs(node.players.all()) do
                    if identity.key(p) == key then perms.apply_tag(p) end
                end
            end
        end
        return { name = ctx.data.name }
    end,
})

-- ---------------------------------------------------------------------------
-- vehicles
-- ---------------------------------------------------------------------------

-- every vehicle of the target, or one of them (`vid`: the global vehicle id
-- the client mod shows; it must be the target's own -- anyone else's is bad_arg)
registry.define("car_delete", {
    perm = "car.delete", target = "player", rank = true, self = true,
    shape = { vid = { type = "int", min = 0, optional = true } },
    fn = function(ctx)
        local n
        if ctx.data.vid ~= nil then
            local ok = caps.delete_one(ctx.target.player, ctx.data.vid)
            if not ok then return "bad_arg", { field = "vid" } end
            n = 1
        else
            n = caps.delete_all(ctx.target.player)
        end
        if ctx.target.pid ~= ctx.actor.pid then
            say.tell(ctx.target.player, "you.cars_deleted", { by = ctx.actor.name })
        end
        return { target = target_info(ctx.target), deleted = n, vid = ctx.data.vid }
    end,
})

-- ---------------------------------------------------------------------------
-- vote-kick
-- ---------------------------------------------------------------------------

registry.define("votekick_start", {
    perm = "votekick.start", target = "player", shape = { reason = { type = "string", max = 120, optional = true } },
    fn = function(ctx)
        local state, err, params = votekick.start(ctx.actor, ctx.target.player, ctx.data.reason)
        if not state then return err, params end
        return { vote = state }
    end,
})

registry.define("vote_cast", {
    perm = "votekick.vote", shape = { yes = { type = "bool" } }, audit = false,
    fn = function(ctx)
        if ctx.actor.console then return "console_cannot" end
        local ok, counted = votekick.cast(ctx.actor.player, ctx.data.yes)
        if not ok then return counted end
        -- the count with this vote in; the outcome, if it decided the vote, arrives as vote.state
        return { vote = counted, running = votekick.running() }
    end,
})

registry.define("vote_cancel", {
    perm = "votekick.cancel",
    fn = function(ctx)
        local ok, err = votekick.cancel(ctx.actor)
        if not ok then return err end
        return {}
    end,
})

registry.define("vote_state", {
    audit = false,
    fn = function() return { vote = votekick.state() } end,
})

-- ---------------------------------------------------------------------------
-- players, settings, audit, server
-- ---------------------------------------------------------------------------

-- the row the panel shows; `viewer` (an actor or a player) decides whether
-- the address is shown: their own, or mod.ban and up -- masked otherwise
function M.player_row(p, full, viewer)
    local key = identity.key(p)
    local muted, m = mutes.is_muted(key)
    local row = {
        pid = p.id, name = p.name, group = perms.group_of(p), level = perms.level_of(p),
        vehicles = p.vehicleCount or 0, ping = p.pingSeconds, connected = p.connectedSeconds,
        guest = identity.is_guest(p), verified = p.verified == true,
        -- the panel's Mute / Unmute and Whitelist / Unwhitelist buttons follow these two
        muted = muted == true, whitelisted = whitelist.has(key),
    }
    if full then
        local rec = identity.record(key)
        local reveal = viewer == nil or viewer.console == true or (viewer.pid or viewer.id) == p.id or reveals(viewer)
        row.key = reveal and key or identity.mask_key(key)
        row.ip = reveal and p.ip or identity.mask_ip(p.ip)
        row.account = p.accountId
        row.names = rec and rec.names or {}
        row.joins = rec and rec.joins or 0
        row.first_seen = rec and rec.first_seen or nil
        row.warns = rec and rec.warns or {}
        row.mute = muted and m or nil
        row.cap = caps.limit(p)
    end
    return row
end

registry.define("players", {
    perm = "players.view", audit = false,
    fn = function()
        local out = {}
        for _, p in ipairs(node.players.all()) do out[#out + 1] = M.player_row(p, false) end
        return { players = out, count = #out, max = node.server.maxPlayers and node.server.maxPlayers() or nil }
    end,
})

-- read-only, so a unique prefix of a connected name is accepted here (nowhere else)
registry.define("player_get", {
    perm = "players.view", target = "player", fuzzy = true, audit = false,
    fn = function(ctx) return { player = M.player_row(ctx.target.player, true, ctx.actor) } end,
})

registry.define("settings_list", {
    perm = "settings.read", audit = false,
    fn = function() return { settings = settings.list() } end,
})

registry.define("settings_set", {
    perm = "settings.write", shape = { key = { type = "string", max = 64 }, value = { type = "any" } },
    fn = function(ctx)
        if not settings.is_runtime(ctx.data.key) then return "unknown_setting", { key = ctx.data.key } end
        local v, err = settings.set(ctx.data.key, ctx.data.value)
        if v == nil then return "bad_value", { key = ctx.data.key, why = err } end
        return { key = ctx.data.key, value = v }
    end,
})

registry.define("settings_reset", {
    perm = "settings.write", shape = { key = { type = "string", max = 64 } },
    fn = function(ctx)
        local ok = settings.reset(ctx.data.key)
        if not ok then return "unknown_setting", { key = ctx.data.key } end
        return { key = ctx.data.key, value = settings.get(ctx.data.key) }
    end,
})

-- the tail is bounded (limit <= 200, from memory); the addresses in it are for mod.ban and up
registry.define("audit_tail", {
    perm = "audit.view", shape = { limit = { type = "int", min = 1, max = 200, optional = true, default = 30 } },
    audit = false,
    fn = function(ctx)
        local rows = audit.tail(ctx.data.limit)
        if not reveals(ctx.actor) then rows = identity.mask(rows) end
        return { rows = rows }
    end,
})

registry.define("announce", {
    perm = "server.announce", shape = { text = { type = "string", max = 200 } },
    fn = function(ctx)
        say.all("announce", { text = ctx.data.text, by = ctx.actor.name })
        return { text = ctx.data.text }
    end,
})

registry.define("reload", {
    perm = "server.reload",
    fn = function()
        local name = node.resources.manifest and node.resources.manifest().name or "warden"
        node.after(100, function() node.resources.reload(name) end)
        return { resource = name }
    end,
})

registry.define("lang", {
    shape = { lang = { type = "string", max = 5, enum = { "en", "ru" } } }, audit = false,
    fn = function(ctx)
        if ctx.actor.console then return "console_cannot" end
        return { lang = say.set_lang(ctx.actor.player, ctx.data.lang) }
    end,
})

registry.define("whoami", {
    audit = false,
    fn = function(ctx)
        if ctx.actor.console then return { name = "console" } end
        return { me = M.player_row(ctx.actor.player, true, ctx.actor), perms = perms.perms_of(ctx.actor.player) }
    end,
})

-- ---------------------------------------------------------------------------
-- the panel's own state: shown / hidden and the UI scale, per identity key,
-- the caller's own record only (no target, no permission: any player has a
-- panel; the console has none)
-- ---------------------------------------------------------------------------

function M.ui_state(player)
    return uistate.resolve(identity.key(player), settings.get("ui.default_shown") and perms.has(player, "players.view"))
end

registry.define("ui_get", {
    audit = false,
    fn = function(ctx)
        if ctx.actor.console then return "console_cannot" end
        return { ui = M.ui_state(ctx.actor.player) }
    end,
})

registry.define("ui_set", {
    shape = {
        shown = { type = "bool", optional = true },
        scale = { type = "number", min = 0, max = 100, optional = true },
    }, audit = false,
    fn = function(ctx)
        if ctx.actor.console then return "console_cannot" end
        if ctx.data.shown == nil and ctx.data.scale == nil then return "bad_arg", { field = "shown" } end
        uistate.set(ctx.actor.key, { shown = ctx.data.shown, scale = ctx.data.scale })
        return { ui = M.ui_state(ctx.actor.player) }
    end,
})

return M
