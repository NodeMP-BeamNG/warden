-- warden/bridge: the client end of the wd:req / wd:reply / wd:event protocol.
--
-- Runs inside the NodeMP client mod as a file the warden resource streams
-- (game-engine LuaJIT, Lua 5.1 semantics: no integer subtype, no //). `node`
-- is the client table (node.on / node.emitServer / node.log); jsonEncode,
-- jsonDecode and log are the game's. Every call is guarded: nothing here may
-- take the game down. No code ever arrives from the server -- only JSON
-- data.
--
--   bridge.request(op, data, cb) -> id     wd:req { id, op, data }; cb(ok, data | error)
--                                          error = { code, params }; no reply within TIMEOUT_S
--                                          answers { code = "timeout" }
--   bridge.on(name, fn) -> unsubscribe     "session" (the hello record), "event" (every wd:event),
--                                          and each ev by name: "players.changed", "groups.changed",
--                                          "settings.changed", "vote.state", "notice", "panel";
--                                          "outdated", "connected"
--   bridge.hello()                          sys.hello { protocol, uiVersion, lang }; retried while the
--                                          server has not answered (its join is still completing)
--   bridge.getState() -> { session, connected, hello, outdated, vote }
--   bridge.now() -> seconds since load     the panel's clock (onUpdate dt, summed)
--
-- The table returned has onUpdate / onExtensionLoaded / onExtensionUnloaded,
-- so the client mod registers it as a game extension and the per-frame
-- sweep runs (net/resources.lua: registerExtension -> newExtensionProxy).

local M = {}

M.VERSION = "0.1.0"
M.PROTOCOL = 1
M.TIMEOUT_S = 10
M.HELLO_RETRY_S = 2
M.HELLO_MAX_TRIES = 30
M.EVENTS = { req = "wd:req", reply = "wd:reply", event = "wd:event" }

local TAG = "warden"

local pending = {}      -- id -> { cb, op, at }
local next_id = 0
local listeners = {}    -- name -> { { fn, alive }, ... }
local state = { session = nil, connected = false, hello = false, outdated = false, vote = nil }
local now = 0
local sweep_at = 0
local hello = { pending = false, tries = 0, at = 0 }

local function say(level, msg)
    if log then
        pcall(log, level, TAG, msg)
    elseif node and node.log then
        pcall(node.log, "[" .. TAG .. "] " .. msg)
    end
end
M.say = say

local function encode(v)
    if type(jsonEncode) ~= "function" then return nil end
    local ok, text = pcall(jsonEncode, v)
    if ok then return text end
    return nil
end

local function decode(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" or raw == "" or type(jsonDecode) ~= "function" then return nil end
    local ok, v = pcall(jsonDecode, raw)
    if ok and type(v) == "table" then return v end
    return nil
end

-- listeners -----------------------------------------------------------------

function M.on(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return function() return false end end
    local list = listeners[name]
    if list == nil then
        list = {}
        listeners[name] = list
    end
    local entry = { fn = fn, alive = true }
    list[#list + 1] = entry
    return function()
        if not entry.alive then return false end
        entry.alive = false
        for i = #list, 1, -1 do
            if list[i] == entry then table.remove(list, i) end
        end
        return true
    end
end

function M.emit(name, ...)
    local list = listeners[name]
    if list == nil then return 0 end
    local snapshot = {}
    for i, entry in ipairs(list) do snapshot[i] = entry end
    local called = 0
    for _, entry in ipairs(snapshot) do
        if entry.alive then
            called = called + 1
            local ok, err = pcall(entry.fn, ...)
            if not ok then say("E", "listener for " .. name .. " failed: " .. tostring(err)) end
        end
    end
    return called
end

function M.getState()
    return state
end

function M.now()
    return now
end

-- requests ------------------------------------------------------------------

local function answer(id, ok, payload)
    local p = pending[id]
    if p == nil then return end
    pending[id] = nil
    if type(p.cb) == "function" then
        local okc, err = pcall(p.cb, ok, payload)
        if not okc then
            say("E", "callback of " .. tostring(p.op) .. " #" .. tostring(id) .. " failed: " .. tostring(err))
        end
    end
end

function M.request(op, data, cb)
    next_id = next_id + 1
    local id = next_id
    if type(data) ~= "table" then data = {} end
    pending[id] = { cb = cb, op = op, at = now }
    local text = encode({ id = id, op = op, data = data })
    if text == nil or not node or type(node.emitServer) ~= "function" then
        say("E", "cannot send " .. tostring(op) .. ": no JSON encoder or no node.emitServer")
        answer(id, false, { code = "offline" })
        return id
    end
    local ok, err = pcall(node.emitServer, M.EVENTS.req, text)
    if not ok then
        say("E", "emitServer failed for " .. tostring(op) .. ": " .. tostring(err))
        answer(id, false, { code = "offline" })
    end
    return id
end

function M.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

local function sweep()
    for id, p in pairs(pending) do
        if now - p.at >= M.TIMEOUT_S then
            say("W", tostring(p.op) .. " #" .. tostring(id) .. " timed out after " .. M.TIMEOUT_S .. " s")
            answer(id, false, { code = "timeout" })
        end
    end
end

-- hello ---------------------------------------------------------------------

local function game_lang()
    if type(settings) ~= "table" or type(settings.getValue) ~= "function" then return nil end
    local ok, value = pcall(settings.getValue, "uiLanguage")
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function on_session(data)
    state.session = data
    state.hello = true
    state.outdated = false
    state.connected = true
    state.vote = data.vote
    M.emit("session", data)
    M.emit("connected", true)
end

function M.hello()
    if hello.pending then return end
    hello.pending = true
    hello.tries = hello.tries + 1
    M.request("sys.hello", { protocol = M.PROTOCOL, uiVersion = M.VERSION, lang = game_lang() }, function(ok, payload)
        hello.pending = false
        if ok then
            hello.tries = 0
            on_session(payload)
            say("I", "hello: " .. tostring(payload and payload.me and payload.me.group) .. ", lang "
                .. tostring(payload and payload.lang))
            return
        end
        local code = type(payload) == "table" and payload.code or tostring(payload)
        if code == "ui_outdated" then
            state.outdated = true
            say("E", "the server refused protocol " .. M.PROTOCOL .. " (ui_outdated)")
            M.emit("outdated", payload)
            return
        end
        if code == "timeout" and hello.tries < M.HELLO_MAX_TRIES then
            -- the server has no warden, or the join is still completing: try again
            hello.at = now + M.HELLO_RETRY_S
            return
        end
        say("W", "hello refused: " .. code)
    end)
end

-- the wire ------------------------------------------------------------------

local function on_reply(raw)
    local msg = decode(raw)
    if msg == nil or msg.id == nil then return end
    if msg.ok == true then
        answer(msg.id, true, msg.data)
    else
        answer(msg.id, false, type(msg.error) == "table" and msg.error or { code = "internal" })
    end
end

local function on_event(raw)
    local msg = decode(raw)
    if msg == nil or type(msg.ev) ~= "string" then return end
    if msg.ev == "vote.state" then
        state.vote = type(msg.data) == "table" and msg.data.vote or nil
    end
    M.emit("event", msg)
    M.emit(msg.ev, msg.data)
end

local function subscribe()
    if not node or type(node.on) ~= "function" then
        say("E", "no client node table: the bridge is inert")
        return
    end
    node.on(M.EVENTS.reply, on_reply)
    node.on(M.EVENTS.event, on_event)
end

-- extension hooks -----------------------------------------------------------

function M.onUpdate(dt)
    now = now + (tonumber(dt) or 0)
    if hello.at > 0 and now >= hello.at then
        hello.at = 0
        M.hello()
    end
    if now >= sweep_at then
        sweep_at = now + 0.5
        sweep()
    end
end

function M.onExtensionLoaded()
    hello.at = now + 0.1
end

function M.onExtensionUnloaded()
    for id in pairs(pending) do answer(id, false, { code = "timeout" }) end
    state.connected = false
    state.hello = false
    M.emit("connected", false)
end

subscribe()
say("I", "bridge " .. M.VERSION .. " (protocol " .. M.PROTOCOL .. ") loaded")

return M
