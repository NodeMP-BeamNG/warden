-- core.settings: the runtime settings -- the [config] keys whose schema entry
-- says `runtime = true`. The value in force is data/settings.json when it has
-- the key, else resource.toml's. `/settings set` and the panel write through
-- here; every change is announced to the listeners so the modules re-read.
--
--   settings.init(cfg)                    cfg from core.config.load
--   settings.get("votekick.threshold")    the effective value
--   settings.set(key, raw) -> ok, err     coerced against the schema; persisted
--   settings.reset(key) -> ok             back to resource.toml's value
--   settings.list() -> { { key, value, default, type, overridden }, ... }
--   settings.on_change(fn)                fn(key, value)
--   settings.is_runtime(key)

local config = require("core.config")
local store = require("core.store")
local util = require("core.util")

local M = {}

local cfg = nil
local file = nil
local listeners = {}

function M.init(loaded)
    cfg = loaded
    file = store.open("settings", function() return {} end)
    -- an edited settings.json: validate and announce every key it carries
    file:on_reload(function(data)
        for key, value in pairs(data) do
            if M.is_runtime(key) then
                local ok = config.coerce(config.SCHEMA[key], value)
                if ok ~= nil then M._announce(key, ok) end
            end
        end
    end)
end

function M.is_runtime(key)
    local spec = config.SCHEMA[key]
    return spec ~= nil and spec.runtime == true
end

function M.get(key)
    if file ~= nil and file.data[key] ~= nil and M.is_runtime(key) then
        local ok = config.coerce(config.SCHEMA[key], file.data[key])
        if ok ~= nil then return ok end
    end
    return config.get(cfg, key)
end

function M._announce(key, value)
    for _, fn in ipairs(listeners) do pcall(fn, key, value) end
end

function M.set(key, raw)
    if not M.is_runtime(key) then return nil, "not_runtime" end
    local value, why = config.coerce(config.SCHEMA[key], raw)
    if value == nil then return nil, why end
    file.data[key] = value
    file:mark()
    M._announce(key, value)
    return value
end

function M.reset(key)
    if not M.is_runtime(key) then return nil, "not_runtime" end
    file.data[key] = nil
    file:mark()
    M._announce(key, M.get(key))
    return true
end

function M.list()
    local out = {}
    for _, key in ipairs(config.ORDER) do
        local spec = config.SCHEMA[key]
        if spec.runtime then
            out[#out + 1] = {
                key = key, value = M.get(key), default = config.get(cfg, key), type = spec.type,
                min = spec.min, max = spec.max, enum = spec.enum,
                overridden = file ~= nil and file.data[key] ~= nil,
            }
        end
    end
    return out
end

function M.on_change(fn)
    listeners[#listeners + 1] = fn
end

-- the whole loaded config, for the keys that are not runtime
function M.config()
    return cfg
end

-- a value shown to a player / the panel as text
function M.render(value)
    if type(value) == "table" then return node.json.encode(value) end
    if math.type(value) == "float" then return string.format("%g", value) end
    return tostring(value)
end

M.util = util

return M
