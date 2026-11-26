#!/usr/bin/env python3
"""The jester flow end to end, on the real AGNTCY components (the facilitator's integration test):
the Directory and a SLIM node started on loopback by `facilitator infra up` (on their own ports and in
their own state folder, so a running facilitator is not touched), the participants registered (their
OASF records pushed to the Directory), two fake agents attached through `facilitator mcp` (the fake MCP
client), and the person attached the same way, as a Claude Code session would be since 0.2.0 (one
shared entry, the handle from FACILITATOR_HANDLE): the person's say "@jester tell @domain-expert-one a
joke", the four answers routed by the rules over SLIM, the person's mail (it never waits) and
transcript, then the person's next message held at the hop limit (option A: it counts as a hop), the
person's continue, the jester's answer in the mail, and `facilitator verify` on the chain. Everything it
started is stopped by pid.

Needs: the facilitator command with dirctl, slimctl and slim-bindings (an installed Feature, or
FACILITATOR_BIN with FACILITATOR_DIRCTL and FACILITATOR_SLIMCTL). Run in the Feature's scenario
`jester_flow`, or by hand: python3 -I test/facilitator/integration/jester_flow.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "unit"))
from fake_mcp import FakeMcpClient, facilitator_argv  # noqa: E402

PARTICIPANTS = """participants:
  - name: jester
    cli: openai-compatible
    kind: resident
    attachment: mcp
    description: tells short jokes
    skills: [humour]
  - name: domain-expert-one
    cli: claude
    kind: resident
    attachment: mcp
    description: the domain expert
    skills: [expertise]
"""


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="fac-it-", dir="/tmp")
    repo = Path(tmp) / "repo"
    (repo / ".devcontainer").mkdir(parents=True)
    (repo / ".devcontainer" / "participants.yml").write_text(PARTICIPANTS)
    (repo / ".devcontainer" / "facilitator.yml").write_text("facilitator:\n  humans: [you]\n")
    base = int(os.environ.get("FACILITATOR_IT_PORT_BASE", "28000"))
    env = {**os.environ, "FACILITATOR_HOME": str(Path(tmp) / "home"), "FACILITATOR_KEYS": "file",
           "FACILITATOR_TRANSPORT": "slim", "FACILITATOR_DIR_PORT": str(base + 888), "FACILITATOR_DIR_OCI_PORT": str(base + 555),
           "FACILITATOR_DIR_P2P_PORT": str(base + 999), "FACILITATOR_DIR_GATEWAY_PORT": str(base + 889),
           "FACILITATOR_SLIM_PORT": str(base + 357), "FACILITATOR_HOP_LIMIT": "3"}
    env.pop("FACILITATOR_HANDLE", None)
    fac = facilitator_argv()
    ok = True

    def run(*args, check=True) -> subprocess.CompletedProcess:
        r = subprocess.run(fac + list(args), cwd=repo, env=env, capture_output=True, text=True, timeout=120)
        print(f"$ facilitator {' '.join(args)}  (exit {r.returncode})")
        if r.stdout.strip():
            print("  " + r.stdout.strip().replace("\n", "\n  "))
        if r.stderr.strip():
            print("  stderr: " + r.stderr.strip().replace("\n", "\n  stderr: "))
        if check and r.returncode != 0:
            raise SystemExit(f"FAIL: facilitator {' '.join(args)} exited {r.returncode}")
        return r

    def expect(cond, what):
        nonlocal ok
        print(f"{'ok  ' if cond else 'FAIL'} {what}")
        ok = ok and bool(cond)

    clients = []
    try:
        t0 = time.time()
        run("infra", "up")
        run("infra", "up")                                   # idempotent: the second says running
        st = json.loads(run("infra", "status", "--json").stdout)
        expect(all(r["healthy"] for r in st), "infra: agent, dir and slim healthy on loopback")
        run("register", "--all")
        recs = json.loads(subprocess.run(fac + ["participants", "--json"], cwd=repo, env=env, capture_output=True,
                                         text=True).stdout)
        expect(all(p.get("cid") for p in recs["participants"] if p["kind"] != "human"),
               "register: each participant's OASF record is in the Directory (a CID)")
        home = Path(env["FACILITATOR_HOME"])
        jester = FakeMcpClient(fac + ["mcp", "--as", "jester"], env,
                               (home / "tokens" / "jester").read_text().strip(), cwd=str(repo))
        expert = FakeMcpClient(fac + ["mcp", "--as", "domain-expert-one"], env,
                               (home / "tokens" / "domain-expert-one").read_text().strip(), cwd=str(repo))
        person = FakeMcpClient(fac + ["mcp"], {**env, "FACILITATOR_HANDLE": "you"},
                               (home / "tokens" / "you").read_text().strip(), cwd=str(repo))
        clients = [jester, expert, person]
        pinit = person.initialize()
        expect("mail" in pinit["result"]["instructions"], "mcp: the person's session is told to read with mail")
        ptools = [t["name"] for t in person.request("tools/list")["result"]["tools"]]
        expect(ptools == ["say", "mail", "transcript", "continue", "approve", "deny", "who"],
               "mcp: the person (FACILITATOR_HANDLE=you, no --as) has say, mail, transcript, continue, approve, deny, who")
        t0m = time.time()
        empty = person.call("mail")
        expect(empty["content"][0]["text"] == "no new messages" and time.time() - t0m < 3, "mail: nothing yet, at once")
        for c in clients[:2]:
            init = c.initialize()
            expect(init["result"]["serverInfo"]["name"] == "facilitator", "mcp: initialize")
            tools = {t["name"] for t in c.request("tools/list")["result"]["tools"]}
            expect(tools == {"receive", "reply", "say", "who"}, "mcp: tools/list has receive, reply, say, who")
        who = jester.call("who")
        expect(not who["isError"] and "domain-expert-one" in who["content"][0]["text"], "mcp: who lists the expert")
        nothing = expert.call("receive", {"wait_seconds": 1})
        expect("nothing yet" in nothing["content"][0]["text"], "mcp: receive with nothing waiting times out")

        log: list[tuple[float, str, str]] = []

        def agent(c, name, script):
            for answer in script:
                got = c.call("receive", {"wait_seconds": 90}, timeout=120)
                m = got.get("structuredContent", {}).get("message")
                log.append((time.time(), name, m["text"] if m else "nothing"))
                if not m:
                    return
                r = c.call("reply", answer)
                log.append((time.time(), name, r["content"][0]["text"]))

        tj = threading.Thread(target=agent, args=(jester, "jester", [
            {"text": "@domain-expert-one Why did the packet cross the network? To get to the other signature."},
            {"text": "Thanks.", "to": ["you"]},
            {"text": "One more: a SLIM node walks into a bar. It keeps no state, so it walks in again."}]))
        te = threading.Thread(target=agent, args=(expert, "domain-expert-one", [{"text": "Ready for the joke."}, {"text": "Ha. Old, but good."}]))
        tj.start()
        te.start()
        time.sleep(2.5)                                      # both are in receive (attached)
        sent_at = time.time()
        said = person.call("say", {"text": "@jester tell @domain-expert-one a joke"})
        r = said["structuredContent"]
        conv = r["conversation"]
        expect(not said["isError"] and sorted(r["to"]) == ["domain-expert-one", "jester"] and "jester" in r["notified"],
               "say (the person, over MCP): every mention is delivered (both), over SLIM")
        te.join(120)
        end = time.time() + 90
        while time.time() < end:                             # the jester's second answer, then its third receive waits
            n = len(json.loads(run("transcript", "--conv", conv, "--json").stdout)["messages"])
            if n >= 5:
                break
            time.sleep(1)
        for when, who_, text in log:
            print(f"  +{when - sent_at:5.2f}s {who_}: {text}")
        first = next((w for w, n, _ in log if n == "jester"), None)
        expect(first is not None and first - sent_at < 2.0, "receive: the jester had the message within 2 s (SLIM, not the poll)")
        tr = json.loads(run("transcript", "--conv", conv, "--json").stdout)
        got = [(m["from"], [r["rule"] for r in m["routes"]], [r["to"] for r in m["routes"]]) for m in tr["messages"]]
        print("  " + json.dumps(got))
        want = [("you", ["mention"], [["jester", "domain-expert-one"]]), ("jester", ["mention"], [["domain-expert-one"]]),
                ("domain-expert-one", ["asker"], [["you"]]), ("domain-expert-one", ["asker"], [["jester"]]),
                ("jester", ["mention"], [["you"]])]
        expect(sorted(got) == sorted(want),
               "the flow: you -> jester and expert (both); jester -> expert; expert -> you and jester (the askers); jester -> you")
        expect(sorted(m["hops"] for m in tr["messages"]) == [0, 1, 1, 2, 3], "hops 0, 1, 1, 2, 3")
        mail = person.call("mail")
        ms = mail["structuredContent"]["messages"]
        print("  " + mail["content"][0]["text"].replace("\n", "\n  "))
        expect(len(ms) == 4 and mail["content"][0]["text"].startswith("4 new messages:")
               and sum(1 for m in ms if m["for_you"]) == 2,
               "mail: the four answers in one call, two of them addressed to the person")
        expect(person.call("mail")["content"][0]["text"] == "no new messages", "mail: what was read is not handed over again")
        pt = person.call("transcript", {"conversation": conv, "limit": 50})
        expect(not pt["isError"] and "Thanks." in pt["content"][0]["text"], "transcript (the person, over MCP)")
        more = person.call("say", {"text": "@jester one more", "conversation": conv})
        mr = more["structuredContent"]
        expect(not mr["delivered"] and mr["held"][0]["reason"] == "hop-limit",
               "say: the person's next message counts as a hop (4 > 3) and is held: the conversation pauses")
        st = json.loads(run("status", "--json").stdout)
        expect(any(c["conversation"] == conv and c["paused"] == "hop-limit" for c in st["conversations"]),
               "status: the conversation is paused")
        refused = jester.call("continue", {"conversation": conv})
        expect(refused["isError"] and "only a person" in refused["content"][0]["text"], "continue: refused to an agent")
        cont = person.call("continue", {"conversation": conv})
        expect(not cont["isError"] and cont["structuredContent"]["delivered"]
               and cont["structuredContent"]["to"] == ["jester"], "continue (the person): the held message goes to the jester")
        tj.join(120)
        end = time.time() + 30
        got3 = []
        while time.time() < end and not got3:
            got3 = person.call("mail")["structuredContent"]["messages"]
            time.sleep(0 if got3 else 1)
        expect([m["from"] for m in got3] == ["jester"] and "SLIM node" in got3[0]["text"],
               "mail: the jester's answer after the continue")
        expect(all(t["state"] == "completed" for m in tr["messages"] for r in m["routes"] if r["to"] != ["you"] for t in r["tasks"]),
               "every delivery's A2A task is completed")
        v = run("verify", "--conv", conv, check=False)
        expect(v.returncode == 0, "verify: the chain verifies back to the human")
        vj = json.loads(run("verify", "--conv", conv, "--format", "json", check=False).stdout)
        expect(vj["ok"] and vj["messages"] == 7, "verify --format json: 7 chains, no problem")
        print(f"elapsed {time.time() - t0:.1f}s")
    finally:
        for c in clients:
            c.close()
        run("infra", "down", check=False)
        st = subprocess.run(fac + ["infra", "status", "--json"], cwd=repo, env=env, capture_output=True, text=True)
        try:
            rows = json.loads(st.stdout)
            expect(not any(r["running"] for r in rows), "infra down: nothing left running")
        except ValueError:
            pass
    __import__("shutil").rmtree(tmp, ignore_errors=True)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
