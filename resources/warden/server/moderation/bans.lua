-- moderation.bans: bans through node.bans (the server persists them in
-- bans.json and refuses the connect before any resource sees it), plus what
-- the server does not keep: who banned, why, the name, and the expiry of a
-- temporary ban (data/bans_meta.json). A timer lifts expired bans.
--
--   bans.init()
--   bans.ban(target, by, reason, duration_sec?) -> ok, err
--       target = { key, player?, name }; a duration makes it temporary
--   bans.unban(key) -> ok, err
--   bans.list() -> array { key, who, name, reason, by, at, until }
--   bans.tick()                     lifts what expired (node.every, and callable)
--   bans.meta(key) -> the record

local store = require("core.store")
local identity = require("identity.identity")
local util = require("core.util")

local M = {}

M.CHECK_MS = 30000

local file = nil
local timer = nil

function M.init()
    file = store.open("bans_meta", function() return {} end)
    if timer then node.cancel(timer) end
    timer = node.every(M.CHECK_MS, M.tick)
end

function M.meta(key)
    return file.data[key]
end

function M.ban(target, by, reason, duration)
    local key = target.key
    local who = identity.ban_target(key)
    if who == nil then return nil, "bad_target" end
    reason = util.clean(reason or "", 200)
    if reason == "" then reason = nil end
    local now = util.now()
    local until_ts = nil
    if duration and duration > 0 then until_ts = now + math.floor(duration) end
    local ok
    if target.player and type(target.player.ban) == "function" then
        -- kicks too, and bans the account when verified and the ip always
        ok = target.player:ban(reason or "banned")
        if target.player.accountId == nil and who ~= target.player.ip then
            node.bans.add(who, reason)
        end
    else
        ok = node.bans.add(who, reason)
    end
    if not ok then return nil, "ban_failed" end
    file.data[key] = {
        who = who, name = target.name or identity.display(key), reason = reason,
        by = by and by.key or "console", by_name = by and by.name or "console",
        at = now, ["until"] = until_ts,
    }
    -- a verified player's ip is banned as well by player:ban; remember it so unban lifts both
    if target.player and target.player.accountId ~= nil and target.player.ip then
        file.data[key].ip = target.player.ip
    end
    file:mark()
    return true
end

function M.unban(key)
    local who = identity.ban_target(key)
    if who == nil then return nil, "bad_target" end
    local meta = file.data[key]
    local lifted = node.bans.remove(who) and true or false
    if meta and meta.ip and meta.ip ~= who then
        if node.bans.remove(meta.ip) then lifted = true end
    end
    if meta then
        file.data[key] = nil
        file:mark()
    end
    if not lifted and not meta then return nil, "not_banned" end
    return true
end

function M.is_banned(key)
    local who = identity.ban_target(key)
    if who == nil then return false end
    return node.bans.has(who) and true or false
end

function M.list()
    local out = {}
    local seen = {}
    for key, meta in pairs(file.data) do
        seen[tostring(meta.who)] = true
        if meta.ip then seen[tostring(meta.ip)] = true end
        out[#out + 1] = {
            key = key, who = meta.who, name = meta.name, reason = meta.reason, by = meta.by_name or meta.by,
            at = meta.at, ["until"] = meta["until"],
        }
    end
    -- bans the server has that warden did not make (an operator's, an older run's)
    local all = node.bans.all and node.bans.all() or {}
    for _, b in ipairs(type(all) == "table" and all or {}) do
        local who = b.account or b.ip
        if who ~= nil and not seen[tostring(who)] then
            out[#out + 1] = {
                key = b.account and ("acct:" .. tostring(b.account)) or ("ip:" .. tostring(b.ip)),
                who = who, name = b.name, reason = b.reason, by = nil, at = b.at, ["until"] = nil,
            }
        end
    end
    table.sort(out, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return out
end

function M.tick()
    local now = util.now()
    local lifted = 0
    for key, meta in pairs(file.data) do
        if meta["until"] and meta["until"] <= now then
            M.unban(key)
            lifted = lifted + 1
        end
    end
    return lifted
end

return M
