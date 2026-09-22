-- A stand-in for the server's `node` table under plain Lua 5.4. Only what
-- warden touches: config, log, timers on a virtual clock (node._advance),
-- events (node.on / node._emit), sends (node._sent), json, an in-memory fs
-- over the real lang/ folder, players (node._join / node._leave build fake
-- Player objects with kick/ban/tell/send/vehicles/setRole), vehicles,
-- bans (node._bans), the bus (node._bus), server, resources.
--
-- Everything recorded lives under underscore names so a test can assert on
-- it; node._reset() returns the stub to its initial state.

local json = require("json")

local sep = package.config:sub(1, 1)
local RESOURCE_DIR = table.concat({ WD_ROOT or ".", "resources", "warden" }, sep)

local node = {}

local function fmt(msg, ...)
    if select("#", ...) > 0 then return string.format(tostring(msg), ...) end
    return tostring(msg)
end

-- log -----------------------------------------------------------------------

local log = {}
local function record(level, text)
    node._log[#node._log + 1] = { level = level, text = text }
    if node._echo then print(string.format("[stub:%s] %s", level, text)) end
end
setmetatable(log, { __call = function(_, msg, ...) record("info", fmt(msg, ...)) end })
log.warn = function(msg, ...) record("warn", fmt(msg, ...)) end
log.error = function(msg, ...) record("error", fmt(msg, ...)) end
node.log = log

function node._log_text(level)
    local parts = {}
    for _, l in ipairs(node._log) do
        if level == nil or l.level == level then parts[#parts + 1] = l.text end
    end
    return table.concat(parts, "\n")
end

-- timers (virtual clock, ms) ---------------------------------------------------

local next_timer = 0

local function add_timer(ms, fn, repeating)
    if type(ms) ~= "number" then error("timer: ms must be a number", 2) end
    if type(fn) ~= "function" then error("timer: fn must be a function", 2) end
    next_timer = next_timer + 1
    node._timers[next_timer] = { id = next_timer, ms = ms, fn = fn, due = node._now_ms + ms, every = repeating }
    return next_timer
end

node.after = function(ms, fn) return add_timer(ms, fn, false) end
node.every = function(ms, fn) return add_timer(ms, fn, true) end
node.cancel = function(id) node._timers[id] = nil end

function node._timer_count()
    local n = 0
    for _ in pairs(node._timers) do n = n + 1 end
    return n
end

-- advances the clock by ms, firing due timers in order (once per due mark)
function node._advance(ms)
    local target = node._now_ms + (ms or 0)
    while true do
        local soonest = nil
        for _, tm in pairs(node._timers) do
            if tm.due <= target and (soonest == nil or tm.due < soonest.due or
                (tm.due == soonest.due and tm.id < soonest.id)) then
                soonest = tm
            end
        end
        if soonest == nil then break end
        node._now_ms = soonest.due
        if soonest.every then soonest.due = soonest.due + soonest.ms else node._timers[soonest.id] = nil end
        local ok, err = pcall(soonest.fn)
        if not ok then record("error", "error in timer: " .. tostring(err)) end
    end
    node._now_ms = target
end

-- events --------------------------------------------------------------------------

node.on = function(name, fn)
    if type(name) ~= "string" or name == "" then error("node.on: event name must be a string", 2) end
    if type(fn) ~= "function" then error("node.on: handler must be a function", 2) end
    node._handlers[name] = node._handlers[name] or {}
    local list = node._handlers[name]
    for i, h in ipairs(list) do
        if h == fn then table.remove(list, i) break end
    end
    list[#list + 1] = fn
end

node.off = function(name, fn)
    local list = node._handlers[name]
    if not list then return 0 end
    if fn == nil then
        node._handlers[name] = nil
        return #list
    end
    for i, h in ipairs(list) do
        if h == fn then table.remove(list, i) return 1 end
    end
    return 0
end

-- every handler of name; returns the first `false, reason` (one veto denies) or true
function node._emit(name, ...)
    local denied, reason = false, nil
    for _, fn in ipairs({ table.unpack(node._handlers[name] or {}) }) do
        local ok, verdict, why = pcall(fn, ...)
        if not ok then
            record("error", "error in event '" .. name .. "': " .. tostring(verdict))
        elseif verdict == false and not denied then
            denied, reason = true, why
        end
    end
    if denied then return false, reason end
    return true
end

function node._handler_count(name)
    return #(node._handlers[name] or {})
end

-- sending -------------------------------------------------------------------------

local function payload(data)
    if data == nil then return "" end
    if type(data) == "table" then return json.encode(data) end
    return tostring(data)
end

node.send = function(target, event, data)
    local id = type(target) == "table" and target.id or target
    local p = node._players[id]
    node._sent[#node._sent + 1] = { to = id, event = event, data = payload(data) }
    return p ~= nil
end

node.broadcast = function(event, data, except)
    local ex = type(except) == "table" and except.id or except
    node._sent[#node._sent + 1] = { to = "all", event = event, data = payload(data), except = ex }
    return true
end

-- the decoded payloads of `event` sent to `to` ("all" or a pid; nil = any)
function node._sent_of(event, to)
    local out = {}
    for _, s in ipairs(node._sent) do
        if s.event == event and (to == nil or s.to == to) then
            local ok, v = pcall(json.decode, s.data)
            out[#out + 1] = ok and v or s.data
        end
    end
    return out
end

-- json / fs -----------------------------------------------------------------------

node.json = {
    encode = function(v, opts) return json.encode(v, opts) end,
    decode = function(text)
        local ok, v = pcall(json.decode, text)
        if ok then return v end
        return nil
    end,
}

local function outside(path)
    path = tostring(path)
    return path:find("%.%.") or path:match("^[/\\]") or path:match("^%a:")
end

local function real(path)
    return RESOURCE_DIR .. sep .. tostring(path):gsub("/", sep)
end

node.fs = {}
node.fs.read = function(path)
    if outside(path) then return nil end
    if node._files[path] ~= nil then return node._files[path] end
    local f = io.open(real(path), "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end
node.fs.write = function(path, data)
    if outside(path) then return false end
    node._files[path] = data
    node._writes[#node._writes + 1] = path
    return true
end
node.fs.exists = function(path)
    if outside(path) then return nil, "outside" end
    if node._files[path] ~= nil then return "file" end
    local f = io.open(real(path), "rb")
    if f then
        f:close()
        return "file"
    end
    return nil
end
node.fs.rename = function(from, to)
    if node._files[from] == nil then return false, "not found" end
    node._files[to] = node._files[from]
    node._files[from] = nil
    return true
end
node.fs.copy = function(from, to)
    local data = node.fs.read(from)
    if data == nil then return false end
    node._files[to] = data
    return true
end
node.fs.remove = function(path)
    if node._files[path] == nil then return false, "not found" end
    node._files[path] = nil
    return true
end
node.fs.mkdir = function() return true end
node.fs.list = function(path)
    local out = {}
    local prefix = (path or "") .. "/"
    for name, data in pairs(node._files) do
        if name:sub(1, #prefix) == prefix and not name:sub(#prefix + 1):find("/") then
            out[#out + 1] = { name = name:sub(#prefix + 1), dir = false, size = #data }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    if #out == 0 then return nil end
    return out
end
node.fs.watch = function(path, fn)
    node._watches[#node._watches + 1] = { path = path, fn = fn }
    return #node._watches
end
node.fs.unwatch = function(id) node._watches[id] = nil end

-- a "changed" for every watcher of path (a hoster edited the file)
function node._touch(path)
    for _, w in pairs(node._watches) do
        if w.path == path then w.fn(path, "changed") end
    end
end

-- players -------------------------------------------------------------------------

local Player = {}
Player.__index = Player

function Player.isConnected(self) return node._players[self.id] == self end
function Player.kick(self, reason)
    node._kicked[#node._kicked + 1] = { id = self.id, name = self.name, reason = reason }
    node._leave(self.id)
    return true
end
function Player.ban(self, reason)
    if self.accountId ~= nil then node._bans[tostring(self.accountId)] = { reason = reason, account = self.accountId } end
    node._bans[self.ip] = { reason = reason, ip = self.ip }
    node._banned[#node._banned + 1] = { id = self.id, name = self.name, reason = reason }
    node._leave(self.id)
    return true
end
function Player.tell(self, text, ...)
    if select("#", ...) > 0 then text = string.format(text, ...) end
    node._told[#node._told + 1] = { id = self.id, text = text }
end
function Player.send(self, event, data) return node.send(self.id, event, data) end
function Player.setRole(self, role) self.role = role return true end
function Player.vehicles(self)
    local out = {}
    for gid, v in pairs(node._vehicles) do
        if v.spawnerId == self.id then out[#out + 1] = node.vehicles.get(gid) end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- node._join(id, { name, ip, accountId, guest, verified, accountRoles, vehicleCount })
function node._join(id, fields)
    fields = fields or {}
    local p = setmetatable({
        id = id, name = fields.name or ("Player" .. id), ip = fields.ip or ("10.0.0." .. id),
        accountId = fields.accountId, guest = fields.guest, verified = fields.verified,
        accountRoles = fields.accountRoles or "", vehicleCount = fields.vehicleCount or 0,
        pingSeconds = 0.1, connectedSeconds = 1, role = "",
    }, Player)
    if p.guest == nil then p.guest = p.accountId == nil end
    if p.verified == nil then p.verified = p.accountId ~= nil end
    node._players[id] = p
    return p
end

function node._leave(id)
    node._players[id] = nil
end

-- what a player was told, as one string per line (nil = everyone)
function node._told_text(id)
    local parts = {}
    for _, m in ipairs(node._told) do
        if id == nil or m.id == id then parts[#parts + 1] = m.text end
    end
    return table.concat(parts, "\n")
end

node.players = {
    get = function(id)
        if type(id) ~= "number" or id < 0 then return nil end
        return node._players[id] or setmetatable({ id = id }, Player)
    end,
    all = function()
        local out = {}
        for _, p in pairs(node._players) do out[#out + 1] = p end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    ids = function()
        local out = {}
        for _, p in ipairs(node.players.all()) do out[#out + 1] = p.id end
        return out
    end,
    count = function()
        local n = 0
        for _ in pairs(node._players) do n = n + 1 end
        return n
    end,
    find = function(name)
        for _, p in pairs(node._players) do
            if p.name and p.name:lower() == tostring(name):lower() then return p end
        end
        return nil
    end,
}

-- vehicles ------------------------------------------------------------------------

local Vehicle = {}
Vehicle.__index = function(self, key)
    local m = rawget(Vehicle, key)
    if m ~= nil then return m end
    local rec = node._vehicles[rawget(self, "id")]
    return rec and rec[key] or nil
end
function Vehicle.exists(self) return node._vehicles[self.id] ~= nil end
function Vehicle.delete(self)
    if node._vehicles[self.id] == nil then return false end
    local spawner = node._players[node._vehicles[self.id].spawnerId]
    node._vehicles[self.id] = nil
    if spawner then spawner.vehicleCount = math.max(0, (spawner.vehicleCount or 1) - 1) end
    return true
end

function node._vehicle(gid, spawnerId)
    node._vehicles[gid] = { id = gid, spawnerId = spawnerId }
    local p = node._players[spawnerId]
    if p then p.vehicleCount = (p.vehicleCount or 0) + 1 end
    return node._vehicles[gid]
end

node.vehicles = {
    get = function(id)
        if type(id) ~= "number" or id < 0 then return nil end
        return setmetatable({ id = id }, Vehicle)
    end,
    all = function()
        local out = {}
        for gid in pairs(node._vehicles) do out[#out + 1] = node.vehicles.get(gid) end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    count = function()
        local n = 0
        for _ in pairs(node._vehicles) do n = n + 1 end
        return n
    end,
}

-- bans (node._bans: who -> { reason }) -------------------------------------------------

node.bans = {
    add = function(who, reason)
        if type(who) == "table" then return who:ban(reason) end
        local key = tostring(who)
        node._bans[key] = { reason = reason, [type(who) == "number" and "account" or "ip"] = who }
        return true
    end,
    remove = function(who)
        local key = tostring(who)
        if node._bans[key] == nil then return false end
        node._bans[key] = nil
        return true
    end,
    has = function(who)
        if type(who) == "table" then
            return (who.accountId ~= nil and node._bans[tostring(who.accountId)] ~= nil) or node._bans[who.ip] ~= nil
        end
        return node._bans[tostring(who)] ~= nil
    end,
    all = function()
        local out = {}
        for _, b in pairs(node._bans) do
            out[#out + 1] = { ip = b.ip, account = b.account, reason = b.reason, at = 0, name = b.name }
        end
        return out
    end,
}

-- bus -----------------------------------------------------------------------------

node.bus = {
    emit = function(name, data)
        local text = payload(data)
        node._bus[#node._bus + 1] = { name = name, data = text }
        for _, fn in ipairs({ table.unpack(node._bus_handlers[name] or {}) }) do
            local ok, err = pcall(fn, "stub", text)
            if not ok then record("error", "error in bus handler '" .. tostring(name) .. "': " .. tostring(err)) end
        end
    end,
    on = function(name, fn)
        if type(name) ~= "string" or name == "" then error("node.bus.on: name must be a string", 2) end
        if type(fn) ~= "function" then error("node.bus.on: handler must be a function", 2) end
        node._bus_handlers[name] = node._bus_handlers[name] or {}
        table.insert(node._bus_handlers[name], fn)
    end,
    off = function(name, fn)
        local list = node._bus_handlers[name]
        if not list then return 0 end
        if fn == nil then
            node._bus_handlers[name] = nil
            return #list
        end
        for i, h in ipairs(list) do
            if h == fn then table.remove(list, i) return 1 end
        end
        return 0
    end,
}

-- the decoded payloads emitted under name
function node._bus_of(name)
    local out = {}
    for _, m in ipairs(node._bus) do
        if m.name == name then
            local ok, v = pcall(json.decode, m.data)
            out[#out + 1] = ok and v or m.data
        end
    end
    return out
end

-- server / resources ------------------------------------------------------------------

node.server = {
    unixTime = function() return node._unix + node._now_ms // 1000 end,
    time = function() return node._unix + node._now_ms / 1000 end,
    uptime = function() return node._now_ms / 1000 end,
    name = function() return "stub" end,
    version = function() return "1.4.1" end,
    maxPlayers = function() return 16 end,
    maxCars = function() return 4 end,
}

node.resources = {
    manifest = function() return { name = "warden", version = "0.0.0-test", config = node.config } end,
    reload = function(name)
        node._reloads[#node._reloads + 1] = tostring(name)
        return true
    end,
}

-- ---------------------------------------------------------------------------

function node._reset()
    node.config = {}
    node._log = {}
    node._echo = false
    node._timers = {}
    node._now_ms = 0
    node._unix = 1700000000
    node._handlers = {}
    node._sent = {}
    node._told = {}
    node._kicked = {}
    node._banned = {}
    node._bus = {}
    node._bus_handlers = {}
    node._files = {}
    node._writes = {}
    node._watches = {}
    node._players = {}
    node._vehicles = {}
    node._bans = {}
    node._reloads = {}
end

node._reset()

return node
