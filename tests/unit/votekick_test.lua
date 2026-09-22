-- vote-kick: start rules, the count, the outcome, cooldowns, the pushes.

local boot = require("boot")

local function setup(overrides)
    -- off by default (the spec); these tests turn it on unless told otherwise
    overrides = overrides or {}
    overrides.votekick = overrides.votekick or {}
    if overrides.votekick.enabled == nil then overrides.votekick.enabled = true end
    local W = boot(overrides)
    local players = {}
    for i = 1, 6 do players[i] = node._join(i, { name = "P" .. i, accountId = i }) end
    W.perms.set_group(players[1], "trusted")   -- may start
    W.perms.set_group(players[6], "mod")       -- immune (level 50), may cancel
    for _, p in ipairs(players) do node._emit("playerJoined", p) end
    node._told, node._sent = {}, {}
    return W, players
end

local function cmd(player, line)
    node.bus.emit("chat:command", { pid = player.id, name = line:match("^/(%S+)"), args = {}, raw = line })
end

local function vote_events()
    local out = {}
    for _, e in ipairs(node._sent_of("wd:event", "all")) do
        if e.ev == "vote.state" then out[#out + 1] = e.data end
    end
    return out
end

local tests = {}

tests.start_rules = function()
    local W, P = setup()
    cmd(P[2], "/votekick P3")
    t.match(node._told_text(2), "You may not do that %(votekick%.start%)")
    cmd(P[1], "/votekick P1")
    t.match(node._told_text(1), "cannot vote%-kick yourself")
    cmd(P[1], "/votekick P6")
    t.match(node._told_text(1), "cannot be vote%-kicked")
    cmd(P[1], "/votekick Nobody")
    t.match(node._told_text(1), "No player matches")
    t.falsy(W.votekick.running())
    -- too few players
    for i = 3, 6 do node._leave(i) end
    node._told = {}
    cmd(P[1], "/votekick P2")
    t.match(node._told_text(1), "at least 4 players")
    local W2 = setup({ votekick = { enabled = false } })
    node._told = {}
    cmd(P[1], "/votekick P2")
    t.match(node._told_text(1), "Vote%-kick is off")
    t.falsy(W2.votekick.running())
end

tests.a_vote_passes = function()
    local W, P = setup()
    cmd(P[1], "/votekick P3 ramming")
    t.truthy(W.votekick.running())
    local s = W.votekick.state()
    t.eq(s.eligible, 5)
    t.eq(s.needed, 3, "ceil(0.6 * 5)")
    t.eq(s.yes, 1, "the starter's own yes")
    t.eq(s.seconds_left, 60)
    -- everyone was told, in the chat and as a wd:event
    t.eq(#node._told, 6)
    t.match(node._told_text(2), "P1 started a vote to kick P3 %(ramming%)%. /vote yes or /vote no, 60 s, 3 yes needed")
    local ev = vote_events()
    t.eq(#ev, 1)
    t.eq(ev[1].event, "started")
    t.eq(ev[1].vote.target.name, "P3")
    -- the target cannot vote; others do
    node._told = {}
    cmd(P[3], "/vote yes")
    t.match(node._told_text(3), "The target does not vote")
    cmd(P[2], "/vote no")
    cmd(P[4], "/vote yes")
    t.match(node._told_text(4), "Vote counted: 2/3 yes")
    t.eq(#node._kicked, 0)
    cmd(P[5], "/vote yes")
    t.eq(#node._kicked, 1)
    t.eq(node._kicked[1].name, "P3")
    t.eq(node._kicked[1].reason, "vote-kicked: ramming")
    t.falsy(W.votekick.running())
    t.match(node._told_text(1), "Vote passed: P3 was kicked %(3 yes%)")
    ev = vote_events()
    t.eq(ev[#ev].event, "passed")
    -- cooldown for the starter and (were they back) the target
    node._told = {}
    cmd(P[1], "/votekick P2")
    t.match(node._told_text(1), "Wait 300 s before another vote")
    node._advance(301 * 1000)
    node._told = {}
    cmd(P[1], "/votekick P2")
    t.truthy(W.votekick.running())
    -- the audit has the start
    local rows = W.audit.tail(5)
    local starts = 0
    for _, r in ipairs(rows) do
        if r.op == "votekick_start" and r.result == "ok" then starts = starts + 1 end
    end
    t.eq(starts, 2)
end

tests.a_vote_fails_on_no_or_timeout = function()
    local W, P = setup()
    cmd(P[1], "/votekick P3")
    cmd(P[2], "/vote no")
    cmd(P[4], "/vote no")
    cmd(P[5], "/vote no")
    t.falsy(W.votekick.running(), "no cannot be beaten any more")
    t.match(node._told_text(1), "Vote to kick P3 failed %(1/3%)")
    t.eq(#node._kicked, 0)
    node._advance(301 * 1000)
    node._told = {}
    cmd(P[1], "/votekick P3")
    node._advance(59 * 1000)
    t.truthy(W.votekick.running())
    node._advance(2 * 1000)
    t.falsy(W.votekick.running(), "the window closed")
    t.match(node._told_text(2), "failed")
    -- a vote against a target who leaves ends
    node._advance(301 * 1000)
    cmd(P[1], "/votekick P3")
    node._emit("playerLeft", P[3])
    node._leave(3)
    t.falsy(W.votekick.running())
    -- one at a time
    node._advance(301 * 1000)
    cmd(P[1], "/votekick P2")
    node._told = {}
    cmd(P[1], "/votekick P4")
    t.match(node._told_text(1), "A vote is already running")
end

tests.cancel_and_the_leaving_voter = function()
    local W, P = setup()
    cmd(P[1], "/votekick P3")
    cmd(P[2], "/vote yes")
    node._told = {}
    cmd(P[4], "/vote cancel")
    t.match(node._told_text(4), "You may not do that %(votekick%.cancel%)")
    cmd(P[6], "/vote cancel")
    t.falsy(W.votekick.running())
    t.match(node._told_text(6), "Vote cancelled")
    t.match(node._told_text(1), "The vote to kick P3 was cancelled")
    node._told = {}
    cmd(P[2], "/vote yes")
    t.match(node._told_text(2), "There is no vote running")
    -- a voter who leaves takes the vote along (the count adjusts)
    node._advance(301 * 1000)
    cmd(P[1], "/votekick P3")
    cmd(P[2], "/vote yes")
    t.eq(W.votekick.state().yes, 2)
    node._emit("playerLeft", P[2])
    node._leave(2)
    t.eq(W.votekick.state().yes, 1)
    t.eq(W.votekick.state().eligible, 4)
    t.eq(W.votekick.state().needed, 3)
    -- through the panel protocol as well
    node._sent = {}
    W.protocol.handle(P[4], '{"id":1,"op":"vote.cast","data":{"yes":true}}')
    local replies = node._sent_of("wd:reply", 4)
    t.eq(replies[1].ok, true)
    t.eq(replies[1].data.vote.yes, 2)
    W.protocol.handle(P[5], '{"id":2,"op":"vote.state"}')
    t.eq(node._sent_of("wd:reply", 5)[1].data.vote.needed, 3)
end

return tests
