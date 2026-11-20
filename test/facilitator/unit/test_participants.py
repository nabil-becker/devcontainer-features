"""The participant list (participants.yml, alias agents.yml, as the participant component defines it,
plus attachment, description and skills), facilitator.yml, the settings' order (NFR-6), and lean refused."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import tempfile  # noqa: E402

from facilitator import participants as P  # noqa: E402
from facilitator import settings  # noqa: E402


def refused(text, want, where="p.yml"):
    try:
        P.parse_participants(text, where)
    except P.ListError as e:
        assert want in str(e), str(e)
        return
    raise AssertionError(f"accepted: {text!r}")


def test_participants_and_agents_alias():
    ps, w = P.parse_participants(helpers.PARTICIPANTS, "p.yml")
    assert [p.name for p in ps] == ["jester", "domain-expert-one", "third"]
    assert ps[0].skills == ["humour"] and ps[0].description == "tells jokes" and ps[1].attachment == "mcp"
    assert w == []
    # the devhost's own agents.yml shape: agents:, args, default, session-name
    ps, w = P.parse_participants("""agents:
  - name: host
    cli: claude
    kind: on-demand
    folder: .
    args: [--remote-control]
    default: true          # task dc:agent with no name starts it
    session-name: "{machine} {handle}"
""", "agents.yml")
    assert ps[0].name == "host" and ps[0].args == ["--remote-control"] and w == []


def test_list_problems_named_with_line():
    refused("participants:\n  - name: a\n    cli: x\n", "entry 1: has no kind")
    refused("participants:\n  - name: Jester\n    cli: x\n    kind: resident\n", "lowercase")
    refused("participants:\n  - name: a\n    cli: x\n    kind: sometimes\n", "neither resident nor on-demand")
    refused("participants:\n  - name: a\n    cli: x\n    kind: resident\n  - name: a\n    cli: y\n    kind: resident\n",
            "already used")
    refused("participants:\n  - name: facilitator\n    cli: x\n    kind: resident\n", "reserved")
    refused("participants:\n  - name: a\n    cli: x\n    kind: resident\n    attachment: telepathy\n", "neither mcp nor pump")
    refused("participants: []\nagents: []\n", "one list, not two")
    refused("other: 1\n", "no participants:")
    refused("participants:\n\t- name: a\n", "a tab in the indentation")
    refused("participants:\n  - name: a\n    cli: x\n    kind: resident\n  - name: 'b\n", "p.yml:5")


def test_unknown_keys_warned():
    _, w = P.parse_participants("participants:\n  - name: a\n    cli: x\n    kind: resident\n    colour: red\n", "p.yml")
    assert any("unknown key 'colour'" in x for x in w)
    _, w = P.parse_participants("participants:\n  - name: a\n    cli: x\n    kind: resident\n    attachment: pump\n", "p.yml")
    assert any("pump is not in this version" in x for x in w)


def test_facilitator_yml():
    cfg, w = P.parse_facilitator("facilitator:\n  humans: [nabil, you]\n  fallback: a\n  model:\n    cli: claude\n",
                                 "f.yml", ["a"])
    assert cfg.humans == ["nabil", "you"] and cfg.fallback == "a" and cfg.model == {"cli": "claude"}
    assert any("not used in this version" in x for x in w)
    for bad, want in (("facilitator:\n  fallback: ghost\n", "not a participant"),
                      ("facilitator:\n  humans: [a]\n", "also a participant"),
                      ("facilitator:\n  humans: [Big]\n", "lowercase")):
        try:
            P.parse_facilitator(bad, "f.yml", ["a"])
            raise AssertionError(bad)
        except P.ListError as e:
            assert want in str(e)


def test_settings_order_and_files():
    with tempfile.TemporaryDirectory() as t:
        root = os.path.join(t, "r")
        os.makedirs(os.path.join(root, ".devcontainer", "sub"))
        start = os.path.join(root, ".devcontainer", "sub")
        env = {"FACILITATOR_HOP_LIMIT": "9", "AGENTS_FILE": "x/agents.yml"}
        s = settings.load({}, start=__import__("pathlib").Path(start), environ=env)
        assert s.root == __import__("pathlib").Path(root).resolve()
        assert (s["FACILITATOR_HOP_LIMIT"], s.sources["FACILITATOR_HOP_LIMIT"]) == ("9", "the environment")
        open(os.path.join(root, ".devcontainer", ".env"), "w").write("FACILITATOR_HOP_LIMIT=8\n")
        s = settings.load({}, start=__import__("pathlib").Path(root), environ=env)
        assert s["FACILITATOR_HOP_LIMIT"] == "8"
        open(os.path.join(root, ".env"), "w").write("FACILITATOR_HOP_LIMIT='7'\nPARTICIPANTS_FILE=p.yml\n")
        s = settings.load({}, start=__import__("pathlib").Path(root), environ=env)
        assert s["FACILITATOR_HOP_LIMIT"] == "7"
        assert s.participants_file()[0].name == "p.yml"
        s = settings.load({"FACILITATOR_HOP_LIMIT": "6"}, start=__import__("pathlib").Path(root), environ=env)
        assert s.int("FACILITATOR_HOP_LIMIT") == 6
        os.remove(os.path.join(root, ".env"))
        s = settings.load({}, start=__import__("pathlib").Path(root), environ={"AGENTS_FILE": "a.yml"})
        assert s.participants_file()[1].startswith("AGENTS_FILE")
        s = settings.load({}, start=__import__("pathlib").Path(root), environ={})
        assert s.participants_file()[0].name == "agents.yml"            # the alias, when there is no participants.yml
        open(os.path.join(root, ".devcontainer", "participants.yml"), "w").write("participants: []\n")
        s = settings.load({}, start=__import__("pathlib").Path(root), environ={})
        assert s.participants_file()[0].name == "participants.yml"


def test_lean_is_refused():
    s = settings.load({"FACILITATOR_BACKEND": "lean"}, environ={})
    try:
        s.backend()
        raise AssertionError("lean accepted")
    except settings.SettingsError as e:
        assert "not yet: slice 5" in str(e)
    s = settings.load({"FACILITATOR_BACKEND": "carrier-pigeon"}, environ={})
    try:
        s.backend()
        raise AssertionError("an unknown backend accepted")
    except settings.SettingsError as e:
        assert "agntcy or lean" in str(e)


if __name__ == "__main__":
    helpers.run_tests(globals())
