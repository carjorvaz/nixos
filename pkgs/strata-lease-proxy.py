#!/usr/bin/env python3
"""Two-door lease proxy for the Strata server.

The engine behind this proxy keeps ONE live conversation: a request that is not
a continuation of it clears its chain, so the next turn of an interactive
conversation has to re-read its whole prompt.  A background client (a refresh
job, a scheduled reflect loop) firing 20-36k tokens between two of the user's
turns is therefore not merely slow - it throws the conversation away.

So the public surface is split in two doors:

  * the interactive door is what users and interactive agents talk to.  A POST
    to /v1/chat/completions or /v1/messages takes the lease: it starts when the
    request is forwarded and is renewed when its response ends, so it covers
    the turn itself plus LEASE_SECONDS of time for the next one.
  * the background door is machine traffic.  While the lease is active a
    request here is held - never forwarded - until the lease expires or
    HOLD_CAP_SECONDS pass.  A hold that outlives the cap ends in 503 with
    Retry-After, which every sane HTTP client retries.  The 502s that answer
    an unreachable or closed engine carry Retry-After too: hindsight turns
    any 5xx with Retry-After into a durable operation defer, and a bare 502
    would burn its retry budget while strata cold-boots from the Optane pack.

Classification is by source as well as by door.  Moving a background job to
port 8090 would mean editing the tailnet policy, which lives in the Tailscale
admin console and allows only pius -> tiberius:8080, so --background-host names
(resolved at startup into a set of addresses) mark their requests as background
traffic on *every* door: they are held exactly like a request on the background
door and never renew the lease.  On the interactive door their
GET/HEAD/OPTIONS pass through untouched, because a read cannot clear the
engine's conversation; the background door keeps holding everything it is
given.  The point is that hindsight on pius keeps http://tiberius:8080/v1
unchanged and still cannot walk in between the user's turns.

Everything else (/health, /v1/models, /props, /slots, every GET) is a plain
reverse proxy that streams: the response head is relayed as soon as the engine
produces it and the body chunk by chunk, so SSE tokens reach the caller while
the engine is still generating - nothing is buffered, and there is no read
timeout on the body.

One request per connection in both directions: the client is always answered
with Connection: close, and the upstream connection is opened per request and
closed after it, so no client can keep a connection resident across another
client's turn.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import contextvars
import ipaddress
import json
import math
import os
import re
import signal
import socket
import sys
import time

DOOR_FRONT = "front"
DOOR_BACK = "back"
SOURCE_INTERACTIVE = "interactive"
SOURCE_BACKGROUND = "background"

# A read cannot clear the engine's conversation, so a background source's
# reads are never held - only the requests that could evict the live chain.
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})

# Only these POSTs take or renew the lease.  /health, /v1/models, /props,
# /slots and every GET are read-only: they must never keep the background door
# shut, or a monitoring probe would keep a job out forever.
LEASE_PATHS = frozenset({"/v1/chat/completions", "/v1/messages"})

HEAD_TIMEOUT = 60.0  # client -> proxy: the request head
CONNECT_TIMEOUT = 10.0  # proxy -> engine: the TCP connect
RESPONSE_HEAD_TIMEOUT = 900.0  # prefill may run for minutes before any header
HOLD_POLL = 0.1  # how often a held request re-checks the lease
RESOLVE_RETRY = 60.0  # how long an unresolvable --background-host waits
STREAM_CHUNK = 64 * 1024
READ_LIMIT = 1024 * 1024  # largest head the stream readers will buffer
SHUTDOWN_GRACE = 5.0
DRAIN_TIMEOUT = 5.0  # how long an error reply waits for the client's body
DRAIN_LIMIT = 64 * 1024 * 1024


class ProtocolError(Exception):
    """Framing this proxy refuses to guess at."""


class Sink:
    """A throwaway body sink, used only to read a body off the wire."""

    @staticmethod
    def write(_data):
        pass

    @staticmethod
    async def drain():
        pass


class Request:
    """One parsed request head.

    The raw header lines are kept so the head can be relayed verbatim apart
    from the one header the proxy owns (Connection).
    """

    __slots__ = ("method", "target", "path", "start", "headers")

    def __init__(self, method, target, path, start, headers):
        self.method = method
        self.target = target
        self.path = path
        self.start = start
        self.headers = headers


class Response:
    __slots__ = ("code", "start", "headers")

    def __init__(self, code, start, headers):
        self.code = code
        self.start = start
        self.headers = headers


# -- head parsing and rebuilding ---------------------------------------------


def header_index(lines):
    """Header name -> the values it carried, in order (names lower-cased)."""
    index = {}
    for line in lines:
        name, sep, value = line.partition(b":")
        if not sep:
            continue
        index.setdefault(name.strip().lower(), []).append(value.strip())
    return index


def parse_request(head):
    lines = head[:-4].split(b"\r\n")
    parts = lines[0].split()
    if len(parts) != 3 or not parts[2].startswith(b"HTTP/"):
        raise ProtocolError("malformed request line")
    method = parts[0].decode("latin-1")
    target = parts[1].decode("latin-1")
    return Request(method, target, target.split("?", 1)[0], lines[0], lines[1:])


def parse_response(head):
    lines = head[:-4].split(b"\r\n")
    parts = lines[0].split(b" ", 2)
    if len(parts) < 2 or not parts[1].isdigit():
        raise ProtocolError("malformed status line")
    return Response(int(parts[1]), lines[0], lines[1:])


def rebuild(start, lines, drop=(), add=()):
    """The head with `drop`ped header names removed and `add`ed lines appended.

    Every other line is copied byte for byte, so Transfer-Encoding,
    Content-Type and friends survive the trip unchanged.
    """
    out = [start]
    for line in lines:
        name, sep, _value = line.partition(b":")
        if sep and name.strip().lower() in drop:
            continue
        out.append(line)
    out.extend(add)
    return b"\r\n".join(out) + b"\r\n\r\n"


CORS_ORIGIN = contextvars.ContextVar("cors_origin", default=None)

CORS_ORIGIN_RE = re.compile(r"http://(?:127\.0\.0\.1|localhost)(?::\d{1,5})?\Z")


def cors_origin(headers):
    """The request's Origin if it is a local page, else None.

    The proxy has no authentication, so CORS is deliberately limited to
    loopback origins: a page served from the user's own machine may call the
    engine, a random website may not.
    """
    values = headers.get(b"origin") or []
    if not values:
        return None
    origin = values[0].decode("latin-1").strip()
    return origin if CORS_ORIGIN_RE.match(origin) else None


def cors_lines(origin):
    return [
        b"Access-Control-Allow-Origin: " + origin.encode("latin-1"),
        b"Access-Control-Allow-Methods: GET, POST, OPTIONS",
        b"Access-Control-Allow-Headers: Content-Type, Authorization",
        b"Access-Control-Max-Age: 600",
        b"Vary: Origin",
    ]


def is_chunked(values):
    tokens = [token.strip() for token in b",".join(values).lower().split(b",") if token.strip()]
    return bool(tokens) and tokens[-1] == b"chunked"


def expects_continue(headers):
    return b"100-continue" in b",".join(headers.get(b"expect", [])).lower()


def request_body_kind(headers):
    """('chunked' | 'length' | 'none', byte count or 0)."""
    transfer = headers.get(b"transfer-encoding")
    if transfer:
        if not is_chunked(transfer):
            raise ProtocolError("unsupported transfer-encoding")
        return "chunked", 0
    lengths = headers.get(b"content-length")
    if lengths:
        raw = lengths[-1].strip()
        if not raw.isdigit():
            raise ProtocolError("bad content-length")
        return "length", int(raw)
    return "none", 0


def response_body_kind(method, code, headers):
    """('chunked' | 'length' | 'eof' | 'none', byte count or 0).

    Transfer-Encoding wins over Content-Length, as RFC 9112 requires; a
    response with neither is delimited by the upstream closing the connection
    (which it will: the request carried Connection: close).
    """
    if method.upper() == "HEAD" or code in (204, 304) or 100 <= code < 200:
        return "none", 0
    transfer = headers.get(b"transfer-encoding")
    if transfer and is_chunked(transfer):
        return "chunked", 0
    lengths = headers.get(b"content-length")
    if lengths:
        values = {value.strip() for value in lengths}
        if len(values) == 1:
            raw = values.pop()
            if raw.isdigit():
                return "length", int(raw)
    return "eof", 0


# -- relaying ----------------------------------------------------------------


async def flush(writer):
    try:
        await writer.drain()
        return True
    except (ConnectionError, OSError):
        return False


async def relay_length(src, dst, length):
    remaining = length
    while remaining:
        data = await src.read(min(STREAM_CHUNK, remaining))
        if not data:
            raise ConnectionResetError("the peer closed before the body ended")
        dst.write(data)
        remaining -= len(data)
        if not await flush(dst):
            raise ConnectionResetError("the other side closed mid-body")


async def relay_chunked(src, dst, limit=None):
    """Relay chunked framing unchanged, one chunk at a time (SSE-safe)."""
    total = 0
    while True:
        try:
            line = await src.readuntil(b"\r\n")
        except asyncio.LimitOverrunError as exc:
            raise ProtocolError("chunk header too long") from exc
        dst.write(line)
        field = line.split(b";", 1)[0].strip()
        try:
            size = int(field, 16)
        except ValueError as exc:
            raise ProtocolError("bad chunk size") from exc
        if size < 0:
            raise ProtocolError("negative chunk size")
        if not await flush(dst):
            raise ConnectionResetError("the other side closed mid-body")
        if size == 0:
            while True:
                trailer = await src.readuntil(b"\r\n")
                dst.write(trailer)
                if trailer == b"\r\n":
                    break
            await flush(dst)
            return
        total += size
        if limit is not None and total > limit:
            raise ProtocolError("body too large")
        await relay_length(src, dst, size)
        crlf = await src.readexactly(2)
        if crlf != b"\r\n":
            raise ProtocolError("missing CRLF after a chunk")
        dst.write(crlf)
        if not await flush(dst):
            raise ConnectionResetError("the other side closed mid-body")


async def relay_until_eof(src, dst):
    while True:
        data = await src.read(STREAM_CHUNK)
        if not data:
            return
        dst.write(data)
        if not await flush(dst):
            raise ConnectionResetError("the other side closed mid-body")


# -- who is calling ----------------------------------------------------------


def canonical(address):
    """One spelling per address: IPv4-mapped IPv6 folds to IPv4, scope off."""
    try:
        parsed = ipaddress.ip_address(str(address).split("%", 1)[0])
    except ValueError:
        return None
    if isinstance(parsed, ipaddress.IPv6Address) and parsed.ipv4_mapped is not None:
        return str(parsed.ipv4_mapped)
    return str(parsed)


def peer_address(writer):
    peer = writer.get_extra_info("peername")
    if not isinstance(peer, tuple) or not peer:
        return None
    return canonical(peer[0])


class BackgroundSources:
    """The addresses whose requests are background traffic on every door.

    The names come from --background-host.  Resolution does not happen in the
    constructor: a tailnet name can be unresolvable for a while after boot, and
    that case must be an explicit, logged failure - never a crash, and never a
    silent "everything is interactive".
    """

    def __init__(self, hosts):
        self.hosts = list(dict.fromkeys(hosts))
        self.addresses = set()

    def contains(self, address):
        return address is not None and address in self.addresses

    async def resolve(self):
        loop = asyncio.get_running_loop()
        pending = list(self.hosts)
        while pending:
            failures = []
            for host in pending:
                try:
                    infos = await loop.getaddrinfo(
                        host, None, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM
                    )
                except OSError as exc:
                    failures.append((host, exc))
                    continue
                found = {canonical(info[4][0]) for info in infos} - {None}
                if not found:
                    failures.append((host, "no addresses"))
                    continue
                self.addresses |= found
                print(
                    f"[lease] background source {host} -> {' '.join(sorted(found))}",
                    file=sys.stderr,
                    flush=True,
                )
            if not failures:
                return
            for host, reason in failures:
                print(
                    f"[lease] cannot resolve background source {host!r} ({reason}); "
                    f"retrying in {RESOLVE_RETRY:g} s",
                    file=sys.stderr,
                    flush=True,
                )
            pending = [host for host, _reason in failures]
            await asyncio.sleep(RESOLVE_RETRY)


# -- the proxy ---------------------------------------------------------------


class LeaseProxy:
    def __init__(self, upstream, lease_seconds, hold_cap, background_hosts=()):
        self.upstream = upstream
        self.lease_seconds = lease_seconds
        self.hold_cap = hold_cap
        self.sources = BackgroundSources(background_hosts)
        self.lease_until = 0.0
        self.shutdown = asyncio.Event()

    # -- lease ---------------------------------------------------------------

    def lease_active(self):
        return time.monotonic() < self.lease_until

    def lease_remaining(self):
        return max(0.0, self.lease_until - time.monotonic())

    def take_lease(self):
        self.lease_until = time.monotonic() + self.lease_seconds

    async def wait_out_lease(self):
        """Hold until the lease is gone or the hold cap is spent.

        Returns True when the request may be forwarded.
        """
        deadline = time.monotonic() + self.hold_cap
        while self.lease_active():
            now = time.monotonic()
            if now >= deadline or self.shutdown.is_set():
                break
            await asyncio.sleep(
                min(HOLD_POLL, deadline - now, max(self.lease_remaining(), 0.01))
            )
        return not self.lease_active()

    # -- one connection ------------------------------------------------------

    async def handle(self, reader, writer, door):
        started = time.monotonic()
        method = path = "-"
        status = "-"
        source = (
            SOURCE_BACKGROUND
            if self.sources.contains(peer_address(writer))
            else SOURCE_INTERACTIVE
        )
        leased = self.lease_active()
        tune(writer)
        try:
            try:
                head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), HEAD_TIMEOUT)
            except asyncio.IncompleteReadError as exc:
                if not exc.partial:
                    status = None  # a connection that asked nothing: no request to log
                    return
                status = "400"
                await self.fail(writer, 400, "Bad Request", "the request head ended early")
                return
            except asyncio.TimeoutError:
                status = "408"
                await self.fail(writer, 408, "Request Timeout", "no request head arrived in time")
                return
            except asyncio.LimitOverrunError:
                status = "431"
                await self.fail(writer, 431, "Request Header Fields Too Large", "the request head is too large")
                return
            try:
                request = parse_request(head)
            except ProtocolError:
                status = "400"
                await self.fail(writer, 400, "Bad Request", "malformed request line")
                return
            method, path = request.method, request.path
            leased = self.lease_active()
            status = await self.dispatch(reader, writer, door, source, request)
        except asyncio.CancelledError:
            status = "cancelled"
            raise
        except (ConnectionError, OSError) as exc:
            if status == "-":
                status = "aborted"
            print(f"[lease] door={door} broken connection: {exc}", file=sys.stderr, flush=True)
        except Exception as exc:  # one bad request must never take the door down
            if status == "-":
                status = "error"
            print(f"[lease] door={door} {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        finally:
            if status is not None:
                self.log(
                    door,
                    source,
                    method,
                    path,
                    status,
                    (time.monotonic() - started) * 1000.0,
                    leased,
                )
            with contextlib.suppress(Exception):
                writer.close()
            with contextlib.suppress(Exception, asyncio.CancelledError):
                await asyncio.wait_for(writer.wait_closed(), SHUTDOWN_GRACE)

    async def dispatch(self, reader, writer, door, source, request):
        headers = header_index(request.headers)
        origin = cors_origin(headers)
        CORS_ORIGIN.set(origin)
        if (
            request.method.upper() == "OPTIONS"
            and origin
            and b"access-control-request-method" in headers
        ):
            await self.preflight(writer, origin)
            return "204"

        # The back door is machine traffic by construction and keeps holding
        # everything it is given.  A background *source* on the front door is
        # held for the requests that could evict the conversation; its reads
        # cannot, so they pass through.
        subject = door == DOOR_BACK or (
            source == SOURCE_BACKGROUND and request.method.upper() not in SAFE_METHODS
        )

        if subject and not await self.wait_out_lease():
            retry = max(1, math.ceil(self.lease_remaining()))
            await self.fail(
                writer,
                503,
                "Service Unavailable",
                "the interactive conversation holds the engine lease; retry later",
                retry_after=retry,
            )
            # Read the body off the wire before closing, so a client in the
            # middle of an upload reads the 503 instead of a reset.
            await self.discard_body(reader, headers)
            return "503"

        renew = (
            door == DOOR_FRONT
            and source == SOURCE_INTERACTIVE
            and request.method.upper() == "POST"
            and request.path in LEASE_PATHS
        )
        if renew:
            self.take_lease()

        status = await self.forward(reader, writer, request, headers)
        if renew:
            self.take_lease()
        return status

    async def forward(self, reader, writer, request, headers):
        try:
            kind, length = request_body_kind(headers)
        except ProtocolError:
            await self.fail(writer, 400, "Bad Request", "unsupported request body framing")
            await self.discard_body(reader, headers)
            return "400"

        host, port = self.upstream
        try:
            upstream_reader, upstream_writer = await asyncio.wait_for(
                asyncio.open_connection(host, port, limit=READ_LIMIT), CONNECT_TIMEOUT
            )
        except (OSError, asyncio.TimeoutError):
            # Retry-After turns this into a durable operation defer on the
            # hindsight side; without it a strata cold boot (Optane pack
            # load) exhausts the operation's retry budget while the engine
            # is merely not listening yet.
            await self.fail(
                writer,
                502,
                "Bad Gateway",
                f"the strata engine is not reachable at {host}:{port}",
                retry_after=30,
            )
            await self.discard_body(reader, headers)
            return "502"
        tune(upstream_writer)

        try:
            upstream_writer.write(
                rebuild(
                    request.start,
                    request.headers,
                    drop=(b"connection", b"expect"),
                    add=(b"Connection: close",),
                )
            )
            if not await flush(upstream_writer):
                upstream_writer.close()
                await self.fail(writer, 502, "Bad Gateway", "the strata engine closed the connection", retry_after=30)
                await self.discard_body(reader, headers)
                return "502"
        except (ConnectionError, OSError):
            upstream_writer.close()
            await self.fail(writer, 502, "Bad Gateway", "the strata engine closed the connection", retry_after=30)
            await self.discard_body(reader, headers)
            return "502"

        # A client that asked for 100-continue held its body back until it was
        # admitted; the header left the forwarded head above, so the engine can
        # never send a second interim answer and break the framing.
        if expects_continue(headers):
            writer.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            if not await flush(writer):
                upstream_writer.close()
                return "aborted"

        try:
            if kind == "chunked":
                await relay_chunked(reader, upstream_writer)
            elif kind == "length" and length:
                await relay_length(reader, upstream_writer, length)
        except ProtocolError:
            upstream_writer.close()
            await self.fail(writer, 400, "Bad Request", "malformed request body")
            return "400"
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            # The client stopped mid-body (or the engine went away): there is
            # nobody left to answer.
            upstream_writer.close()
            return "aborted"

        try:
            response = await self.read_response_head(upstream_reader, writer)
        except asyncio.TimeoutError:
            upstream_writer.close()
            await self.fail(writer, 504, "Gateway Timeout", "the strata engine did not answer in time")
            return "504"
        except (
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
            ConnectionError,
            OSError,
            ProtocolError,
        ):
            upstream_writer.close()
            await self.fail(writer, 502, "Bad Gateway", "the strata engine closed the connection")
            return "502"

        body_kind, body_length = response_body_kind(
            request.method, response.code, header_index(response.headers)
        )
        add = [b"Connection: close"]
        origin = CORS_ORIGIN.get()
        if origin:
            add.extend(cors_lines(origin))
        writer.write(rebuild(response.start, response.headers, drop=(b"connection",), add=tuple(add)))
        if not await flush(writer):
            upstream_writer.close()
            return str(response.code)

        try:
            if body_kind == "chunked":
                await relay_chunked(upstream_reader, writer)
            elif body_kind == "length":
                await relay_length(upstream_reader, writer, body_length)
            elif body_kind == "eof":
                await relay_until_eof(upstream_reader, writer)
        except (asyncio.IncompleteReadError, ConnectionError, OSError, ProtocolError):
            # Headers are gone already; the only honest signal left is closing
            # the client connection, which the finally in handle() does.
            pass
        finally:
            upstream_writer.close()
        return str(response.code)

    async def read_response_head(self, upstream_reader, writer):
        while True:
            head = await asyncio.wait_for(
                upstream_reader.readuntil(b"\r\n\r\n"), RESPONSE_HEAD_TIMEOUT
            )
            response = parse_response(head)
            if not 100 <= response.code < 200:
                return response
            writer.write(head)  # an interim answer (100 Continue, 103 Early Hints)
            if not await flush(writer):
                raise ConnectionResetError("the client closed")

    # -- replies -------------------------------------------------------------

    async def fail(self, writer, code, reason, message, retry_after=None):
        body = json.dumps({"error": {"message": message, "type": "lease_proxy", "code": code}}).encode()
        head = [
            f"HTTP/1.1 {code} {reason}".encode(),
            b"Content-Type: application/json",
            b"Content-Length: " + str(len(body)).encode(),
            b"Cache-Control: no-store",
            b"Connection: close",
        ]
        if retry_after is not None:
            head.append(b"Retry-After: " + str(int(retry_after)).encode())
        origin = CORS_ORIGIN.get()
        if origin:
            head.extend(cors_lines(origin))
        writer.write(b"\r\n".join(head) + b"\r\n\r\n" + body)
        await flush(writer)

    async def preflight(self, writer, origin):
        head = [b"HTTP/1.1 204 No Content"]
        head.extend(cors_lines(origin))
        head.append(b"Connection: close")
        writer.write(b"\r\n".join(head) + b"\r\n\r\n")
        await flush(writer)

    async def discard_body(self, reader, headers):
        if expects_continue(headers):
            return  # the body is still held back by the client, waiting for us
        try:
            kind, length = request_body_kind(headers)
        except ProtocolError:
            return
        try:
            if kind == "chunked":
                await asyncio.wait_for(relay_chunked(reader, Sink(), limit=DRAIN_LIMIT), DRAIN_TIMEOUT)
            elif kind == "length" and 0 < length <= DRAIN_LIMIT:
                await asyncio.wait_for(relay_length(reader, Sink(), length), DRAIN_TIMEOUT)
        except (
            asyncio.TimeoutError,
            asyncio.IncompleteReadError,
            ConnectionError,
            OSError,
            ProtocolError,
        ):
            pass

    # -- logging -------------------------------------------------------------

    @staticmethod
    def log(door, source, method, path, status, elapsed_ms, leased):
        clean = path.replace("\r", "").replace("\n", "")[:200]
        print(
            f"[lease] door={door} src={source} method={method} path={clean} status={status} "
            f"ms={elapsed_ms:.0f} lease={'active' if leased else 'idle'}",
            file=sys.stderr,
            flush=True,
        )


def tune(writer):
    """Nagle off: an SSE token must not wait for the next one."""
    sock = writer.get_extra_info("socket")
    if sock is not None:
        with contextlib.suppress(OSError):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


# -- startup -----------------------------------------------------------------


def parse_address(text):
    if text.startswith("["):
        host, sep, rest = text[1:].partition("]")
        if not sep or not rest.startswith(":"):
            raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {text!r}")
        port_text = rest[1:]
    else:
        host, sep, port_text = text.rpartition(":")
        if not sep:
            raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {text!r}")
    if not port_text.isdigit() or not 0 < int(port_text) < 65536:
        raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {text!r}")
    return host, int(port_text)


def seconds(parser, value, env_name, default):
    if value is not None:
        return float(value)
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        parser.error(f"{env_name} must be a number of seconds, got {raw!r}")


async def run(front, back, upstream, lease_seconds, hold_cap, background_hosts):
    proxy = LeaseProxy(upstream, lease_seconds, hold_cap, background_hosts)
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    proxy.shutdown = stop
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError, RuntimeError):
            loop.add_signal_handler(sig, stop.set)

    # Resolution never blocks the listeners: a name that is not there yet keeps
    # retrying in the background while the doors serve what they already have.
    resolver = loop.create_task(proxy.sources.resolve()) if proxy.sources.hosts else None

    servers = []
    for address, door in ((front, DOOR_FRONT), (back, DOOR_BACK)):

        async def handler(reader, writer, _door=door):
            await proxy.handle(reader, writer, _door)

        servers.append(
            await asyncio.start_server(
                handler, address[0], address[1], limit=READ_LIMIT, backlog=128, reuse_address=True
            )
        )
    print(
        f"[lease] interactive={front[0]}:{front[1]} background={back[0]}:{back[1]} "
        f"upstream={upstream[0]}:{upstream[1]} lease={lease_seconds:g}s hold_cap={hold_cap:g}s "
        f"background_hosts={' '.join(proxy.sources.hosts) or '-'}",
        file=sys.stderr,
        flush=True,
    )

    await stop.wait()
    if resolver is not None and not resolver.done():
        resolver.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await resolver
    for server in servers:
        server.close()
    await asyncio.gather(*(server.wait_closed() for server in servers), return_exceptions=True)

    # Held requests wake on the same event and answer 503 before this drain.
    current = asyncio.current_task()
    tasks = [task for task in asyncio.all_tasks(loop) if task is not current and not task.done()]
    if tasks:
        _done, pending = await asyncio.wait(tasks, timeout=SHUTDOWN_GRACE)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.wait(pending, timeout=2.0)
    print("[lease] stopped", file=sys.stderr, flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Lease-gated two-door front end for the Strata server.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--front",
        type=parse_address,
        required=True,
        metavar="HOST:PORT",
        help="the interactive door (users and interactive agents)",
    )
    parser.add_argument(
        "--back",
        type=parse_address,
        required=True,
        metavar="HOST:PORT",
        help="the background door (jobs, refresh loops)",
    )
    parser.add_argument(
        "--upstream",
        type=parse_address,
        required=True,
        metavar="HOST:PORT",
        help="the Strata server this proxy fronts",
    )
    parser.add_argument(
        "--background-host",
        action="append",
        default=None,
        metavar="NAME",
        help="an address or host name whose requests are background traffic on every door "
        "(repeatable, or comma-separated); resolved at startup and retried until it resolves",
    )
    parser.add_argument(
        "--lease-seconds",
        type=float,
        default=None,
        metavar="N",
        help="how long a finished turn keeps the background door shut (default 600, "
        "or $STRATA_LEASE_SECONDS)",
    )
    parser.add_argument(
        "--hold-cap-seconds",
        type=float,
        default=None,
        metavar="N",
        help="the longest a background request waits for the lease before a 503 "
        "(default 500, or $STRATA_LEASE_HOLD_CAP)",
    )
    args = parser.parse_args(argv)

    lease_seconds = seconds(parser, args.lease_seconds, "STRATA_LEASE_SECONDS", 600.0)
    hold_cap = seconds(parser, args.hold_cap_seconds, "STRATA_LEASE_HOLD_CAP", 500.0)
    if lease_seconds <= 0:
        parser.error("--lease-seconds must be positive")
    if hold_cap <= 0:
        parser.error("--hold-cap-seconds must be positive")

    background_hosts = [
        host.strip()
        for value in (args.background_host or [])
        for host in value.split(",")
        if host.strip()
    ]

    try:
        asyncio.run(
            run(
                args.front,
                args.back,
                args.upstream,
                lease_seconds,
                hold_cap,
                background_hosts,
            )
        )
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
