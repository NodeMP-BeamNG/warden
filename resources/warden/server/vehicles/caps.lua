-- vehicles.caps: how many vehicles a player may have, by group
-- (groups.json caps.vehicles; -1 = unlimited; car.cap.bypass ignores it).
-- Enforced on vehicleSpawnRequest: the deny reason is shown by the client.
--
--   caps.limit(player) -> number       -1 for unlimited
--   caps.check(player) -> true | false, reason_code, params
--   caps.delete_all(player) -> n       every vehicle the player has
--   caps.delete_one(player, vid) -> bool   one of the player's vehicles by its global id; false
--                                       when it is not theirs (nobody deletes through a stranger)

local groups = require("perms.groups")
local perms = require("perms.perms")

local M = {}

function M.limit(player)
    if perms.has(player, "car.cap.bypass") then return -1 end
    return groups.cap(perms.group_of(player), "vehicles")
end

function M.check(player)
    local limit = M.limit(player)
    if limit < 0 then return true end
    local have = tonumber(player.vehicleCount) or 0
    if have >= limit then return false, "cap.vehicles", { limit = limit } end
    return true
end

function M.delete_all(player)
    local n = 0
    local list = type(player.vehicles) == "function" and player:vehicles() or {}
    for _, v in ipairs(list or {}) do
        if type(v.delete) == "function" and v:delete() then n = n + 1 end
    end
    return n
end

function M.delete_one(player, vid)
    local list = type(player.vehicles) == "function" and player:vehicles() or {}
    for _, v in ipairs(list or {}) do
        if v.id == vid and type(v.delete) == "function" then return v:delete() == true end
    end
    return false
end

return M
