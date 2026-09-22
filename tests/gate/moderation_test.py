#!/usr/bin/env python3
"""Moderation gate: kick (the KICK frame with the reason), ban and tempban
(the rejoin refused by the server's own ban list, /bans, /unban), mute (the
notice on a chat line), warn, the whitelist and allow_guests at the connect
gate, group assignment with the rank rule and the role tag, the vehicle cap
on a real spawn, /car delete, the audit rows, /settings.

Everyone here is a guest (no directory), which is what the review's name
findings are about: a guest's name hands out no privilege (/group,
/whitelist add need #pid or the key), a name entry on the whitelist never
admits a guest, a name shared by a connected guest and a record is
`ambiguous`, prefixes match nobody, ip: keys are address literals, a
refused wd:req cannot stuff the audit, addresses are for mod.ban and up.

One server (31210, WD_TEST_HOOKS=1). Every client comes from its own
loopback address (127.0.0.1, .2, .3, ...), so each has its own record.
"""
import json
import sys
import time

from harness import Client, Inbox, Server, TEST_HOOKS_ENV, check, err_code, info, lang, probe, probe_data, \
    require_server, result

PORT = 31210
CAR = json.dumps({"jbm": "coupe", "vcf": {"parts": {}, "paints": [{"baseColor": [1, 0, 0, 1]}]}}).encode()

ALICE, BOB, CARL, MOD, FAKE = "127.0.0.1", "127.0.0.2", "127.0.0.3", "127.0.0.4", "127.0.0.5"
SAVE = 1.5  # the stores write coalesced, within a second of a change


def main():
    require_server()
    info("=== moderation ===")
    # the scenario types far more than 8 commands per 10 s; the limiter has its own unit test
    with Server(PORT, env=TEST_HOOKS_ENV, name="moderation", config={"limits": {"commands_per_10s": 100}}) as srv:
        alice = Client.join(PORT, name="Alice", source=ALICE)
        bob = Client.join(PORT, name="Bob", source=BOB)
        mod = Client.join(PORT, name="Mod", source=MOD)
        a, b, m_ = Inbox(alice), Inbox(bob), Inbox(mod)

        info("--- fixtures: Alice admin, Mod mod, Bob default ---")
        r = probe(alice, "group.set", {"group": "admin"})
        check(r.get("ok") is True and probe_data(r, "level") == 90, "Alice is an admin", r)
        check(probe_data(probe(alice, "me"), "role") == "admin", "the role tag follows the group")
        r = probe(mod, "group.set", {"group": "mod"})
        check(probe_data(r, "level") == 50, "Mod is a mod", r)
        check(probe_data(probe(bob, "me"), "group") == "default", "Bob is default (own ip, own record)")
        check(probe_data(probe(bob, "me"), "key") == "ip:" + BOB, "Bob's key is his ip")

        info("--- the rank rule ---")
        m = m_.chat("/kick Alice")
        check(m_.chat_lines(m) == ["Alice is not below your level."], "a mod cannot kick an admin")
        m = b.chat("/kick Mod")
        check(b.chat_lines(m) == ["You may not do that (mod.kick)."], "a default player has no mod.kick")

        info("--- group set: below your own level only; a guest by #pid, never by name ---")
        m = m_.chat("/group Bob trusted")
        check(m_.chat_lines(m) == ["You may not do that (perms.set)."], "perms.set is the admin's")
        m = a.chat("/group Bob trusted")
        check(a.chat_lines(m) == ["'Bob' is a guest's name and proves nothing; use #pid or the key (ip:%s)." % BOB],
              "a guest's name hands out no group (the admin sees the key: mod.ban)")
        check(probe_data(probe(bob, "me"), "group") == "default", "Bob is still default")
        m = a.chat("/group #%d trusted" % bob.id)
        check(a.chat_lines(m) == ["Bob is now in trusted."], "/group #pid trusted")
        got = b.wait("chat:msg", lambda x: isinstance(x, dict) and "put you in the group" in x.get("text", ""), 5)
        check(got is not None and got["text"] == "Alice put you in the group trusted.", "Bob was told", got)
        check(probe_data(probe(bob, "me"), "role") == "trusted", "Bob's tag is trusted")
        m = a.chat("/group #%d admin" % bob.id)
        check(a.chat_lines(m) == ["The group admin is not below your level."], "not at or above your own level")
        m = a.chat("/group ip:%s owner" % BOB)
        check(a.chat_lines(m) == ["The group owner is not below your level."], "never owner")
        m = a.chat("/group ip:nodemp:1 trusted")
        check(a.chat_lines(m) == [lang("err.bad_key").replace("{target}", "ip:nodemp:1")],
              "an ip: key must be an address literal")

        info("--- whitelist at the gate: a name entry never admits a guest ---")
        m = a.chat("/whitelist on")
        check(a.chat_lines(m) == ["Whitelist is on."], "/whitelist on")
        kind, why = Client.try_join(PORT, name="Carl", source=CARL)
        check(kind == "kick" and why == lang("join.whitelist"), "a connect is refused with the whitelist text",
              (kind, why))
        m = a.chat("/whitelist add Carl")
        check(a.chat_lines(m) == [lang("done.whitelist_add_name").replace("{entry}", "name:carl")],
              "a name not seen yet is a name entry, and the answer says what it is good for")
        kind, why = Client.try_join(PORT, name="Carl", source=CARL)
        check(kind == "kick" and why == lang("join.whitelist"), "a guest of that name is not admitted by it",
              (kind, why))
        m = a.chat("/whitelist add ip:" + CARL)
        check(a.chat_lines(m) == ["Whitelisted ip:%s." % CARL], "a guest goes on the list by key")
        carl = Client.join(PORT, name="Carl", source=CARL)
        check(carl.id is not None, "Carl is let in by key", carl.id)
        rec = probe(carl, "record")
        check(probe_data(rec, "record", ).get("names") == ["Carl"], "Carl has a record now (the join ran)", rec)
        m = a.chat("/whitelist add Carl")
        check(a.chat_lines(m) == ["'Carl' is a guest's name and proves nothing; use #pid or the key (ip:%s)." % CARL],
              "a connected guest's name is refused as well")
        carl.close()
        time.sleep(SAVE)
        wl = srv.data("whitelist.json")
        check(wl and "ip:" + CARL in wl["entries"] and "name:carl" in wl["entries"],
              "the name entry stays: the guest did not consume it", wl)
        m = a.chat("/whitelist list")
        lines = a.chat_lines(m)
        check(lines[0] == "Whitelist on, 2 entry(ies):" and lines[1].startswith("ip:" + CARL)
              and lines[2].startswith("name:carl"), "/whitelist list", lines)
        m = a.chat("/whitelist remove Carl")
        check(a.chat_lines(m) == ["Removed name:carl from the whitelist."], "/whitelist remove takes the name entry")
        kind, _ = Client.try_join(PORT, name="Carl", source=CARL)
        check(kind == "welcome", "the key entry still admits", kind)
        m = a.chat("/whitelist remove ip:" + CARL)
        check(a.chat_lines(m) == ["Removed ip:%s from the whitelist." % CARL], "/whitelist remove by key")
        kind, _ = Client.try_join(PORT, name="Carl", source=CARL)
        check(kind == "kick", "removed: refused again", kind)
        m = a.chat("/whitelist off")
        check(a.chat_lines(m) == ["Whitelist is off."], "/whitelist off")
        kind, _ = Client.try_join(PORT, name="Carl", source=CARL)
        check(kind == "welcome", "whitelist off: anyone joins", kind)

        info("--- allow_guests ---")
        m = a.chat("/settings set allow_guests false")
        check(a.chat_lines(m) == ["allow_guests = false"], "/settings set")
        kind, why = Client.try_join(PORT, name="Eve", source=CARL)
        check(kind == "kick" and why == lang("join.no_guests"), "no directory account: refused", (kind, why))
        time.sleep(SAVE)
        settings = srv.data("settings.json")
        check(settings.get("allow_guests") is False, "settings.json carries the override", settings)
        m = a.chat("/settings reset allow_guests")
        check(a.chat_lines(m) == ["allow_guests back to true"], "/settings reset")
        m = b.chat("/settings list")
        check(b.chat_lines(m) == ["You may not do that (settings.read)."], "settings.read is not trusted's")

        info("--- warn and mute ---")
        m = m_.chat("/warn Bob no ramming")
        check(m_.chat_lines(m) == ["Warned Bob (#1): no ramming"], "/warn")
        got = b.wait("chat:msg", lambda x: isinstance(x, dict) and "Warning #1" in x.get("text", ""), 5)
        check(got is not None and got["text"] == "Warning #1 from Mod: no ramming", "Bob was told", got)
        check(len(probe_data(probe(bob, "record"), "record")["warns"]) == 1, "the warning is on the record")
        m = m_.chat("/mute Bob 30m spam")
        check(m_.chat_lines(m) == ["Muted Bob (30m): spam"], "/mute")
        mb = b.mark()
        bob.chat("hello")
        got = b.wait("chat:msg", lambda x: isinstance(x, dict) and x.get("scope") == "system", 5, mb)
        check(got is not None and got["text"].startswith("You are muted (") and "by Mod: spam" in got["text"],
              "a muted player is told on a chat line", got)
        mute = probe_data(probe(bob, "mute.of"), "mute")
        check(mute and mute["until"] - mute["at"] == 1800, "the mute has its expiry", mute)
        m = m_.chat("/unmute Bob")
        check(m_.chat_lines(m) == ["Unmuted Bob."], "/unmute")
        check(probe_data(probe(bob, "mute.of"), "muted") is False, "the mute is gone")

        info("--- the vehicle cap on a real spawn ---")
        probe(bob, "group.set", {"group": "default"})
        g1 = bob.inner.spawn(CAR)
        check(g1 is not None and g1 >= 0, "the first car of a default player spawns", g1)
        g2 = bob.inner.spawn(CAR, budget=5)
        check(g2 is None or g2 < 0, "the second is denied by the cap (1)", g2)
        ga = alice.inner.spawn(CAR)
        gb = alice.inner.spawn(CAR)
        check(ga is not None and ga >= 0 and gb is not None and gb >= 0, "an admin has car.cap.bypass", (ga, gb))
        m = b.chat("/car delete")
        check(b.chat_lines(m) == ["Deleted 1 vehicle(s) of Bob."], "/car delete on oneself")
        m = b.chat("/car delete Alice")
        check(b.chat_lines(m) == ["You may not do that (car.delete)."], "not on others without car.delete")
        m = m_.chat("/car delete Alice")
        check(m_.chat_lines(m) == ["Alice is not below your level."], "nor above your level")
        m = a.chat("/car delete Bob")
        check(a.chat_lines(m) == ["Deleted 0 vehicle(s) of Bob."], "an admin may (nothing left to delete)")

        info("--- kick: the KICK frame ---")
        m = m_.chat("/kick Bob too fast")
        check(m_.chat_lines(m) == ["Kicked Bob: too fast"], "/kick answers the mod")
        reason = bob.kicked()
        check(reason == "too fast", "Bob got the KICK with the reason", reason)
        bob.close()
        kind, _ = Client.try_join(PORT, name="Bob", source=BOB)
        check(kind == "welcome", "a kick is not a ban", kind)

        info("--- tempban: KICK, the core refuses the rejoin, /bans, /unban ---")
        bob = Client.join(PORT, name="Bob", source=BOB)
        m = m_.chat("/tempban Bob 30m griefing")
        check(m_.chat_lines(m) == ["Banned Bob for 30m: griefing"], "/tempban")
        reason = bob.kicked()
        check(reason == "griefing", "Bob got the KICK", reason)
        bob.close()
        time.sleep(SAVE)
        kind, why = Client.try_join(PORT, name="Bob", source=BOB)
        check(kind == "kick", "the core refuses the banned ip before warden sees it", (kind, why))
        meta = srv.data("bans_meta.json")
        row = meta.get("ip:" + BOB)
        check(row and row["reason"] == "griefing" and row["by_name"] == "Mod" and row["until"] - row["at"] == 1800,
              "bans_meta.json has the row with the expiry", meta)
        m = a.chat("/bans")
        lines = a.chat_lines(m)
        check(lines[0] == "1 ban(s):" and lines[1].startswith("Bob (ip:%s) griefing until" % BOB), "/bans", lines)
        m = m_.chat("/unban Bob")
        check(m_.chat_lines(m) == ["You may not do that (mod.ban)."], "unban is mod.ban")
        m = a.chat("/unban Bob")
        check(a.chat_lines(m) == ["Unbanned Bob."], "/unban by the name from the history")
        time.sleep(SAVE)
        check(srv.data("bans_meta.json") == {}, "metadata gone")
        kind, _ = Client.try_join(PORT, name="Bob", source=BOB)
        check(kind == "welcome", "the connect works again", kind)

        info("--- a permanent ban by the admin ---")
        bob = Client.join(PORT, name="Bob", source=BOB)
        m = m_.chat("/ban Bob")
        check(m_.chat_lines(m) == ["You may not do that (mod.ban)."], "mod.ban is the admin's")
        m = a.chat("/ban Bob cheating")
        check(a.chat_lines(m) == ["Banned Bob: cheating"], "/ban")
        check(bob.kicked() == "cheating", "KICK with the reason")
        bob.close()
        kind, _ = Client.try_join(PORT, name="Bob", source=BOB)
        check(kind == "kick", "refused", kind)
        m = a.chat("/unban ip:" + BOB)
        check(a.chat_lines(m) == ["Unbanned Bob."], "/unban by key")

        info("--- names: whole and unambiguous; keys: literals ---")
        m = a.chat("/tempban Bo 1h")
        check(a.chat_lines(m) == ["No player matches 'Bo'."], "a prefix bans nobody")
        m = a.chat("/ban ip:nodemp:1")
        check(a.chat_lines(m) == [lang("err.bad_key").replace("{target}", "ip:nodemp:1")],
              "an account ban cannot be smuggled in as an ip: key")
        m = a.chat("/bans")
        check(a.chat_lines(m) == ["0 ban(s):"], "nothing was banned by it")
        fake = Client.join(PORT, name="Bob", source=FAKE)
        m = m_.chat("/mute Bob")
        lines = m_.chat_lines(m)
        check(len(lines) == 1 and lines[0].startswith("'Bob' matches several players: ")
              and lines[0].endswith(" Use #pid or the key.") and "ip:127.0.*.*" in lines[0] and BOB not in lines[0],
              "a connected guest and a record of the same name: ambiguous, the addresses masked for a mod", lines)
        m = a.chat("/mute Bob")
        lines = a.chat_lines(m)
        check(len(lines) == 1 and "ip:%s #%d guest" % (FAKE, fake.id) in lines[0] and "ip:%s guest" % BOB in lines[0],
              "the admin (mod.ban) sees the keys", lines)
        m = m_.chat("/mute #%d 30m" % fake.id)
        check(m_.chat_lines(m) == ["Muted Bob (30m): -"], "the pid is never in doubt")
        fake.close()

        info("--- a refused wd:req cannot stuff the audit; addresses are for mod.ban and up ---")
        bob = Client.join(PORT, name="Bob", source=BOB)
        b = Inbox(bob)
        r = b.request("mod.kick", {"pid": alice.id, "junk": "x" * 15000})
        check(err_code(r) == "denied", "Bob may not kick", r)
        row = probe_data(probe(alice, "audit.tail", {"n": 1}), "rows")[0]
        check(row["op"] == "mod.kick" or row["op"] == "kick", "the refusal is the last row", row)
        check(row.get("args") == {"pid": alice.id} and row.get("dropped") == 1,
              "the row keeps the shape's fields only and counts the rest", row)
        r = b.request("players.get", {"pid": alice.id})
        check(err_code(r) == "denied", "no players.view for Bob", r)
        r = m_.request("players.get", {"pid": bob.id})
        p = r.get("data", {}).get("player", {})
        check(p.get("ip") == "127.0.*.*" and p.get("key") == "ip:127.0.*.*", "a mod sees masked addresses", p)
        r = a.request("players.get", {"pid": bob.id})
        p = r.get("data", {}).get("player", {})
        check(p.get("ip") == BOB and p.get("key") == "ip:" + BOB, "an admin sees them", p)
        bob.close()

        info("--- the audit ---")
        rows = probe_data(probe(alice, "audit.tail", {"n": 100}), "rows")
        ops = [r_["op"] for r_ in rows]
        for op in ("kick", "tempban", "ban", "unban", "warn", "mute", "unmute", "group_set", "whitelist_add",
                   "whitelist_remove", "whitelist_enable", "settings_set", "settings_reset", "car_delete"):
            check(op in ops, "audit has %s" % op)
        denied = [r_ for r_ in rows if r_["result"] == "denied"]
        reasons = {r_["reason"] for r_ in denied}
        check("outranked" in reasons and "denied" in reasons, "the refusals carry their reason", reasons)
        check({"guest_by_name", "ambiguous", "bad_key", "no_target"} <= reasons, "and the new ones", reasons)
        check(all(len(json.dumps(r_)) <= 1400 for r_ in rows), "no row is anywhere near the stuffing size")
        m = m_.chat("/audit 3")
        lines = m_.chat_lines(m)
        check(lines[0] == "Last 3 audit row(s):" and len(lines) == 4, "/audit 3", lines)
        check(srv.lua_errors() == [], "no Lua errors", srv.lua_errors())
        for c in (alice, mod):
            c.close()
    audit_files = [k for k in srv.data() if k.startswith("audit/")]
    check(len(audit_files) == 1 and audit_files[0].endswith(".jsonl"), "one audit file for the day", audit_files)
    return result()


if __name__ == "__main__":
    sys.exit(main())
