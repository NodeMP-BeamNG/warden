-- ui.protocol: the wd:req / wd:reply envelope the warden-ui client half
-- speaks, and wd:event for what the server pushes.
--
--   client -> server  wd:req    { id = <int>, op = "<domain>.<verb>", data = {...} }
--   server -> client  wd:reply  { id, ok = true, data } | { id, ok = false, error = { code, params } }
--   server -> client  wd:event  { ev = "players.changed" | "groups.changed" | "vote.state" | "notice"
--                                | "settings.changed", data }
--
-- Order of checks on a frame: the limiter (junk counts), the envelope (id an
-- integer, op a string), the op is known (ui.ops), then commands.registry.run
-- does permission, target, rank, shape and audit. A frame that fails before
-- the registry is answered when it has an id.
--
--   protocol.init(cfg)
--   protocol.handle(player, raw) -> reply       the whole path, for the tests
--   protocol.send_event(player_or_pid, ev, data)
--   protocol.PROTOCOL                           bumped on an incompatible change

local limiter = require("core.limiter")
local ops = require("ui.ops")
local perms = require("perms.perms")
local util = require("core.util")

local M = {}

M.PROTOCOL = 1
M.EVENTS = { req = "wd:req", reply = "wd:reply", event = "wd:event" }
M.MAX_FRAME = 16 * 1024

local lim = nil
local strikes = {}   -- pid -> over-limit count (a warning line once, then silence)

local function reply(player, id, result)
    local msg = { id = id, ok = result.ok }
    if result.ok then msg.data = result.data else msg.error = result.error end
    if type(player.send) == "function" then
        player:send(M.EVENTS.reply, msg)
    else
        node.send(player.id or player, M.EVENTS.reply, msg)
    end
    return msg
end

function M.send_event(target, ev, data)
    local msg = { ev = ev, data = data }
    if type(target) == "table" and type(target.send) == "function" then return target:send(M.EVENTS.event, msg) end
    return node.send(target, M.EVENTS.event, msg)
end

function M.broadcast_event(ev, data)
    return node.broadcast(M.EVENTS.event, { ev = ev, data = data })
end

function M.handle(player, raw)
    local ok, retry = lim:allow(player.id, util.now())
    if not ok then
        strikes[player.id] = (strikes[player.id] or 0) + 1
        if strikes[player.id] == 1 then
            node.log("[warden] wd:req from #" .. tostring(player.id) .. " over the limit; ignoring for "
                .. retry .. " s")
        end
        return nil
    end
    if type(raw) == "string" and #raw > M.MAX_FRAME then return nil end
    local msg = util.decode(raw)
    if msg == nil then return nil end
    local id = math.tointeger(tonumber(msg.id))
    if id == nil then return nil end
    if type(msg.op) ~= "string" then
        return reply(player, id, { ok = false, error = { code = "bad_op" } })
    end
    local actor = perms.actor(player)
    local result = ops.run(actor, msg.op, type(msg.data) == "table" and msg.data or {})
    return reply(player, id, result)
end

function M.forget(pid)
    strikes[pid] = nil
    if lim then lim:forget(pid) end
end

function M.init(cfg)
    lim = limiter.new({ { n = cfg.limits.ui_per_sec, window = 1 }, { n = cfg.limits.ui_per_min, window = 60 } })
    strikes = {}
    node.on(M.EVENTS.req, function(player, raw) M.handle(player, raw) end)
end

return M
