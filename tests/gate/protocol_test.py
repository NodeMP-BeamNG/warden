#!/usr/bin/env python3
"""Protocol gate: the wd:req / wd:reply / wd:event surface the warden-ui
panel uses -- sys.hello (protocol check, the record, the permission
catalogue), players.list / players.get / players.subscribe with the
coalesced players.changed push, the mod.* actions from the panel with their
effect on the other client, groups.list / groups.save / groups.delete with
the groups.changed push, settings.list / set / reset with settings.changed,
audit.tail, the notice push, the frame limiter, and the bus API through a
second resource that asks warden:getGroup.

One server (31220, WD_TEST_HOOKS=1, ui_per_sec raised for the scenario).
"""
import json
import os
import sys
import time

from harness import Client, Inbox, Server, TEST_HOOKS_ENV, check, err_code, info, probe, probe_data, require_server, \
    result

PORT = 31220
ALICE, BOB, CARL = "127.0.0.1", "127.0.0.2", "127.0.0.3"

# a second resource that consumes the bus API and logs the answers
ASKER = r'''
node.bus.on("warden:group", function(_, data) node.log("asker got group: " .. tostring(data)) end)
node.bus.on("warden:perm", function(_, data) node.log("asker got perm: " .. tostring(data)) end)
node.bus.on("warden:groupChanged", function(_, data) node.log("asker saw groupChanged: " .. tostring(data)) end)
node.bus.on("warden:ready", function(_, data) node.log("asker saw ready: " .. tostring(data)) end)
node.on("asker:ask", function(player, data)
    local d = node.json.decode(data)
    node.bus.emit("warden:getGroup", { pid = player.id, tag = d.tag })
    node.bus.emit("warden:hasPerm", { pid = player.id, perm = d.perm, tag = d.tag })
end)
node.log("asker loaded")
'''


class ServerWithAsker(Server):
    def _prepare_home(self):
        super()._prepare_home()
        d = os.path.join(self.home, "resources", "asker", "server")
        os.makedirs(d)
        with open(os.path.join(d, "main.lua"), "w", encoding="utf-8", newline="\n") as f:
            f.write(ASKER)
        with open(os.path.join(self.home, "resources", "asker", "resource.toml"), "w", encoding="utf-8",
                  newline="\n") as f:
            f.write('name = "asker"\nversion = "0.0.1"\ntype = "lua"\n\n[server]\nmain = "server/main.lua"\n')


def main():
    require_server()
    info("=== protocol ===")
    config = {"limits": {"ui_per_sec": 100, "ui_per_min": 5000, "commands_per_10s": 100}}
    with ServerWithAsker(PORT, env=TEST_HOOKS_ENV, name="protocol", config=config) as srv:
        check("asker loaded" in srv.log(), "the asker resource is up")
        alice = Client.join(PORT, name="Alice", source=ALICE)
        bob = Client.join(PORT, name="Bob", source=BOB)
        a, b = Inbox(alice), Inbox(bob)
        probe(alice, "group.set", {"group": "admin"})

        info("--- hello ---")
        r = a.hello(lang="ru")
        check(r.get("ok") is True, "sys.hello ok", r)
        d = r.get("data") or {}
        check(d.get("protocol") == 1 and d.get("key") == "F9" and d.get("lang") == "ru", "protocol, key, lang", d)
        check(d.get("me", {}).get("group") == "admin" and d["me"]["level"] == 90 and d["me"]["pid"] == alice.id,
              "the record", d.get("me"))
        check("mod.kick" in d.get("perms", []) and "perms.manage" not in d["perms"], "the effective perms", d.get("perms"))
        check(any(p[0] == "perms.manage" for p in d.get("permissions", [])), "the permission catalogue")
        check(d.get("vote") is None, "no vote running")
        r = b.hello(protocol=7)
        check(err_code(r) == "ui_outdated" and r["error"]["params"]["server"] == 1, "a wrong protocol is refused", r)
        r = b.hello()
        check(r.get("ok") is True and r["data"]["me"]["group"] == "default", "Bob's hello", r)

        info("--- players ---")
        r = b.request("players.list")
        check(err_code(r) == "denied", "players.list needs players.view", r)
        r = a.request("players.list")
        names = sorted(p["name"] for p in r.get("data", {}).get("players", []))
        check(r.get("ok") is True and names == ["Alice", "Bob"] and r["data"]["count"] == 2 and r["data"]["max"] == 16,
              "players.list", r)
        r = a.request("players.get", {"pid": bob.id})
        p = r.get("data", {}).get("player", {})
        check(p.get("key") == "ip:" + BOB and p.get("cap") == 1 and p.get("names") == ["Bob"] and p.get("guest") is True,
              "players.get: the full row", p)
        r = a.request("players.get", {"pid": 99})
        check(err_code(r) == "offline", "an unknown pid is offline", r)
        probe(bob, "group.set", {"group": "mod"})
        r = b.request("players.get", {"pid": alice.id})
        p = r.get("data", {}).get("player", {})
        check(p.get("ip") == "127.0.*.*" and p.get("key") == "ip:127.0.*.*",
              "a mod (no mod.ban) sees masked addresses", p)
        r = b.request("players.get", {"pid": bob.id})
        check(r.get("data", {}).get("player", {}).get("ip") == BOB, "one's own address is shown", r)
        probe(bob, "group.set", {"group": "default"})
        r = a.request("players.subscribe", {"on": True})
        check(r.get("ok") is True and len(r["data"]["players"]) == 2, "subscribe answers the snapshot", r)
        m = a.mark()
        carl = Client.join(PORT, name="Carl", source=CARL)
        probe(carl, "group.set", {"group": "trusted"})
        pushes = a.events("players.changed", m, settle=1.5)
        check(len(pushes) == 1, "a join and a group change: one coalesced players.changed", len(pushes))
        check(pushes and any(p["name"] == "Carl" and p["group"] == "trusted" for p in pushes[0]["players"]),
              "the push carries the new state", pushes)
        check(b.events("players.changed", 0) == [], "Bob (no players.view) gets no push")

        info("--- actions from the panel ---")
        r = b.request("mod.warn", {"pid": carl.id, "reason": "x"})
        check(err_code(r) == "denied", "Bob may not warn", r)
        r = a.request("mod.warn", {"pid": carl.id, "reason": "no ramming"})
        check(r.get("ok") is True and r["data"]["count"] == 1 and r["data"]["target"]["name"] == "Carl", "mod.warn", r)
        c = Inbox(carl)
        got = c.wait("chat:msg", lambda x: isinstance(x, dict) and "Warning #1" in x.get("text", ""), 5)
        check(got is not None, "Carl was told in the chat", got)
        r = a.request("mod.mute", {"pid": carl.id, "duration": 600, "reason": "spam"})
        check(r.get("ok") is True and r["data"]["duration"] == 600, "mod.mute", r)
        r = a.request("mod.unmute", {"pid": carl.id})
        check(r.get("ok") is True, "mod.unmute", r)
        r = a.request("mod.mute", {"pid": carl.id, "duration": 5})
        check(err_code(r) == "bad_arg" and r["error"]["params"]["field"] == "duration", "shape: duration >= 60", r)
        r = a.request("groups.set", {"pid": carl.id, "group": "mod"})
        check(r.get("ok") is True and r["data"]["level"] == 50, "groups.set", r)
        r = a.request("groups.set", {"pid": carl.id, "group": "admin"})
        check(err_code(r) == "group_too_high", "not your own level", r)
        r = a.request("car.delete", {"pid": carl.id})
        check(err_code(r) == "outranked" or r.get("ok") is True, "car.delete on a mod by an admin: allowed", r)
        m = a.mark()
        r = a.request("mod.kick", {"pid": carl.id, "reason": "bye"})
        check(r.get("ok") is True, "mod.kick from the panel", r)
        check(carl.kicked() == "bye", "Carl got the KICK")
        carl.close()
        push = a.wait("wd:event", lambda e: isinstance(e, dict) and e.get("ev") == "players.changed"
                      and len(e["data"]["players"]) == 2, 5, m)
        check(push is not None and sorted(p["name"] for p in push["data"]["players"]) == ["Alice", "Bob"],
              "the kick's leave was pushed", push)

        info("--- notice push ---")
        m = b.mark()
        a.request("mod.warn", {"pid": bob.id, "reason": "seatbelt"})
        notices = b.events("notice", m)
        check(len(notices) == 1 and notices[0]["code"] == "you.warned" and "seatbelt" in notices[0]["text"],
              "Bob's panel got the notice", notices)

        info("--- groups ---")
        r = a.request("groups.list")
        check(r.get("ok") is True and [g["name"] for g in r["data"]["groups"]] == ["default", "trusted", "mod", "admin",
                                                                                   "owner"], "groups.list", r)
        r = a.request("groups.save", {"group": {"name": "vip", "level": 20}})
        check(err_code(r) == "denied" and r["error"]["params"]["perm"] == "perms.manage", "perms.manage is the owner's")
        # the hoster grants it: edit groups.json on disk, warden reloads it
        path = os.path.join(srv.resource_home, "data", "groups.json")
        with open(path, encoding="utf-8") as f:
            groups = json.load(f)
        groups["admin"]["perms"].append("perms.manage")
        time.sleep(3.2)  # past the store's own-write window
        with open(path, "w", encoding="utf-8") as f:
            json.dump(groups, f)
        check(srv.wait_log(r"groups\.json changed on disk, reloaded", 5) is not None, "the edit was picked up")
        m = a.mark()
        r = a.request("groups.save", {"group": {"name": "vip", "level": 20, "inherits": ["trusted"],
                                                 "perms": ["mod.warn"], "caps": {"vehicles": 4}}})
        check(r.get("ok") is True and r["data"]["group"]["caps"]["vehicles"] == 4, "groups.save", r)
        pushes = a.events("groups.changed", m)
        check(len(pushes) >= 1 and any(g["name"] == "vip" for g in pushes[-1]["groups"]), "groups.changed pushed", pushes)
        r = a.request("groups.save", {"group": {"name": "vip", "level": 20, "perms": ["server.reload"]}})
        check(err_code(r) == "perm_not_yours", "cannot grant what you lack", r)
        r = a.request("groups.save", {"group": {"name": "vip", "level": 20, "inherits": ["owner"]}})
        check(err_code(r) == "group_too_high" and r["error"]["params"]["group"] == "owner",
              "nor inherit from a group at or above your level (the review's escalation)", r)
        r = a.request("groups.save", {"group": {"name": "vip", "level": 20, "inherits": ["admin"]}})
        check(err_code(r) == "group_too_high", "admin is at the actor's own level", r)
        r = a.request("groups.list")
        vip = [g for g in r["data"]["groups"] if g["name"] == "vip"][0]
        check(vip["inherits"] == ["trusted"] and vip["perms"] == ["mod.warn"], "vip is as it was saved", vip)
        r = a.request("groups.delete", {"name": "vip"})
        check(r.get("ok") is True, "groups.delete", r)
        r = a.request("groups.delete", {"name": "owner"})
        check(err_code(r) == "group_too_high", "owner is above an admin", r)
        r = a.request("groups.delete", {"name": "default"})
        check(err_code(r) == "protected", "default is protected", r)

        info("--- settings ---")
        r = b.request("settings.list")
        check(err_code(r) == "denied", "settings.read", r)
        r = a.request("settings.list")
        keys = [s["key"] for s in r.get("data", {}).get("settings", [])]
        check("votekick.threshold" in keys and "ui.key" not in keys, "the runtime keys", keys)
        m = a.mark()
        r = a.request("settings.set", {"key": "votekick.threshold", "value": 0.75})
        check(r.get("ok") is True and r["data"]["value"] == 0.75, "settings.set", r)
        pushes = a.events("settings.changed", m)
        check(pushes and pushes[-1]["key"] == "votekick.threshold" and pushes[-1]["value"] == 0.75,
              "settings.changed pushed to the subscriber", pushes)
        r = a.request("settings.set", {"key": "votekick.threshold", "value": 3})
        check(err_code(r) == "bad_value", "bounds", r)
        r = a.request("settings.reset", {"key": "votekick.threshold"})
        check(r.get("ok") is True and r["data"]["value"] == 0.6, "settings.reset", r)
        r = a.request("audit.tail", {"limit": 5})
        check(r.get("ok") is True and len(r["data"]["rows"]) == 5 and r["data"]["rows"][0]["op"] == "settings_reset",
              "audit.tail", r)

        info("--- the bus API from another resource ---")
        alice.emit("asker:ask", {"tag": "t1", "perm": "mod.kick"})
        check(srv.wait_log(r'asker got group: .*"group":"admin"', 5) is not None, "warden:getGroup answered")
        check(srv.wait_log(r'asker got perm: .*"ok":true', 5) is not None, "warden:hasPerm answered")
        check(srv.wait_log(r'asker saw groupChanged: .*"group":"mod"', 2) is not None, "groupChanged was published")
        check(srv.wait_log(r'asker saw ready', 2) is not None, "warden:ready was published")
        bob.emit("asker:ask", {"tag": "t2", "perm": "mod.kick"})
        check(srv.wait_log(r'asker got perm: .*"ok":false.*"tag":"t2"|asker got perm: .*"tag":"t2".*"ok":false', 5)
              is not None, "a default player has no mod.kick")

        info("--- the limiter ---")
        with Server(PORT + 1, name="limits", config={"limits": {"ui_per_sec": 2}}) as lim:
            zed = Client.join(PORT + 1, name="Zed", source=ALICE)
            z = Inbox(zed)
            ids = [z.send("me.get") for _ in range(5)]
            time.sleep(0.5)
            z.pump(0.5)
            answered = [r_ for r_ in z.all("wd:reply") if r_.get("id") in ids]
            check(len(answered) == 2, "2 of 5 frames in one second were answered", len(answered))
            check(lim.wait_log(r"over the limit", 3) is not None, "one log line about it")
            zed.close()

        check(srv.lua_errors() == [], "no Lua errors", srv.lua_errors())
        alice.close()
        bob.close()
    return result()


if __name__ == "__main__":
    sys.exit(main())
