-- commands.registry: every action warden can take, in one table, and the one
-- path that runs them -- from a chat line, from the panel (wd:req) and later
-- from the console. The checks happen here and nowhere else:
--
--   1. the kind exists                       -> unknown_kind
--   2. the actor has the permission          -> denied   (before the target is looked up:
--                                               a refusal tells nothing about who exists)
--   3. the target resolves (pid / name / key)-> no_target, offline, ambiguous, guest_by_name, bad_key
--   4. rank: level(actor) > level(target)    -> outranked (kinds with rank = true)
--   5. the data has the shape                -> bad_arg { field }
--   6. fn(ctx) in xpcall                     -> internal
--   7. a change a read-only store refused    -> store_readonly (the actor is told, not left believing)
--   8. audit (success and refusal alike; the row carries the shape's fields only, cut short)
--
--   registry.define(kind, spec)     spec = { perm, target = "player" | "key" | "none",
--                                   rank = bool, self = bool (may act on oneself without
--                                   perm/rank), privileged = bool (a name that is a guest's is
--                                   refused: group, whitelist), fuzzy = bool (a unique prefix of
--                                   a connected name is accepted: read-only kinds only),
--                                   shape = { field = { type, max, min, optional, enum } },
--                                   fn = function(ctx) return data end }
--   registry.run(actor, kind, data) -> { ok = true, data } | { ok = false, error = { code, params } }
--   registry.kinds() -> sorted names
--   registry.allowed(actor, kind) -> bool
--
-- ctx = { actor, kind, data, raw, target = { pid?, key, name, level, group, player? } | nil,
--         detail = nil (a handler may set what the audit row should carry as `detail`) }

local audit = require("core.audit")
local groups = require("perms.groups")
local identity = require("identity.identity")
local perms = require("perms.perms")
local store = require("core.store")
local util = require("core.util")

local M = {}

M.KINDS = {}
M.ARG_MAX = 200   -- bytes of a string kept in an audit row

function M.define(kind, spec)
    if type(kind) ~= "string" or type(spec) ~= "table" or type(spec.fn) ~= "function" then
        error("registry.define(kind, { perm, target, fn })", 2)
    end
    spec.target = spec.target or "none"
    spec.shape = spec.shape or {}
    M.KINDS[kind] = spec
end

function M.kinds()
    return util.keys(M.KINDS)
end

function M.allowed(actor, kind)
    local spec = M.KINDS[kind]
    if spec == nil then return false end
    if spec.perm == nil then return true end
    return actor.console or perms.has(actor.player or actor, spec.perm)
end

local after = {}

-- fn(kind, result, ctx) after every run (the panel pushes on it)
function M.after(fn)
    after[#after + 1] = fn
end

local function fail(code, params)
    return { ok = false, error = { code = code, params = params } }
end

-- may this actor see addresses? (spec 4.7: IPs are for mod.ban and up)
local function reveals(actor)
    return actor.console == true or perms.has(actor.player or actor, "mod.ban")
end

-- the level the rank rule compares against: the key's group, and for an
-- address every connected player behind it (an ip ban hits them all)
local function rank_of(key, player)
    local group = player and perms.group_of(player) or perms.group_of_key(key)
    local level = player and perms.level_of(player) or groups.level(group)
    local ip = key:match("^ip:(.+)$")
    if ip then
        for _, p in ipairs(node.players.all()) do
            if p.ip == ip then level = math.max(level, perms.level_of(p)) end
        end
    end
    return group, level
end

-- a target from data.pid (a connected player), data.key (a key) or
-- data.target ("#pid", a key, a name); see identity.find for the name rules
local function resolve(spec, actor, data)
    local player, key
    if data.pid ~= nil then
        local pid = math.tointeger(tonumber(data.pid))
        if pid == nil then return nil, fail("bad_arg", { field = "pid" }) end
        player = node.players.get(pid)
        if player == nil or not player:isConnected() then return nil, fail("offline") end
        key = identity.key(player)
    elseif data.key ~= nil then
        key = identity.parse_key(data.key)
        if key == nil then return nil, fail("bad_key", { target = util.clean(tostring(data.key), 64) }) end
        player = identity.online_by_key(key)
    elseif type(data.target) == "string" then
        local found, why, params = identity.find(data.target, {
            online_only = spec.target == "player", fuzzy = spec.fuzzy == true, strict_guest = spec.privileged == true,
            prefer_pid = spec.self and not actor.console and actor.pid or nil,
        })
        if found == nil then
            params = params or {}
            if why == "ambiguous" then
                params.keys = identity.describe(params.candidates, reveals(actor))
                params.candidates = nil
            elseif why == "guest_by_name" and not reveals(actor) then
                params.key = identity.mask_key(params.key)
            end
            return nil, fail(why, params)
        end
        key, player = found, why
    else
        return nil, fail("bad_arg", { field = "target" })
    end
    if spec.target == "player" and player == nil then return nil, fail("offline") end
    local group, level = rank_of(key, player)
    return {
        pid = player and player.id or nil, key = key,
        name = player and player.name or identity.display(key), level = level, group = group, player = player,
    }
end

local function check_shape(spec, data)
    local out = {}
    for field, rule in pairs(spec.shape) do
        local v = data[field]
        if v == nil or v == "" then
            if not rule.optional then return nil, field end
            out[field] = rule.default
        else
            if rule.type == "string" then
                if type(v) ~= "string" then v = tostring(v) end
                v = util.clean(v, rule.max or 200)
                if v == "" and not rule.optional then return nil, field end
                if rule.enum and not util.contains(rule.enum, v) then return nil, field end
                out[field] = v
            elseif rule.type == "int" then
                local n = math.tointeger(tonumber(v))
                if n == nil then return nil, field end
                if rule.min and n < rule.min then return nil, field end
                if rule.max and n > rule.max then return nil, field end
                out[field] = n
            elseif rule.type == "number" then
                local n = tonumber(v)
                if n == nil then return nil, field end
                if rule.min and n < rule.min then return nil, field end
                if rule.max and n > rule.max then return nil, field end
                out[field] = n
            elseif rule.type == "bool" then
                if type(v) == "boolean" then out[field] = v
                elseif v == "true" or v == "yes" or v == "1" then out[field] = true
                elseif v == "false" or v == "no" or v == "0" then out[field] = false
                else return nil, field end
            elseif rule.type == "table" then
                if type(v) ~= "table" then return nil, field end
                out[field] = v
            elseif rule.type == "any" then
                out[field] = v
            else
                return nil, field
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- the audit row
-- ---------------------------------------------------------------------------

local function slim_value(v)
    local tv = type(v)
    if tv == "string" then return util.clean(v, M.ARG_MAX) end
    if tv == "number" or tv == "boolean" then return v end
    if tv == "table" then return "<table:" .. util.count(v) .. ">" end
    return "<" .. tv .. ">"
end

-- what of the data the row keeps: the shape's fields and the targeting
-- ones, each cut short; anything else is counted, never copied. The client
-- chooses what it sends -- the log must not be its to fill.
local TARGETING = { pid = true, target = true, key = true }

local function slim_args(spec, data)
    local out, dropped = {}, 0
    for k, v in pairs(data) do
        if type(k) == "string" and (spec.shape[k] ~= nil or TARGETING[k]) then
            out[k] = slim_value(v)
        else
            dropped = dropped + 1
        end
    end
    return out, dropped
end

local function record(spec, actor, kind, target, data, result, detail)
    local args, dropped = slim_args(spec, type(data) == "table" and data or {})
    local row = {
        actor = actor, op = kind, target = target and { pid = target.pid, key = target.key, name = target.name } or nil,
        args = args, result = result.ok and "ok" or "denied",
        reason = (not result.ok) and result.error.code or nil,
        dropped = dropped > 0 and dropped or nil, detail = detail,
    }
    audit.log(row)
end

-- before the target is looked up: could this be the actor acting on
-- themselves (the self kinds need no permission for that)?
local function targets_self(actor, data)
    if actor.console then return false end
    if data.pid ~= nil then return math.tointeger(tonumber(data.pid)) == actor.pid end
    if data.key ~= nil then return data.key == actor.key end
    if type(data.target) == "string" then
        local t = util.trim(data.target)
        return t == ("#" .. tostring(actor.pid)) or t == actor.key
            or (type(actor.name) == "string" and t:lower() == actor.name:lower())
    end
    return false
end

function M.run(actor, kind, data)
    data = type(data) == "table" and data or {}
    local spec = M.KINDS[kind]
    if spec == nil then return fail("unknown_kind", { kind = tostring(kind) }) end
    local allowed = M.allowed(actor, kind)
    if not allowed and not (spec.self == true and targets_self(actor, data)) then
        local r = fail("denied", { perm = spec.perm })
        record(spec, actor, kind, nil, data, r)
        return r
    end
    local target, err
    if spec.target ~= "none" then
        target, err = resolve(spec, actor, data)
        if target == nil then
            record(spec, actor, kind, nil, data, err)
            return err
        end
    end
    local on_self = target ~= nil and not actor.console and target.pid ~= nil and target.pid == actor.pid
    local skip_checks = on_self and spec.self == true
    if not skip_checks then
        if not allowed then
            local r = fail("denied", { perm = spec.perm })
            record(spec, actor, kind, target, data, r)
            return r
        end
        if spec.rank and target ~= nil and not perms.outranks(actor, target) then
            local r = fail("outranked", { target = target.name })
            record(spec, actor, kind, target, data, r)
            return r
        end
    end
    local args, bad = check_shape(spec, data)
    if args == nil then
        local r = fail("bad_arg", { field = bad })
        record(spec, actor, kind, target, data, r)
        return r
    end
    local ctx = { actor = actor, kind = kind, data = args, raw = data, target = target }
    local rejected_before = store.rejected
    local ok, res, res_params = xpcall(spec.fn, debug.traceback, ctx)
    local result
    if not ok then
        node.log("[warden] " .. kind .. " failed: " .. tostring(res))
        result = fail("internal")
    elseif type(res) == "table" and res.ok == false then
        result = res
    elseif type(res) == "string" then
        -- a handler's `return "code", params` is a refusal
        result = fail(res, res_params)
    else
        result = { ok = true, data = res }
    end
    if result.ok and store.rejected > rejected_before then
        -- the change is in memory but a read-only store refused to keep it
        local name = store.last_readonly or "?"
        node.log("[warden] " .. kind .. " by " .. tostring(actor.name) .. ": not saved, data/" .. name
            .. ".json is read-only (fix the file; it is left alone until it parses)")
        result = fail("store_readonly", { store = name })
    end
    if spec.audit ~= false then record(spec, actor, kind, target, args, result, ctx.detail) end
    for _, fn in ipairs(after) do pcall(fn, kind, result, ctx) end
    return result
end

M.fail = fail

return M
