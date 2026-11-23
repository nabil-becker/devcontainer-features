"""Run by test/facilitator/http_flow.sh under the bundle's python: an agent of the node (jester), through the
facilitator's own API (the calls the MCP tools make). It answers every message it is delivered until told to stop.

    http_agent.py <agent> <seconds> <text>     receive (waiting up to <seconds> in all) and reply, again and again;
                                               prints one JSON line per answered message and exits 0 when it has
                                               answered at least one, 1 when it has answered none
"""
import json
import sys
import time

sys.path.insert(0, "/opt/facilitator/lib" if len(sys.argv) < 5 else sys.argv[4])
from facilitator import settings  # noqa: E402
from facilitator.app import Facilitator, Session  # noqa: E402


def main(argv):
    agent, seconds, text = argv[1], float(argv[2]), argv[3]
    fac = Facilitator(settings.load())
    s = Session(fac, agent, (fac.state.tokens / agent).read_text().strip())
    end, n = time.time() + seconds, 0
    while time.time() < end:
        got = s.receive(min(2.0, max(0.0, end - time.time())))
        if got is None:
            continue
        r = s.reply(text)
        n += 1
        print(json.dumps({"answered": got["parts"][0]["text"], "from": got["from"], "conversation": got["conversation"],
                          "delivered": r["delivered"], "to": r["to"]}), flush=True)
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
