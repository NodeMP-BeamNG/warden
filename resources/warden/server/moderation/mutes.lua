-- moderation.mutes: mutes and warnings, both on the player's record.
--
-- A mute is ADVISORY until the platform has a cancellable chat event
-- (server issue #43): warden cannot stop the `chat` resource from relaying
-- the line, so a muted player is told on every line that they are muted and
-- the mute is visible to admins. Once the event exists, its name goes into
-- resource.toml `chat_veto_event` and install_veto() drops the lines.
--
--   mutes.init()
--   mutes.mute(target, by, reason, duration_sec?) -> ok
--   mutes.unmute(key) -> ok, err
--   mutes.is_muted(key) -> bool, record      expired mutes are cleared on read
--   mutes.warn(target, by, reason) -> count
--   mutes.warns(key) -> array
--   mutes.install_veto(event_name)          node.on(event, ...) returning false for muted players
--   mutes.notice(player) -> bool             say "you are muted" at most once per NOTICE_S

local identity = require("identity.identity")
local util = require("core.util")

local M = {}

M.NOTICE_S = 10
M.MAX_WARNS = 50

local last_notice = {}   -- pid -> ts

function M.init()
    last_notice = {}
end

function M.mute(target, by, reason, duration)
    local rec = identity.record(target.key, true)
    local now = util.now()
    rec.mute = {
        reason = util.clean(reason or "", 200), by = by and by.name or "console", at = now,
        ["until"] = (duration and duration > 0) and (now + math.floor(duration)) or nil,
    }
    identity.mark()
    return true
end

function M.unmute(key)
    local rec = identity.record(key)
    if rec == nil or rec.mute == nil then return nil, "not_muted" end
    rec.mute = nil
    identity.mark()
    return true
end

function M.is_muted(key)
    local rec = identity.record(key)
    if rec == nil or type(rec.mute) ~= "table" then return false end
    local m = rec.mute
    if m["until"] and m["until"] <= util.now() then
        rec.mute = nil
        identity.mark()
        return false
    end
    return true, m
end

function M.warn(target, by, reason)
    local rec = identity.record(target.key, true)
    rec.warns = rec.warns or {}
    rec.warns[#rec.warns + 1] = {
        reason = util.clean(reason or "", 200), by = by and by.name or "console", at = util.now(),
    }
    while #rec.warns > M.MAX_WARNS do table.remove(rec.warns, 1) end
    identity.mark()
    return #rec.warns
end

function M.warns(key)
    local rec = identity.record(key)
    return rec and rec.warns or {}
end

function M.notice(player)
    local now = util.now()
    local last = last_notice[player.id]
    if last and now - last < M.NOTICE_S then return false end
    last_notice[player.id] = now
    return true
end

function M.forget(pid)
    last_notice[pid] = nil
end

-- the integration point for server issue #43
function M.install_veto(event_name)
    if type(event_name) ~= "string" or event_name == "" then return false end
    node.on(event_name, function(player)
        if type(player) ~= "table" then return end
        local muted, m = M.is_muted(identity.key(player))
        if muted then return false, m and m.reason or "muted" end
    end)
    return true
end

return M
