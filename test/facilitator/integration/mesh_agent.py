"""Run inside a node container by test/facilitator/mesh_flow.sh: a person or an agent of that node, through the
facilitator's own API (the same calls the MCP tools make), one step per call, JSON on standard output.

    mesh_agent.py open <person> <member>... -- <text>     a person opens a conversation and writes in it
    mesh_agent.py say <person> <conversation> <text>       a person writes in a conversation
    mesh_agent.py answer <agent> <wait seconds> <text>     an agent receives (waits) and replies
    mesh_agent.py mail <person>                            a person's unread messages
    mesh_agent.py who                                      who this node lists (its own, and other nodes')
"""
import json
import sys

sys.path.insert(0, "/opt/facilitator/lib")
from facilitator import settings  # noqa: E402
from facilitator.app import Facilitator, FacilitatorError, Session  # noqa: E402


def session(fac, handle):
    tok = (fac.state.tokens / handle).read_text().strip()
    return Session(fac, handle, tok)


def main(argv):
    try:
        return step(argv)
    except FacilitatorError as e:
        print(json.dumps({"error": str(e)}))
        return 1


def step(argv):
    fac = Facilitator(settings.load())
    cmd = argv[0]
    if cmd == "open":
        person, rest = argv[1], argv[2:]
        cut = rest.index("--")
        members, text = rest[:cut], " ".join(rest[cut + 1:])
        conv = fac.new_conversation(person, members)
        mid = fac.write(conv, person, text, None, None, None, None, 0)
        out = fac.dispatch(conv, mid)
    elif cmd == "say":
        out = fac.send(argv[1], argv[3], argv[2])
    elif cmd == "answer":
        s = session(fac, argv[1])
        got = s.receive(float(argv[2]))
        if got is None:
            out = {"received": None}
        else:
            out = {"received": got, "dispatch": s.reply(argv[3])}
    elif cmd == "mail":
        out = fac.mail(argv[1], 50, mark=False)
    elif cmd == "who":
        out = fac.who()
    else:
        raise SystemExit(f"unknown step {cmd}")
    print(json.dumps(out, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
