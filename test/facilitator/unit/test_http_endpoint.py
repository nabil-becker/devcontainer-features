"""The MCP endpoint over HTTP (slice N4; the `http` module, endpoint.py) on loopback with the `mcp` library 2.3.0: a
bearer token or a 401 with no detail; a per-address back-off after 10 failed authentications (the right token
refused too, before it is parsed); a 64 KiB body; a wrong Origin or Host; only /mcp and (with http.issuers, test_oauth.py) the well-known metadata; the
tools an HTTP client is offered (who, say, reply, receive, mail, transcript) and never continue or approve; who showing
a public client only the public-exposed agents; a first message held, released by a person's approve, answered by an
agent and received by the client; `receive` capped at the level's http_receive_wait and at two at a time; a revoked
token refused at once; a message too large and the public rate refused; via in the record. Needs the `mcp` library:
this file runs under a python that has it (FACILITATOR_TEST_MCP_PYTHON, the bundle's own interpreter) and says so when
there is none (the unit tests of the node side are test_http.py)."""
import os
import sys

try:
    import mcp  # noqa: F401
except ImportError:
    py = os.environ.get("FACILITATOR_TEST_MCP_PYTHON")
    if py and os.path.isfile(py) and not os.environ.get("_FAC_REEXEC"):
        os.environ["_FAC_REEXEC"] = "1"
        os.execv(py, [py, "-I", os.path.abspath(__file__)])
    print("skip: the mcp library is not importable here (FACILITATOR_TEST_MCP_PYTHON names a python that has it)")
    sys.exit(0)

from pathlib import Path  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import asyncio  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import socket  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import warnings  # noqa: E402

warnings.simplefilter("ignore")
from facilitator import endpoint  # noqa: E402

MESH = """preset: team
expose:
  jester: public
  "*": local
limits:
  public:
    http_receive_wait: 2s
"""


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Node:
    """A node with its endpoint running in a thread; one client enrolled."""

    def __init__(self, mesh=MESH, abuse=None, extra_fac=""):
        self.port = free_port()
        self.e = helpers.Env(facilitator_yml=f"facilitator:\n  humans: [you]\n  http:\n    listen: 127.0.0.1:{self.port}\n{extra_fac}")
        (self.e.root / ".devcontainer" / "mesh.yml").write_text(mesh)
        self.fac = self.e.register_all()
        self.token = self.fac.enrol_http("cli-one", "you")["token"]
        self.d = endpoint.Daemon(self.fac, abuse)
        threading.Thread(target=self.d.run, daemon=True).start()
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    def close(self):
        if self.d.server:
            self.d.server.should_exit = True
            time.sleep(0.3)
        self.e.close()

    def raw(self, method="POST", path="/mcp", headers=None, body=b"{}", token="__own__"):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **(headers or {})}
        if token == "__own__":
            token = self.token
        if token:
            h["Authorization"] = f"Bearer {token}"
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            c.request(method, path, body=body, headers=h)
            r = c.getresponse()
            return r.status, dict(r.getheaders()), r.read()
        finally:
            c.close()

    def session(self, token=None):
        import contextlib
        import httpx2
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client
        tok, port = token or self.token, self.port

        @contextlib.asynccontextmanager
        async def go():
            async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {tok}"}, timeout=30) as hc:
                async with streamable_http_client(f"http://127.0.0.1:{port}/mcp", http_client=hc) as (r, w):
                    async with ClientSession(r, w) as s:
                        await s.initialize()
                        yield s
        return go()


def call(node, name, args=None):
    async def go():
        async with node.session() as s:
            r = await s.call_tool(name, args or {})
            return r.is_error, r.content[0].text
    return asyncio.run(go())


def test_auth_origin_host_size_and_paths():
    n = Node()
    try:
        st, h, _ = n.raw(token=None)
        assert st == 401 and 'invalid_token' in h.get("www-authenticate", "") and "resource_metadata" not in h.get("www-authenticate", "")
        assert n.raw(token="cli-one.wrong")[0] == 401 and n.raw(token="garbage")[0] == 401
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}).encode()
        st, _, out = n.raw(body=body)
        assert st == 200 and b"facilitator" in out, (st, out[:200])
        assert n.raw(body=body, headers={"Origin": "https://evil.example"})[0] == 403
        assert n.raw(body=body, headers={"Host": "evil.example"})[0] in (400, 403, 421)
        assert n.raw(path="/other")[0] == 404 and n.raw(path="/")[0] == 404
        assert n.raw(path="/.well-known/oauth-protected-resource/mcp", token=None, method="GET")[0] == 404   # no issuers: nothing to publish (N5b)
        st, _, _ = n.raw(body=b"x" * (endpoint.MAX_BODY + 1))
        assert st == 413
        st, _, _ = n.raw(body=b"x" * 10, headers={"Content-Length": str(endpoint.MAX_BODY + 5)})
        assert st in (400, 413)
    finally:
        n.close()


def test_ten_failures_block_the_address_even_for_the_right_token():
    n = Node()
    try:
        for _ in range(endpoint.FAIL_LIMIT):
            assert n.raw(token="cli-one.nope")[0] == 401
        st, h, out = n.raw()                                         # the right token, from the blocked address
        assert st == 429 and h.get("retry-after") == str(endpoint.BLOCK_SECONDS) and b"nope" not in out
    finally:
        n.close()


def test_abuse_state_window_block_and_open_requests():
    now = [1000.0]
    a = endpoint.Abuse(clock=lambda: now[0])
    for _ in range(endpoint.FAIL_LIMIT - 1):
        a.failed("1.2.3.4")
    assert not a.is_blocked("1.2.3.4")
    a.failed("1.2.3.4")
    assert a.is_blocked("1.2.3.4") and not a.is_blocked("5.6.7.8")
    now[0] += endpoint.BLOCK_SECONDS + 1
    assert not a.is_blocked("1.2.3.4")                               # the back-off ends
    for _ in range(endpoint.FAIL_LIMIT - 1):                          # failures outside the window do not add up
        a.failed("9.9.9.9")
        now[0] += endpoint.FAIL_WINDOW / 4
    assert not a.is_blocked("9.9.9.9")
    assert all(a.enter("x") for _ in range(endpoint.MAX_PER_ADDRESS)) and not a.enter("x")
    a.leave("x")
    assert a.enter("x")


def test_tools_offered_and_the_reach_rule():
    n = Node()
    try:
        async def go():
            async with n.session() as s:
                tools = [t.name for t in (await s.list_tools()).tools]
                who = (await s.call_tool("who", {})).content[0].text
                cont = await s.call_tool("continue", {"conversation": "c-1"}) if False else None
                return tools, who
        tools, who = asyncio.run(go())
        assert tools == ["who", "say", "reply", "receive", "mail", "transcript"], tools
        assert "@jester" in who and "domain-expert-one" not in who and "@you" not in who, who
        async def refused():
            async with n.session() as s:
                out = []
                for name in ("continue", "approve"):
                    try:
                        r = await s.call_tool(name, {"conversation": "c-1", "client": "cli-one"})
                        out.append(r.is_error)
                    except Exception:                                # the library refuses a tool that does not exist
                        out.append(True)
                return out
        assert asyncio.run(refused()) == [True, True]
        err, text = call(n, "say", {"text": "@domain-expert-one hi", "conversation": "new"})
        assert err and "is no participant" in text, text
    finally:
        n.close()


def test_first_contact_approve_agent_answers_client_receives_and_via():
    n = Node()
    try:
        fac = n.fac
        fac.state.seen("jester")
        err, text = call(n, "say", {"text": "@jester tell me a joke"})
        assert not err and "held" in text and "a person must approve" in text, text
        j = n.e.session(fac, "jester")
        assert j.receive(0) is None
        fac.approve_client("cli-one", "you")
        got = j.receive(0)
        assert got["from"] == "cli-one"
        j.reply("Why did the packet cross the network?")
        err, text = call(n, "receive", {"wait_seconds": 5})
        assert not err and "MESSAGE in conversation" in text and "packet" in text, text
        err, text = call(n, "reply", {"text": "ha"})
        assert not err and "sent" in text, text
        err, text = call(n, "mail")
        assert not err, text
        conv = fac.conversations_of("cli-one")[0]
        err, text = call(n, "transcript", {"conversation": conv})
        assert not err and "(via HTTP, authenticated by bearer token, client cli-one)" in text, text
        from facilitator import verify
        assert verify.verify(fac, conv)["ok"]
        err, text = call(n, "transcript", {"conversation": "c-00000000"})
        assert err and "you are not in" in text
    finally:
        n.close()


def test_receive_is_capped_by_the_level_and_two_at_a_time():
    n = Node()
    try:
        t0 = time.time()
        err, text = call(n, "receive", {"wait_seconds": 60})       # the public level's http_receive_wait here is 2 s
        assert not err and "nothing yet (waited 2 s)" in text and time.time() - t0 < 20, text
        async def three():
            async with n.session() as s:
                rs = await asyncio.gather(*[s.call_tool("receive", {"wait_seconds": 2}) for _ in range(3)])
                return sorted(r.is_error for r in rs), [r.content[0].text for r in rs]
        errs, texts = asyncio.run(three())
        assert errs == [False, False, True] and any("at most 2 receive calls" in t for t in texts), texts
    finally:
        n.close()


def test_revoke_closes_at_once_and_public_limits_are_refused():
    n = Node()
    try:
        fac = n.fac
        fac.state.seen("jester")
        err, text = call(n, "say", {"text": "@jester x" + "y" * (16 * 1024)})
        assert err and "too large" in text, text
        fac.approve_client("cli-one", "you")
        conv = None
        for i in range(3):
            err, text = call(n, "say", {"text": f"@jester msg {i}", "conversation": conv or "new"})
            assert not err, text
            conv = conv or fac.conversations_of("cli-one")[0]
        err, text = call(n, "say", {"text": "one more", "conversation": conv})
        assert err and "rate limit" in text, text
        fac.revoke_client("cli-one", "you")
        assert n.raw()[0] == 401                                     # at once
        assert n.raw(token=n.token)[0] == 401
    finally:
        n.close()


def test_the_endpoint_refuses_to_start_when_it_may_not():
    e = helpers.Env(facilitator_yml="facilitator:\n  humans: [you]\n  http:\n    listen: 127.0.0.1:18999\n")
    try:
        (e.root / ".devcontainer" / "mesh.yml").write_text("preset: solo\n")
        fac = e.fac()
        try:
            endpoint.Daemon(fac)
            raise AssertionError("solo")
        except endpoint.EndpointError as err:
            assert "preset solo" in str(err)
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
