"""The MCP protocol over stdio (`facilitator mcp --as <handle>`, run as a subprocess and driven by the fake
MCP client): initialize, tools/list, receive blocking and timing out, receive woken by a delivery, reply,
the token check, a cancelled receive taking nothing, and a clean standard output."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402

from fake_mcp import FakeMcpClient, facilitator_argv  # noqa: E402


def client(e, handle, token=True):
    tok = (e.home / "tokens" / handle).read_text().strip() if token is True else token
    return FakeMcpClient(facilitator_argv() + ["mcp", "--as", handle], dict(os.environ), tok, cwd=str(e.root))


def test_initialize_and_tools_list():
    e = helpers.Env()
    c = None
    try:
        e.register_all()
        c = client(e, "jester")
        r = c.initialize()["result"]
        assert r["protocolVersion"] == "2025-06-18"
        assert r["serverInfo"] == {"name": "facilitator", "version": __import__("facilitator").__version__}
        assert "receive" in r["instructions"] and "@jester" in r["instructions"]
        tools = c.request("tools/list")["result"]["tools"]
        assert [t["name"] for t in tools] == ["receive", "reply", "say", "who"]
        assert tools[1]["inputSchema"]["required"] == ["text"]
        assert c.request("ping")["result"] == {}
        assert c.request("no/such")["error"]["code"] == -32601
        old = c.request("initialize", {"protocolVersion": "1999-01-01"})["result"]["protocolVersion"]
        assert old == "2025-11-25"
    finally:
        if c:
            c.close()
            assert c.stray.empty(), "something other than JSON-RPC on standard output"
        e.close()


def test_receive_blocks_and_times_out():
    e = helpers.Env()
    c = None
    try:
        e.register_all()
        c = client(e, "jester")
        c.initialize()
        t0 = time.time()
        r = c.call("receive", {"wait_seconds": 2})
        took = time.time() - t0
        assert "nothing yet" in r["content"][0]["text"] and not r["isError"]
        assert 1.8 <= took < 6, took
        bad = c.call("receive", {"wait_seconds": -1})
        assert bad["isError"]
    finally:
        if c:
            c.close()
        e.close()


def test_receive_is_woken_by_a_delivery_and_reply_routes_back():
    e = helpers.Env()
    c = None
    try:
        fac = e.register_all()
        c = client(e, "jester")
        c.initialize()
        out = {}

        def recv():
            t0 = time.time()
            out["r"] = c.call("receive", {"wait_seconds": 20})
            out["took"] = time.time() - t0
        th = threading.Thread(target=recv)
        th.start()
        time.sleep(1.5)
        sent = fac.send("you", "@jester a joke, please")
        th.join(30)
        m = out["r"]["structuredContent"]["message"]
        assert m["message_id"] == sent["message_id"] and m["from"] == "you"
        assert out["took"] < 6, out["took"]
        r = c.call("reply", {"text": "Knock knock."})
        assert not r["isError"] and r["structuredContent"]["to"] == ["you"], r
        assert r["structuredContent"]["rule"] in ("direct", "asker")
        w = c.call("who")
        assert "@domain-expert-one" in w["content"][0]["text"]
        assert w["structuredContent"]["conversations"] == [sent["conversation"]]
    finally:
        if c:
            c.close()
            assert c.stray.empty()
        e.close()


def test_token_is_checked():
    e = helpers.Env()
    cs = []
    try:
        e.register_all()
        for tok in (None, "not-the-token", (e.home / "tokens" / "domain-expert-one").read_text().strip()):
            c = client(e, "jester", tok)
            cs.append(c)
            c.initialize()                                  # the handshake works; the tools say why not
            r = c.call("receive", {"wait_seconds": 0})
            assert r["isError"] and "FACILITATOR_TOKEN" in r["content"][0]["text"], r
        c = client(e, "nobody", "x")
        cs.append(c)
        c.initialize()
        assert "not a registered participant" in c.call("who")["content"][0]["text"]
    finally:
        for c in cs:
            c.close()
        e.close()


def test_cancelled_receive_takes_nothing():
    e = helpers.Env()
    c = None
    try:
        fac = e.register_all()
        c = client(e, "jester")
        c.initialize()
        rid = c.send("tools/call", {"name": "receive", "arguments": {"wait_seconds": 30}})
        time.sleep(1)
        c.send("notifications/cancelled", {"requestId": rid}, notify=True)
        time.sleep(2.5)
        sent = fac.send("you", "@jester still there?")
        time.sleep(1)
        r = c.call("receive", {"wait_seconds": 5})
        assert r["structuredContent"]["message"]["message_id"] == sent["message_id"]
    finally:
        if c:
            c.close()
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
