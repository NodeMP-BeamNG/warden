#!/usr/bin/env python3
"""Node wire v1 -- the shared Python codec for every wire-speaking test.

This is the Python mirror of server/include/net/Protocol.h (C++, server +
launcher vendored pair) and client/lua/ge/extensions/MPNetworkHelpers.lua
(Lua). The three MUST agree byte-for-byte; parity is asserted against the
golden fixtures in docs/protocol_fixtures/ by wire_parity_test.py.

Frame formats
-------------
TCP frame (server session, relay channel, command channel):

    offset  size  field
    0       4     length    u32 LE = 3 + len(body)  (covers cat+sub+flags+body)
    4       1     category  Cat enum
    5       1     subtype   per-category *Packet enum
    6       1     flags     bit0 = FLAG_COMPRESSED, bits 1..7 reserved (must be 0)
    7       n     body      packet-specific fields

UDP datagram (launcher <-> server only):

    client -> server:  [u8 category][u8 subtype][u8 flags][u32 LE client_id][body]
    server -> client:  [u8 category][u8 subtype][u8 flags][body]

Field encoding rules: all integers little-endian; strings UTF-8 without NUL;
at most one variable-length field per packet and it is always last (tail,
length implied by the frame); a variable field that is not last carries a
u16 LE length prefix (str16); fixed-size arrays (keys, nonces, tokens) are
raw; booleans are u8 0/1. No ':' delimiter exists anywhere on the wire.

FLAG_COMPRESSED means the body is [u32 LE raw_size][one zstd frame] (wire
v14; v13 and older carried a bare zlib stream). raw_size is the exact
decompressed length, validated against the body cap BEFORE decompression
(launcher<->server hop only). TLS 1.3 wraps the launcher<->server TCP
connection below this framing (TOFU fingerprint pinning, decision D1) -- no
frame field carries TLS state.
"""

from __future__ import annotations

import enum
import hashlib
import socket
import ssl
import struct

try:
    from compression import zstd as _zstd  # Python 3.14+ stdlib
except ImportError:  # pragma: no cover
    import zstandard as _zstd  # pip install zstandard (same API surface used)

# The protocol taxonomy -- versions, categories, subtypes, body-field enums
# and size caps -- is GENERATED from server/include/net/Protocol.h by
# sdk/tools/wiregen.py. It used to be copied here by hand, and the copy fell
# behind: the fixtures sat a protocol version below the code, and UdpHello was
# still documented as the raw token it stopped being in version 10.
#
# Everything below this import is the CODEC, which is this file's own work:
# framing, compression, the reader and writer, the handshake helpers.
from wire_taxonomy import *  # noqa: F401,F403
from wire_taxonomy import (Cat, CATEGORY_OF, SUBTYPE_ENUM, PROTO_VERSION,
                           FLAG_COMPRESSED, FLAGS_RESERVED_MASK, MAX_BODY_CAP,
                           MAX_FRAME_LENGTH, MAX_UDP_DATAGRAM, PRE_AUTH_FRAME_CAP,
                           UDP_DATAGRAM_MAC_LEN, UDP_HELLO_MAC_LABEL,
                           UDP_HELLO_MAC_LEN, UDP_HELLO_NONCE_LEN,
                           UDP_SESSION_KEY_LEN)


class WireError(Exception):
    """A frame that does not obey the protocol."""


def _packet_id(subtype):
    """(category byte, subtype byte) for a member of any subtype enum."""
    cat = CATEGORY_OF.get(type(subtype))
    if cat is None:
        raise WireError(f"{type(subtype).__name__} is not a packet subtype enum")
    return int(cat), int(subtype)


def resolve(cat: int, sub: int):
    """The subtype enum member for one (category, subtype) pair.

    Subtype 0x00 is invalid in every category, which is what makes a zeroed
    buffer a protocol error rather than a packet.
    """
    try:
        enum_cls = SUBTYPE_ENUM[Cat(cat)]
    except ValueError:
        raise WireError(f"unknown category 0x{cat:02X}") from None
    try:
        return enum_cls(sub)
    except ValueError:
        raise WireError(f"unknown subtype 0x{sub:02X} in {enum_cls.__name__}") from None


class Writer:
    """Accumulates one packet body.

    w = Writer().u32(gid).str16(name).tail(config_json)
    frame = encode(Vehicle.SPAWN, w.body)

    tail() must be the final append; str16 caps at 64 KB.
    """

    def __init__(self):
        self._parts: list[bytes] = []
        self._sealed = False

    def _append(self, b: bytes) -> "Writer":
        if self._sealed:
            raise WireError("append after tail field")
        self._parts.append(b)
        return self

    def u8(self, v: int) -> "Writer":
        return self._append(struct.pack("<B", v))

    def u16(self, v: int) -> "Writer":
        return self._append(struct.pack("<H", v))

    def u32(self, v: int) -> "Writer":
        return self._append(struct.pack("<I", v))

    def i8(self, v: int) -> "Writer":
        return self._append(struct.pack("<b", v))

    def i32(self, v: int) -> "Writer":
        return self._append(struct.pack("<i", v))

    def u64(self, v: int) -> "Writer":
        return self._append(struct.pack("<Q", v))

    def f32(self, v: float) -> "Writer":
        """IEEE-754 binary32, little-endian (kinematic snapshot fields)."""
        return self._append(struct.pack("<f", v))

    def raw(self, b: bytes) -> "Writer":
        """Fixed-size byte array (key, nonce, token); no length prefix."""
        return self._append(bytes(b))

    def str16(self, s) -> "Writer":
        """u16 LE length prefix + bytes (variable field that is not last)."""
        b = s.encode() if isinstance(s, str) else bytes(s)
        if len(b) > 0xFFFF:
            raise WireError("str16 field exceeds 64 KB")
        return self._append(struct.pack("<H", len(b)) + b)

    def tail(self, s) -> "Writer":
        """The single unprefixed variable field; must be the last append."""
        b = s.encode() if isinstance(s, str) else bytes(s)
        self._append(b)
        self._sealed = True
        return self

    @property
    def body(self) -> bytes:
        return b"".join(self._parts)


class Reader:
    """Bounds-checked cursor over one received body.

    Every accessor raises WireError on overrun.
    """

    def __init__(self, body: bytes):
        self._body = body
        self._pos = 0

    def _need(self, n: int) -> bytes:
        if n > self.remaining:
            raise WireError("packet body truncated")
        b = self._body[self._pos:self._pos + n]
        self._pos += n
        return b

    def u8(self) -> int:
        return self._need(1)[0]

    def u16(self) -> int:
        return struct.unpack("<H", self._need(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self._need(4))[0]

    def i8(self) -> int:
        return struct.unpack("<b", self._need(1))[0]

    def i32(self) -> int:
        return struct.unpack("<i", self._need(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self._need(8))[0]

    def f32(self) -> float:
        """IEEE-754 binary32, little-endian."""
        return struct.unpack("<f", self._need(4))[0]

    def raw(self, n: int) -> bytes:
        return self._need(n)

    def str16(self) -> bytes:
        return self._need(self.u16())

    def tail(self) -> bytes:
        return self._need(self.remaining)

    @property
    def remaining(self) -> int:
        return len(self._body) - self._pos


# ---------------------------------------------------------------------------
# Frame / datagram encode-decode
# ---------------------------------------------------------------------------

def encode_payload(subtype, body: bytes = b"", flags: int = 0) -> bytes:
    """[cat][sub][flags][body] -- the length-covered part of a TCP frame."""
    cat, sub = _packet_id(subtype)
    return struct.pack("<BBB", cat, sub, flags) + body


def encode(subtype, body: bytes = b"", flags: int = 0) -> bytes:
    """One complete TCP frame: [u32 LE length][cat][sub][flags][body]."""
    payload = encode_payload(subtype, body, flags)
    return struct.pack("<I", len(payload)) + payload


def decode_payload(payload: bytes):
    """Inverse of encode_payload -> (subtype enum, flags, body).

    Rejects reserved flag bits; raises WireError for unknown (cat, sub).
    """
    if len(payload) < 3:
        raise WireError("frame payload shorter than cat+sub+flags")
    cat, sub, flags = payload[0], payload[1], payload[2]
    if flags & FLAGS_RESERVED_MASK:
        raise WireError("reserved flag bits set")
    return resolve(cat, sub), flags, payload[3:]


def decode(frame: bytes):
    """Inverse of encode; validates the length field exactly."""
    if len(frame) < 7:
        raise WireError("frame shorter than header")
    (length,) = struct.unpack("<I", frame[:4])
    if length != len(frame) - 4:
        raise WireError("frame length field mismatch")
    return decode_payload(frame[4:])


def encode_datagram(subtype, body: bytes = b"", flags: int = 0) -> bytes:
    """Server -> client UDP datagram: [cat][sub][flags][body]."""
    return encode_payload(subtype, body, flags)


def encode_client_datagram(subtype, client_id: int, body: bytes = b"", flags: int = 0) -> bytes:
    """Client -> server UDP datagram: [cat][sub][flags][u32 client_id][body]."""
    cat, sub = _packet_id(subtype)
    return struct.pack("<BBBI", cat, sub, flags, client_id) + body


def decode_datagram(dgram: bytes):
    """Inverse of encode_datagram -> (subtype enum, flags, body)."""
    return decode_payload(dgram)


def decode_client_datagram(dgram: bytes):
    """Inverse of encode_client_datagram -> (subtype, flags, client_id, body)."""
    if len(dgram) < 7:
        raise WireError("client datagram shorter than header")
    subtype, flags, rest = decode_payload(dgram)
    (client_id,) = struct.unpack("<I", rest[:4])
    return subtype, flags, client_id, rest[4:]


# ---------------------------------------------------------------------------
# Socket helpers (TCP stream framing + zstd normalization)
# ---------------------------------------------------------------------------

def compress_body(body: bytes, level: int = 3) -> bytes:
    """The v14 FLAG_COMPRESSED body transform: [u32 LE raw_size][zstd frame]."""
    return struct.pack("<I", len(body)) + _zstd.compress(body, level)


def decompress_body(body: bytes, max_raw_size: int = MAX_BODY_CAP) -> bytes:
    if len(body) < 5:
        raise WireError("compressed body too short for the raw_size prefix")
    (raw_size,) = struct.unpack("<I", body[:4])
    # Cap checked BEFORE decompression, mirroring the server/launcher.
    if raw_size == 0 or raw_size > max_raw_size:
        raise WireError(f"compressed body raw_size {raw_size} outside the cap")
    out = _zstd.decompress(body[4:])
    if len(out) != raw_size:
        raise WireError("decompressed length does not match raw_size")
    return out


def send_packet(sock: socket.socket, subtype, body: bytes = b"", compress: bool = False) -> None:
    """Sends one framed packet; optionally zstd-compresses the body."""
    if compress:
        sock.sendall(encode(subtype, compress_body(body), FLAG_COMPRESSED))
    else:
        sock.sendall(encode(subtype, body))


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed connection")
        buf += chunk
    return buf


def recv_packet(sock: socket.socket):
    """Receives one framed packet -> (subtype enum, body).

    Transparently inflates FLAG_COMPRESSED bodies, mirroring what the
    launcher does before relaying to the game.
    """
    (length,) = struct.unpack("<I", recv_exact(sock, 4))
    if length > MAX_FRAME_LENGTH:
        raise WireError(f"frame length {length} exceeds cap")
    subtype, flags, body = decode_payload(recv_exact(sock, length))
    if flags & FLAG_COMPRESSED:
        body = decompress_body(body)
    return subtype, body


# ---------------------------------------------------------------------------
# TLS (launcher<->server hop; decision D1 = TOFU fingerprint pinning)
# ---------------------------------------------------------------------------

def tls_context() -> ssl.SSLContext:
    """TLS 1.3 client context without CA verification.

    The server uses a self-signed certificate; identity comes from SHA-256
    fingerprint pinning (the `pin=` argument of tls_connect), exactly like
    the launcher's trust-on-first-use store.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    return ctx


def peer_fingerprint(tls_sock: ssl.SSLSocket) -> str:
    """SHA-256 of the peer certificate, 'AA:BB:...' (the server logs this)."""
    der = tls_sock.getpeercert(binary_form=True)
    digest = hashlib.sha256(der).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


def tls_connect(host: str, port: int, timeout: float = 10.0, pin: str | None = None,
                source: str | None = None) -> ssl.SSLSocket:
    """TCP connect + TLS 1.3 handshake -> wrapped socket.

    When `pin` is given (with or without ':' separators, any case) the peer
    certificate fingerprint must match, otherwise WireError is raised.

    `source` binds the local end to an address before connecting. The server
    caps concurrent connections per source IP (anti-abuse), so a load bench
    that wants more clients than that cap has to come from several addresses
    -- 127.0.0.2, 127.0.0.3 and the rest of 127/8 are all local.
    """
    raw = socket.create_connection((host, port), timeout=timeout,
                                   source_address=(source, 0) if source else None)
    try:
        s = tls_context().wrap_socket(raw, server_hostname=None)
    except Exception:
        raw.close()
        raise
    if pin is not None:
        got = peer_fingerprint(s).replace(":", "")
        want = pin.replace(":", "").upper()
        if got != want:
            s.close()
            raise WireError(f"TLS fingerprint mismatch: got {got}, pinned {want}")
    return s


def hello(sock: socket.socket, name: str = "", verify=None, ticket: str = "") -> int:
    """HELLO {proto_version[, tail:str player_name]} + IDENTITY {tail:str ticket}
    -> WELCOME {client_id}, then the v15 install-check exchange; returns the client
    id. An empty name (default) keeps the legacy guest naming (server assigns
    Player<id>). `ticket` is the v17 directory join ticket; empty (default) sends
    the Identity frame with no ticket, which is what a direct connect looks like.

    The server states how strictly the player's game install must be checked and
    expects an answer before it will hand over the mod list, so answering is part
    of connecting rather than something each test opts into. By default this
    reports a clean install, which is what a real launcher on an untouched install
    reports -- for STRICT (v18) that includes naming the reference manifest the
    VerifyRequest carried, `manifest=<hash>;` in front of the detail, as an honest
    launcher does. Pass `verify=(outcome, problems, detail)` to report something
    else -- that is how a test exercises the server's refusal -- or a callable
    `verify(level_asked, manifest_hash) -> (outcome, problems, detail)` when the
    report has to depend on what was asked.

    Raises WireError when the server answers anything else (e.g. a KICK
    with the reason in its body).
    """
    w = Writer().u16(PROTO_VERSION)
    if name:
        w = w.tail(name.encode())
    send_packet(sock, Handshake.HELLO, w.body)
    # v17: the Identity frame always follows Hello; the server reads exactly one.
    ident = Writer()
    if ticket:
        ident = ident.tail(ticket.encode())
    send_packet(sock, Handshake.IDENTITY, ident.body)
    subtype, body = recv_packet(sock)
    if subtype is Session.KICK:
        raise WireError(f"kicked during handshake: {body.decode(errors='replace')!r}")
    if subtype is not Handshake.WELCOME:
        raise WireError(f"expected WELCOME, got {subtype!r}")
    client_id = Reader(body).u32()

    subtype, body = recv_packet(sock)
    if subtype is Session.KICK:
        raise WireError(f"kicked during handshake: {body.decode(errors='replace')!r}")
    if subtype is not Handshake.VERIFY_REQUEST:
        raise WireError(f"expected VERIFY_REQUEST, got {subtype!r}")
    r = Reader(body)
    asked = r.u8()
    manifest_hash = r.tail().decode(errors="replace")  # v18: empty unless STRICT
    # The launcher's floor (Integrity::FloorForServer): a server that asks for
    # OFF still gets a SIZE check, and the report says SIZE -- the server treats
    # a report claiming level 0 as malformed, since no launcher ever ran "off".
    ran = max(asked, int(VerifyLevel.SIZE))
    if callable(verify):
        outcome, problems, detail = verify(ran, manifest_hash)
    elif verify is not None:
        outcome, problems, detail = verify
    else:
        outcome, problems, detail = VerifyOutcome.CLEAN, 0, strict_detail(ran, manifest_hash)
    send_packet(sock, Handshake.VERIFY_REPORT,
                Writer().u8(ran).u8(int(outcome)).u32(problems)
                .tail(detail.encode() if isinstance(detail, str) else detail).body)
    return client_id


def strict_detail(level: int, manifest_hash: str, detail: str = "") -> str:
    """The detail of a report at `level`: for STRICT (v18) it starts with
    `manifest=<hash>;`, naming the reference the launcher checked against."""
    if level == int(VerifyLevel.STRICT):
        return f"manifest={manifest_hash};{detail}"
    return detail


def udp_hello_body(client_id: int, token: bytes, nonce: bytes) -> bytes:
    """UdpHello body (wire v10): [u8[16] nonce][u8[32] mac], where
    mac = HMAC-SHA256(token, LABEL || u32 client_id LE || nonce). The raw token
    is never sent -- only proof of knowledge."""
    import hmac
    mac = hmac.new(bytes(token),
                   UDP_HELLO_MAC_LABEL + struct.pack("<I", client_id) + bytes(nonce),
                   hashlib.sha256).digest()
    return bytes(nonce) + mac


def udp_hello(udp_sock: socket.socket, addr, client_id: int, token: bytes,
              nonce: bytes | None = None) -> None:
    """Sends the UDP_HELLO datagram (v10 HMAC challenge) binding client_id <->
    endpoint without ever transmitting the raw token."""
    import os as _os
    if nonce is None:
        nonce = _os.urandom(UDP_HELLO_NONCE_LEN)
    body = udp_hello_body(client_id, token, nonce)
    udp_sock.sendto(encode_client_datagram(Handshake.UDP_HELLO, client_id, body), addr)


def udp_auth_trailer(datagram: bytes, seq: int, token: bytes) -> bytes:
    """Transport-layer auth trailer for a client -> server datagram (v10):
    appends [u32 LE seq][u8[16] mac] where mac = HMAC-SHA256(token, datagram ||
    seq)[:16]. `datagram` is the base client->server datagram bytes
    (encode_client_datagram output)."""
    import hmac
    withseq = bytes(datagram) + struct.pack("<I", seq)
    mac = hmac.new(bytes(token), withseq, hashlib.sha256).digest()[:UDP_DATAGRAM_MAC_LEN]
    return withseq + mac


def encode_client_datagram_authed(subtype, client_id: int, seq: int, token: bytes,
                                  body: bytes = b"", flags: int = 0) -> bytes:
    """A client -> server datagram with the v10 auth trailer (seq + MAC)."""
    inner = encode_client_datagram(subtype, client_id, body, flags)
    return udp_auth_trailer(inner, seq, token)


# ---------------------------------------------------------------------------
# ChaCha20 (RFC 8439, 32-bit LE block counter) -- reference implementation
# for the encrypted-content tests; Node starts the counter at 1.
# ---------------------------------------------------------------------------

def _rotl32(v: int, n: int) -> int:
    return ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF


def _quarter(s: list, a: int, b: int, c: int, d: int) -> None:
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF; s[d] = _rotl32(s[d] ^ s[a], 16)  # noqa: E702
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF; s[b] = _rotl32(s[b] ^ s[c], 12)  # noqa: E702
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF; s[d] = _rotl32(s[d] ^ s[a], 8)   # noqa: E702
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF; s[b] = _rotl32(s[b] ^ s[c], 7)   # noqa: E702


def chacha20_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    state = [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574]
    state += list(struct.unpack("<8I", key))
    state.append(counter & 0xFFFFFFFF)
    state += list(struct.unpack("<3I", nonce))
    w = state.copy()
    for _ in range(10):
        _quarter(w, 0, 4, 8, 12)
        _quarter(w, 1, 5, 9, 13)
        _quarter(w, 2, 6, 10, 14)
        _quarter(w, 3, 7, 11, 15)
        _quarter(w, 0, 5, 10, 15)
        _quarter(w, 1, 6, 11, 12)
        _quarter(w, 2, 7, 8, 13)
        _quarter(w, 3, 4, 9, 14)
    return struct.pack("<16I", *[(w[i] + state[i]) & 0xFFFFFFFF for i in range(16)])


def chacha20_xor(key: bytes, nonce: bytes, data: bytes, counter: int = 1) -> bytes:
    """XOR-crypt with the keystream starting at block `counter` (default 1,
    the convention used by Node content encryption)."""
    out = bytearray(len(data))
    for i in range(0, len(data), 64):
        ks = chacha20_block(key, counter + i // 64, nonce)
        chunk = data[i:i + 64]
        out[i:i + len(chunk)] = bytes(a ^ b for a, b in zip(chunk, ks))
    return bytes(out)
