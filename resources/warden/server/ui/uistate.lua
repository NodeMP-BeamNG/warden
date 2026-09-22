-- ui.uistate: what a player's panel looks like for them -- shown or hidden,
-- the UI scale -- kept per identity key in data/ui.json so it survives a
-- rejoin (the control model of the CobaltEssentials Interface: the window is
-- on by default, the player hides it once and it stays hidden for them).
--
-- The store is bounded: past MAX_RECORDS keys the least recently touched
-- record goes (every set() stamps `at`). Only the two fields are ever kept,
-- whatever the client sends; a scale outside SCALE_MIN..SCALE_MAX is clamped,
-- not refused, so a panel can never be told to draw at a size nobody can read.
--
--   uistate.init()
--   uistate.get(key) -> { shown = bool | nil, scale = number | nil }   nil fields = never set
--   uistate.set(key, { shown?, scale? }) -> record                      the fields given, clamped
--   uistate.resolve(key, default_shown) -> { shown, scale }             with the defaults filled in
--   uistate.count() -> number of records

local store = require("core.store")
local util = require("core.util")

local M = {}

M.MAX_RECORDS = 5000
M.SCALE_MIN = 0.75
M.SCALE_MAX = 1.5
M.SCALE_DEFAULT = 1.0

local file = nil

function M.init()
    file = store.open("ui", function() return {} end)
    if type(file.data) ~= "table" then file.data = {} end
    M.trim()
end

function M.clamp_scale(v)
    local n = tonumber(v)
    if n == nil then return nil end
    if n ~= n then return M.SCALE_DEFAULT end -- NaN
    if n < M.SCALE_MIN then n = M.SCALE_MIN end
    if n > M.SCALE_MAX then n = M.SCALE_MAX end
    -- two decimals: the value travels as JSON and is compared by the client
    return math.floor(n * 100 + 0.5) / 100
end

function M.count()
    return util.count(file and file.data or {})
end

-- drops the least recently touched records down to MAX_RECORDS
function M.trim()
    local over = M.count() - M.MAX_RECORDS
    if over <= 0 then return 0 end
    local list = {}
    for key, rec in pairs(file.data) do
        list[#list + 1] = { key = key, at = type(rec) == "table" and tonumber(rec.at) or 0 }
    end
    table.sort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.key < b.key
    end)
    for i = 1, over do file.data[list[i].key] = nil end
    file:mark()
    return over
end

function M.get(key)
    local rec = file and file.data[key]
    if type(rec) ~= "table" then return { shown = nil, scale = nil } end
    local shown = rec.shown
    if type(shown) ~= "boolean" then shown = nil end
    return { shown = shown, scale = M.clamp_scale(rec.scale) }
end

function M.set(key, fields)
    if type(key) ~= "string" or key == "" then return nil end
    fields = type(fields) == "table" and fields or {}
    local rec = file.data[key]
    if type(rec) ~= "table" then
        if M.count() >= M.MAX_RECORDS then M.trim() end
        if M.count() >= M.MAX_RECORDS then
            -- still full: make room for the newcomer
            local oldest, oldest_at = nil, math.huge
            for k, r in pairs(file.data) do
                local at = type(r) == "table" and tonumber(r.at) or 0
                if at < oldest_at or (at == oldest_at and (oldest == nil or k < oldest)) then
                    oldest, oldest_at = k, at
                end
            end
            if oldest then file.data[oldest] = nil end
        end
        rec = {}
        file.data[key] = rec
    end
    if type(fields.shown) == "boolean" then rec.shown = fields.shown end
    if fields.scale ~= nil then
        local s = M.clamp_scale(fields.scale)
        if s ~= nil then rec.scale = s end
    end
    rec.at = util.now()
    file:mark()
    return M.get(key)
end

function M.resolve(key, default_shown)
    local rec = M.get(key)
    return {
        shown = rec.shown == nil and (default_shown == true) or rec.shown == true,
        scale = rec.scale or M.SCALE_DEFAULT,
    }
end

return M
