-- core.config: the [config] table of resource.toml, validated against one
-- schema. The schema is the single source of keys, types, bounds and
-- defaults: tools/config-doc.lua renders it into the README, and
-- core.settings marks the subset an admin may change at runtime.
--
--   config.load(raw) -> cfg, warnings   raw = node.config (or a test table);
--                                        every key present, bad values replaced
--                                        by the default with a warning line
--   config.SCHEMA                        { key = { type, default, min?, max?, enum?, runtime? } }
--   config.get(cfg, "votekick.threshold")

local util = require("core.util")

local M = {}

-- type: "string" | "int" | "number" | "bool" | "list<int>" | "list<string>"
M.SCHEMA = {
    ["language"] = { type = "string", default = "en", enum = { "en", "ru" }, runtime = true },
    ["owner_ids"] = { type = "list<int>", default = {} },
    ["directory_admin_is_owner"] = { type = "bool", default = true },
    ["allow_guests"] = { type = "bool", default = true, runtime = true },
    ["role_tag"] = { type = "bool", default = true, runtime = true },
    ["default_group"] = { type = "string", default = "default" },
    ["chat_fallback"] = { type = "bool", default = false },
    ["chat_veto_event"] = { type = "string", default = "" },
    ["whitelist.enabled"] = { type = "bool", default = false, runtime = true },
    ["votekick.enabled"] = { type = "bool", default = false, runtime = true },
    ["votekick.threshold"] = { type = "number", default = 0.6, min = 0.5, max = 1.0, runtime = true },
    ["votekick.min_players"] = { type = "int", default = 4, min = 2, max = 200, runtime = true },
    ["votekick.window_sec"] = { type = "int", default = 60, min = 15, max = 600, runtime = true },
    ["votekick.cooldown_sec"] = { type = "int", default = 300, min = 0, max = 86400, runtime = true },
    ["votekick.immune_level"] = { type = "int", default = 50, min = 0, max = 1000, runtime = true },
    ["limits.commands_per_10s"] = { type = "int", default = 8, min = 1, max = 100 },
    ["limits.ui_per_sec"] = { type = "int", default = 10, min = 1, max = 100 },
    ["limits.ui_per_min"] = { type = "int", default = 120, min = 1, max = 5000 },
    ["audit.enabled"] = { type = "bool", default = true },
    ["audit.retain_days"] = { type = "int", default = 90, min = 1, max = 3650 },
    ["spawn.enabled"] = { type = "bool", default = true, runtime = true },
    ["ui.default_shown"] = { type = "bool", default = true, runtime = true },
    ["ui.welcome"] = { type = "bool", default = true, runtime = true },
    ["ui.theme"] = { type = "string", default = "cobalt", enum = { "cobalt", "game" }, runtime = true },
}

-- the keys in resource.toml order (config-doc and /settings list use it)
M.ORDER = {
    "language", "owner_ids", "directory_admin_is_owner", "allow_guests", "role_tag", "default_group",
    "chat_fallback", "chat_veto_event",
    "whitelist.enabled",
    "votekick.enabled", "votekick.threshold", "votekick.min_players", "votekick.window_sec",
    "votekick.cooldown_sec", "votekick.immune_level",
    "limits.commands_per_10s", "limits.ui_per_sec", "limits.ui_per_min",
    "audit.enabled", "audit.retain_days",
    "spawn.enabled",
    "ui.default_shown", "ui.welcome", "ui.theme",
}

local function check_list(value, item)
    if type(value) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(value) do
        if item == "int" then
            local n = math.tointeger(tonumber(v))
            if n == nil then return nil end
            out[i] = n
        else
            if type(v) ~= "string" then return nil end
            out[i] = v
        end
    end
    return out
end

-- value coerced to the schema type, or nil, reason
function M.coerce(spec, value)
    local t = spec.type
    if t == "bool" then
        if type(value) == "boolean" then return value end
        if value == "true" then return true end
        if value == "false" then return false end
        return nil, "expected true or false"
    elseif t == "int" then
        local n = math.tointeger(tonumber(value))
        if n == nil then return nil, "expected an integer" end
        if spec.min and n < spec.min then return nil, "below " .. spec.min end
        if spec.max and n > spec.max then return nil, "above " .. spec.max end
        return n
    elseif t == "number" then
        local n = tonumber(value)
        if n == nil then return nil, "expected a number" end
        if spec.min and n < spec.min then return nil, "below " .. spec.min end
        if spec.max and n > spec.max then return nil, "above " .. spec.max end
        return n + 0.0
    elseif t == "string" then
        if type(value) ~= "string" then
            if type(value) == "number" or type(value) == "boolean" then value = tostring(value) else
                return nil, "expected a string"
            end
        end
        if spec.enum and not util.contains(spec.enum, value) then
            return nil, "one of " .. table.concat(spec.enum, ", ")
        end
        return value
    elseif t == "list<int>" or t == "list<string>" then
        local list = check_list(value, t == "list<int>" and "int" or "string")
        if list == nil then return nil, "expected a list of " .. (t == "list<int>" and "integers" or "strings") end
        return list
    end
    return nil, "unknown type " .. tostring(t)
end

function M.load(raw)
    raw = type(raw) == "table" and raw or {}
    local cfg, warnings = {}, {}
    for _, key in ipairs(M.ORDER) do
        local spec = M.SCHEMA[key]
        local given = util.get_path(raw, key)
        local value
        if given == nil then
            value = util.copy(spec.default)
        else
            local ok, why = M.coerce(spec, given)
            if ok == nil then
                warnings[#warnings + 1] = string.format("config %s: %s; using the default", key, why)
                value = util.copy(spec.default)
            else
                value = ok
            end
        end
        util.set_path(cfg, key, value)
    end
    return cfg, warnings
end

function M.get(cfg, key)
    return util.get_path(cfg, key)
end

return M
