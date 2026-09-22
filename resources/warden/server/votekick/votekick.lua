-- votekick: one vote at a time. Started by a player with votekick.start
-- against a connected target below votekick.immune_level; everyone else
-- connected votes yes or no within votekick.window_sec; yes votes reaching
-- threshold * eligible (and more than the no votes) kick the target. A
-- target and a starter are each on cooldown afterwards. All decisions are
-- taken here on the server; the panel and the chat only show and cast.
--
-- Off by default (the spec): votekick.enabled = true turns it on.
--
-- Votes weigh by identity (identity.key): two guests from one address are
-- one voter, one vote, one head in the count; the players needed to hold a
-- vote (min_players) are counted the same way. The cooldowns live in
-- data/votekick.json so a restart or a /reload does not reset them.
--
--   votekick.init()
--   votekick.start(actor, target_player, reason) -> vote | nil, err
--   votekick.cast(player, yes) -> ok, err
--   votekick.cancel(actor) -> ok, err
--   votekick.state() -> the public state table or nil
--   votekick.on(fn)                       fn(event, state) with event
--                                        "started" | "updated" | "passed" | "failed" | "cancelled"
--   votekick.tick()                       ends the vote when the window closed (node.every)
--   votekick.player_left(player)          a voter or the target left (a pid is accepted)
--   votekick.cooldown_left(key) -> seconds

local identity = require("identity.identity")
local perms = require("perms.perms")
local settings = require("core.settings")
local store = require("core.store")
local util = require("core.util")

local M = {}

M.TICK_MS = 1000

local current = nil
local file = nil        -- data/votekick.json: { cooldown = { key -> ts until } }
local listeners = {}
local timer = nil
local seq = 0

local function cooldowns()
    if type(file.data.cooldown) ~= "table" then
        file.data.cooldown = {}
        file:mark()
    end
    return file.data.cooldown
end

local function prune_cooldowns()
    local now = util.now()
    local cd = cooldowns()
    local changed = false
    for key, ts in pairs(cd) do
        if type(ts) ~= "number" or ts <= now then
            cd[key] = nil
            changed = true
        end
    end
    if changed then file:mark() end
end

function M.init()
    current = nil
    file = store.open("votekick", function() return { cooldown = {} } end)
    prune_cooldowns()
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

-- the distinct identities connected, less the target's
local function eligible()
    local set, n = {}, 0
    for _, p in ipairs(node.players.all()) do
        local k = identity.key(p)
        if (current == nil or k ~= current.target.key) and not set[k] then
            set[k] = true
            n = n + 1
        end
    end
    return n, set
end

local function identities_connected()
    local set, n = {}, 0
    for _, p in ipairs(node.players.all()) do
        local k = identity.key(p)
        if not set[k] then
            set[k] = true
            n = n + 1
        end
    end
    return n
end

function M.needed()
    if current == nil then return 0 end
    local threshold = tonumber(settings.get("votekick.threshold")) or 0.6
    return math.max(1, math.ceil(threshold * (eligible())))
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
        yes = yes, no = no, needed = M.needed(), eligible = (eligible()),
        ends_at = current.ends_at, seconds_left = math.max(0, current.ends_at - util.now()),
    }
end

function M.cooldown_left(key)
    local ts = cooldowns()[key]
    if type(ts) ~= "number" then return 0 end
    return math.max(0, ts - util.now())
end

local function finish(event)
    local vote = current
    current = nil
    local now = util.now()
    local cd = tonumber(settings.get("votekick.cooldown_sec")) or 0
    local table_ = cooldowns()
    if cd > 0 then
        table_[vote.target.key] = now + cd
        if vote.starter.key ~= "console" then table_[vote.starter.key] = now + cd end
        file:mark()
    end
    current = vote      -- state() for the listeners still sees it
    emit(event)
    current = nil
    return vote
end

local function immune(target)
    return perms.level_of(target) >= (tonumber(settings.get("votekick.immune_level")) or 50)
end

function M.start(actor, target, reason)
    if not settings.get("votekick.enabled") then return nil, "vote.disabled" end
    if current ~= nil then return nil, "vote.running" end
    local min = tonumber(settings.get("votekick.min_players")) or 4
    if identities_connected() < min then return nil, "vote.too_few", { min = min } end
    if target.id == actor.pid then return nil, "vote.self" end
    local tkey = identity.key(target)
    if not actor.console and tkey == actor.key then return nil, "vote.self" end
    if immune(target) then return nil, "vote.immune" end
    prune_cooldowns()
    local left = M.cooldown_left(tkey)
    if left > 0 then return nil, "vote.cooldown", { sec = left } end
    if not actor.console then
        left = M.cooldown_left(actor.key)
        if left > 0 then return nil, "vote.cooldown", { sec = left } end
    end
    local now = util.now()
    seq = seq + 1
    current = {
        id = seq, started_at = now, ends_at = now + (tonumber(settings.get("votekick.window_sec")) or 60),
        target = { pid = target.id, key = tkey, name = target.name or ("Player" .. target.id), player = target },
        starter = { pid = actor.pid, key = actor.key, name = actor.name },
        reason = util.clean(reason or "", 120), votes = {},
    }
    if not actor.console then current.votes[actor.key] = true end
    emit("started")
    M.resolve()
    return M.state()
end

function M.cast(player, yes)
    if current == nil then return nil, "vote.none" end
    local key = identity.key(player)
    if player.id == current.target.pid or key == current.target.key then return nil, "vote.target_cannot" end
    current.votes[key] = yes and true or false
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
        cooldowns()[actor.key] = nil
        file:mark()
    end
    return true
end

-- passes when yes reached the needed count and beats no; fails when no can
-- no longer be beaten or the window closed. A target who became immune
-- while the vote ran (put in a group at immune_level) is not kicked.
function M.resolve()
    if current == nil then return nil end
    local s = M.state()
    local needed = s.needed
    if s.yes >= needed and s.yes > s.no then
        local target = current.target.player
        if target and target:isConnected() and immune(target) then
            finish("failed")
            return "failed"
        end
        local vote = finish("passed")
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

-- a player left: the target ends the vote; a voter's vote goes with them
-- unless another connected player shares their identity
function M.player_left(player)
    if current == nil then return end
    local pid = type(player) == "table" and player.id or player
    if pid == current.target.pid then
        finish("failed")
        return
    end
    if type(player) == "table" then
        local key = identity.key(player)
        local shared = false
        for _, p in ipairs(node.players.all()) do
            if p.id ~= pid and identity.key(p) == key then shared = true end
        end
        if not shared then current.votes[key] = nil end
    end
    emit("updated")
    M.resolve()
end

function M.running()
    return current ~= nil
end

return M
