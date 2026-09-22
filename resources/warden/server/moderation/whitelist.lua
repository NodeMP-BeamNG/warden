-- moderation.whitelist: who may join when whitelist.enabled is on --
-- data/whitelist.json holds keys ("acct:12", "ip:1.2.3.4") and names
-- ("name:bob", for a player not seen yet; matched case-insensitively and
-- turned into the key at their first join). The connect check itself is
-- in main.lua's playerConnectRequest handler, which asks allowed().
--
--   whitelist.init()
--   whitelist.allowed(player) -> bool          true when the list is off
--   whitelist.add(entry, by) -> ok, err         key, "name:x" or a plain name
--   whitelist.remove(entry) -> ok, err
--   whitelist.list() -> array { entry, by, at }
--   whitelist.enabled() -> bool

local store = require("core.store")
local identity = require("identity.identity")
local settings = require("core.settings")
local util = require("core.util")

local M = {}

local file = nil

function M.init()
    file = store.open("whitelist", function() return { entries = {} } end)
    if type(file.data.entries) ~= "table" then
        file.data.entries = {}
        file:mark()
    end
end

function M.enabled()
    return settings.get("whitelist.enabled") == true
end

local function normalize(entry)
    entry = util.trim(entry)
    if entry == "" or #entry > 64 then return nil end
    if entry:match("^acct:%d+$") or entry:match("^ip:[%w%.:]+$") then return entry end
    if entry:match("^name:.+$") then return "name:" .. entry:sub(6):lower() end
    if entry:match("^#%d+$") then
        local key = identity.find(entry)
        return key
    end
    -- a plain name: the key when we know the player, else a name entry
    local key = identity.find(entry)
    if key then return key end
    return "name:" .. entry:lower()
end

function M.allowed(player)
    if not M.enabled() then return true end
    local entries = file.data.entries
    if entries[identity.key(player)] then return true end
    local name = type(player.name) == "string" and ("name:" .. player.name:lower()) or nil
    if name and entries[name] then
        -- promote the name entry to the key now that we know it
        entries[identity.key(player)] = entries[name]
        entries[name] = nil
        file:mark()
        return true
    end
    return false
end

function M.add(entry, by)
    local norm = normalize(entry)
    if norm == nil then return nil, "bad_entry" end
    if file.data.entries[norm] then return nil, "already" end
    file.data.entries[norm] = { by = by and by.name or "console", at = util.now() }
    file:mark()
    return norm
end

function M.remove(entry)
    local norm = normalize(entry)
    if norm == nil then return nil, "bad_entry" end
    if not file.data.entries[norm] then return nil, "not_listed" end
    file.data.entries[norm] = nil
    file:mark()
    return norm
end

function M.list()
    local out = {}
    for entry, meta in pairs(file.data.entries) do
        out[#out + 1] = { entry = entry, name = identity.display(entry), by = meta.by, at = meta.at }
    end
    table.sort(out, function(a, b) return a.entry < b.entry end)
    return out
end

return M
