-- votekick: one vote at a time. Started by a player with votekick.start
-- against a connected target below votekick.immune_level; everyone else
-- connected votes yes or no within votekick.window_sec; yes votes reaching
-- threshold * eligible (and more than the no votes) kick the target. A
-- target and a starter are each on cooldown afterwards. All decisions are
-- taken here on the server; the panel and the chat only show and cast.
--
--   votekick.init()
--   votekick.start(actor, target_player, reason) -> vote | nil, err
--   votekick.cast(player, yes) -> ok, err
--   votekick.cancel(actor) -> ok, err
--   votekick.state() -> the public state table or nil
--   votekick.on(fn)                       fn(event, state) with event
--                                        "started" | "updated" | "passed" | "failed" | "cancelled"
--   votekick.tick()                       ends the vote when the window closed (node.every)
--   votekick.player_left(pid)

local identity = require("identity.identity")
local perms = require("perms.perms")
local settings = require("core.settings")
local util = require("core.util")

local M = {}

M.TICK_MS = 1000

local current = nil
local cooldown = {}     -- key -> ts until which the key may not be a target / starter
local listeners = {}
local timer = nil
local seq = 0

function M.init()
    current = nil
    cooldown = {}
    if timer then node.cancel(timer) end
    timer = node.every(M.TICK_MS, M.tick)
end

function M.on(fn)
    listeners[#listeners + 1] = fn
end

local function emit(event)
    local state = M.state()
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, event, state)
        if not ok then node.log("[warden] votekick listener failed: " .. tostring(err)) end
    end
end

local function eligible_count()
    local n = 0
    for _, p in ipairs(node.players.all()) do
        if current == nil or p.id ~= current.target.pid then n = n + 1 end
    end
    return n
end

function M.needed()
    if current == nil then return 0 end
    local threshold = tonumber(settings.get("votekick.threshold")) or 0.6
    return math.max(1, math.ceil(threshold * eligible_count()))
end

function M.state()
    if current == nil then return nil end
    local yes, no = 0, 0
    for _, v in pairs(current.votes) do
        if v then yes = yes + 1 else no = no + 1 end
    end
    return {
        id = current.id, target = { pid = current.target.pid, name = current.target.name },
        starter = { pid = current.starter.pid, name = current.starter.name }, reason = current.reason,
        yes = yes, no = no, needed = M.needed(), eligible = eligible_count(),
        ends_at = current.ends_at, seconds_left = math.max(0, current.ends_at - util.now()),
    }
end

local function finish(event)
    local vote = current
    current = nil
    local now = util.now()
    local cd = tonumber(settings.get("votekick.cooldown_sec")) or 0
    cooldown[vote.target.key] = now + cd
    cooldown[vote.starter.key] = now + cd
    current = vote      -- state() for the listeners still sees it
    emit(event)
    current = nil
    return vote
end

function M.start(actor, target, reason)
    if not settings.get("votekick.enabled") then return nil, "vote.disabled" end
    if current ~= nil then return nil, "vote.running" end
    if node.players.count() < (tonumber(settings.get("votekick.min_players")) or 4) then
        return nil, "vote.too_few", { min = settings.get("votekick.min_players") }
    end
    if target.id == actor.pid then return nil, "vote.self" end
    local tkey = identity.key(target)
    if perms.level_of(target) >= (tonumber(settings.get("votekick.immune_level")) or 50) then
        return nil, "vote.immune"
    end
    local now = util.now()
    if (cooldown[tkey] or 0) > now then return nil, "vote.cooldown", { sec = cooldown[tkey] - now } end
    if not actor.console and (cooldown[actor.key] or 0) > now then
        return nil, "vote.cooldown", { sec = cooldown[actor.key] - now }
    end
    seq = seq + 1
    current = {
        id = seq, started_at = now, ends_at = now + (tonumber(settings.get("votekick.window_sec")) or 60),
        target = { pid = target.id, key = tkey, name = target.name or ("Player" .. target.id), player = target },
        starter = { pid = actor.pid, key = actor.key, name = actor.name },
        reason = util.clean(reason or "", 120), votes = {},
    }
    if not actor.console then current.votes[actor.pid] = true end
    emit("started")
    M.resolve()
    return M.state()
end

function M.cast(player, yes)
    if current == nil then return nil, "vote.none" end
    if player.id == current.target.pid then return nil, "vote.target_cannot" end
    current.votes[player.id] = yes and true or false
    emit("updated")
    local counted = M.state()
    M.resolve()
    return true, counted
end

function M.cancel(actor)
    if current == nil then return nil, "vote.none" end
    finish("cancelled")
    if actor and not actor.console then
        -- a cancelled vote does not burn the starter's cooldown twice; the target's stays
        cooldown[actor.key] = nil
    end
    return true
end

-- passes when yes reached the needed count and beats no; fails when no can
-- no longer be beaten or the window closed
function M.resolve()
    if current == nil then return nil end
    local s = M.state()
    local needed = s.needed
    if s.yes >= needed and s.yes > s.no then
        local vote = finish("passed")
        local target = vote.target.player
        if target and type(target.kick) == "function" and target:isConnected() then
            target:kick("vote-kicked" .. (vote.reason ~= "" and (": " .. vote.reason) or ""))
        end
        return "passed"
    end
    local remaining = s.eligible - s.yes - s.no
    if s.yes + remaining < needed or util.now() >= current.ends_at then
        finish("failed")
        return "failed"
    end
    return nil
end

function M.tick()
    if current == nil then return end
    if not current.target.player or not current.target.player:isConnected() then
        finish("failed")
        return
    end
    M.resolve()
end

function M.player_left(pid)
    if current == nil then return end
    if pid == current.target.pid then
        finish("failed")
        return
    end
    current.votes[pid] = nil
    emit("updated")
    M.resolve()
end

function M.running()
    return current ~= nil
end

return M
