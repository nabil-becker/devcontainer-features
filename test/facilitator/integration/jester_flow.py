#!/usr/bin/env python3
"""The jester flow end to end, on the real AGNTCY components (the facilitator's integration test):
the Directory and a SLIM node started on loopback by `facilitator infra up` (on their own ports and in
their own state folder, so a running facilitator is not touched), the participants registered (their
OASF records pushed to the Directory), two fake agents attached through `facilitator mcp` (the fake MCP
client), the human's "@jester tell @domain-expert-one a joke" sent, the four messages routed by the
rules over SLIM, then `facilitator verify` on the chain. Everything it started is stopped by pid.

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
           "FACILITATOR_SLIM_PORT": str(base + 357)}
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
        clients = [jester, expert]
        for c in clients:
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
                got = c.call("receive", {"wait_seconds": 60}, timeout=90)
                m = got.get("structuredContent", {}).get("message")
                log.append((time.time(), name, m["text"] if m else "nothing"))
                if not m:
                    return
                r = c.call("reply", answer)
                log.append((time.time(), name, r["content"][0]["text"]))

        tj = threading.Thread(target=agent, args=(jester, "jester", [
            {"text": "@domain-expert-one Why did the packet cross the network? To get to the other signature."},
            {"text": "Thanks.", "to": ["you"]}]))
        te = threading.Thread(target=agent, args=(expert, "domain-expert-one", [{"text": "Ha. Old, but good."}]))
        tj.start()
        te.start()
        time.sleep(2.5)                                      # both are in receive (attached)
        sent_at = time.time()
        r = json.loads(run("send", "--text", "@jester tell @domain-expert-one a joke", "--json").stdout)
        conv = r["conversation"]
        expect(r["to"] == ["jester"] and r["notified"] == ["jester"], "send: routed to @jester and delivered over SLIM")
        tj.join(120)
        te.join(120)
        for when, who_, text in log:
            print(f"  +{when - sent_at:5.2f}s {who_}: {text}")
        first = next((w for w, n, _ in log if n == "jester"), None)
        expect(first is not None and first - sent_at < 2.0, "receive: the jester had the message within 2 s (SLIM, not the poll)")
        tr = json.loads(run("transcript", "--conv", conv, "--json").stdout)
        got = [(m["from"], [r["rule"] for r in m["routes"]], [r["to"] for r in m["routes"]]) for m in tr["messages"]]
        print("  " + json.dumps(got))
        expect(got == [("you", ["mention"], [["jester"]]), ("jester", ["mention"], [["domain-expert-one"]]),
                       ("domain-expert-one", ["asker"], [["jester"]]), ("jester", ["mention"], [["you"]])],
               "the jester flow: you -> jester -> domain-expert-one -> jester (the asker) -> you")
        expect([m["hops"] for m in tr["messages"]] == [0, 1, 2, 3], "hops 0, 1, 2, 3")
        expect(all(t["state"] == "completed" for m in tr["messages"][:3] for r in m["routes"] for t in r["tasks"]),
               "every delivery's A2A task is completed")
        v = run("verify", "--conv", conv, check=False)
        expect(v.returncode == 0, "verify: the chain verifies back to the human")
        vj = json.loads(run("verify", "--conv", conv, "--format", "json", check=False).stdout)
        expect(vj["ok"] and vj["messages"] == 4, "verify --format json: 4 chains, no problem")
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
