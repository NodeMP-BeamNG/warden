#!/usr/bin/env python3
"""One fake launcher client for every test that needs a joined session.

Forty tests used to carry their own `class Client`, about 3200 lines of the
same handshake, the same `wait`/`drain`/`ask` and the same spawn helper. They
were not identical, and the differences were the expensive part: a couple of
them did not retry when the server answered "still starting", and those were
exactly the tests that failed inside a full sweep and passed on their own.

The split from the other two shared modules is deliberate. `wire.py` owns the
codec -- what a packet looks like on the wire, generated from Protocol.h.
`servertest.py` owns the process -- starting a server and tearing it down.
This owns the session: what a launcher does between TLS and gameplay, so that
a test can say what it is testing instead of restating the join.

A test that needs something genuinely unusual -- malformed frames, a partial
handshake, a corrupt MAC -- should keep its own client. Bending this one to
cover adversarial traffic would make it unreadable for the majority that just
wants to join and send an event.
"""
from __future__ import annotations

import socket
import time

import wire
from wire import (Content, Event, Handshake, Module, Reader, Session, Vehicle,
                  Writer)

HOST = "127.0.0.1"

# Everything a dead or half-open socket can raise, plus a protocol refusal.
# ConnectionError, socket.timeout and TimeoutError are all OSError subclasses.
LOST = (wire.WireError, OSError)


def parse_event(sub, body):
    """(event name, payload bytes) for an EVENT frame, (None, None) otherwise.

    Every test filters relayed events this way, so it lives here rather than
    being copied into each one.
    """
    if sub is not Event.EVENT:
        return None, None
    r = Reader(body)
    return r.str16().decode(), r.tail()


class Client:
    """A joined session: TLS, the full handshake, and optionally a UDP endpoint.

    `hint` names the client in assertion messages, which is what makes a
    failure in a four-client test readable. `port` is per-test by convention
    (harness_test enforces it), so it is always passed explicitly.
    """

    def __init__(self, port, hint="client", name="", host=HOST, udp=False,
                 ready_timeout=30.0, connect_timeout=10.0, join_budget=5.0, ticket="",
                 source=None):
        self.port = port
        self.host = host
        self.hint = hint
        # The local address to come from. None is the ordinary case; a load
        # bench spreads its clients over 127.0.0.x to get past the server's
        # per-IP connection cap.
        self.source = source
        self.udp = None
        self.token = None
        self.seq = 0
        self.last_claim = 0
        self._claim_id = 0

        self.ticket = ticket  # v17 directory join ticket; "" = none (a direct connect)
        self.tcp = self._connect(name, ready_timeout, connect_timeout)
        self._join(join_budget)
        self.name = name or f"Player{self.id}"
        if udp:
            self.udp_bind()

    # -- connect and join ---------------------------------------------------

    def _connect(self, name, ready_timeout, connect_timeout):
        """TLS + HELLO, retried until the server is ready or the budget ends.

        A server that has bound its port but not finished loading holds the
        handshake open now instead of kicking, so the retry is here for the
        older behaviour: a test pointed at a server from before that change
        should still pass rather than fail on a race it cannot control.
        """
        deadline = time.monotonic() + ready_timeout
        last = ""
        while True:
            tcp = None
            try:
                tcp = wire.tls_connect(self.host, self.port, timeout=connect_timeout,
                                       source=self.source)
                self.id = wire.hello(tcp, name, ticket=self.ticket)
                return tcp
            except LOST as e:
                # Closed here rather than left to the collector: a refused
                # attempt still holds one of the server's per-IP connection
                # slots until its socket goes away.
                if tcp is not None:
                    tcp.close()
                last = repr(e)
                if time.monotonic() > deadline:
                    raise RuntimeError(
                        f"{self.hint}: server did not become ready: {last}") from e
                time.sleep(0.3)

    def _join(self, budget):
        """ModsRequest -> ModsInfo -> SyncDone -> UdpToken -> MapInfo ->
        JoinWorld -> SelfInfo, the sequence the launcher performs."""
        wire.send_packet(self.tcp, Content.MODS_REQUEST)
        sub, _ = wire.recv_packet(self.tcp)
        assert sub is Content.MODS_INFO, f"{self.hint}: no MODS_INFO, got {sub!r}"
        wire.send_packet(self.tcp, Content.SYNC_DONE)
        sub, token = wire.recv_packet(self.tcp)
        assert sub is Handshake.UDP_TOKEN and len(token) == 64, \
            f"{self.hint}: bad UDP_TOKEN, got {sub!r} ({len(token)} B)"
        self.token = token
        sub, _ = wire.recv_packet(self.tcp)
        assert sub is Handshake.MAP_INFO, f"{self.hint}: no MAP_INFO, got {sub!r}"
        wire.send_packet(self.tcp, Handshake.JOIN_WORLD)
        assert self.wait(lambda t, b: t is Session.SELF_INFO, budget) != (None, None), \
            f"{self.hint}: no SELF_INFO sync frame"

    # -- TCP ----------------------------------------------------------------

    def send(self, subtype, body=b"", compress=False):
        """Sends one framed packet on the session socket."""
        wire.send_packet(self.tcp, subtype, body, compress)

    def wait(self, predicate, budget, collected=None):
        """The first frame matching `predicate`, or (None, None) at the budget.

        Frames that do not match are consumed; pass `collected` to keep them.
        """
        end = time.monotonic() + budget
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                return None, None
            self.tcp.settimeout(remaining)
            try:
                sub, body = wire.recv_packet(self.tcp)
            except LOST:
                return None, None
            if collected is not None:
                collected.append((sub, body))
            if predicate(sub, body):
                return sub, body

    def drain(self, budget):
        """Every frame that arrives within the budget."""
        frames = []
        self.wait(lambda t, b: False, budget, frames)
        return frames

    # -- events -------------------------------------------------------------

    def send_event(self, event, data=b""):
        """Fires an EVENT at the server without waiting for anything back."""
        if isinstance(data, str):
            data = data.encode()
        self.send(Event.EVENT, Writer().str16(event).tail(data).body)

    def ask(self, event, reply_name, data=b"", budget=15, collect=None):
        """Sends EVENT{event} and returns the payload of the first
        EVENT{reply_name}, or None if none arrives within the budget.

        The budget is a ceiling, not a delay: a healthy round trip returns in
        milliseconds and pays none of it. It is generous because a script
        handler answers from the language worker's queue, and a machine
        running the whole suite can leave that queue seconds deep -- a
        tighter bound fails the test for being busy rather than for being
        wrong, and no caller here treats a missing reply as a pass.

        `collect`, when given a list, keeps every frame seen on the way to
        the reply. Anything the handler sent BEFORE answering -- a broadcast
        it triggered, an event it fired -- arrives first and would otherwise
        be consumed and lost here.
        """
        self.send_event(event, data)
        got = self.wait(lambda t, b: parse_event(t, b)[0] == reply_name, budget, collect)
        if got == (None, None):
            return None
        return parse_event(*got)[1].decode()

    def ask_all(self, event, reply_name, data=b"", budget=3):
        """Every EVENT{reply_name} payload arriving within the budget.

        For handlers that answer more than once -- a reload test counts the
        replies to tell "registered twice" from "registered once".
        """
        self.send_event(event, data)
        answers = []
        for sub, body in self.drain(budget):
            name, payload = parse_event(sub, body)
            if name == reply_name:
                answers.append(payload.decode())
        return answers

    def send_module(self, channel, payload):
        """Sends a module-channel message to the native module on `channel`."""
        self.send(Module.DATA, Writer().u32(channel).tail(payload).body)

    # -- vehicles -----------------------------------------------------------

    def spawn(self, car_json, budget=5):
        """Requests a spawn and returns the global id the server assigned,
        or -1 if no Spawn for this client arrived within the budget."""
        self.send(Vehicle.SPAWN_REQ, Writer().u32(0).tail(car_json).body)

        def mine(t, b):
            if t is not Vehicle.SPAWN:
                return False
            r = Reader(b)
            r.u32()
            return r.u32() == self.id

        got = self.wait(mine, budget)
        return Reader(got[1]).u32() if got != (None, None) else -1

    def send_claim(self, gid, kind):
        """Sends a SeatClaim and returns its claim id without waiting.

        Separate from `claim` because a test that races two clients for one
        seat has to get both claims out before either verdict comes back.
        """
        self._claim_id += 1
        self.last_claim = self._claim_id
        self.send(Vehicle.SEAT_CLAIM, Writer().u32(gid).u8(int(kind)).u32(self._claim_id).body)
        return self._claim_id

    def wait_verdict(self, gid, claim_id, budget=5):
        """The SeatVerdict result byte for one claim, or None at the budget."""
        def mine(t, b):
            if t is not Vehicle.SEAT_VERDICT:
                return False
            r = Reader(b)
            return r.u32() == gid and r.u32() == claim_id

        got = self.wait(mine, budget)
        if got == (None, None):
            return None
        r = Reader(got[1])
        r.u32()
        r.u32()
        return r.u8()

    def claim(self, gid, kind, budget=5):
        """Claims a seat and returns the verdict result byte."""
        return self.wait_verdict(gid, self.send_claim(gid, kind), budget)

    def leave(self, gid, budget=5):
        """Leaves a seat and returns the verdict result byte."""
        return self.claim(gid, wire.SeatClaimKind.LEAVE, budget)

    # -- UDP ----------------------------------------------------------------

    def udp_bind(self, settle=0.3):
        """Registers a UDP endpoint for this session (the v10 HMAC UdpHello).

        Deferred rather than done at join time for tests that check what the
        server does with a session that has no UDP endpoint yet. `settle` is
        the pause that lets the registration land before anything relies on
        it, since UdpHello has no acknowledgement.
        """
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if self.source:
            self.udp.bind((self.source, 0))
        self.udp.settimeout(3)
        wire.udp_hello(self.udp, (self.host, self.port), self.id, self.token)
        if settle:
            time.sleep(settle)
        return self.udp

    def send_udp(self, subtype, body=b""):
        """Sends a client -> server datagram with the v10 auth trailer."""
        self.seq += 1
        self.udp.sendto(
            wire.encode_client_datagram_authed(subtype, self.id, self.seq, self.token, body),
            (self.host, self.port))

    def wait_udp(self, predicate, budget):
        """The first datagram matching `predicate`, or (None, None)."""
        end = time.monotonic() + budget
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                return None, None
            self.udp.settimeout(remaining)
            try:
                data, _ = self.udp.recvfrom(wire.MAX_UDP_DATAGRAM)
            except LOST:
                return None, None
            try:
                sub, flags, body = wire.decode_datagram(data)
            except wire.WireError:
                continue
            if flags & wire.FLAG_COMPRESSED:
                body = wire.decompress_body(body)
            if predicate(sub, body):
                return sub, body

    def drain_udp(self, budget):
        """Every datagram that arrives within the budget."""
        frames = []
        end = time.monotonic() + budget
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                return frames
            self.udp.settimeout(remaining)
            try:
                data, _ = self.udp.recvfrom(wire.MAX_UDP_DATAGRAM)
            except LOST:
                return frames
            try:
                sub, flags, body = wire.decode_datagram(data)
            except wire.WireError:
                continue
            if flags & wire.FLAG_COMPRESSED:
                body = wire.decompress_body(body)
            frames.append((sub, body))

    def close(self):
        try:
            self.tcp.close()
        finally:
            if self.udp is not None:
                self.udp.close()
