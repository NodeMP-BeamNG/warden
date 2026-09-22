-- perms: what a player may do. The group comes from the player's record
-- (identity), the owner group from resource.toml (owner_ids) or the
-- directory's ADM role; a player with no record is in default_group.
--
-- The rank rule needs a level for an offline key as well: owner_ids are
-- read live, the directory's ADM role is remembered on the record at every
-- join (rec.owner_role; cleared at the first join without it) and the level
-- is written there too (rec.level, informational). An offline owner or
-- admin keeps their level, so nobody bans or demotes them while they are
-- away.
--
--   perms.init(cfg)
--   perms.group_of(player) -> name
--   perms.group_of_key(key) -> name            owner-aware (owner_ids, the remembered ADM flag)
--   perms.level_of(player) -> number
--   perms.level_of_key(key) -> number
--   perms.is_owner(player) / is_owner_key(key) -> bool
--   perms.has(player, perm) -> bool
--   perms.outranks(actor, target) -> bool      level(actor) > level(target); owners always
--   perms.set_group(player_or_key, group) -> ok, err   never on an owner (owner_is_config)
--   perms.remember(player)                     on join: rec.owner_role, rec.level
--   perms.actor(player) -> { pid, key, name, group, level, console = false }
--   perms.CONSOLE -> the console actor (level math.huge)
--   perms.apply_tag(player)                    player:setRole(group) when role_tag is on
--   perms.on_change(fn)                        fn(key, group, pid?)

local groups = require("perms.groups")
local identity = require("identity.identity")
local settings = require("core.settings")
local util = require("core.util")

local M = {}

local cfg = nil
local listeners = {}

M.CONSOLE = { pid = -1, key = "console", name = "console", group = "owner", level = math.huge, console = true }

function M.init(loaded)
    cfg = loaded
end

function M.on_change(fn)
    listeners[#listeners + 1] = fn
end

local function is_owner_id(id)
    id = math.tointeger(tonumber(id)) or id
    for _, o in ipairs(cfg.owner_ids or {}) do
        if o == id then return true end
    end
    return false
end

local function is_directory_admin(player)
    return cfg.directory_admin_is_owner == true and player.accountRoles == "ADM"
end

local function is_owner(player)
    if player.accountId ~= nil and is_owner_id(player.accountId) then return true end
    return is_directory_admin(player)
end

M.is_owner = is_owner

function M.is_owner_key(key)
    if type(key) ~= "string" then return false end
    local id = key:match("^acct:(%d+)$")
    if id and is_owner_id(id) then return true end
    local rec = identity.record(key)
    return cfg.directory_admin_is_owner == true and rec ~= nil and rec.owner_role == true
end

function M.group_of(player)
    if type(player) ~= "table" then return cfg.default_group end
    if player.console then return "owner" end
    if is_owner(player) then return "owner" end
    local rec = identity.record(identity.key(player))
    local g = rec and rec.group
    if type(g) == "string" and groups.exists(g) then return g end
    if groups.exists(cfg.default_group) then return cfg.default_group end
    return "default"
end

function M.group_of_key(key)
    if M.is_owner_key(key) then return "owner" end
    local rec = identity.record(key)
    local g = rec and rec.group
    if type(g) == "string" and groups.exists(g) then return g end
    return cfg.default_group
end

function M.level_of_key(key)
    return groups.level(M.group_of_key(key))
end

-- on join: the record keeps what the rank rule needs while the player is offline
function M.remember(player)
    local rec = identity.record_of(player)
    local adm = is_directory_admin(player) or nil
    local level = M.level_of(player)
    if rec.owner_role ~= adm or rec.level ~= level then
        rec.owner_role = adm
        rec.level = level
        identity.mark()
    end
    return rec
end

function M.level_of(player)
    if type(player) == "table" and player.console then return math.huge end
    return groups.level(M.group_of(player))
end

function M.has(player, perm)
    if type(player) == "table" and player.console then return true end
    return groups.allows(M.group_of(player), perm)
end

function M.perms_of(player)
    local set = groups.effective_perms(M.group_of(player))
    local out = {}
    for p in pairs(set) do out[#out + 1] = p end
    table.sort(out)
    return out
end

-- the rank rule: an action against a target needs a strictly higher level
function M.outranks(actor, target)
    if actor.console then return true end
    local a = actor.level or M.level_of(actor)
    local b = target.level or M.level_of(target)
    return a > b
end

function M.actor(player)
    if player == nil or player.console then return M.CONSOLE end
    local group = M.group_of(player)
    return {
        pid = player.id, key = identity.key(player), name = player.name or ("Player" .. tostring(player.id)),
        group = group, level = groups.level(group), console = false, player = player,
    }
end

function M.apply_tag(player)
    if not settings.get("role_tag") then return end
    if type(player.setRole) ~= "function" then return end
    local group = M.group_of(player)
    pcall(player.setRole, player, group == cfg.default_group and "" or group)
end

-- target: a Player or a key; the owner group is never assigned here, and an
-- owner (owner_ids, ADM) is never moved: their group comes from the config
function M.set_group(target, group)
    if not groups.exists(group) then return nil, "unknown_group" end
    if group == "owner" then return nil, "owner_is_config" end
    local key, player
    if type(target) == "table" then
        key, player = identity.key(target), target
        if is_owner(player) then return nil, "owner_is_config" end
    else
        key = tostring(target)
        if M.is_owner_key(key) then return nil, "owner_is_config" end
    end
    local rec = identity.record(key, true)
    rec.group = group ~= cfg.default_group and group or nil
    rec.level = groups.level(group)
    identity.mark()
    if player then M.apply_tag(player) end
    for _, fn in ipairs(listeners) do pcall(fn, key, group, player and player.id or nil) end
    return true
end

M.util = util

return M
