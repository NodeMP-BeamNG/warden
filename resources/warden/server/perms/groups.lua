-- perms.groups: the groups -- a level, the groups it inherits from, the
-- named permissions, the vehicle cap. data/groups.json is the hoster's file;
-- the defaults below are written on first start.
--
--   groups.init()
--   groups.get(name) -> group | nil           { name, level, inherits, perms, caps = { vehicles } }
--   groups.all() -> array sorted by level
--   groups.effective_perms(name) -> set        perms of the group and everything it inherits
--   groups.allows(name, perm) -> bool          "*" grants everything; "mod.*" a prefix
--   groups.level(name) -> number               0 for an unknown group
--   groups.cap(name, what) -> number           -1 = unlimited; inherited when the group has none
--   groups.save(def) -> ok, err                create or replace (validated)
--   groups.remove(name) -> ok, err             not the built-in default / owner
--   groups.on_change(fn)

local store = require("core.store")
local util = require("core.util")

local M = {}

M.NAME_PATTERN = "^[a-z][a-z0-9_%-]{1,23}$"
M.PERM_PATTERN = "^[a-z][a-z0-9_]*%.[a-z0-9_%.]+$"
M.PROTECTED = { default = true, owner = true }
M.MAX_GROUPS = 64

-- the permissions warden itself checks, with the group that has them by default
M.PERMISSIONS = {
    { "players.view", "See the player list with groups and levels" },
    { "mod.kick", "Kick a player" },
    { "mod.ban", "Ban a player for good, lift bans" },
    { "mod.tempban", "Ban a player for a while" },
    { "mod.mute", "Mute and unmute" },
    { "mod.warn", "Warn a player (written to the record)" },
    { "mod.whitelist", "Edit the whitelist" },
    { "car.delete", "Delete another player's vehicles" },
    { "car.cap.bypass", "No vehicle cap" },
    { "perms.set", "Put a player in a group (below your own level)" },
    { "perms.manage", "Edit the groups" },
    { "settings.read", "Read the runtime settings" },
    { "settings.write", "Change the runtime settings" },
    { "audit.view", "Read the audit log" },
    { "votekick.start", "Start a vote-kick" },
    { "votekick.vote", "Vote" },
    { "votekick.cancel", "Cancel a running vote" },
    { "server.announce", "Say a line to everyone" },
    { "server.reload", "Reload the resource" },
}

function M.defaults()
    return {
        default = { level = 0, inherits = {}, perms = { "votekick.vote" }, caps = { vehicles = 1 } },
        trusted = { level = 10, inherits = { "default" }, perms = { "votekick.start" }, caps = { vehicles = 3 } },
        mod = { level = 50, inherits = { "trusted" },
            perms = { "players.view", "mod.kick", "mod.tempban", "mod.mute", "mod.warn", "car.delete",
                "audit.view", "votekick.cancel" },
            caps = { vehicles = 5 } },
        admin = { level = 90, inherits = { "mod" },
            perms = { "mod.ban", "mod.whitelist", "perms.set", "settings.read", "settings.write",
                "server.announce", "car.cap.bypass" },
            caps = { vehicles = -1 } },
        owner = { level = 100, inherits = { "admin" }, perms = { "*" }, caps = { vehicles = -1 } },
    }
end

local file = nil
local listeners = {}
local cache = {}   -- name -> effective perm set

local function invalidate()
    cache = {}
    for _, fn in ipairs(listeners) do pcall(fn) end
end

function M.init()
    file = store.open("groups", M.defaults)
    -- a groups.json missing the two anchors gets them back
    local d = M.defaults()
    for _, name in ipairs({ "default", "owner" }) do
        if type(file.data[name]) ~= "table" then
            file.data[name] = d[name]
            file:mark()
        end
    end
    file:on_reload(invalidate)
    invalidate()
end

function M.on_change(fn)
    listeners[#listeners + 1] = fn
end

function M.exists(name)
    return type(name) == "string" and type(file.data[name]) == "table"
end

function M.get(name)
    local g = file.data[name]
    if type(g) ~= "table" then return nil end
    return {
        name = name, level = tonumber(g.level) or 0, inherits = util.copy(g.inherits or {}),
        perms = util.copy(g.perms or {}), caps = util.copy(g.caps or {}),
    }
end

function M.all()
    local out = {}
    for name in pairs(file.data) do out[#out + 1] = M.get(name) end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return a.name < b.name
    end)
    return out
end

function M.level(name)
    local g = file.data[name]
    if type(g) ~= "table" then return 0 end
    return tonumber(g.level) or 0
end

local function collect(name, seen, set)
    if seen[name] then return end
    seen[name] = true
    local g = file.data[name]
    if type(g) ~= "table" then return end
    for _, p in ipairs(g.perms or {}) do set[p] = true end
    for _, parent in ipairs(g.inherits or {}) do collect(parent, seen, set) end
end

function M.effective_perms(name)
    if cache[name] then return cache[name] end
    local set = {}
    collect(name, {}, set)
    cache[name] = set
    return set
end

function M.allows(name, perm)
    local set = M.effective_perms(name)
    if set["*"] then return true end
    if set[perm] then return true end
    -- "mod.*" covers "mod.kick"
    local prefix = perm:match("^(.-)%.[^%.]+$")
    while prefix do
        if set[prefix .. ".*"] then return true end
        prefix = prefix:match("^(.-)%.[^%.]+$")
    end
    return false
end

-- the cap of the group, else the first inherited group that has one, else 1
function M.cap(name, what)
    what = what or "vehicles"
    local seen = {}
    local function look(n)
        if seen[n] then return nil end
        seen[n] = true
        local g = file.data[n]
        if type(g) ~= "table" then return nil end
        if type(g.caps) == "table" and g.caps[what] ~= nil then
            return math.tointeger(tonumber(g.caps[what])) or -1
        end
        for _, parent in ipairs(g.inherits or {}) do
            local v = look(parent)
            if v ~= nil then return v end
        end
        return nil
    end
    local v = look(name)
    if v == nil then return 1 end
    return v
end

-- would `name` inheriting `parents` loop back to itself?
local function cycles(name, parents)
    local seen = { [name] = true }
    local stack = {}
    for _, p in ipairs(parents) do stack[#stack + 1] = p end
    while #stack > 0 do
        local n = table.remove(stack)
        if n == name then return true end
        if not seen[n] then
            seen[n] = true
            local g = file.data[n]
            for _, p in ipairs(type(g) == "table" and g.inherits or {}) do stack[#stack + 1] = p end
        end
    end
    return false
end

-- validates and stores { name, level, inherits, perms, caps }
function M.save(def)
    if type(def) ~= "table" then return nil, "bad_group" end
    local name = def.name
    if type(name) ~= "string" or not name:match("^[a-z][a-z0-9_%-]*$") or #name > 24 then return nil, "bad_name" end
    if not M.exists(name) and util.count(file.data) >= M.MAX_GROUPS then return nil, "too_many" end
    local level = math.tointeger(tonumber(def.level))
    if level == nil or level < 0 or level > 1000 then return nil, "bad_level" end
    local inherits = {}
    for _, p in ipairs(type(def.inherits) == "table" and def.inherits or {}) do
        if type(p) ~= "string" or not M.exists(p) then return nil, "unknown_parent" end
        if p ~= name then inherits[#inherits + 1] = p end
    end
    if cycles(name, inherits) then return nil, "cycle" end
    local perms = {}
    for _, p in ipairs(type(def.perms) == "table" and def.perms or {}) do
        if type(p) ~= "string" or (p ~= "*" and not p:match("^[a-z][a-z0-9_]*[%.%*a-z0-9_]*$")) or #p > 64 then
            return nil, "bad_perm"
        end
        perms[#perms + 1] = p
    end
    local caps = {}
    if type(def.caps) == "table" then
        for k, v in pairs(def.caps) do
            local n = math.tointeger(tonumber(v))
            if type(k) ~= "string" or n == nil or n < -1 or n > 1000 then return nil, "bad_cap" end
            caps[k] = n
        end
    end
    if name == "owner" and not util.contains(perms, "*") then perms[#perms + 1] = "*" end
    file.data[name] = { level = level, inherits = inherits, perms = perms, caps = caps }
    file:mark()
    invalidate()
    return M.get(name)
end

function M.remove(name)
    if M.PROTECTED[name] then return nil, "protected" end
    if not M.exists(name) then return nil, "unknown_group" end
    for other, g in pairs(file.data) do
        if other ~= name and util.contains(g.inherits or {}, name) then return nil, "in_use" end
    end
    file.data[name] = nil
    file:mark()
    invalidate()
    return true
end

return M
