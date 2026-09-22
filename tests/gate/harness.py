#!/usr/bin/env python3
"""Gate harness: a real Node-Server running the warden resource beside the
`chat` example resource, and fake clients that join, type chat lines and
send wd:req frames.

    from harness import *

    with Server(PORT, env=TEST_HOOKS_ENV) as srv:
        alice = Client.join(PORT, name="Alice")
        a = Inbox(alice)
        a.chat("/help")
        lines = a.chat_lines()
        reply = a.request("players.list")
        probe(alice, "group.set", {"pid": alice.id, "group": "admin"})   # tests/gate/hooks/dev/test_hooks.lua

Environment:
    WD_SERVER_BIN   the Node-Server binary (default: ./.server/Node-Server[.exe]; tools/get-server.*
                    downloads and verifies it)
    WD_KEEP_TMP=1   keep the scratch homes under tests/gate/_tmp/ (CI uploads server.log)

Every server gets its own home under tests/gate/_tmp/<name>_<port>/ with a
copy of resources/warden/ (with [config] overrides applied) and a copy of the
chat resource (the server archive's examples/chat, else ../examples/chat),
and runs with NODE_OBFUSCATE=false and NODE_VERIFY_GAME=off. Ports are per
test file (31200-31299, a block of ten each) so a sweep never collides.

Without a directory every player is unverified (keyed by IP), so the tests
put players into groups through the test hooks (WD_TEST_HOOKS=1), never
through owner_ids.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LIB = os.path.join(HERE, "lib")
if LIB not in sys.path:
    sys.path.insert(0, LIB)

import tomllib  # noqa: E402  (Python 3.11+)

import testclient  # noqa: E402
import wire  # noqa: E402
from wire import Handshake, Session, Writer  # noqa: E402

RESOURCE_DIR = os.path.join(ROOT, "resources", "warden")
HOOKS_DIR = os.path.join(HERE, "hooks")
TMP = os.path.join(HERE, "_tmp")
HOST = "127.0.0.1"
KEEP_TMP = os.environ.get("WD_KEEP_TMP", "") not in ("", "0", "false", "no")
GRACEFUL_STOP_TIMEOUT = 5.0
TEST_HOOKS_ENV = {"WD_TEST_HOOKS": "1"}

LOST = testclient.LOST


# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------

_failed = 0
_passed = 0


def check(cond, name, detail=""):
    global _failed, _passed
    print(("[PASS] " if cond else "[FAIL] ") + name + ((" - " + str(detail)) if detail else ""), flush=True)
    if cond:
        _passed += 1
    else:
        _failed += 1
    return bool(cond)


def info(text):
    print("[INFO] " + text, flush=True)


def result():
    print("RESULT: %s (%d passed, %d failed)" % ("SUCCESS" if _failed == 0 else "FAILURE", _passed, _failed),
          flush=True)
    return 0 if _failed == 0 else 1


def wait_for(predicate, budget, step=0.1):
    end = time.monotonic() + budget
    while True:
        value = predicate()
        if value or time.monotonic() >= end:
            return value
        time.sleep(step)


def lang(code, language="en"):
    """The shipped text of a dictionary code."""
    with open(os.path.join(RESOURCE_DIR, "lang", language + ".json"), encoding="utf-8") as f:
        return json.load(f)[code]


# ---------------------------------------------------------------------------
# the server binary and the chat resource
# ---------------------------------------------------------------------------

def server_binary():
    candidates = []
    env = os.environ.get("WD_SERVER_BIN")
    if env:
        candidates.append(os.path.abspath(env))
    candidates += [
        os.path.join(ROOT, ".server", "Node-Server.exe"),
        os.path.join(ROOT, ".server", "Node-Server"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c, candidates
    return None, candidates


def require_server():
    exe, looked = server_binary()
    if exe is None:
        print("ERROR: no Node-Server binary; run tools/get-server.ps1 (or .sh) or set WD_SERVER_BIN. Looked at:\n  "
              + "\n  ".join(looked))
        print("RESULT: FAILURE")
        sys.exit(1)
    return exe


def chat_resource_dir(exe):
    """The chat example resource: shipped in the server archive's examples/,
    else the examples checkout beside this repository."""
    candidates = [
        os.path.join(os.path.dirname(exe), "examples", "chat"),
        os.path.join(os.path.dirname(ROOT), "examples", "chat"),
    ]
    for c in candidates:
        if os.path.isfile(os.path.join(c, "server", "main.lua")):
            return c
    return None


# ---------------------------------------------------------------------------
# ports
# ---------------------------------------------------------------------------

def _can_bind(port, kind):
    s = socket.socket(socket.AF_INET, kind)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def wait_listening(port, deadline, host=HOST):
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def wait_free(port, deadline):
    while time.monotonic() < deadline:
        if _can_bind(port, socket.SOCK_STREAM) and _can_bind(port, socket.SOCK_DGRAM):
            return True
        time.sleep(0.2)
    return False


# ---------------------------------------------------------------------------
# resource.toml [config] overrides
# ---------------------------------------------------------------------------

def _toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    raise TypeError("cannot write %r to TOML" % (v,))


def _toml_key(k):
    return k if re.match(r"^[A-Za-z0-9_-]+$", k) else json.dumps(k)


def _toml_table(name, table, out):
    scalars = {k: v for k, v in table.items() if not isinstance(v, dict)}
    subs = {k: v for k, v in table.items() if isinstance(v, dict)}
    if scalars or not subs:
        out.append("[%s]" % name if name else "")
        for k, v in scalars.items():
            out.append("%s = %s" % (_toml_key(k), _toml_value(v)))
        out.append("")
    for k, v in subs.items():
        _toml_table((name + "." if name else "") + _toml_key(k), v, out)


def _deep_merge(base, over):
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def patch_manifest(path, overrides):
    """Rewrites resource.toml with `overrides` (nested dict or dotted keys) merged into [config]."""
    with open(path, "rb") as f:
        data = tomllib.load(f)
    config = data.get("config", {})
    for key, value in overrides.items():
        if isinstance(key, str) and "." in key and not isinstance(value, dict):
            cur = config
            parts = key.split(".")
            for p in parts[:-1]:
                cur = cur.setdefault(p, {})
            cur[parts[-1]] = value
        else:
            _deep_merge(config, {key: value})
    data["config"] = config
    out = []
    for k, v in data.items():
        if not isinstance(v, dict):
            out.append("%s = %s" % (_toml_key(k), _toml_value(v)))
    out.append("")
    for k, v in data.items():
        if isinstance(v, dict):
            _toml_table(_toml_key(k), v, out)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out).rstrip() + "\n")


def resource_version():
    with open(os.path.join(RESOURCE_DIR, "resource.toml"), "rb") as f:
        return tomllib.load(f).get("version")


# ---------------------------------------------------------------------------
# the server
# ---------------------------------------------------------------------------

class Server:
    """A Node-Server with warden and chat, for the duration of a `with` block.

    port      the server's TCP/UDP port (per test)
    env       extra environment (WD_TEST_HOOKS=1 copies the probes in)
    config    [config] overrides for the scratch copy of resource.toml
    wait_for  the log text to wait for ("ready:" of warden by default)
    name      the scratch home is tests/gate/_tmp/<name>_<port>
    """

    def __init__(self, port, env=None, config=None, wait_for="warden %s ready" % resource_version(),
                 ready_timeout=60.0, name="server", exe=None, chat=True):
        self.port = port
        self.extra_env = dict(env or {})
        self.hooks = self.extra_env.get("WD_TEST_HOOKS") == "1"
        self.config = config
        self.wait_for_text = wait_for
        self.ready_timeout = ready_timeout
        self.name = name
        self.exe = exe or require_server()
        self.chat = chat
        self.home = os.path.join(TMP, "%s_%d" % (name, port))
        self.log_path = os.path.join(self.home, "server.log")
        self.proc = None
        self._log = None
        self._final_log = None
        self.exit_code = None

    @property
    def resource_home(self):
        return os.path.join(self.home, "resources", "warden")

    def _prepare_home(self):
        shutil.rmtree(self.home, ignore_errors=True)
        os.makedirs(os.path.join(self.home, "resources"))
        os.makedirs(os.path.join(self.home, "content"))
        dest = self.resource_home
        shutil.copytree(RESOURCE_DIR, dest, ignore=shutil.ignore_patterns(".obfcache", "__pycache__", "data"))
        if self.hooks:
            shutil.copytree(HOOKS_DIR, os.path.join(dest, "server"), dirs_exist_ok=True)
        if self.config:
            patch_manifest(os.path.join(dest, "resource.toml"), self.config)
        if self.chat:
            src = chat_resource_dir(self.exe)
            if src is None:
                raise RuntimeError("no chat example resource beside the server binary or under ../examples/chat")
            shutil.copytree(src, os.path.join(self.home, "resources", "chat"))

    def environment(self):
        env = dict(os.environ)
        env.pop("NODE_TEST_PORT", None)
        env["NODE_PORT"] = str(self.port)
        env["NODE_OBFUSCATE"] = "false"
        env["NODE_VERIFY_GAME"] = "off"
        env["NODE_NAME"] = "warden gate " + self.name
        # the server's own per-player car limit is 1 by default; warden's caps
        # are what the gates test, so the server's must not be the tighter one
        env["NODE_MAX_CARS"] = "10"
        env["NODE_MAX_PLAYERS"] = "16"
        env.setdefault("NODE_DEBUG", "false")
        for name in ("NODE_DATABASE_URL", "NODE_DB_URL", "NODE_DB_DEFAULT_URL"):
            env[name] = ""
        env.update(self.extra_env)
        return env

    def __enter__(self):
        if not wait_free(self.port, time.monotonic() + 15):
            raise RuntimeError("port %d is still taken" % self.port)
        self._prepare_home()
        self._final_log = None
        self.exit_code = None
        self._log = open(self.log_path, "w", encoding="utf-8")
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        self.proc = subprocess.Popen(
            [self.exe], cwd=self.home, env=self.environment(), stdout=self._log,
            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=flags)
        if not wait_listening(self.port, time.monotonic() + 30):
            why = self.why_not_up()
            self.__exit__(None, None, None)
            raise RuntimeError("server did not start listening on %d: %s" % (self.port, why))
        if self.wait_for_text:
            if not self.wait_log(re.escape(self.wait_for_text), self.ready_timeout):
                why = self.why_not_up()
                self.__exit__(None, None, None)
                raise RuntimeError("server never logged %r: %s" % (self.wait_for_text, why))
        return self

    def __exit__(self, *exc):
        self.stop()
        return False

    def stop(self, graceful=True, timeout=GRACEFUL_STOP_TIMEOUT):
        """Asks the server to exit cleanly (serverShutdown runs: SIGTERM on
        Linux, Ctrl-Break on Windows) and kills it after `timeout` seconds."""
        if self.proc is not None:
            if graceful and self.proc.poll() is None:
                try:
                    if hasattr(signal, "CTRL_BREAK_EVENT"):
                        self.proc.send_signal(signal.CTRL_BREAK_EVENT)
                    else:
                        self.proc.terminate()
                    self.proc.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    info("server %s did not exit within %.0fs; killing it" % (self.name, timeout))
                except Exception:
                    pass
            killed = False
            if self.proc.poll() is None:
                killed = True
                try:
                    self.proc.kill()
                    self.proc.wait(timeout=10)
                except Exception:
                    pass
            self.exit_code = None if killed else self.proc.poll()
            self.proc = None
        if self._log is not None:
            self._log.close()
            self._log = None
        self._final_log = self._read_log_file()
        self._final_data = self._read_data()
        if not KEEP_TMP:
            shutil.rmtree(self.home, ignore_errors=True)
        time.sleep(0.5)
        return self.exit_code

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def _read_log_file(self):
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    def _read_data(self):
        """Every data/*.json (and audit file) of the scratch resource, decoded."""
        out = {}
        base = os.path.join(self.resource_home, "data")
        for dirpath, _, files in os.walk(base):
            for name in files:
                rel = os.path.relpath(os.path.join(dirpath, name), base).replace("\\", "/")
                try:
                    with open(os.path.join(dirpath, name), encoding="utf-8") as f:
                        text = f.read()
                except OSError:
                    continue
                if name.endswith(".json"):
                    try:
                        out[rel] = json.loads(text)
                    except ValueError:
                        out[rel] = text
                else:
                    out[rel] = text
        return out

    def data(self, rel=None):
        """The resource's data files (live, or as they were at stop())."""
        files = self._final_data if getattr(self, "_final_data", None) is not None and self.proc is None \
            else self._read_data()
        return files if rel is None else files.get(rel)

    def log(self):
        if self._final_log is not None:
            return self._final_log
        return self._read_log_file()

    def wait_log(self, pattern, timeout=10.0):
        rx = re.compile(pattern, re.M)
        return wait_for(lambda: rx.search(self.log()), timeout)

    def lua_errors(self):
        """Lines the server logged about Lua errors in any resource."""
        rx = re.compile(r"\berror in .+?:|stack traceback|attempt to ", re.I)
        return [ln.strip() for ln in self.log().splitlines() if rx.search(ln)]

    def why_not_up(self):
        bits = []
        code = self.proc.poll() if self.proc is not None else None
        bits.append("the process is still running" if code is None else "the process exited with %d" % code)
        tail = [ln.strip() for ln in self.log().splitlines() if ln.strip()][-5:]
        bits.append("last log: " + " | ".join(tail) if tail else "no log at " + self.log_path)
        return "; ".join(bits)


# ---------------------------------------------------------------------------
# clients
# ---------------------------------------------------------------------------

def parse_event(sub, body):
    return testclient.parse_event(sub, body)


class Client:
    """A joined fake client."""

    def __init__(self, inner):
        self.inner = inner

    @staticmethod
    def join(port, name="", hint=None, udp=False, ready_timeout=30.0, source=None):
        """`source` is the local address to come from: 127.0.0.2, 127.0.0.3, ...
        give every client its own ip and therefore its own warden record."""
        inner = testclient.Client(port, hint or (name or "client"), name=name, udp=udp, ready_timeout=ready_timeout,
                                  source=source)
        return Client(inner)

    @staticmethod
    def try_join(port, name="", timeout=15.0, source=None):
        """HELLO + IDENTITY, then the server's first answer: ("welcome", id) or ("kick", reason)."""
        deadline = time.monotonic() + 30
        while True:
            try:
                s = wire.tls_connect(HOST, port, timeout=5, source=source)
                break
            except (OSError, wire.WireError):
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.3)
        try:
            w = Writer().u16(wire.PROTO_VERSION)
            if name:
                w = w.tail(name.encode())
            wire.send_packet(s, Handshake.HELLO, w.body)
            wire.send_packet(s, Handshake.IDENTITY, Writer().body)
            s.settimeout(timeout)
            sub, body = wire.recv_packet(s)
            if sub is Session.KICK:
                return "kick", body.decode(errors="replace")
            if sub is Handshake.WELCOME:
                return "welcome", wire.Reader(body).u32()
            return "other", repr((sub, body))
        finally:
            s.close()

    @property
    def id(self):
        return self.inner.id

    @property
    def name(self):
        return self.inner.name

    def emit(self, event, data=None):
        if data is None:
            payload = b""
        elif isinstance(data, (dict, list)):
            payload = json.dumps(data).encode()
        else:
            payload = data if isinstance(data, bytes) else str(data).encode()
        self.inner.send_event(event, payload)

    def chat(self, text):
        """Says a chat line the way the client mod does (the chat resource's wire event)."""
        self.emit("chat:send", {"text": text})

    def kicked(self, timeout=5.0):
        """The reason text of the KICK frame the server sent this client, or None."""
        try:
            sub, body = self.inner.wait(lambda t, b: t is Session.KICK, timeout)
        except LOST:
            return ""
        if sub is None:
            return None
        return body.decode(errors="replace")

    def close(self):
        self.inner.close()

    @staticmethod
    def _decode(payload):
        text = payload.decode(errors="replace") if isinstance(payload, bytes) else payload
        try:
            return json.loads(text)
        except (ValueError, TypeError):
            return text


class Inbox:
    """Reads a client's frames and keeps every wire event as (name, payload),
    so a test can wait for a reply and still see the pushes around it.

        a = Inbox(alice)
        m = a.chat("/kick Bob")            # a mark: what arrives from now on
        a.chat_lines(m)                    # the chat:msg texts since the mark
        reply = a.request("players.list")  # wd:req -> the wd:reply with that id
        a.events("vote.state", m)          # the wd:event payloads of that ev
    """

    _ids = [0]

    def __init__(self, client):
        self.client = client
        self.items = []
        self.frames = []
        self.claimed = set()

    def pump(self, budget=0.2):
        for sub, body in self.client.inner.drain(budget):
            name, payload = parse_event(sub, body)
            if name is not None:
                self.items.append((name, Client._decode(payload)))
            else:
                self.frames.append((sub, body))

    def wait(self, event, predicate=None, timeout=10.0, since=0):
        end = time.monotonic() + timeout
        while True:
            for i, (name, payload) in enumerate(self.items):
                if i < since or i in self.claimed or name != event:
                    continue
                if predicate is None or predicate(payload):
                    self.claimed.add(i)
                    return payload
            remaining = end - time.monotonic()
            if remaining <= 0:
                return None
            self.pump(min(0.25, remaining))

    def all(self, event=None, since=0):
        self.pump(0.05)
        return [p for n, p in self.items[since:] if event is None or n == event]

    def mark(self):
        self.pump(0.05)
        return len(self.items)

    def chat(self, text):
        m = self.mark()
        self.client.chat(text)
        return m

    def chat_lines(self, since=0, timeout=5.0, settle=0.4):
        """The chat:msg texts since the mark (waits for the first, then settles)."""
        self.wait("chat:msg", timeout=timeout, since=since)
        time.sleep(settle)
        return [m.get("text") if isinstance(m, dict) else m for m in self.all("chat:msg", since)]

    def events(self, ev=None, since=0, settle=0.3):
        time.sleep(settle)
        out = []
        for e in self.all("wd:event", since):
            if isinstance(e, dict) and (ev is None or e.get("ev") == ev):
                out.append(e.get("data"))
        return out

    def send(self, op, data=None, rid=None):
        if rid is None:
            Inbox._ids[0] += 1
            rid = Inbox._ids[0]
        msg = {"id": rid, "op": op}
        if data is not None:
            msg["data"] = data
        self.client.emit("wd:req", msg)
        return rid

    def request(self, op, data=None, rid=None, timeout=15.0):
        rid = self.send(op, data, rid)
        reply = self.wait("wd:reply", lambda r: isinstance(r, dict) and r.get("id") == rid, timeout)
        if reply is None:
            return {"id": rid, "ok": False, "error": {"code": "no_reply"}}
        return reply

    def hello(self, lang=None, protocol=1, ui_version="gate"):
        data = {"protocol": protocol, "uiVersion": ui_version}
        if lang is not None:
            data["lang"] = lang
        return self.request("sys.hello", data)


def err_code(reply):
    return ((reply or {}).get("error") or {}).get("code")


# ---------------------------------------------------------------------------
# test hooks (WD_TEST_HOOKS=1)
# ---------------------------------------------------------------------------

_probe_ids = [0]


def probe(client, what, args=None, budget=15):
    """One `wd:_test.query {id, what, args}` round trip, answered by
    tests/gate/hooks/dev/test_hooks.lua (only with env=TEST_HOOKS_ENV)."""
    _probe_ids[0] += 1
    qid = _probe_ids[0]
    raw = client.inner.ask("wd:_test.query", "wd:_test.reply",
                           json.dumps({"id": qid, "what": what, "args": args or {}}), budget=budget)
    if raw is None:
        return {"id": qid, "ok": False, "error": {"code": "no_reply"}}
    return json.loads(raw)


def probe_data(reply, key=None):
    d = reply.get("data") or {}
    return d if key is None else d.get(key)


__all__ = [
    "Client", "HOST", "Inbox", "LOST", "RESOURCE_DIR", "ROOT", "Server", "TEST_HOOKS_ENV", "check", "err_code", "info",
    "lang", "parse_event", "probe", "probe_data", "require_server", "resource_version", "result", "wait_for",
]
