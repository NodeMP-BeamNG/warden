-- moderation.whitelist: who may join when whitelist.enabled is on --
-- data/whitelist.json holds keys ("acct:12", "ip:1.2.3.4") and names
-- ("name:bob", for a player not seen yet). A name entry is matched
-- case-insensitively and turned into the key at the first join of a
-- SIGNED-IN account of that name (`verified and not guest`): a guest's name
-- is whatever the guest typed, so a name entry never admits one -- on a
-- server without a directory, or for guests, whitelist by ip: key or #pid.
-- The connect check itself is in main.lua's playerConnectRequest handler,
-- which asks allowed().
--
--   whitelist.init()
--   whitelist.allowed(player) -> bool          true when the list is off
--   whitelist.add(entry, by) -> entry, err, params   key, "name:x", "#pid" or a plain name
--                                              (a name that is a guest's or in doubt is refused:
--                                              guest_by_name / ambiguous, as the commands do)
--   whitelist.remove(entry) -> entry, err, params    an entry as listed, or what add() takes
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

-- what an admin typed as an entry: key | nil, err, params
local function normalize(entry)
    entry = util.trim(entry)
    if entry == "" or #entry > 64 then return nil, "bad_entry" end
    if identity.looks_like_key(entry) then
        local key = identity.parse_key(entry)
        if key == nil then return nil, "bad_key", { target = entry } end
        return key
    end
    if entry:match("^name:.+$") then return "name:" .. entry:sub(6):lower() end
    if entry:match("^#%d+$") then
        local key, why = identity.find(entry)
        if key == nil then return nil, why == "offline" and "offline" or "bad_entry" end
        return key
    end
    -- a plain name: the account's key when we know one of that name; a name
    -- entry when nobody does; never a guest's key (their name proves nothing)
    local key, why, params = identity.find(entry, { strict_guest = true })
    if key then return key end
    if why == "no_target" then return "name:" .. entry:lower() end
    return nil, why, params
end

function M.allowed(player)
    if not M.enabled() then return true end
    local entries = file.data.entries
    if entries[identity.key(player)] then return true end
    if player.verified ~= true or player.guest == true or player.accountId == nil then return false end
    local name = type(player.name) == "string" and ("name:" .. player.name:lower()) or nil
    if name and entries[name] then
        -- a signed-in account of that name: promote the name entry to the key now that we know it
        entries[identity.key(player)] = entries[name]
        entries[name] = nil
        file:mark()
        return true
    end
    return false
end

function M.add(entry, by)
    local norm, err, params = normalize(entry)
    if norm == nil then return nil, err, params end
    if file.data.entries[norm] then return nil, "already" end
    file.data.entries[norm] = { by = by and by.name or "console", at = util.now() }
    file:mark()
    return norm
end

function M.remove(entry)
    local typed = util.trim(entry)
    -- an entry as it is listed goes first (a name entry a guest of that name could shadow)
    if file.data.entries[typed] then
        file.data.entries[typed] = nil
        file:mark()
        return typed
    end
    local as_name = "name:" .. typed:lower()
    if file.data.entries[as_name] then
        file.data.entries[as_name] = nil
        file:mark()
        return as_name
    end
    local norm, err, params = normalize(entry)
    if norm == nil then return nil, err, params end
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
