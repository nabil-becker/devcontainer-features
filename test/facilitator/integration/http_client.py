"""The leaf client of test/facilitator/http_flow.sh: a bare MCP client over Streamable HTTP with a bearer token (the
`mcp` library's own client), the fallback for a vendor CLI that cannot run here (proposal 11.1). Run under the
bundle's python. One step per call; prints JSON lines; exit 0 when every assertion held.

    http_client.py <url> <token> edge          401 with no token and a wrong one, 413, the Origin check, 404, the tool list
    http_client.py <url> <token> hello         who (only the public agent), a message to a hidden one, a first message (held)
    http_client.py <url> <token> converse <conversation>    receive the answer, reply, read the transcript (via), mail
    http_client.py <url> <token> limits <conversation>      the public rate and the size refused
    http_client.py <url> <token> closed        the token no longer works (401)
"""
import asyncio
import http.client
import json
import os
import sys
from urllib.parse import urlsplit

import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


def say_ok(what: str) -> None:
    print(json.dumps({"ok": what}), flush=True)


def need(cond, what: str) -> None:
    if not cond:
        print(json.dumps({"FAIL": what}), flush=True)
        sys.exit(1)
    say_ok(what)


def raw(url, token, method="POST", path="/mcp", headers=None, body=b"{}"):
    u = urlsplit(url)
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **(headers or {})}
    if token:
        h["Authorization"] = f"Bearer {token}"
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    out = (r.status, dict(r.getheaders()), r.read())
    c.close()
    return out


async def with_session(url, token, fn):
    async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {token}"}, timeout=60) as hc:
        async with streamable_http_client(url, http_client=hc) as (r, w):
            async with ClientSession(r, w) as s:
                await s.initialize()
                return await fn(s)


async def tool(s, name, args=None):
    r = await s.call_tool(name, args or {})
    return r.is_error, r.content[0].text


def main(argv):
    base, token, step = argv[1], argv[2], argv[3]
    url = base.rstrip("/") + "/mcp"
    if step == "edge":
        need(raw(base, None)[0] == 401, "no token: 401")
        st, h, _ = raw(base, "x.wrong")
        need(st == 401 and "resource_metadata" not in h.get("www-authenticate", ""), "a wrong token: 401, no detail")
        need(raw(base, token, body=b"x" * 70000)[0] == 413, "a 70 KB body: 413")
        need(raw(base, token, headers={"Origin": "https://evil.example"})[0] == 403, "a foreign Origin: 403")
        need(raw(base, token, path="/admin")[0] == 404, "another path: 404")

        async def tools(s):
            return [t.name for t in (await s.list_tools()).tools]
        names = asyncio.run(with_session(url, token, tools))
        need(names == ["who", "say", "reply", "receive", "mail", "transcript"], f"the tools offered: {names}")
        return 0
    if step == "hello":
        async def go(s):
            _, who = await tool(s, "who")
            need("@jester" in who and "domain-expert-one" not in who, "who lists only the public agent")
            err, text = await tool(s, "say", {"text": "@domain-expert-one hello", "conversation": "new"})
            need(err and "is no participant" in text, "a hidden agent reads as one that does not exist")
            err, text = await tool(s, "say", {"text": "@jester tell me a joke"})
            need(not err and "held" in text and "a person must approve" in text, "the first message is held for approval")
            _, who = await tool(s, "who")
            conv = who.split("your conversations: ")[1].split(",")[0].strip()
            print(json.dumps({"conversation": conv}), flush=True)
        asyncio.run(with_session(url, token, go))
        return 0
    if step == "converse":
        conv = argv[4]

        async def go(s):
            err, text = await tool(s, "receive", {"wait_seconds": 25})
            need(not err and "MESSAGE in conversation" in text and "packet" in text, "receive: the agent's answer")
            err, text = await tool(s, "reply", {"text": "thanks"})
            need(not err and "sent" in text, "reply")
            err, text = await tool(s, "transcript", {"conversation": conv})
            how = os.environ.get("HTTP_CLIENT_VIA", "bearer token")                 # "OAuth" in test/facilitator/oauth_flow.sh
            need(f"(via HTTP, authenticated by {how}, client" in text, f"transcript shows via ({how})")
            err, text = await tool(s, "mail")
            need(not err, "mail")
            err, text = await tool(s, "transcript", {"conversation": "c-00000000"})
            need(err and "you are not in" in text, "transcript of a conversation it is not in: refused")
        asyncio.run(with_session(url, token, go))
        return 0
    if step == "limits":
        conv = argv[4]

        async def go(s):
            err, text = await tool(s, "say", {"text": "@jester " + "x" * 17000, "conversation": "new"})
            need(err and "too large" in text, "a message past max_packet is refused")
            n = 0
            for i in range(6):
                err, text = await tool(s, "say", {"text": f"@jester again {i}", "conversation": conv})
                if err:
                    need("rate limit" in text, "the public rate is refused")
                    return
                n += 1
            need(False, f"no rate limit after {n} messages")
        asyncio.run(with_session(url, token, go))
        return 0
    if step == "closed":
        need(raw(base, token)[0] == 401, "a revoked token: 401 at once")
        return 0
    print("no step " + step)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
