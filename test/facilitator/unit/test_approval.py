"""Gate A of the Operator's ruling of 2026-11-25 (cross-node-approval, facilitator 0.9.0): limits.<level>.approval holds what
crosses between nodes until a person approves it. No network and no SLIM: another node's agent is a card the node admitted and
a key the test holds, whose entries (a message, and the route its node's facilitator writes for it) are signed here.

First, the facts of 0.8.0 (what first-contact does at private), then every-message and per-conversation: the value checks, held
messages in the record, mail and the turn-hook line, approve and deny, the 7-day rule, a person only, the audit register, verify,
and HTTP clients."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

from facilitator import identity, mesh as mesh_mod, verify as verify_mod  # noqa: E402
from facilitator.app import FacilitatorError, HELD_DAYS, Session  # noqa: E402
from registerengine import adapters  # noqa: E402

TEAM = """preset: team
role: peer
node:
  id: node-a
  name: a.mesh.test
  domain: a.mesh.test
  listen:
    private: 0.0.0.0:46358
  join: 0.0.0.0:46359
trust:
  a.mesh.test: private
expose:
  "*": private
limits:
  private:
    approval: {mode}
"""


def env_with(mode="none", text=None):
    e = helpers.Env()
    (e.root / ".devcontainer" / "mesh.yml").write_text(text or TEAM.format(mode=mode))
    (e.root / ".devcontainer" / "facilitator.yml").write_text("humans: [you]\n")
    return e


class Remote:
    """Another node's agent `p1` on node `node-b`, level private: its card admitted, and its key (also its facilitator's) held here."""

    def __init__(self, fac, node="node-b", level="private"):
        self.fac, self.node, self.principal = fac, node, f"p1.{node}"
        def newkey(name):
            pk = Path(fac.state.home) / f"{name}-{node}"
            assert subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(pk)], capture_output=True).returncode == 0
            pub = pk.with_suffix(".pub").read_text().split()
            return f"{pub[0]} {pub[1]}", pk

        self.key, self.path = newkey("agent")             # p1's
        fkey, self.fpath = newkey("facilitator")          # its node's facilitator's: the anchor of the routes it writes
        card = {"v": 1, "node": node, "domain": "a.mesh.test", "id": f"spiffe://a.mesh.test/node/{node}", "cert": "x",
                "facilitator": fkey, "participants": [{"handle": "p1", "key": self.key, "kind": "agent", "exposure": level}],
                "at": identity.now_utc(), "sig": "x"}
        fac.net.save_card(card, level)

    def conversation(self, local="jester"):
        return self.fac.new_conversation(local, [self.principal])

    def say(self, conv, text, local="jester", hops=1):
        """A message of the remote agent to a local agent, and the route its node's facilitator wrote for it (a task)."""
        fac = self.fac
        mid = "m-" + __import__("secrets").token_hex(6)
        rec = fac.record
        data = {"thread": conv, "message_id": mid, "parts": [{"kind": "text", "text": text}], "root": "m-aaaaaaaaaaaa",
                "hops": hops, "to": [fac.p(conv, local)]}
        for who, kind, d, path in ((self.principal, "message", data, self.path),
                             ("facilitator", "route", {"thread": conv, "message_id": mid, "rule": "mention",
                                                       "to": [fac.p(conv, local)],
                                                       "tasks": [{"task": "t-" + __import__("secrets").token_hex(6),
                                                                  "assignee": fac.p(conv, local)}], "held": []}, self.fpath)):
            adapters.add(rec.store(conv), str(path), who, kind, d, rec.anchors_for(conv), checked=rec.checked,
                         register=conv, kinds=rec.kinds)
        return mid


def waiting(fac, handle="jester"):
    return [p["message"]["message_id"] for p in fac.pending(handle)]


# ---------------------------------------------------------------- step 1: the facts of 0.8.0

def test_first_contact_is_enforced_for_another_nodes_agent_at_private_too():
    """FACT (0.8.0): approval is read from the sender's card level, whatever the level: first-contact at private holds the
    first message of a private node's agent until a person approves that agent (not only at public)."""
    e = env_with("first-contact")
    try:
        fac = e.register_all()
        r = Remote(fac)
        conv = r.conversation()
        mid = r.say(conv, "hello")
        assert waiting(fac) == [] and fac.remote_first_contact(r.principal)           # held, not handed to the agent
        assert [a["client"] for a in fac.pending_approvals()] == [r.principal]        # and shown to a person
        fac.approve_client(r.principal, "you")
        assert waiting(fac) == [mid]                                                  # approved: delivered
        # and with none (the default of private) it flows
        e2 = env_with("none")
        try:
            f2 = e2.register_all()
            r2 = Remote(f2)
            c2 = r2.conversation()
            assert waiting(f2) == [] and r2.say(c2, "hi") in waiting(f2)
        finally:
            e2.close()
    finally:
        e.close()


# ---------------------------------------------------------------- mesh.yml

def test_the_new_values_parse_at_private_and_public_and_are_refused_at_local():
    for v in ("every-message", "per-conversation", "first-contact", "none"):
        for lv in ("private", "public"):
            m = mesh_mod.parse(f"preset: open\nlimits:\n  {lv}:\n    approval: {v}\n", Path("mesh.yml"))
            assert not m.findings and m.limit(lv, "approval")[0] == v, (v, lv, m.findings)
    for v in ("every-message", "per-conversation"):
        m = mesh_mod.parse(f"preset: team\nlimits:\n  local:\n    approval: {v}\n", Path("mesh.yml"))
        assert any(f.rule == "bad-value" and "local" in f.message for f in m.findings), m.findings
    m = mesh_mod.parse("preset: team\nlimits:\n  local:\n    approval: first-contact\n", Path("mesh.yml"))
    assert not m.findings                                   # as before
    m = mesh_mod.parse("preset: team\nlimits:\n  private:\n    approval: sometimes\n", Path("mesh.yml"))
    assert any("every-message" in f.message for f in m.findings)


def test_check_and_explain_show_the_effective_approval():
    e = env_with("every-message")
    try:
        e.register_all()
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "check", "--json"],
                           capture_output=True, text=True)
        parts = {p["part"]: p for p in json.loads(r.stdout)}
        assert "private every-message (mesh.yml)" in parts["approval"]["detail"], r.stdout[-800:]
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "explain",
                            "spiffe://a.mesh.test/node/node-b/agent/p1"], capture_output=True, text=True)
        assert "approval: every-message (mesh.yml limits.private.approval)" in r.stdout, r.stdout + r.stderr
    finally:
        e.close()


# ---------------------------------------------------------------- every-message

def test_every_message_holds_each_message_until_a_person_approves_that_message():
    e = env_with("every-message")
    try:
        fac = e.register_all()
        r = Remote(fac)
        conv = r.conversation()
        m1, m2 = r.say(conv, "first\nmore lines"), r.say(conv, "second")
        assert waiting(fac) == []
        held = fac.held_messages()
        assert [h["message_id"] for h in held] == [m1, m2] and held[0]["node"] == "node-b" and held[0]["line"] == "first"
        assert held[0]["mode"] == "every-message" and held[0]["level"] == "private" and held[0]["from"] == r.principal
        # the record marks it held: a notice of this node's facilitator, once
        assert fac.note_held(conv) == 2 and fac.note_held(conv) == 0
        _, proj, _ = fac.record.read(conv)
        assert [n["code"] for n in proj["notices"]] == ["approval", "approval"] and "held at node-a" in proj["notices"][0]["text"]
        # mail lists them; the turn hook counts them
        s = e.session(fac, "you")
        mail = s.mail()
        assert [h["message_id"] for h in mail["held"]] == [m1, m2]
        from facilitator.mcp import mail_text
        assert f"HELD {m1} from {r.principal} (node node-b, private, every-message)" in mail_text(mail)
        assert "2 messages held for your approval" in fac.mail_notice("you")
        # approve one message: only it flows
        out = s.approve(m1)
        assert out["answered"][0]["answer"] == "approved" and out["answered"][0]["delivered"]
        assert waiting(fac) == [m1] and [h["message_id"] for h in fac.held_messages()] == [m2]
        _, proj, _ = fac.record.read(conv)
        assert any(n["code"] == "approved" and "approved by you at node-a" in n["text"] for n in proj["notices"])
        # the audit register has it, signed
        ev = [x for x in fac.audit.events() if x["event"] == "message-approved"]
        assert ev and ev[0]["subject"] == m1 and ev[0]["by"] == "you"
        # deny the other: not delivered, a signed notice to the sender in the conversation
        s.deny(m2)
        assert waiting(fac) == [m1] and fac.held_messages() == []
        _, proj, _ = fac.record.read(conv)
        assert any(n["code"] == "denied" and {"thread": conv, "message_id": m2} in n["refs"] for n in proj["notices"])
        assert any(x["event"] == "message-denied" and x["subject"] == m2 for x in fac.audit.events())
        assert "held for your approval" not in fac.mail_notice("you")
        # a third message is held again
        m3 = r.say(conv, "third")
        assert [h["message_id"] for h in fac.held_messages()] == [m3]
    finally:
        e.close()


def test_per_conversation_holds_the_first_message_and_the_rest_flows_once_approved():
    e = env_with("per-conversation")
    try:
        fac = e.register_all()
        r = Remote(fac)
        c1, c2 = r.conversation(), r.conversation("domain-expert-one")
        a1 = r.say(c1, "opening")
        assert waiting(fac) == [] and [h["message_id"] for h in fac.held_messages()] == [a1]
        r.say(c1, "still held")
        fac.answer_message(c1, "you", True)                   # by conversation: everything held in it
        assert len(waiting(fac)) == 2 and fac.held_messages() == []
        a3 = r.say(c1, "later")
        assert a3 in waiting(fac) and fac.held_messages() == []        # the conversation flows now
        b1 = r.say(c2, "another conversation", local="domain-expert-one")          # a new conversation: held again
        assert waiting(fac, "domain-expert-one") == [] and [h["message_id"] for h in fac.held_messages()] == [b1]
        fac.answer_message(b1, "you", False)
        b2 = r.say(c2, "after a denial", local="domain-expert-one")
        assert waiting(fac, "domain-expert-one") == [] and [h["message_id"] for h in fac.held_messages()] == [b2]
    finally:
        e.close()


def test_a_message_held_longer_than_seven_days_is_not_delivered_even_when_approved():
    e = env_with("every-message")
    try:
        fac = e.register_all()
        r = Remote(fac)
        conv = r.conversation()
        mid = r.say(conv, "old")
        # the message's time is its entry's: make this node's clock eight days later
        real = time.time
        time.time = lambda: real() + (HELD_DAYS + 1) * 86400
        try:
            held = fac.held_messages()
            assert held and held[0]["expired"]
            out = fac.answer_message(mid, "you", True)
            assert out["answered"][0]["answer"] == "expired" and not out["answered"][0]["delivered"]
            assert waiting(fac) == []
            _, proj, _ = fac.record.read(conv)
            assert not any(n["code"] == "approved" for n in proj["notices"])
            assert any("more than 7 days" in n["text"] for n in proj["notices"])
        finally:
            time.time = real
    finally:
        e.close()


def test_the_receiving_node_decides_and_another_nodes_notice_answers_nothing():
    e = env_with("every-message")
    try:
        fac = e.register_all()
        r = Remote(fac)
        conv = r.conversation()
        mid = r.say(conv, "pushy")
        # the sending node's facilitator signs an 'approved' notice for its own message: it does not count here
        rec = fac.record
        adapters.add(rec.store(conv), str(r.fpath), "facilitator", "notice",
                     {"thread": conv, "code": "approved", "text": "approved by me", "refs": [{"thread": conv, "message_id": mid}]},
                     rec.anchors_for(conv), checked=rec.checked, register=conv, kinds=rec.kinds)
        assert waiting(fac) == [] and [h["message_id"] for h in fac.held_messages()] == [mid]
        # with none, the same message flows: each node restricts the other by its own mesh.yml
        (e.root / ".devcontainer" / "mesh.yml").write_text(TEAM.format(mode="none"))
        assert waiting(e.fac()) == [mid]
    finally:
        e.close()


def test_answering_is_a_persons_and_nothing_else_can_do_it():
    e = env_with("every-message")
    try:
        fac = e.register_all()
        r = Remote(fac)
        mid = r.say(r.conversation(), "x")
        agent = e.session(fac, "jester")
        for call in (lambda: agent.approve(mid), lambda: agent.deny(mid)):
            try:
                call()
                raise AssertionError("an agent must not answer")
            except FacilitatorError as ex:
                assert "person" in str(ex)
        assert fac.held_messages()
        # the CLI refuses inside an agent's job, and acts for a person's own shell
        import os
        cli = [sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator")]
        for verb in ("approve", "deny"):
            p = subprocess.run([*cli, verb, mid], capture_output=True, text=True, env={**os.environ, "CLAUDECODE": "1"})
            assert p.returncode == 1 and "agent's job" in p.stderr, p.stderr
        assert [h["message_id"] for h in fac.held_messages()] == [mid]
        person = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "DEVHOST_JOB_CHILD", "FACILITATOR_HANDLE")}
        p = subprocess.run([*cli, "approve", mid], capture_output=True, text=True, env=person)
        assert p.returncode == 0 and "approved by you" in p.stdout, p.stdout + p.stderr
        assert waiting(fac) == [mid]
        assert subprocess.run([*cli, "deny", "m-doesnotexist"], capture_output=True, text=True, env=person).returncode != 0
    finally:
        e.close()


def test_verify_shows_that_a_person_approved_the_message():
    e = env_with("every-message")
    try:
        fac = e.register_all()
        r = Remote(fac)
        conv = r.conversation()
        mid = r.say(conv, "x")
        fac.note_held(conv)
        v = verify_mod.verify(fac, conv, mid)
        assert any("held for a person's approval at node-a" in l for l in v["chains"][mid]), v["chains"]
        fac.answer_message(mid, "you", True)
        v = verify_mod.verify(fac, conv, mid)
        assert any("approved by a person at node-a (you; audit entry" in l for l in v["chains"][mid]), v["chains"]
    finally:
        e.close()


# ---------------------------------------------------------------- HTTP clients

def test_every_message_holds_an_http_clients_messages_one_by_one():
    e = env_with(text=TEAM.format(mode="none").replace('"*": private', '"*": public') + "  public:\n    approval: every-message\n")
    try:
        fac = e.fac()
        fac.register("you", push=False)
        fac.register("jester", push=False)
        assert fac.mesh.limit("public", "approval")[0] == "every-message" and fac.mesh.http_level() == "public"
        fac.enrol_http("cli-one", "you")
        out = fac.send_http("cli-one", "@jester hello", None, None)
        assert not out["delivered"]
        out2 = fac.send_http("cli-one", "@jester again", out["conversation"], None)
        assert not out2["delivered"]
        held = fac.held_messages()
        assert [h["message_id"] for h in held] == [out["message_id"], out2["message_id"]] and held[0]["mode"] == "every-message"
        assert fac.pending_approvals() == []                  # not a client approval: per message
        res = fac.answer_message(out["message_id"], "you", True)
        assert res["answered"][0]["delivered"] and [h["message_id"] for h in fac.held_messages()] == [out2["message_id"]]
        assert [p["message"]["message_id"] for p in fac.pending("jester")] == [out["message_id"]]
        fac.answer_message(out2["message_id"], "you", False)
        assert fac.held_messages() == []
        assert [p["message"]["message_id"] for p in fac.pending("jester")] == [out["message_id"]]
    finally:
        e.close()


helpers.run_tests(globals()) if __name__ == "__main__" else None
