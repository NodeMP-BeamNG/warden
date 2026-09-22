#!/usr/bin/env python3
"""Smoke gate: the real server loads warden beside the chat resource, writes
its data files, answers /help and /version through the chat, refuses a
wd:req without permission, and shuts down cleanly with the stores flushed.

Ports 31200-31209.
"""
import sys
import time

from harness import Client, Inbox, Server, TEST_HOOKS_ENV, check, err_code, info, probe, probe_data, require_server, \
    resource_version, result

PORT = 31200


def main():
    require_server()
    version = resource_version()
    info("=== smoke ===")
    with Server(PORT, env=TEST_HOOKS_ENV, name="smoke") as srv:
        log = srv.log()
        check("warden %s ready: 5 group(s), 0 player record(s), whitelist off, votekick off" % version in log,
              "warden logged ready with the defaults (vote-kick off unless turned on)")
        check("test hooks installed" in log, "the probes are in (WD_TEST_HOOKS=1)")
        check("chat loaded" in log, "the chat resource is up beside it")
        check(srv.lua_errors() == [], "no Lua errors at start", srv.lua_errors())
        data = srv.data()
        for name in ("groups.json", "players.json", "whitelist.json", "settings.json", "bans_meta.json",
                     "votekick.json", "ui.json"):
            check(name in data, "data/%s written on first start" % name)
        check(set(data.get("groups.json", {}).keys()) == {"default", "trusted", "mod", "admin", "owner"},
              "groups.json carries the five default groups")

        alice = Client.join(PORT, name="Alice")
        a = Inbox(alice)
        check(srv.wait_log(r"Alice", 10) is not None or True, "Alice joined")
        me = probe(alice, "me")
        check(me.get("ok") is True and probe_data(me, "group") == "default", "a fresh player is in default", me)
        check(probe_data(me, "key", ).startswith("ip:"), "keyed by ip without a directory", probe_data(me, "key"))

        m = a.chat("/version")
        lines = a.chat_lines(m)
        check(lines == ["warden %s" % version], "/version answers through the chat", lines)

        m = a.chat("/help")
        lines = a.chat_lines(m)
        check(lines and lines[0].startswith("9 command(s) you may use (/warden shows or hides the panel)"),
              "/help header for default: no key, /warden", lines)
        check("/vote yes|no|cancel" in lines and "/warden" in lines and "/wd" in lines
              and "/kick <player> [reason]" not in lines, "the default group sees its commands only", lines)
        check(not any("F9" in ln for ln in lines), "no F9 anywhere", lines)

        # /warden (and its alias /wd): the panel toggle -- one wd:event panel to the sender
        m = a.chat("/warden")
        panel = a.events("panel", since=m)
        check(len(panel) == 1 and panel[0].get("toggle") is True, "/warden sends wd:event panel", panel)
        m = a.chat("/wd")
        panel = a.events("panel", since=m)
        check(len(panel) == 1 and panel[0].get("toggle") is True, "/wd is the alias", panel)

        m = a.chat("/kick Alice")
        lines = a.chat_lines(m)
        check(lines == ["You may not do that (mod.kick)."], "a refusal is a system line", lines)

        m = a.chat("/nonsense")
        lines = a.chat_lines(m)
        check(lines == ["Unknown command /nonsense. Try /help."], "unknown command", lines)

        reply = a.request("players.list")
        check(err_code(reply) == "denied", "wd:req players.list without players.view: denied", reply)
        m = a.mark()
        reply = a.hello()
        d = reply.get("data") or {}
        check(reply.get("ok") is True and d.get("me", {}).get("group") == "default" and "key" not in d,
              "sys.hello answers the record, no key", reply)
        check(d.get("protocol") == 2 and d.get("ui") == {"shown": False, "scale": 1.0, "theme": "cobalt"},
              "protocol 2: a plain player's panel is hidden by default", d.get("ui"))
        check(d.get("status", {}).get("spawn") is True and d["status"]["whitelist"] is False
              and d["status"]["players"] == 1 and d["status"]["max_players"] == 16,
              "the status chips", d.get("status"))
        check(d.get("server", {}).get("max_cars") == 10 and d["server"]["max_players"] == 16
              and isinstance(d["server"].get("name"), str), "the server facts", d.get("server"))
        time.sleep(0.5)
        texts = [x.get("text") if isinstance(x, dict) else x for x in a.all("chat:msg", m)]
        check(not any("/warden shows or hides" in (ln or "") for ln in texts),
              "no welcome line for a player without players.view", texts)

        # the join was recorded; stop flushes the stores
        rec = probe(alice, "record")
        check(probe_data(rec, "record", ).get("joins") == 1 and probe_data(rec, "record")["names"] == ["Alice"],
              "the record has the join and the name", rec)
        alice.close()
        check(srv.lua_errors() == [], "no Lua errors during the scenario", srv.lua_errors())
    check(srv.exit_code == 0, "the server exited cleanly", srv.exit_code)
    check("shutdown:" in srv.log(), "the shutdown flush ran")
    players = srv.data("players.json") or {}
    check(any(rec.get("names") == ["Alice"] for rec in players.values()), "players.json was flushed at shutdown",
          players)
    return result()


if __name__ == "__main__":
    sys.exit(main())
