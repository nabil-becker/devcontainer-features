"""The two fake attachments (NFR-12): a fake MCP client (the expert, as an MCP-capable CLI would be) and the
model wrapper against a fake OpenAI-compatible endpoint (the jester, as a local model), in one conversation,
each a separate process. A fake `claude` and `agent-adapter-claude` on PATH record any call: the facilitator
must never run a vendor CLI, though the list names one (NFR-13)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
from http.server import BaseHTTPRequestHandler, HTTPServer  # noqa: E402

from fake_mcp import FakeMcpClient, facilitator_argv  # noqa: E402
from facilitator import model  # noqa: E402


class FakeModel:
    """A tiny OpenAI-compatible /v1/chat/completions: a joke for the first request, thanks for the next."""

    def __init__(self):
        self.requests: list[dict] = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append({"path": self.path, "body": body})
                n = len(outer.requests)
                text = ("@domain-expert-one Why did the packet cross the network? To get signed." if n == 1
                        else "@you Thanks, they liked it.")
                out = json.dumps({"id": f"x{n}", "object": "chat.completion", "model": body["model"],
                                  "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                               "finish_reason": "stop"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def fake_vendor_bin(folder: Path, log: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for name in ("claude", "agent-adapter-claude", "copilot", "gemini"):
        f = folder / name
        f.write_text(f"#!/bin/sh\necho \"{name} $*\" >> {log}\nexit 0\n")
        f.chmod(0o755)


def test_mcp_client_and_model_wrapper_in_one_conversation():
    e = helpers.Env()
    fake = FakeModel()
    wrapper = expert = None
    try:
        fac = e.register_all()
        log = e.home.parent / "vendor-calls.log"
        fake_vendor_bin(e.home.parent / "fakebin", log)
        env = {**os.environ, "PATH": f"{e.home.parent / 'fakebin'}:{os.environ['PATH']}"}
        persona = e.root / "jester.md"
        persona.write_text("You are the jester: you tell one short joke when asked.")
        wrapper = subprocess.Popen(facilitator_argv() + ["model", "--as", "jester", "--endpoint", fake.url, "--model", "tiny",
                                                         "--definition", str(persona), "--wait", "30"],
                                   cwd=e.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={**env, "FACILITATOR_TOKEN": (e.home / "tokens" / "jester").read_text().strip()})
        expert = FakeMcpClient(facilitator_argv() + ["mcp", "--as", "domain-expert-one"], env,
                               (e.home / "tokens" / "domain-expert-one").read_text().strip(), cwd=str(e.root))
        expert.initialize()
        out = {}

        def expert_turn():
            out["got"] = []                       # both mentions are delivered: the request, then the joke
            for answer in ("Ready for the joke.", "Ha. Old, but good."):
                got = expert.call("receive", {"wait_seconds": 30}, timeout=60)
                out["got"].append(got["structuredContent"]["message"]["from"])
                expert.call("reply", {"text": answer})
        th = threading.Thread(target=expert_turn)
        th.start()
        time.sleep(1.5)
        sent = fac.send("you", "@jester tell @domain-expert-one a joke")
        th.join(60)
        conv = sent["conversation"]
        end = time.time() + 30
        while time.time() < end:
            _, proj, _ = fac.record.read(conv)
            if len(proj["order"]) >= 5 and all(m in proj["routes"] for m in proj["order"]):
                break
            time.sleep(0.3)
        msgs = [proj["messages"][m] for m in proj["order"]]
        assert sorted(m["from"] for m in msgs) == ["domain-expert-one", "domain-expert-one", "jester", "jester", "you"], \
            [m["from"] for m in msgs]
        assert out["got"] == ["you", "jester"]
        assert sorted(str(r["to"]) for m in msgs for r in proj["routes"][m["message_id"]]) == \
            sorted(str(t) for t in [["jester", "domain-expert-one"], ["domain-expert-one"], ["you"], ["jester"], ["you"]])
        first = fake.requests[0]["body"]
        assert fake.requests[0]["path"] == "/v1/chat/completions" and first["model"] == "tiny"
        assert first["messages"][0]["role"] == "system" and "the jester" in first["messages"][0]["content"]
        assert {"role": "user", "content": "@you: @jester tell @domain-expert-one a joke"} in first["messages"]
        second = fake.requests[1]["body"]["messages"]
        # the history, rebuilt from the record: the request, the jester's own joke, then what others said in the group
        roles = [m["role"] for m in second[1:]]
        assert roles[0] == "user" and roles[-1] == "user" and roles.count("assistant") == 1, second   # the expert's "Ready" races the joke
        assert second[-1]["content"] == "@domain-expert-one: Ha. Old, but good.", second
        from facilitator.verify import verify
        assert verify(fac, conv)["ok"]
        assert not log.exists(), f"a vendor CLI was run: {log.read_text()}"
    finally:
        for p in (wrapper,):
            if p:
                p.terminate()
                p.wait(10)
        if expert:
            expert.close()
        fake.close()
        e.close()


def test_model_endpoint_errors():
    assert model.chat_url("http://h:1") == "http://h:1/v1/chat/completions"
    assert model.chat_url("http://h:1/v1/") == "http://h:1/v1/chat/completions"
    assert model.chat_url("http://h:1/v1/chat/completions") == "http://h:1/v1/chat/completions"
    try:
        model.complete("http://127.0.0.1:9", "m", [{"role": "user", "content": "x"}], timeout=2)
        raise AssertionError("no error from a closed port")
    except model.ModelError as e:
        assert "127.0.0.1:9" in str(e)


def test_model_wrapper_once_with_nothing():
    e = helpers.Env()
    try:
        e.register_all()
        t0 = time.time()
        r = subprocess.run(facilitator_argv() + ["model", "--as", "jester", "--endpoint", "http://127.0.0.1:9", "--model", "m",
                                                 "--once", "--wait", "1"], cwd=e.root, capture_output=True, text=True,
                           env={**os.environ, "FACILITATOR_TOKEN": (e.home / "tokens" / "jester").read_text().strip()})
        assert r.returncode == 0 and "nothing yet" in r.stderr, r.stderr
        assert time.time() - t0 < 10
        r = subprocess.run(facilitator_argv() + ["model", "--as", "jester", "--endpoint", "http://x", "--model", "m", "--once"],
                           cwd=e.root, capture_output=True, text=True, env={**os.environ, "FACILITATOR_TOKEN": "wrong"})
        assert r.returncode == 1 and "FACILITATOR_TOKEN" in r.stderr
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
