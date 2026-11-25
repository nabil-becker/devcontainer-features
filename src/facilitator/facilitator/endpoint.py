"""The `http` module (slice N4; ADR-0070, ADR-0071, ADR-0068): the node's MCP endpoint over HTTP (Streamable HTTP,
the `mcp` Python library 2.3.0 as a resource server on a Starlette app, served by uvicorn) for CLIs that cannot start a
stdio server here: Claude Code (`claude mcp add --transport http`) and GitHub Copilot CLI (`copilot mcp add
--transport http`), each with an `Authorization: Bearer <token>` header.

    facilitator http serve          the `http` part of `infra up` runs this when facilitator.http.listen is set

Off by default, refused under the preset solo, and beyond loopback it needs TLS (http.tls_cert and http.tls_key) or
http.behind_proxy: true. In front of the library an ASGI gate runs the abuse limits (proposal 11.3) before any token is
parsed: a per-address back-off after 10 failed authentications in a minute (10 minutes, no detail in the answer), at
most 20 open requests per source address, a 64 KiB body, only /mcp and the well-known metadata. The library then checks
Host and Origin (DNS rebinding) and the bearer token through `TokenVerifier` (the node's table of hashed tokens).

The tools are the participant set (who, say, reply, receive, mail, transcript); never continue or approve. Every call
is the HttpSession of the client the token names: the node signs for it, every packet carries data.via, the client is
mapped to `http.<home domain>` (public unless mesh.yml says private) and sees only agents exposed at that level.
OAuth (slice N5b): with `http.issuers` set, a token from an allow-listed authorization server (a JWT,
checked by oauth.py: issuer, algorithm, signature, exp, the audience of this node's /mcp URL, the scope) is accepted
beside the bearer tokens; the node publishes the RFC 9728 protected-resource metadata at
/.well-known/oauth-protected-resource[/mcp] and answers 401 with `WWW-Authenticate: Bearer resource_metadata=...` so a
cloud AI finds where to log in (403 insufficient_scope for a token without the scope; 503 when an issuer's keys cannot
be read: closed, and not counted against the caller). The client is the token's (issuer, subject), enrolled on its first
valid token and held for a person's approval; `AccessToken.client_id` carries its handle as for a bearer client.

The `mcp` library is imported here only: a node that never opens the endpoint does not need it."""
from __future__ import annotations

import json
import threading
import time
import sys
from collections import defaultdict, deque

from . import __version__, clients as clients_mod, mesh as mesh_mod, oauth as oauth_mod
from .app import Facilitator, FacilitatorError, HttpSession
from .mcp import mail_text

MAX_BODY = 64 * 1024
MAX_PER_ADDRESS = 20
FAIL_LIMIT, FAIL_WINDOW, BLOCK_SECONDS = 10, 60, 600
MAX_RECEIVES = 2
MAX_LIST = 200
PATH = "/mcp"
WELL_KNOWN = "/.well-known/"
METADATA_PATHS = ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource" + PATH)


INSECURE_WARNING = ("http.insecure: tokens travel in plain text; for a local machine or a test environment only")


class EndpointError(RuntimeError):
    pass


def base_url(cfg) -> str:
    if cfg.url:
        return cfg.url.rstrip("/")
    host, port = mesh_mod.parse_addr(cfg.listen)
    if host in ("0.0.0.0", "::"):
        host = "localhost"
    scheme = "https" if (cfg.tls_cert and cfg.tls_key) else "http"
    return f"{scheme}://{host}:{port}"


def allowed_hosts(cfg) -> list[str]:
    """The Host header values accepted (DNS rebinding): the listen address, the address clients use, loopback names."""
    from urllib.parse import urlsplit
    out = list(cfg.allowed_hosts)
    host, port = mesh_mod.parse_addr(cfg.listen)
    if host not in ("0.0.0.0", "::"):
        out.append(f"{host}:{port}")
    u = urlsplit(base_url(cfg))
    out.append(u.netloc)
    if mesh_mod.is_loopback(host):
        out += [f"localhost:{port}", f"127.0.0.1:{port}", f"[::1]:{port}"]
    return list(dict.fromkeys(out))


class Abuse:
    """Per-address state of the gate: failed authentications (a back-off) and open requests."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self.fails: dict[str, deque] = defaultdict(deque)
        self.blocked: dict[str, float] = {}
        self.open: dict[str, int] = defaultdict(int)
        self.lock = threading.Lock()

    def is_blocked(self, addr: str) -> bool:
        with self.lock:
            until = self.blocked.get(addr)
            if until is None:
                return False
            if self.clock() >= until:
                del self.blocked[addr]
                self.fails.pop(addr, None)
                return False
            return True

    def failed(self, addr: str) -> None:
        with self.lock:
            now = self.clock()
            q = self.fails[addr]
            q.append(now)
            while q and now - q[0] > FAIL_WINDOW:
                q.popleft()
            if len(q) >= FAIL_LIMIT:
                self.blocked[addr] = now + BLOCK_SECONDS

    def enter(self, addr: str) -> bool:
        with self.lock:
            if self.open[addr] >= MAX_PER_ADDRESS:
                return False
            self.open[addr] += 1
            return True

    def leave(self, addr: str) -> None:
        with self.lock:
            self.open[addr] = max(0, self.open[addr] - 1)
            if not self.open[addr]:
                del self.open[addr]


class Gate:
    """The ASGI gate in front of the library (see the module docstring). Answers carry no detail."""

    def __init__(self, app, daemon: "Daemon"):
        self.app, self.d = app, daemon

    @staticmethod
    async def _reply(send, status: int, body: dict | None = None, headers: list | None = None) -> None:
        raw = json.dumps(body or {"error": "refused"}).encode()
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(raw)).encode()),
                                *(headers or [])]})
        await send({"type": "http.response.body", "body": raw})

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        d = self.d
        addr = (scope.get("client") or ("?", 0))[0]
        if d.abuse.is_blocked(addr):                           # before any token is parsed
            return await self._reply(send, 429, {"error": "too many requests"}, [(b"retry-after", str(BLOCK_SECONDS).encode())])
        if not d.abuse.enter(addr):
            return await self._reply(send, 429, {"error": "too many requests"})
        try:
            path = scope.get("path", "")
            if not (path == PATH or path.startswith(PATH + "/") or path.startswith(WELL_KNOWN)):
                return await self._reply(send, 404, {"error": "not found"})
            headers = {k.decode().lower(): v.decode("latin-1") for k, v in scope["headers"]}
            if path.startswith(WELL_KNOWN):
                if path in METADATA_PATHS and scope.get("method") in ("GET", "HEAD") and d.oauth is not None:
                    return await self._reply(send, 200, oauth_mod.metadata(d.resource_url, d.cfg.issuers, d.scope_default),
                                             [(b"cache-control", b"public, max-age=300")])
                return await self._reply(send, 404, {"error": "not found"})
            if path == PATH or path.startswith(PATH + "/"):
                auth = headers.get("authorization", "")
                token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
                who, err = await d.authenticate(token)
                if who is None:
                    if err is not None and err.server:                # the node's or an issuer's fault: closed, not the caller's
                        return await self._reply(send, 503, {"error": "temporarily unavailable"}, [(b"retry-after", b"30")])
                    if err is not None and err.code == "insufficient_scope":
                        return await self._reply(send, 403, {"error": "forbidden"}, [(b"www-authenticate", oauth_mod.challenge(
                            d.metadata_url, "insufficient_scope", d.scope_default))])
                    if token or d.oauth is None:                      # a missing token is not a failed one when OAuth is on (discovery)
                        d.abuse.failed(addr)
                    if d.oauth is None:
                        www = b'Bearer error="invalid_token"'
                    else:
                        www = oauth_mod.challenge(d.metadata_url, "invalid_token" if token else None)
                    return await self._reply(send, 401, {"error": "unauthorized"}, [(b"www-authenticate", www)])
            cl = headers.get("content-length")
            if cl is not None and (not cl.isdigit() or int(cl) > MAX_BODY):
                return await self._reply(send, 413, {"error": "too large"})
            seen = [0]

            async def counted():
                msg = await receive()
                if msg["type"] == "http.request":
                    seen[0] += len(msg.get("body", b""))
                    if seen[0] > MAX_BODY:
                        raise _TooLarge()
                return msg

            try:
                return await self.app(scope, counted, send)
            except _TooLarge:
                return await self._reply(send, 413, {"error": "too large"})
        finally:
            d.abuse.leave(addr)


class _TooLarge(Exception):
    pass


class Daemon:
    """The endpoint of one node: one Facilitator, one lock around it, one HttpSession per client."""

    def __init__(self, fac: Facilitator, abuse: Abuse | None = None):
        ok, why = fac.http_ready()
        if not ok:
            raise EndpointError(why)
        self.fac = fac
        self.cfg = fac.participants()[1].http
        if not self.cfg.active:
            raise EndpointError("facilitator.http.listen is not set (or http.enabled is false): nothing to open (ADR-0071)")
        self.lock = threading.RLock()
        self.sessions: dict[str, HttpSession] = {}
        self.receiving: dict[str, int] = defaultdict(int)
        self.server = None
        self.abuse = abuse or Abuse()
        self.level = fac.mesh.http_level()
        self.wait_cap = mesh_mod.seconds(fac.mesh.limit(self.level, "http_receive_wait")[0])
        base = base_url(self.cfg)
        self.resource_url = f"{base}{PATH}"
        self.metadata_url = f"{base}{METADATA_PATHS[1]}"
        self.scope_default = clients_mod.SCOPE
        self.oauth = oauth_mod.Verifier(self.cfg.issuers, self.resource_url, insecure=self.cfg.insecure) if self.cfg.issuers else None
        self.verified: dict[str, tuple] = {}                  # sha256(token) -> (Principal, until): a few seconds, never the token
        self.logged: dict[str, float] = {}

    # ------------------------------------------------------------ the library's token check

    def _log(self, why: str) -> None:
        """One line on the node's stderr per reason a minute: why a token was refused (never the token)."""
        now = time.time()
        if now - self.logged.get(why, 0) >= 60:
            self.logged[why] = now
            if len(self.logged) > 200:
                self.logged.clear()
            sys.stderr.write(f"facilitator http: a token was refused: {why}\n")
            sys.stderr.flush()

    def authenticate_sync(self, token: str):
        """(the client's handle, None) for a token that may be used now; else (None, why): why is None for a token that is
        no one's (the plain refusal), an OAuthError for a refused OAuth token. A bearer token is the table's; an OAuth
        token is checked by oauth.py and names a client by (issuer, subject), enrolled on its first valid token."""
        got = self.fac.clients.check_token(token)
        if got is not None:
            return got[0], None
        if self.oauth is None or token.count(".") != 2:
            return None, None
        import hashlib
        key = hashlib.sha256(token.encode()).hexdigest()
        now = time.time()
        hit = self.verified.get(key)
        if hit and hit[1] > now:
            pr = hit[0]
        else:
            try:
                pr = self.oauth.verify(token)
            except oauth_mod.OAuthError as e:
                self._log(e.why)
                return None, e
            if len(self.verified) > 1000:
                self.verified.clear()
            self.verified[key] = (pr, min(now + 10, pr.expires_at))
        with self.lock:
            try:
                name, c = self.fac.oauth_client(pr.issuer_name, pr.issuer, pr.subject, pr.client_id)
            except FacilitatorError as e:
                self._log(str(e))
                return None, oauth_mod.OAuthError("invalid_token", str(e))
        if c["status"] not in clients_mod.LIVE:
            self._log(f"the client {name} is {c['status']}")
            return None, oauth_mod.OAuthError("invalid_token", f"the client {name} is {c['status']}")
        return name, None

    async def authenticate(self, token: str):
        import anyio
        if not token:
            return None, None
        return await anyio.to_thread.run_sync(self.authenticate_sync, token)

    def verifier(self):
        from mcp.server.auth.provider import AccessToken

        daemon = self

        class Verifier:
            async def verify_token(self, token: str):
                name, _ = await daemon.authenticate(token)
                if name is None:
                    return None
                oauth = (daemon.fac.clients.get(name) or {}).get("auth") == "oauth"
                return AccessToken(token="oauth" if oauth else "bearer", client_id=name, scopes=[clients_mod.SCOPE],
                                   expires_at=None, resource=None, subject=name, claims={"via": "oauth" if oauth else "bearer"})

        return Verifier()

    # ------------------------------------------------------------ sessions

    def session(self, client: str) -> HttpSession:
        with self.lock:
            c = self.fac.clients.get(client)
            if c is None or c["status"] not in clients_mod.LIVE or not self.fac.is_http(client):
                self.sessions.pop(client, None)
                raise FacilitatorError(f"{client} is not an enrolled HTTP client")
            if client not in self.sessions:
                self.sessions[client] = HttpSession(self.fac, client)
            self.fac.clients.seen(client)
            return self.sessions[client]

    # ------------------------------------------------------------ the app

    def build(self):
        import anyio
        from mcp.server.auth.middleware.auth_context import get_access_token
        from mcp.server.auth.settings import AuthSettings
        from mcp.server.mcpserver import MCPServer
        from mcp.server.transport_security import TransportSecuritySettings

        base = base_url(self.cfg)
        server = MCPServer(
            "facilitator", version=__version__,
            instructions=(f"The facilitator's conversations with agents, as an HTTP client of this node (level {self.level}). "
                          "Loop: call receive; when it returns a message, answer with reply, then call receive again. "
                          "say starts a conversation with a handle who lists (to=[handle]). You see only the agents this "
                          "node exposes to you; your first message may wait for a person's approval."),
            token_verifier=self.verifier(),
            auth=AuthSettings(issuer_url=self.cfg.issuers[0].issuer if self.cfg.issuers else base, resource_server_url=self.resource_url, required_scopes=[clients_mod.SCOPE],
                              validate_token_resource=False))

        def me() -> str:
            t = get_access_token()
            if t is None:
                raise ToolError("not authenticated")
            return t.client_id

        from mcp.server.mcpserver.exceptions import ToolError

        async def run(fn):
            """The call in a thread; what it refuses is said to the client in the refusal's own words."""
            try:
                return await anyio.to_thread.run_sync(fn)
            except ToolError:
                raise
            except Exception as e:             # noqa: BLE001 - every failure is the caller's to read
                raise ToolError(str(e)) from None

        def locked(client, fn):
            def go():
                with self.lock:
                    return fn(self.session(client))
            return go

        @server.tool(name="who", description="The handles you can address: the agents this node exposes to you, and the "
                                             "conversations you are in. An agent you cannot reach is not listed.",
                     structured_output=False)
        async def who() -> str:
            w = await run(locked(me(), lambda s: s.who()))
            lines = [f"@{p['handle']} ({p['kind']}{', attached' if p.get('attached') else ''})"
                     + (f": {p['description']}" if p.get("description") else "") for p in w["participants"]]
            lines.append(f"your conversations: {', '.join(w.get('conversations', [])) or 'none yet'}")
            return "\n".join(lines)

        @server.tool(name="say", description="Start a conversation with an agent (conversation 'new' or none, with to or "
                                             "an @handle in the text) or write in one you are in (its id). Held for a "
                                             "person's approval on your first contact.", structured_output=False)
        async def say(text: str, conversation: str | None = None, to: list[str] | None = None) -> str:
            if not text.strip():
                raise ToolError("say needs text")
            r = await run(locked(me(), lambda s: s.say(conversation, text, to)))
            return _routed(r)

        @server.tool(name="reply", description="Answer the message receive handed you. Start the text with @handle (or "
                                               "pass to) to address someone else; with no mention it goes back to the asker.",
                     structured_output=False)
        async def reply(text: str, to: list[str] | None = None) -> str:
            if not text.strip():
                raise ToolError("reply needs text")
            r = await run(locked(me(), lambda s: s.reply(text, to)))
            return _routed(r)

        @server.tool(name="receive", description=f"Wait for the next message delivered to you, at most {self.wait_cap} s at "
                                                 "this level (call again when nothing came).", structured_output=False)
        async def receive(wait_seconds: int | None = None) -> str:
            client = me()
            wait = self.wait_cap if wait_seconds is None else wait_seconds
            if not isinstance(wait, int) or wait < 0:
                raise ToolError("wait_seconds: a whole number of seconds, 0 or more")
            wait = min(wait, self.wait_cap)
            with self.lock:
                if self.receiving[client] >= MAX_RECEIVES:
                    raise ToolError(f"at most {MAX_RECEIVES} receive calls at a time per client")
                self.receiving[client] += 1
            try:
                end = time.time() + wait
                while True:
                    got = await run(locked(client, lambda s: s.receive(0)))
                    if got is not None:
                        break
                    if time.time() >= end:
                        return f"nothing yet (waited {wait} s); call receive again."
                    await anyio.sleep(0.5)
            finally:
                with self.lock:
                    self.receiving[client] -= 1
            return (f"MESSAGE in conversation {got['conversation']} (members: {', '.join(got['members'])}), message "
                    f"{got['message_id']}, {got['hops']} hop(s) from the person or client who began it:\n{got['text']}\n\n"
                    f"Answer with reply (with no mention it goes back to @{got['from']}), then call receive again.")

        @server.tool(name="mail", description="The messages that came in, unread, from every conversation you are in; they "
                                              "are then marked read. Never waits.", structured_output=False)
        async def mail(limit: int = 20) -> str:
            if not 1 <= limit <= MAX_LIST:
                raise ToolError(f"limit: a whole number, 1 to {MAX_LIST}")
            return mail_text(await run(locked(me(), lambda s: s.mail(limit))))

        @server.tool(name="transcript", description="A conversation you are in, read only: every message with its routes, "
                                                    "notices and how each was signed (via).", structured_output=False)
        async def transcript(conversation: str, limit: int = 50) -> str:
            if not 1 <= limit <= 500:
                raise ToolError("limit: a whole number, 1 to 500")
            return "\n".join(await run(locked(me(), lambda s: s.transcript(conversation, limit))))

        sec = TransportSecuritySettings(enable_dns_rebinding_protection=True, allowed_hosts=allowed_hosts(self.cfg),
                                        allowed_origins=list(self.cfg.allowed_origins))
        host, _ = mesh_mod.parse_addr(self.cfg.listen)
        app = server.streamable_http_app(streamable_http_path=PATH, stateless_http=True, json_response=False,
                                         transport_security=sec, host=host, max_request_body_size=MAX_BODY)
        return Gate(app, self)

    # ------------------------------------------------------------ run

    def run(self) -> int:
        import uvicorn
        host, port = mesh_mod.parse_addr(self.cfg.listen)
        h = self.fac.state.home / "http"
        h.mkdir(parents=True, exist_ok=True)
        import os
        status = h / "status.json"
        self.fac.state.write_private(status, json.dumps({"pid": os.getpid(), "listen": self.cfg.listen, "url": base_url(self.cfg),
                                                         "level": self.level, "started": clients_mod.now_iso()}) + "\n")
        if self.cfg.insecure:
            print("facilitator: warning: " + INSECURE_WARNING, file=sys.stderr, flush=True)
        conf = uvicorn.Config(self.build(), host=host, port=port, log_level="warning", access_log=False, server_header=False,
                              ssl_certfile=self.cfg.tls_cert, ssl_keyfile=self.cfg.tls_key,
                              proxy_headers=self.cfg.behind_proxy, forwarded_allow_ips="*" if self.cfg.behind_proxy else None,
                              timeout_keep_alive=5)
        self.server = uvicorn.Server(conf)
        try:
            self.server.run()
        finally:
            try:
                status.unlink()
            except OSError:
                pass
        return 0


def _routed(r: dict) -> str:
    if not r.get("delivered", True):
        return f"written ({r['message_id']}) and held: {'; '.join(r['notices'])}"
    to = ", ".join("@" + h for h in r["to"]) or "nobody"
    extra = f" ({'; '.join(r['notices'])})" if r.get("notices") else ""
    return f"sent {r['message_id']} in {r['conversation']} to {to} by rule {r['rule']}{extra}."
