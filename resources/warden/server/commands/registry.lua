-- commands.registry: every action warden can take, in one table, and the one
-- path that runs them -- from a chat line, from the panel (wd:req) and later
-- from the console. The checks happen here and nowhere else:
--
--   1. the kind exists                       -> unknown_kind
--   2. the actor has the permission          -> denied
--   3. the target resolves (pid / name / key)-> no_target, offline
--   4. rank: level(actor) > level(target)    -> outranked (kinds with rank = true)
--   5. the data has the shape                -> bad_arg { field }
--   6. fn(ctx) in xpcall                     -> internal
--   7. audit (success and refusal alike)
--
--   registry.define(kind, spec)     spec = { perm, target = "player" | "key" | "none",
--                                   rank = bool, self = bool (may act on oneself without
--                                   perm/rank), shape = { field = { type, max, min, optional, enum } },
--                                   fn = function(ctx) return data end }
--   registry.run(actor, kind, data) -> { ok = true, data } | { ok = false, error = { code, params } }
--   registry.kinds() -> sorted names
--   registry.allowed(actor, kind) -> bool
--
-- ctx = { actor, kind, data, target = { pid?, key, name, level, group, player? } | nil, fail(code, params) }

local audit = require("core.audit")
local identity = require("identity.identity")
local perms = require("perms.perms")
local util = require("core.util")

local M = {}

M.KINDS = {}

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

-- a target from data.pid (a connected player), data.target ("#pid", a name,
-- a key) or data.key
local function resolve(spec, data)
    local player, key
    if data.pid ~= nil then
        local pid = math.tointeger(tonumber(data.pid))
        if pid == nil then return nil, fail("bad_arg", { field = "pid" }) end
        player = node.players.get(pid)
        if player == nil or not player:isConnected() then return nil, fail("offline") end
        key = identity.key(player)
    elseif type(data.key) == "string" then
        key = data.key
        for _, p in ipairs(node.players.all()) do
            if identity.key(p) == key then player = p break end
        end
    elseif type(data.target) == "string" then
        local found, online = identity.find(data.target)
        if found == nil then return nil, fail("no_target", { target = data.target }) end
        key, player = found, online
        if player == nil then
            for _, p in ipairs(node.players.all()) do
                if identity.key(p) == key then player = p break end
            end
        end
    else
        return nil, fail("bad_arg", { field = "target" })
    end
    if spec.target == "player" and player == nil then return nil, fail("offline") end
    local group = player and perms.group_of(player) or perms.group_of_key(key)
    local level = player and perms.level_of(player) or require("perms.groups").level(group)
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

local function record(actor, kind, target, args, result)
    local row = {
        actor = actor, op = kind, target = target and { pid = target.pid, key = target.key, name = target.name } or nil,
        args = args, result = result.ok and "ok" or "denied",
        reason = (not result.ok) and result.error.code or nil,
    }
    if result.ok and type(result.data) == "table" and result.data.audit ~= nil then row.detail = result.data.audit end
    audit.log(row)
end

function M.run(actor, kind, data)
    data = type(data) == "table" and data or {}
    local spec = M.KINDS[kind]
    if spec == nil then return fail("unknown_kind", { kind = tostring(kind) }) end
    local target, err
    if spec.target ~= "none" then
        target, err = resolve(spec, data)
        if target == nil then
            record(actor, kind, nil, data, err)
            return err
        end
    end
    local on_self = target ~= nil and not actor.console and target.pid ~= nil and target.pid == actor.pid
    local skip_checks = on_self and spec.self == true
    if not skip_checks then
        if not M.allowed(actor, kind) then
            local r = fail("denied", { perm = spec.perm })
            record(actor, kind, target, data, r)
            return r
        end
        if spec.rank and target ~= nil and not perms.outranks(actor, target) then
            local r = fail("outranked", { target = target.name })
            record(actor, kind, target, data, r)
            return r
        end
    end
    local args, bad = check_shape(spec, data)
    if args == nil then
        local r = fail("bad_arg", { field = bad })
        record(actor, kind, target, data, r)
        return r
    end
    local ctx = { actor = actor, kind = kind, data = args, raw = data, target = target }
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
    if spec.audit ~= false then record(actor, kind, target, args, result) end
    for _, fn in ipairs(after) do pcall(fn, kind, result, ctx) end
    return result
end

M.fail = fail

return M
