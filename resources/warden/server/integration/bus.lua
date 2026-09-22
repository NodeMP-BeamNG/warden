-- integration.bus: how another resource reads warden without importing it,
-- over node.bus (JSON payloads).
--
--   ask                              answered with
--   warden:getGroup  { pid | key, tag? }   warden:group  { pid?, key, group, level, perms, tag? }
--   warden:hasPerm   { pid | key, perm, tag? }   warden:perm   { pid?, key, perm, ok, tag? }
--
--   published
--   warden:ready         { version }
--   warden:groupChanged  { key, group, pid? }        a player moved to a group
--   warden:groupsChanged {}                          the group definitions changed
--
-- The tag is echoed so a caller with several questions in flight can match
-- the answers. A pid must be connected; a key ("acct:12", "ip:...") need not.

local groups = require("perms.groups")
local identity = require("identity.identity")
local perms = require("perms.perms")
local util = require("core.util")

local M = {}

local function subject(d)
    if d.pid ~= nil then
        local p = node.players.get(math.tointeger(tonumber(d.pid)) or -1)
        if p == nil or not p:isConnected() then return nil end
        return identity.key(p), perms.group_of(p), p.id
    end
    if type(d.key) == "string" then
        return d.key, perms.group_of_key(d.key), nil
    end
    return nil
end

local function perms_list(group)
    local out = {}
    for p in pairs(groups.effective_perms(group)) do out[#out + 1] = p end
    table.sort(out)
    return out
end

function M.init(version)
    node.bus.on("warden:getGroup", function(_, data)
        local d = util.decode(data)
        if d == nil then return end
        local key, group, pid = subject(d)
        if key == nil then
            node.bus.emit("warden:group", { error = "unknown", tag = d.tag })
            return
        end
        node.bus.emit("warden:group", {
            pid = pid, key = key, group = group, level = groups.level(group), perms = perms_list(group), tag = d.tag,
        })
    end)
    node.bus.on("warden:hasPerm", function(_, data)
        local d = util.decode(data)
        if d == nil or type(d.perm) ~= "string" then return end
        local key, group, pid = subject(d)
        if key == nil then
            node.bus.emit("warden:perm", { error = "unknown", perm = d.perm, tag = d.tag })
            return
        end
        node.bus.emit("warden:perm", {
            pid = pid, key = key, perm = d.perm, ok = groups.allows(group, d.perm), tag = d.tag,
        })
    end)
    perms.on_change(function(key, group, pid)
        node.bus.emit("warden:groupChanged", { key = key, group = group, pid = pid })
    end)
    groups.on_change(function() node.bus.emit("warden:groupsChanged", {}) end)
    node.bus.emit("warden:ready", { version = version })
end

return M
