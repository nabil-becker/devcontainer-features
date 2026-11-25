"""Slice N5a's signed audit register (ruling HC3): the `audit` type given by the facilitator Feature, the events of the HTTP
enrolments written to it as they happen, the N4 log replayed into it (once each, in order), and `verify` showing a cut, an
edit, a forged writer and an unreplayed line."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import shutil  # noqa: E402

MESH = "preset: team\nnode:\n  id: n1\n"


def _fac():
    e = helpers.Env()
    (e.root / ".devcontainer" / "mesh.yml").write_text(MESH)
    fac = e.register_all()
    return e, fac


def test_type_is_given_beside_the_conversation_type():
    from facilitator.record import audit_type, conversation_type
    t = audit_type()
    assert t.name == "audit" and set(t.kinds) == {"enrolment"} and t.outside_git
    assert conversation_type().name == "conversation"


def test_a_forget_is_signed_and_verifies():
    e, fac = _fac()
    try:
        fac.clients.create("claude-one", "you")
        fac.clients.revoke("claude-one", "you")
        fac.clients.forget("claude-one", "you")
        evs = fac.audit.events()
        assert [x["event"] for x in evs] == ["enrolled", "revoked", "forget"] and evs[-1]["subject"] == "claude-one", evs
        ok, detail = fac.audit.verify()
        assert ok and "3 signed event(s)" in detail, detail
        assert fac.clients.audit_ok()[0]
    finally:
        e.close()


def test_events_are_written_signed_as_they_happen():
    e, fac = _fac()
    try:
        fac.clients.create("claude-one", "you", "a laptop")
        fac.clients.approve("claude-one", "you")
        fac.clients.revoke("claude-one", "you")
        evs = fac.audit.events()
        assert [(x["event"], x["subject"], x["by"]) for x in evs] == [
            ("enrolled", "claude-one", "you"), ("approved", "claude-one", "you"), ("revoked", "claude-one", "you")], evs
        ok, detail = fac.audit.verify()
        assert ok and "3 signed event(s)" in detail and "3 log line(s) all replayed" in detail, detail
        # signed by the facilitator's key (an anchor), as the conversations' routes are
        led, proj, flags = fac.audit.read()
        pub = fac.signer.public("facilitator")
        assert all(led.valid[i].key == pub and led.valid[i].principal == "facilitator" for i in led.order)
    finally:
        e.close()


def test_replay_of_the_n4_log_is_complete_and_idempotent():
    e, fac = _fac()
    try:
        fac.clients.sink = None                      # a node that ran slice N4: the log exists, the register does not
        fac.clients.create("a-client", "you")
        fac.clients.approve("a-client", "you")
        fac.clients.revoke("a-client", "you")
        ok, detail = fac.audit.verify()
        assert not ok and "no audit register yet" in detail and "3 log line(s) not replayed" in detail, detail
        assert fac.audit.replay() == 3
        assert fac.audit.replay() == 0               # once each
        ok, detail = fac.audit.verify()
        assert ok, detail
        assert [x["event"] for x in fac.audit.events()] == ["enrolled", "approved", "revoked"]
        assert all(x.get("line") and x.get("claimed") for x in fac.audit.events())     # the replayed line's hash, its own time
        fac.clients.sink = fac.audit.on_line
        fac.clients.create("b-client", "you")
        assert fac.audit.verify()[0] and len(fac.audit.events()) == 4
    finally:
        e.close()


def test_verify_shows_a_cut_an_unreplayed_line_and_a_forged_entry():
    e, fac = _fac()
    try:
        for n in ("c1", "c2", "c3"):
            fac.clients.create(n, "you")
        assert fac.audit.verify()[0]
        entries = sorted(fac.audit.dir.glob("*.entry"))
        assert len(entries) == 3
        # a line added to the log behind the register's back: not replayed
        with open(fac.clients.audit_file, "a") as f:
            f.write(json.dumps({"at": "2026-11-23T10:00:00Z", "event": "approved", "client": "c1", "by": "you", "prev": "x"}) + "\n")
        ok, detail = fac.audit.verify()
        assert not ok and "not in the register" in detail, detail
        assert fac.audit.replay() == 1 and fac.audit.verify()[0]
        assert not fac.clients.audit_ok()[0]          # the log's own hash chain is cut by the hand-made line: it still shows
        # remove the middle entry: the later one is held, waiting for it (a gap in the chain)
        by_seq = sorted(entries, key=lambda p: p.stat().st_mtime_ns)
        shutil.copy(by_seq[1], Path(e.tmp.name) / "saved")
        by_seq[1].unlink()
        fac.audit.checked.clear()
        ok, detail = fac.audit.verify()
        assert not ok and "held" in detail and "a gap in the chain" in detail, detail
    finally:
        e.close()


def test_an_entry_by_another_key_is_flagged_and_ignored():
    e, fac = _fac()
    try:
        fac.clients.create("c1", "you")
        from registerengine import adapters
        # `you` is a registered participant with its own key, but not an anchor of the audit register
        try:
            adapters.add(fac.audit.store(), fac.signer.signing_path("you"), "you", "enrolment",
                         {"event": "approved", "subject": "c1", "by": "you"}, fac.audit.anchors(), checked=set(),
                         register="audit-enrolment", kinds=fac.audit.type.kinds)
            wrote = True
        except Exception:                            # noqa: BLE001 - refused at the writer: also right
            wrote = False
        ok, detail = fac.audit.verify()
        if wrote:
            assert not ok and ("refused" in detail or "not-facilitator" in detail), detail
        assert [x["event"] for x in fac.audit.events()] == ["enrolled"]
    finally:
        e.close()


helpers.run_tests(globals())
