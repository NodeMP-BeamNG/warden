-- ui.push: what the server tells the panels without being asked.
--
--   players.changed  { players }     to the subscribers (players.view), coalesced to one per PLAYERS_MS
--   groups.changed   { groups }      to the subscribers, after a group edit
--   settings.changed { key, value }  to the subscribers with settings.read
--   vote.state       { event, vote } to everyone (the wdVote banner)
--   notice           { text, code, params }  to one player (what say.tell said)
--
--   push.init()                       wires the sources (perms, groups, votekick, say, registry)
--   push.subscribe(pid) / unsubscribe(pid) / hello(pid)
--   push.players() / push.groups() / push.settings(key, value)
--   push.snapshot() -> the players array
--   push.player_left(pid)

local builtin = require("commands.builtin")
local groups = require("perms.groups")
local perms = require("perms.perms")
local registry = require("commands.registry")
local say = require("core.say")
local settings = require("core.settings")
local votekick = require("votekick.votekick")

local M = {}

M.PLAYERS_MS = 1000
M.EVENT = "wd:event"

local subscribers = {}   -- pid -> true
local hellos = {}        -- pid -> true (has a panel; receives notices)
local players_timer = nil

local function send(pid, ev, data)
    node.send(pid, M.EVENT, { ev = ev, data = data })
end

function M.snapshot()
    local out = {}
    for _, p in ipairs(node.players.all()) do out[#out + 1] = builtin.player_row(p, false) end
    return out
end

function M.subscribe(pid)
    subscribers[pid] = true
end

function M.unsubscribe(pid)
    subscribers[pid] = nil
end

function M.hello(pid)
    hellos[pid] = true
end

function M.has_panel(pid)
    return hellos[pid] == true
end

function M.player_left(pid)
    subscribers[pid] = nil
    hellos[pid] = nil
end

local function each_subscriber(fn)
    for pid in pairs(subscribers) do
        local p = node.players.get(pid)
        if p and p:isConnected() and perms.has(p, "players.view") then
            fn(pid, p)
        else
            subscribers[pid] = nil
        end
    end
end

function M.players()
    if next(subscribers) == nil then return end
    if players_timer ~= nil then return end
    players_timer = node.after(M.PLAYERS_MS, function()
        players_timer = nil
        local snap = M.snapshot()
        each_subscriber(function(pid) send(pid, "players.changed", { players = snap }) end)
    end)
end

function M.groups()
    local list = groups.all()
    each_subscriber(function(pid) send(pid, "groups.changed", { groups = list }) end)
end

function M.settings(key, value)
    each_subscriber(function(pid, p)
        if perms.has(p, "settings.read") then send(pid, "settings.changed", { key = key, value = value }) end
    end)
end

function M.vote(event, state)
    node.broadcast(M.EVENT, { ev = "vote.state", data = { event = event, vote = state } })
end

function M.notice(player, text, code, params)
    if not hellos[player.id] then return end
    send(player.id, "notice", { text = text, code = code, params = params })
end

local PLAYER_KINDS = {
    kick = true, ban = true, tempban = true, mute = true, unmute = true, warn = true, group_set = true,
    car_delete = true, group_delete = true,
}

function M.init()
    subscribers, hellos, players_timer = {}, {}, nil
    perms.on_change(function() M.players() end)
    groups.on_change(function() M.groups() end)
    settings.on_change(function(key, value) M.settings(key, value) end)
    votekick.on(function(event, state) M.vote(event, state) end)
    say.on_notice(function(player, text, code, params) M.notice(player, text, code, params) end)
    registry.after(function(kind, result)
        if result.ok and PLAYER_KINDS[kind] then M.players() end
    end)
end

return M
