#!/usr/bin/env python3
"""Vote-kick gate: four players from four addresses; the start rules
(permission, too few, immune, self), the vote through the chat and the
panel, the vote.state pushes everyone gets, the target kicked when the
threshold is reached, the cooldown, a failed vote, the cancel.

One server (31230, WD_TEST_HOOKS=1, votekick.cooldown_sec lowered so the
scenario does not wait five minutes).
"""
import sys
import time

from harness import Client, Inbox, Server, TEST_HOOKS_ENV, check, err_code, info, probe, require_server, result

PORT = 31230
IPS = ["127.0.0.1", "127.0.0.2", "127.0.0.3", "127.0.0.4"]


def vote_events(inbox, since, settle=0.5):
    return [e for e in inbox.events("vote.state", since, settle=settle)]


def main():
    require_server()
    info("=== vote-kick ===")
    config = {"votekick": {"cooldown_sec": 3, "window_sec": 15}, "limits": {"commands_per_10s": 100}}
    with Server(PORT, env=TEST_HOOKS_ENV, name="votekick", config=config) as srv:
        info("--- too few players ---")
        p1 = Client.join(PORT, name="P1", source=IPS[0])
        p2 = Client.join(PORT, name="P2", source=IPS[1])
        i1, i2 = Inbox(p1), Inbox(p2)
        probe(p1, "group.set", {"group": "trusted"})
        m = i1.chat("/votekick P2")
        check(i1.chat_lines(m) == ["A vote needs at least 4 players online."], "min_players")
        p3 = Client.join(PORT, name="P3", source=IPS[2])
        p4 = Client.join(PORT, name="P4", source=IPS[3])
        i3, i4 = Inbox(p3), Inbox(p4)
        for i in (i1, i2, i3, i4):
            i.hello()

        info("--- start rules ---")
        m = i2.chat("/votekick P3")
        check(i2.chat_lines(m) == ["You may not do that (votekick.start)."], "default has no votekick.start")
        probe(p4, "group.set", {"group": "mod"})
        m = i1.chat("/votekick P4")
        check(i1.chat_lines(m) == ["That player cannot be vote-kicked."], "a mod (level 50) is immune")
        m = i1.chat("/votekick P1")
        check(i1.chat_lines(m) == ["You cannot vote-kick yourself."], "not yourself")

        info("--- a vote passes: 4 players, 3 eligible, ceil(0.6*3) = 2 yes ---")
        marks = [i.mark() for i in (i1, i2, i3, i4)]
        m = i1.chat("/votekick P3 ramming")
        lines = i1.chat_lines(m)
        check(any(ln.startswith("P1 started a vote to kick P3 (ramming). /vote yes or /vote no, 15 s, 2 yes needed")
                  for ln in lines), "the announcement", lines)
        for i, mk in zip((i2, i3, i4), marks[1:]):
            ev = vote_events(i, mk)
            check(ev and ev[0]["event"] == "started" and ev[0]["vote"]["target"]["name"] == "P3"
                  and ev[0]["vote"]["yes"] == 1 and ev[0]["vote"]["needed"] == 2,
                  "%s got the vote.state started push" % i.client.name, ev)
        m = i3.chat("/vote yes")
        check(i3.chat_lines(m) == ["The target does not vote."], "the target cannot vote")
        m = i2.chat("/vote nope")
        check(i2.chat_lines(m) == ["Usage: /vote yes|no|cancel"], "usage")
        r = i4.request("vote.state")
        check(r.get("ok") is True and r["data"]["vote"]["yes"] == 1 and r["data"]["vote"]["eligible"] == 3,
              "vote.state from the panel", r)
        mk = i2.mark()
        r = i4.request("vote.cast", {"yes": True})
        check(r.get("ok") is True and r["data"]["vote"]["yes"] == 2 and r["data"]["running"] is False,
              "vote.cast from the panel counts and decided the vote", r)
        check(p3.kicked(5) is not None, "P3 was kicked when the threshold was reached")
        ev = vote_events(i2, mk)
        check(any(e["event"] == "passed" for e in ev), "everyone got the passed push", [e["event"] for e in ev])
        lines = i2.chat_lines(mk)
        check(any("Vote passed: P3 was kicked (2 yes)." == ln for ln in lines), "the result in the chat", lines)
        p3.close()
        rows = probe(p1, "audit.tail", {"n": 5}).get("data", {}).get("rows", [])
        check(any(r_["op"] == "votekick_start" and r_["result"] == "ok" for r_ in rows), "the start is audited", rows)

        info("--- cooldown, then a vote that fails and one that is cancelled ---")
        p3 = Client.join(PORT, name="P3", source=IPS[2])
        i3 = Inbox(p3)
        m = i1.chat("/votekick P2")
        lines = i1.chat_lines(m)
        check(lines and lines[0].startswith("Wait ") and lines[0].endswith(" s before another vote."), "cooldown", lines)
        time.sleep(3.5)
        m = i1.chat("/votekick P2 test")
        check(any("started a vote" in ln for ln in i1.chat_lines(m)), "after the cooldown a new vote starts")
        m3 = i3.chat("/vote no")
        check(i3.chat_lines(m3) == ["Vote counted: 1/2 yes."], "a no vote")
        m4 = i4.mark()
        p4.chat("/vote no")
        lines = i4.chat_lines(m4)
        check(any("Vote to kick P2 failed (1/2)." == ln for ln in lines), "no can no longer be beaten: failed", lines)
        time.sleep(3.5)
        m = i1.chat("/votekick P2 again")
        i1.chat_lines(m)
        m = i2.chat("/vote cancel")
        check(i2.chat_lines(m) == ["You may not do that (votekick.cancel)."], "cancel is the mod's")
        mk = i1.mark()
        r = i4.request("vote.cancel")
        check(r.get("ok") is True, "vote.cancel from the panel", r)
        lines = i1.chat_lines(mk)
        check(any("The vote to kick P2 was cancelled." == ln for ln in lines), "cancelled in the chat", lines)
        r = i2.request("vote.cast", {"yes": True})
        check(err_code(r) == "vote.none", "no vote to cast in", r)

        info("--- the window closes ---")
        time.sleep(3.5)
        m = i1.chat("/votekick P2 slow")
        i1.chat_lines(m)
        mk = i2.mark()
        time.sleep(16)
        lines = i2.chat_lines(mk, timeout=5)
        check(any("Vote to kick P2 failed (1/2)." == ln for ln in lines), "the window closed: failed", lines)
        check(srv.lua_errors() == [], "no Lua errors", srv.lua_errors())
        for c in (p1, p2, p3, p4):
            c.close()
    return result()


if __name__ == "__main__":
    sys.exit(main())
