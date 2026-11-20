"""A fake MCP client (one of the two fake attachments, NFR-12): starts `facilitator mcp --as <handle>` and
speaks JSON-RPC to it over stdio, as a CLI would."""
from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time


class FakeMcpClient:
    def __init__(self, argv: list[str], env: dict, token: str | None, cwd: str | None = None):
        e = dict(env)
        if token is not None:
            e["FACILITATOR_TOKEN"] = token
        else:
            e.pop("FACILITATOR_TOKEN", None)
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, cwd=cwd)
        self.n = 0
        self.replies: dict = {}
        self.cv = threading.Condition()
        self.stray: queue.Queue = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.stderr: list[str] = []
        threading.Thread(target=self._err, daemon=True).start()

    def _read(self) -> None:
        for line in self.p.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                self.stray.put(line)            # anything that is not JSON-RPC on stdout breaks a real client
                continue
            with self.cv:
                self.replies[msg.get("id")] = msg
                self.cv.notify_all()

    def _err(self) -> None:
        for line in self.p.stderr:
            self.stderr.append(line.decode(errors="replace"))

    def send(self, method: str, params: dict | None = None, notify: bool = False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        rid = None
        if not notify:
            self.n += 1
            rid = msg["id"] = self.n
        self.p.stdin.write((json.dumps(msg) + "\n").encode())
        self.p.stdin.flush()
        return rid

    def wait(self, rid, timeout: float = 30) -> dict:
        end = time.time() + timeout
        with self.cv:
            while rid not in self.replies:
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError(f"no answer to request {rid} in {timeout} s; stderr: {''.join(self.stderr[-5:])}")
                self.cv.wait(left)
            return self.replies.pop(rid)

    def request(self, method: str, params: dict | None = None, timeout: float = 30) -> dict:
        return self.wait(self.send(method, params), timeout)

    def initialize(self) -> dict:
        r = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "fake-mcp-client", "version": "0"}})
        self.send("notifications/initialized", None, notify=True)
        return r

    def call(self, name: str, args: dict | None = None, timeout: float = 60) -> dict:
        r = self.request("tools/call", {"name": name, "arguments": args or {}}, timeout)
        return r["result"]

    def close(self) -> None:
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()


def facilitator_argv() -> list[str]:
    """The command under test: FACILITATOR_BIN when set (an installed one), else the source tree's."""
    b = os.environ.get("FACILITATOR_BIN")
    if b:
        return [b]
    import shutil
    import sys
    from pathlib import Path
    src = Path(__file__).resolve().parents[3] / "src" / "facilitator" / "bin" / "facilitator"
    if src.is_file():
        return [sys.executable, "-I", str(src)]
    installed = shutil.which("facilitator")          # in a Feature's test container: the installed command
    if not installed:
        raise SystemExit("no facilitator: set FACILITATOR_BIN, or run from the repository")
    return [installed]
