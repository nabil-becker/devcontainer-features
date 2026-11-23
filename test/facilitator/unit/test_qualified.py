"""Qualified handles (slice N3, ruling H5): `@handle.node` names another node's agent. Parsing (the separator, a
dot that is punctuation, a standalone node unchanged), resolving a name against this node's handles and other
nodes' cards, a bare handle that names several refused with their qualified names (no precedence for this node's
own), who's display names, the router's ambiguity in a shared conversation, and a conversation shared with
another node whose members are all `handle.node`."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

from facilitator import router  # noqa: E402
from facilitator.app import FacilitatorError  # noqa: E402

SPOKE = """preset: team
role: spoke
node:
  id: spoke-a
  hub: hub.corp.test:46358
  hub_name: hub.corp.test
  hub_node: hub-1
  domain: corp.test
trust:
  corp.test: private
expose:
  "*": private
"""


def ssh_key() -> str:
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", f"{t}/k"], check=True)
        return " ".join(Path(f"{t}/k.pub").read_text().split()[:2])


def card(fac, node: str, handles: list[str]) -> None:
    """An admitted card as the peers part stores it (lock two ran before; here it is written directly)."""
    d = fac.state.home / "mesh" / "cards"
    d.mkdir(parents=True, exist_ok=True)
    parts = [{"handle": h, "key": ssh_key(), "kind": "agent", "exposure": "private"} for h in handles]
    (d / f"{node}.json").write_text(json.dumps({"card": {"v": 1, "node": node, "domain": "corp.test",
                                                         "facilitator": ssh_key(), "participants": parts},
                                                "level": "private"}))


def spoke_env():
    e = helpers.Env()
    (e.root / ".devcontainer" / "mesh.yml").write_text(SPOKE)
    fac = e.register_all()
    card(fac, "spoke-b", ["jester", "b-only"])
    card(fac, "spoke-c", ["jester"])
    return e, e.fac()


# ---------------------------------------------------------------- parsing

def test_split_and_mentions():
    assert router.split("b1.spoke-b") == ("b1", "spoke-b") and router.split("b1") == ("b1", None)
    assert router.qualify("b1", "spoke-b") == "b1.spoke-b"
    nodes = {"spoke-b", "spoke-a"}
    assert router.mentions("ask @b1.spoke-b and @a1, then @B1.spoke-b again", nodes) == ["b1.spoke-b", "a1"]
    # a dot after a mention that names no known node is punctuation: the mention is the bare handle
    assert router.mentions("thanks @jester.then go", nodes) == ["jester"]
    assert router.mentions("ask @jester.", nodes) == ["jester"]
    # standalone: no node is known, so nothing changes from 0.3.x
    assert router.mentions("hey @jester.spoke-b tell @domain-expert-one", set()) == ["jester", "domain-expert-one"]
    # neither charset holds the separator, so the split is never ambiguous
    from facilitator import mesh
    assert not mesh.NODE_ID_RE.fullmatch("a.b") and not mesh.HANDLE_RE.fullmatch("a.b")


def test_route_in_a_shared_conversation():
    th = {"kind": "group", "members": ["pa.spoke-a", "jester.spoke-a", "jester.spoke-b", "b1.spoke-b"]}
    nodes = {"spoke-a", "spoke-b"}
    d = router.route(th, {}, "pa.spoke-a", "@jester tell a joke", known=set(th["members"]), me="spoke-a", nodes=nodes)
    assert d.to == [] and d.rule == "none"
    assert "@jester.spoke-a, @jester.spoke-b" in d.notices[0][1] and "not delivered" in d.notices[0][1]
    d = router.route(th, {}, "pa.spoke-a", "@jester.spoke-b tell a joke", me="spoke-a", nodes=nodes)
    assert d.to == ["jester.spoke-b"] and d.rule == "mention"
    d = router.route(th, {}, "pa.spoke-a", "@b1 hello", me="spoke-a", nodes=nodes)
    assert d.to == ["b1.spoke-b"]                                 # one member with that handle: the bare one works
    local = {"kind": "group", "members": ["you", "jester", "third"]}
    d = router.route(local, {}, "you", "@jester.spoke-a hi", me="spoke-a", nodes=nodes)
    assert d.to == ["jester"]                                     # this node's own, in a conversation it keeps alone


# ---------------------------------------------------------------- resolving names on a spoke

def test_resolve_and_ambiguity():
    e, fac = spoke_env()
    try:
        net = fac.net
        assert net.resolve("jester") == ["jester", "jester.spoke-b", "jester.spoke-c"]
        assert net.resolve("jester.spoke-b") == ["jester.spoke-b"] and net.resolve("jester.spoke-a") == ["jester"]
        assert net.resolve("b-only") == ["b-only.spoke-b"] and net.resolve("nobody") == []
        assert net.resolve("jester.nowhere") == []
        try:
            fac.resolve_one("jester")
            raise AssertionError("an ambiguous bare handle was resolved")
        except FacilitatorError as ex:
            assert "@jester.spoke-a, @jester.spoke-b, @jester.spoke-c" in str(ex), ex
        assert fac.resolve_one("b-only") == "b-only.spoke-b" and fac.resolve_one("third") == "third"
        assert net.display("jester") == "jester.spoke-a" and net.display("third") == "third"
        assert net.shared_handles() == {"jester": ["jester.spoke-a", "jester.spoke-b", "jester.spoke-c"]}
        rows = {r["handle"] for r in fac.who()["participants"]}
        assert {"jester.spoke-a", "jester.spoke-b", "jester.spoke-c", "b-only", "third"} <= rows, rows
        assert "jester" not in rows
        # the hub no longer refuses a second claim: both cards stay, both agents reachable by qualified name
        assert set(net.remote()) == {"jester.spoke-b", "b-only.spoke-b", "jester.spoke-c"}
    finally:
        e.close()


def test_a_shared_conversation_names_every_member_with_its_node():
    e, fac = spoke_env()
    try:
        try:
            fac.new_conversation("you", ["jester"])
            raise AssertionError("an ambiguous member was taken")
        except FacilitatorError as ex:
            assert "names 3 participants" in str(ex)
        conv = fac.new_conversation("you", ["jester.spoke-c", "third"])
        _, proj, _ = fac.record.read(conv)
        assert proj["thread"]["members"] == ["you.spoke-a", "jester.spoke-c", "third.spoke-a"], proj["thread"]
        assert proj["thread"]["humans"] == ["you.spoke-a"]
        assert fac.net.meta(conv)["members"] == {"you.spoke-a": "spoke-a", "jester.spoke-c": "spoke-c",
                                                 "third.spoke-a": "spoke-a"}
        mid = fac.write(conv, "you", "@jester ask @third", None, None, None, None, 0)
        out = fac.dispatch(conv, mid)
        assert out["to"] == ["jester.spoke-c", "third.spoke-a"], out      # one jester among the members: no ambiguity
        assert conv in fac.conversations_of("third") and conv in fac.conversations_of("you")
        got = [p["conv"] for p in fac.pending("third")]
        assert got == [conv], got
        assert (fac.state.home / "mesh" / "outbox" / "spoke-c" / conv).exists()
        # a conversation this node keeps alone is unchanged: bare principals, nothing queued
        local = fac.new_conversation("you", ["third"])
        _, proj, _ = fac.record.read(local)
        assert proj["thread"]["members"] == ["you", "third"] and fac.net.meta(local) is None
    finally:
        e.close()


helpers.run_tests(globals())
