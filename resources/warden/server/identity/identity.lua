-- identity: who a player is across sessions. The key is the directory
-- account ("acct:<id>") when there is one, else the address ("ip:<addr>") --
-- a guest, or every player of a server without a [Directory]. Records live
-- in data/players.json: the group, the names seen, first/last seen, joins,
-- warnings, the mute, the language.
--
--   identity.init()
--   identity.key(player) -> "acct:12" | "ip:1.2.3.4"
--   identity.record(key, create?) -> record | nil
--   identity.record_of(player) -> record (created)
--   identity.touch(player)             on join: names, joins, last_seen
--   identity.find(text) -> key | nil    "#12" (pid), "acct:12", "ip:...", or a
--                                      name from the history (exact, then unique prefix)
--   identity.display(key) -> the last name seen under the key
--   identity.is_guest(player) -> no account behind the name
--   identity.mark()                    after editing a record

local store = require("core.store")
local util = require("core.util")

local M = {}

M.MAX_NAMES = 10

local file = nil

function M.init()
    file = store.open("players", function() return {} end)
end

function M.is_guest(player)
    return player.accountId == nil
end

function M.key(player)
    if player.accountId ~= nil then return "acct:" .. tostring(math.tointeger(player.accountId) or player.accountId) end
    return "ip:" .. tostring(player.ip or "?")
end

function M.record(key, create)
    local rec = file.data[key]
    if rec == nil and create then
        rec = { group = nil, names = {}, first_seen = util.now(), last_seen = util.now(), joins = 0, warns = {} }
        file.data[key] = rec
        file:mark()
    end
    return rec
end

function M.record_of(player)
    return M.record(M.key(player), true)
end

function M.mark()
    if file then file:mark() end
end

function M.touch(player)
    local rec = M.record_of(player)
    local name = player.name
    if type(name) == "string" and name ~= "" then
        for i, n in ipairs(rec.names) do
            if n == name then table.remove(rec.names, i) break end
        end
        table.insert(rec.names, 1, name)
        while #rec.names > M.MAX_NAMES do table.remove(rec.names) end
    end
    rec.joins = (rec.joins or 0) + 1
    rec.last_seen = util.now()
    rec.last_ip = player.ip
    file:mark()
    return rec
end

function M.display(key)
    local rec = file.data[key]
    if rec and rec.names and rec.names[1] then return rec.names[1] end
    return key
end

function M.all()
    return file.data
end

-- a key from what an admin typed: "#12" is a connected pid; "acct:.." / "ip:.."
-- are keys; else the newest record whose last name matches, exactly first,
-- then by unique case-insensitive prefix
function M.find(text)
    text = util.trim(text)
    if text == "" then return nil end
    local pid = text:match("^#(%d+)$")
    if pid then
        local p = node.players.get(tonumber(pid))
        if p and p:isConnected() then return M.key(p), p end
        return nil
    end
    if text:match("^acct:%d+$") or text:match("^ip:.+$") then
        return file.data[text] and text or text
    end
    local online = node.players.find(text)
    if online then return M.key(online), online end
    local lower = text:lower()
    local exact, prefix, prefix_n = nil, nil, 0
    for key, rec in pairs(file.data) do
        local name = rec.names and rec.names[1]
        if type(name) == "string" then
            if name:lower() == lower then
                if exact == nil or (rec.last_seen or 0) > (file.data[exact].last_seen or 0) then exact = key end
            elseif name:lower():sub(1, #lower) == lower then
                prefix_n = prefix_n + 1
                prefix = key
            end
        end
    end
    if exact then return exact end
    if prefix_n == 1 then return prefix end
    return nil
end

-- the ip / account id a key stands for (what node.bans takes)
function M.ban_target(key)
    local acct = key:match("^acct:(%d+)$")
    if acct then return tonumber(acct) end
    local ip = key:match("^ip:(.+)$")
    if ip then return ip end
    return nil
end

return M
