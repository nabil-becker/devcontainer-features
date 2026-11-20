"""The routing rules (proposal 4.4)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402,F401  (puts src/facilitator on the path)
from facilitator import router  # noqa: E402

G = {"kind": "group", "members": ["you", "jester", "domain-expert-one", "third"]}
D = {"kind": "direct", "members": ["you", "jester"]}
MSGS = {"m-1": {"from": "jester"}, "m-2": {"from": "you"}}
KNOWN = {"you", "jester", "domain-expert-one", "third", "outsider"}


def test_mentions():
    assert router.mentions("Hey @jester tell @domain-expert-one a joke") == ["jester", "domain-expert-one"]
    assert router.mentions("mail me at a@b.c, no mention") == []
    assert router.mentions("@Jester @jester") == ["jester"]


def test_rule1_every_mention_is_delivered():
    d = router.route(G, MSGS, "you", "@jester tell @domain-expert-one a joke", known=KNOWN)
    assert (d.to, d.rule) == (["jester", "domain-expert-one"], "mention")
    assert d.mentions == ["jester", "domain-expert-one"]
    d = router.route(G, MSGS, "you", "@jester, @third and @domain-expert-one: compare", known=KNOWN)
    assert d.to == ["jester", "third", "domain-expert-one"]


def test_rule1_to_argument_and_all():
    d = router.route(G, MSGS, "jester", "a joke", to=["@domain-expert-one"], known=KNOWN)
    assert (d.to, d.rule) == (["domain-expert-one"], "mention")
    d = router.route(G, MSGS, "you", "@all stand up", known=KNOWN)
    assert (sorted(d.to), d.rule) == (["domain-expert-one", "jester", "third"], "all")


def test_rule1_each_once_and_not_self():
    d = router.route(G, MSGS, "jester", "@jester @third @third hi", known=KNOWN)
    assert d.to == ["third"]


def test_mention_of_non_member_and_unknown():
    d = router.route(D, MSGS, "you", "@outsider hello", known=KNOWN)
    assert d.to == [] and d.rule == "none" and d.notices[0][0] == "not-member"
    d = router.route(D, MSGS, "you", "@ghost hello", known=KNOWN)
    assert d.notices[0][0] == "unknown-handle"


def test_rule2_direct_and_group():
    assert router.route(D, MSGS, "you", "hello", known=KNOWN).to == ["jester"]
    d = router.route(G, MSGS, "you", "hello all", known=KNOWN)
    assert (sorted(d.to), d.rule) == (["domain-expert-one", "jester", "third"], "broadcast")
    d = router.route(G, MSGS, "you", "hello all", fallback="third", known=KNOWN)
    assert (d.to, d.rule) == (["third"], "fallback")


def test_rule3_reply_goes_to_asker():
    d = router.route(G, MSGS, "domain-expert-one", "Ha. Old, but good.", reply_to="m-1", known=KNOWN)
    assert (d.to, d.rule) == (["jester"], "asker")
    d = router.route(G, MSGS, "domain-expert-one", "@third over to you", reply_to="m-1", known=KNOWN)
    assert d.to == ["third"]


if __name__ == "__main__":
    helpers.run_tests(globals())
