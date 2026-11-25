"""A person's attachment over MCP (0.2.0, the Operator's MCP-only ruling of 2026-11-20): the tools a
human-kind session gets (say, mail, transcript, continue, who) and an agent's refused; an agent cannot be
a person; mail never blocks, lists several unread messages by conversation and marks them read;
FACILITATOR_HANDLE in place of --as; the turn hook's one line, silent when there is nothing and never
failing; snippet's shared entry; chat, send and continue gone from the command line."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

from fake_mcp import FakeMcpClient, facilitator_argv  # noqa: E402
from facilitator.app import FacilitatorError  # noqa: E402


def client(e, handle=None, token=True, env=None):
    """`facilitator mcp`, with --as when `handle` is given; else the handle from `env`."""
    tok = (e.home / "tokens" / (handle or env["FACILITATOR_HANDLE"])).read_text().strip() if token is True else token
    argv = facilitator_argv() + ["mcp"] + (["--as", handle] if handle else [])
    return FakeMcpClient(argv, {**os.environ, **(env or {})}, tok, cwd=str(e.root))


def cli(e, *args, env=None):
    return subprocess.run(facilitator_argv() + list(args), cwd=e.root, env={**os.environ, **(env or {})},
                          capture_output=True, text=True, timeout=60)


def test_person_tools_over_mcp_and_handle_from_the_environment():
    e = helpers.Env()
    c = None
    try:
        fac = e.register_all()
        fac.state.seen("jester")
        c = client(e, env={"FACILITATOR_HANDLE": "you"})           # no --as: FACILITATOR_HANDLE
        init = c.initialize()["result"]
        assert "mail" in init["instructions"] and "@you" in init["instructions"]
        tools = c.request("tools/list")["result"]["tools"]
        assert [t["name"] for t in tools] == ["say", "mail", "transcript", "continue", "approve", "deny", "who"]
        t0 = time.time()
        r = c.call("mail")
        assert time.time() - t0 < 5 and r["content"][0]["text"] == "no new messages", r   # never waits
        s = c.call("say", {"text": "@jester tell me a joke"})
        assert not s["isError"] and s["structuredContent"]["to"] == ["jester"], s
        conv = s["structuredContent"]["conversation"]
        j = e.session(fac, "jester")
        got = j.receive(0)
        assert got["from"] == "you" and got["hops"] == 0
        j.reply("Why did the packet cross the network?")
        r = c.call("mail")
        assert "1 new message" in r["content"][0]["text"] and "Why did the packet" in r["content"][0]["text"], r
        assert r["structuredContent"]["messages"][0]["for_you"] is True
        assert c.call("mail")["content"][0]["text"] == "no new messages"               # marked read
        tr = c.call("transcript", {"conversation": conv, "limit": 1})
        text = tr["content"][0]["text"]
        assert "1 earlier message(s) not shown" in text and "packet" in text and "tell me a joke" not in text, text
        w = c.call("who")
        assert w["structuredContent"]["conversations"] == [conv]
        for bad in ("receive", "reply"):
            x = c.call(bad, {"text": "x"} if bad == "reply" else {})
            assert x["isError"] and "a person reads with mail" in x["content"][0]["text"], x
        x = c.call("transcript", {"conversation": "c-00000000"})
        assert x["isError"] and "not in c-00000000" in x["content"][0]["text"], x
    finally:
        if c:
            c.close()
            assert c.stray.empty()
        e.close()


def test_mail_lists_several_unread_by_conversation_with_a_limit():
    e = helpers.Env()
    try:
        fac = e.register_all()
        for h in ("jester", "domain-expert-one"):
            fac.state.seen(h)
        a = fac.send("you", "@jester one")["conversation"]
        b = fac.send("you", "@domain-expert-one two")["conversation"]
        j, d = e.session(fac, "jester"), e.session(fac, "domain-expert-one")
        j.receive(0)
        j.reply("j1")
        time.sleep(1.1)                                   # the record's times are to the second
        d.receive(0)
        d.reply("d1")
        j.reply("j2")                                     # later than d1, still listed with its conversation
        assert fac.mail_notice("you") == f"Facilitator: 3 new messages in {a}, {b}"
        r = fac.mail("you", limit=2)
        assert [(m["conversation"], m["text"]) for m in r["messages"]] == [(a, "j1"), (a, "j2")], r
        assert r["more"] == 1
        from facilitator.mcp import mail_text
        t = mail_text(r)
        assert t.splitlines()[0] == "2 new messages:" and t.splitlines()[1].startswith(f"conversation {a} (you, jester)")
        assert "1 more unread: call mail again" in t
        assert fac.mail_notice("you") == f"Facilitator: 1 new message in {b}"
        r = fac.mail("you")
        assert [m["text"] for m in r["messages"]] == ["d1"] and r["more"] == 0
        assert fac.mail_notice("you") == ""
        assert fac.mail("you")["messages"] == []
    finally:
        e.close()


def test_agent_cannot_continue_nor_be_a_person():
    e = helpers.Env(FACILITATOR_HOP_LIMIT=1)
    c = None
    try:
        fac = e.register_all()
        for h in ("jester", "domain-expert-one"):
            fac.state.seen(h)
        conv = fac.new_conversation("you", ["jester", "domain-expert-one"])
        fac.send("you", "@jester go", conv)
        j, d = e.session(fac, "jester"), e.session(fac, "domain-expert-one")
        j.receive(0)
        j.reply("@domain-expert-one hi")
        d.receive(0)
        held = d.reply("@jester hi back")
        assert not held["delivered"]
        # the session refuses the person's tools to an agent
        for call in (lambda: j.continue_(conv), lambda: j.mail(), lambda: j.transcript(conv)):
            try:
                call()
                raise AssertionError("an agent used a person's tool")
            except FacilitatorError as x:
                assert "only a human-kind participant" in str(x)
        try:
            fac.continue_("jester", conv)
            raise AssertionError("an agent continued")
        except FacilitatorError as x:
            assert "only a person" in str(x)
        # over MCP: continue is not listed for an agent, and refused when called
        c = client(e, "jester")
        c.initialize()
        assert "continue" not in [t["name"] for t in c.request("tools/list")["result"]["tools"]]
        x = c.call("continue", {"conversation": conv})
        assert x["isError"] and "only a person" in x["content"][0]["text"], x
        c.close()
        # an agent's token does not open the person's handle; the kind is the roster's, never the caller's
        c = client(e, "you", (e.home / "tokens" / "jester").read_text().strip())
        c.initialize()
        x = c.call("mail")
        assert x["isError"] and "FACILITATOR_TOKEN does not match" in x["content"][0]["text"], x
        # a roster entry of kind human that facilitator.yml no longer lists is refused
        fac.state.set_identity("jester", kind="human")
        try:
            e.session(fac, "jester")
            raise AssertionError("a person not in facilitator.yml attached")
        except FacilitatorError as x:
            assert "not in facilitator.yml's humans" in str(x)
        fac.state.set_identity("jester", kind="agent")
        _, proj, _ = fac.record.read(conv)
        assert proj["continues"] == []
        assert e.session(fac, "you").continue_(conv)["delivered"]
    finally:
        if c:
            c.close()
        e.close()


def test_mcp_needs_a_handle():
    e = helpers.Env()
    try:
        e.register_all()
        env = {k: v for k, v in os.environ.items() if k != "FACILITATOR_HANDLE"}
        r = subprocess.run(facilitator_argv() + ["mcp"], cwd=e.root, env=env, input="", capture_output=True,
                           text=True, timeout=30)
        assert r.returncode == 2 and "FACILITATOR_HANDLE" in r.stderr and "--as" in r.stderr, (r.returncode, r.stderr)
        assert r.stdout == ""
    finally:
        e.close()


def test_the_turn_hook_prints_one_line_or_nothing_and_never_fails():
    e = helpers.Env()
    try:
        fac = e.register_all()
        fac.state.seen("jester")
        r = cli(e, "mail", "--as", "you", "--notice")
        assert r.returncode == 0 and r.stdout == "", r
        assert cli(e, "mail", "--as", "you", "--hook").stdout == ""
        conv = fac.send("you", "@jester hi")["conversation"]
        j = e.session(fac, "jester")
        j.receive(0)
        j.reply("hello")
        j.reply("and again")
        r = cli(e, "mail", "--notice", env={"FACILITATOR_HANDLE": "you"})
        assert r.returncode == 0 and r.stdout == f"Facilitator: 2 new messages in {conv}\n", r
        r = cli(e, "mail", "--as", "you", "--hook")
        h = json.loads(r.stdout)
        assert h["systemMessage"] == f"Facilitator: 2 new messages in {conv}"
        assert h["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit"
        assert "mail tool" in h["hookSpecificOutput"]["additionalContext"]
        again = cli(e, "mail", "--as", "you", "--notice")             # the cached answer: the same line
        assert again.stdout == f"Facilitator: 2 new messages in {conv}\n"
        r = cli(e, "mail", "--as", "you", "--json")                    # the CLI reads, never marks read
        assert len(json.loads(r.stdout)["messages"]) == 2
        assert cli(e, "mail", "--as", "you", "--notice").stdout.startswith("Facilitator: 2 new")
        fac.mail("you")                                                 # the MCP tool marks them read
        assert cli(e, "mail", "--as", "you", "--notice").stdout == ""
        # never a failure: no handle, a broken state folder, a handle that is nobody
        assert cli(e, "mail", "--notice", env={"FACILITATOR_HANDLE": ""}) .returncode == 0
        bad = cli(e, "mail", "--as", "you", "--notice", env={"FACILITATOR_HOME": "/proc/nope", "FACILITATOR_BACKEND": "lean"})
        assert bad.returncode == 0 and bad.stdout == "", bad
        assert cli(e, "mail", "--as", "nobody", "--hook").returncode == 0
    finally:
        e.close()


def test_snippet_prints_one_shared_entry_and_the_environment():
    e = helpers.Env()
    try:
        e.register_all()
        a = json.loads(cli(e, "snippet", "domain-expert-one", "--json").stdout)
        assert a["mcp_config"]["mcpServers"]["facilitator"]["args"] == ["mcp"]          # no --as
        assert a["add"] == "claude mcp add --scope user facilitator -- facilitator mcp"
        assert a["env"][0] == "FACILITATOR_HANDLE=domain-expert-one" and a["env"][1].startswith("FACILITATOR_TOKEN=")
        text = cli(e, "snippet", "domain-expert-one").stdout
        assert "--as" not in text and "FACILITATOR_HANDLE=domain-expert-one" in text
        p = json.loads(cli(e, "snippet", "you", "--json").stdout)
        assert p["kind"] == "human" and p["add"] == a["add"]
        hook = p["hook"]["hooks"]["UserPromptSubmit"][0]["hooks"][0]
        assert hook["command"] == "facilitator mail --as you --hook 2>/dev/null || true" and hook["timeout"] == 10
        assert "Copilot" in cli(e, "snippet", "you").stdout
    finally:
        e.close()


def test_chat_send_and_continue_are_gone_from_the_command_line():
    e = helpers.Env()
    try:
        for verb in ("chat", "send", "continue"):
            r = cli(e, verb, "--help")
            assert r.returncode == 2 and "invalid choice" in r.stderr, (verb, r.stderr)
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
