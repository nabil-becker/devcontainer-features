"""The guard (proposal 4.5): hop limit and continue, the message budget, the rate, a person's message
counted as a hop with only continue resetting (option A, 0.2.0), and a stale participant held, never
dropped (rule 4)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

from facilitator.app import FacilitatorError  # noqa: E402


def ping_pong(e, fac, conv, turns):
    """jester and domain-expert-one answer each other `turns` times; returns the last route."""
    j, d = e.session(fac, "jester"), e.session(fac, "domain-expert-one")
    r = None
    for n in range(turns):
        who, other = (j, "domain-expert-one") if n % 2 == 0 else (d, "jester")
        got = who.receive(0)
        if got is None:
            return r
        r = who.reply(f"@{other} turn {n}")
    return r


def test_hop_limit_pauses_and_continue_resumes():
    e = helpers.Env(FACILITATOR_HOP_LIMIT=3)
    try:
        fac = e.register_all()
        for h in ("jester", "domain-expert-one"):
            fac.state.seen(h)
        conv = fac.new_conversation("you", ["jester", "domain-expert-one"])
        fac.send("you", "@jester start", conv)
        last = ping_pong(e, fac, conv, 10)
        assert last is not None and not last["delivered"], last
        assert last["held"][0]["reason"] == "hop-limit", last
        _, proj, _ = fac.record.read(conv)
        hops = [proj["messages"][m]["hops"] for m in proj["order"]]
        assert hops == [0, 1, 2, 3, 4], hops                 # the 4th hop is written, flagged, not delivered
        from facilitator import guard
        assert guard.paused(proj) == "hop-limit"
        # nobody has anything to receive while paused
        assert e.session(fac, "jester").receive(0) is None
        c = fac.continue_("you", conv)
        assert c["delivered"] and c["to"] == ["jester"], c
        _, proj, _ = fac.record.read(conv)
        assert guard.paused(proj) == ""
        assert e.session(fac, "jester").receive(0) is not None
        assert guard.allowed_hops(proj, proj["order"][0], fac.limits) == 4 - 1 + 3
    finally:
        e.close()


def test_a_persons_message_counts_as_a_hop_and_only_continue_resets():
    """Option A (the Operator's ruling of 2026-11-20): a person's message in a conversation answers its last
    message, one hop more, and is held by a pause like any other; only continue lets the chain run on."""
    from facilitator import guard
    e = helpers.Env(FACILITATOR_HOP_LIMIT=2)
    try:
        fac = e.register_all()
        for h in ("jester", "domain-expert-one"):
            fac.state.seen(h)
        conv = fac.new_conversation("you", ["jester", "domain-expert-one"])
        first = fac.send("you", "@jester go", conv)
        last = ping_pong(e, fac, conv, 5)
        assert last["held"] and last["held"][0]["reason"] == "hop-limit", last
        _, proj, _ = fac.record.read(conv)
        assert guard.paused(proj) == "hop-limit"
        r = fac.send("you", "@jester again", conv)              # no reset: held by the pause
        assert not r["delivered"] and r["held"][0]["reason"] == "paused", r
        _, proj, _ = fac.record.read(conv)
        m = proj["messages"][r["message_id"]]
        assert m["hops"] == 4 and m["root"] == first["message_id"], m
        assert m["reply_to"] == proj["order"][-2]                 # it answers the conversation's last message
        assert guard.paused(proj) == "hop-limit"                  # a person's message no longer resumes it
        assert e.session(fac, "jester").receive(0) is None
        c = fac.continue_("you", conv)                          # the only reset: the person's message goes
        assert c["delivered"] and c["message_id"] == r["message_id"] and c["to"] == ["jester"], c
        got = e.session(fac, "jester").receive(0)
        assert got and got["message_id"] == r["message_id"]
        from facilitator.verify import verify
        assert verify(fac, conv)["ok"], verify(fac, conv)["problems"]
    finally:
        e.close()


def test_a_persons_messages_alone_reach_the_hop_limit():
    """A person talking with one agent, hop limit 3: you 0, jester 1, you 2, jester 3, you 4 held. The
    person's own turns count, so an exchange through a person's session cannot loop without a continue."""
    e = helpers.Env(FACILITATOR_HOP_LIMIT=3)
    try:
        fac = e.register_all()
        fac.state.seen("jester")
        r = fac.send("you", "@jester one")
        conv = r["conversation"]
        assert fac.record.read(conv)[1]["messages"][r["message_id"]]["hops"] == 0
        j = e.session(fac, "jester")
        j.receive(0)
        j.reply("a")                                            # 1
        r2 = fac.send("you", "two", conv)                       # 2: no mention, back to the other member
        assert r2["delivered"] and r2["to"] == ["jester"], r2
        j.receive(0)
        j.reply("b")                                            # 3
        r3 = fac.send("you", "three", conv)                     # 4 > 3: held, the conversation pauses
        assert not r3["delivered"] and r3["held"][0]["reason"] == "hop-limit", r3
        assert fac.continue_("you", conv)["delivered"]
        assert j.receive(0)["message_id"] == r3["message_id"]
    finally:
        e.close()


def test_a_new_conversation_is_a_new_root():
    e = helpers.Env()
    try:
        fac = e.register_all()
        a = fac.send("you", "@jester hello")
        b = fac.send("you", "@jester hello again", "new")
        assert a["conversation"] != b["conversation"]
        for r in (a, b):
            m = fac.record.read(r["conversation"])[1]["messages"][r["message_id"]]
            assert m["hops"] == 0 and m["root"] == r["message_id"]
    finally:
        e.close()


def test_message_budget():
    e = helpers.Env(FACILITATOR_MESSAGE_BUDGET=3, FACILITATOR_HOP_LIMIT=50)
    try:
        fac = e.register_all()
        for h in ("jester", "domain-expert-one"):
            fac.state.seen(h)
        conv = fac.new_conversation("you", ["jester", "domain-expert-one"])
        fac.send("you", "@jester go", conv)
        last = ping_pong(e, fac, conv, 6)
        assert not last["delivered"] and last["held"][0]["reason"] == "budget", last
    finally:
        e.close()


def test_rate_limit_refuses_without_writing():
    e = helpers.Env(FACILITATOR_RATE_LIMIT=2)
    try:
        fac = e.register_all()
        fac.state.seen("jester")
        conv = fac.send("you", "@jester go")["conversation"]
        j = e.session(fac, "jester")
        j.receive(0)
        j.reply("one")
        j.reply("two")
        try:
            j.reply("three")
            raise AssertionError("the third message in a minute was written")
        except FacilitatorError as x:
            assert "rate limit" in str(x)
        _, proj, _ = fac.record.read(conv)
        assert [proj["messages"][m]["text"] for m in proj["order"]] == ["@jester go", "one", "two"]
    finally:
        e.close()


def test_stale_participant_held_never_dropped():
    e = helpers.Env(FACILITATOR_STALE_SECONDS=60)
    try:
        fac = e.register_all()
        r = fac.send("you", "@jester are you there?")       # the jester never called receive
        assert r["held"] == [{"principal": "jester", "reason": "stale"}], r
        _, proj, _ = fac.record.read(r["conversation"])
        assert any(n["code"] == "stale" and "has not been attached" in n["text"] for n in proj["notices"])
        got = e.session(fac, "jester").receive(0)          # it attaches: the message is there
        assert got and got["message_id"] == r["message_id"]
    finally:
        e.close()


def test_say_needs_a_human_chain():
    e = helpers.Env()
    try:
        fac = e.register_all()
        j = e.session(fac, "jester")
        try:
            j.say(None, "hello", ["third"])
            raise AssertionError("a participant began a chain")
        except FacilitatorError as x:
            assert "begins with a human" in str(x)
        fac.state.seen("jester")
        fac.send("you", "@jester ask third")
        j.receive(0)
        r = j.say("new", "what do you think?", ["third"])
        assert r["to"] == ["third"] and r["conversation"] != j.turn.conv
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
