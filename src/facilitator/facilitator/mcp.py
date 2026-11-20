"""`facilitator mcp --as <handle>`: the MCP server a participant's CLI starts (stdio, JSON-RPC 2.0, one
message per line). Four tools, the attachment contract (proposal 4.2, ADR-0061 ruling 2):

    receive {wait_seconds?}            blocks until a message is delivered to you, or the wait ends ("nothing yet")
    reply   {text, to?}                answers what receive handed you; no mention: back to the asker
    say     {text, conversation?, to?} a turn in another conversation (an id, or "new" with to)
    who     {}                         the handles, whether each is attached, your conversations

The caller is authenticated by its participant token (FACILITATOR_TOKEN, which the harness puts in the
CLI's environment from tokens/<handle>). Every message it writes is signed by the signer module with
its key; the participant never holds a key. SLIM's own logging writes to standard output, so the
protocol gets a private copy of standard output and everything else that prints goes to standard error.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import traceback

from . import __version__

PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MAX_WAIT = 3600


def persona(handle: str) -> str:
    return (f"You are @{handle} in the facilitator's conversations with other agents and people. Loop: call the "
            "receive tool; when it returns a message, answer it with reply (start your text with @handle, or pass "
            "to, to address someone else; with no mention your reply goes back to whoever asked), then call "
            "receive again. When receive says nothing yet, call it again. Use who to see the handles; never "
            "invent one.")


TOOLS = [
    {"name": "receive", "description": "Wait for the next message delivered to you (blocks up to wait_seconds; "
                                       "returns 'nothing yet' when none came). Call it again after every answer.",
     "inputSchema": {"type": "object", "properties": {"wait_seconds": {"type": "integer", "minimum": 0, "maximum": MAX_WAIT,
                                                                       "description": "how long to wait; default the Feature's receiveWaitSeconds"}},
                     "additionalProperties": False}},
    {"name": "reply", "description": "Answer the message receive handed you. Start the text with @handle (or pass to) "
                                     "to address someone else; with no mention it goes back to the asker.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "minLength": 1},
                                                      "to": {"type": "array", "items": {"type": "string"}}},
                     "required": ["text"], "additionalProperties": False}},
    {"name": "say", "description": "Write in another conversation you are a member of (its id), or start one "
                                   "(conversation 'new', with to). Needs a message you received first.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "minLength": 1},
                                                      "conversation": {"type": "string"},
                                                      "to": {"type": "array", "items": {"type": "string"}}},
                     "required": ["text"], "additionalProperties": False}},
    {"name": "who", "description": "The handles you can address: each participant and human, whether it is "
                                   "attached, and the conversations you are in.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
]


class Server:
    def __init__(self, handle: str, make_session, wait_default: int, out=None, inp=None):
        """`make_session()` returns a Session (app.Session) or raises; called on the first tool call, so the
        handshake works even when the session cannot (the tool call then says why)."""
        self.handle = handle
        self.make_session = make_session
        self.wait_default = wait_default
        self.out = out
        self.inp = inp
        self.write_lock = threading.Lock()
        self.tool_lock = threading.Lock()
        self.session = None
        self.session_error: str | None = None
        self.cancelled: set = set()

    # ------------------------------------------------------------ wire

    def send(self, msg: dict) -> None:
        line = (json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        with self.write_lock:
            self.out.write(line)
            self.out.flush()

    def result(self, rid, result: dict) -> None:
        self.send({"jsonrpc": "2.0", "id": rid, "result": result})

    def error(self, rid, code: int, message: str) -> None:
        self.send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    # ------------------------------------------------------------ session

    def get_session(self):
        if self.session is None and self.session_error is None:
            try:
                self.session = self.make_session()
            except Exception as e:             # noqa: BLE001 - said to the caller as a tool error
                self.session_error = str(e)
        if self.session is None:
            raise RuntimeError(self.session_error or "no session")
        return self.session

    # ------------------------------------------------------------ tools

    def call(self, rid, name: str, args: dict) -> dict:
        def text(t: str, data=None, err=False) -> dict:
            r = {"content": [{"type": "text", "text": t}], "isError": err}
            if data is not None:
                r["structuredContent"] = data
            return r

        try:
            s = self.get_session()
            if name == "receive":
                wait = args.get("wait_seconds", self.wait_default)
                if not isinstance(wait, int) or isinstance(wait, bool) or not 0 <= wait <= MAX_WAIT:
                    return text(f"wait_seconds: a whole number of seconds, 0 to {MAX_WAIT}", err=True)
                got = self._receive(s, rid, wait)
                if got is None:
                    return text(f"nothing yet (waited {wait} s); call receive again.", {"message": None})
                asker = got["from"]
                return text(f"MESSAGE in conversation {got['conversation']} (members: {', '.join(got['members'])}), "
                            f"message {got['message_id']}, {got['hops']} hop(s) from the human who began it:\n"
                            f"{got['text']}\n\nAnswer with reply (with no mention it goes back to @{asker}), "
                            "then call receive again.", {"message": got})
            if name == "reply":
                if not isinstance(args.get("text"), str) or not args["text"].strip():
                    return text("reply needs text", err=True)
                with self.tool_lock:
                    r = s.reply(args["text"], self._to(args))
                return text(self._routed(r), r)
            if name == "say":
                if not isinstance(args.get("text"), str) or not args["text"].strip():
                    return text("say needs text", err=True)
                with self.tool_lock:
                    r = s.say(args.get("conversation"), args["text"], self._to(args))
                return text(self._routed(r), r)
            if name == "who":
                with self.tool_lock:
                    w = s.who()
                lines = [f"@{p['handle']} ({p['kind']}{', attached' if p.get('attached') else ''})"
                         + (f": {p['description']}" if p.get("description") else "") for p in w["participants"]]
                lines.append(f"your conversations: {', '.join(w.get('conversations', [])) or 'none yet'}")
                return text("\n".join(lines), w)
            return text(f"no tool {name}", err=True)
        except Exception as e:                 # noqa: BLE001 - every failure is the caller's to read
            return text(f"{name}: {e}", err=True)

    def _receive(self, s, rid, wait: int):
        """receive in steps of at most 2 s, so a cancelled request takes no message."""
        import time
        end = time.time() + wait
        while True:
            if rid in self.cancelled:
                return None
            with self.tool_lock:
                got = s.receive(min(2.0, max(0.0, end - time.time())))
            if got is not None or time.time() >= end:
                return got

    @staticmethod
    def _to(args: dict) -> list[str] | None:
        to = args.get("to")
        if to is None:
            return None
        if isinstance(to, str):
            return [to]
        return [str(x) for x in to]

    @staticmethod
    def _routed(r: dict) -> str:
        if not r.get("delivered", True):
            return f"written ({r['message_id']}) and held: {'; '.join(r['notices'])}"
        to = ", ".join("@" + h for h in r["to"]) or "nobody"
        extra = f" ({'; '.join(r['notices'])})" if r.get("notices") else ""
        return f"sent {r['message_id']} in {r['conversation']} to {to} by rule {r['rule']}{extra}."

    # ------------------------------------------------------------ the loop

    def on_message(self, msg: dict) -> None:
        rid, method = msg.get("id"), msg.get("method")
        params = msg.get("params") or {}
        if method == "initialize":
            want = params.get("protocolVersion")
            self.result(rid, {"protocolVersion": want if want in PROTOCOLS else PROTOCOLS[0],
                              "capabilities": {"tools": {"listChanged": False}},
                              "serverInfo": {"name": "facilitator", "version": __version__},
                              "instructions": persona(self.handle)})
        elif method == "ping":
            self.result(rid, {})
        elif method == "tools/list":
            self.result(rid, {"tools": TOOLS})
        elif method == "tools/call":
            name, args = params.get("name"), params.get("arguments") or {}
            threading.Thread(target=lambda: self._call(rid, name, args), daemon=True).start()
        elif method == "notifications/cancelled":
            self.cancelled.add(params.get("requestId"))
        elif method and method.startswith("notifications/"):
            pass
        elif rid is not None:
            self.error(rid, -32601, f"no method {method}")

    def _call(self, rid, name, args) -> None:
        try:
            r = self.call(rid, name, args if isinstance(args, dict) else {})
        except Exception:                      # noqa: BLE001
            r = {"content": [{"type": "text", "text": traceback.format_exc(limit=1)}], "isError": True}
        if rid not in self.cancelled:
            self.result(rid, r)

    def serve(self) -> int:
        for line in self.inp:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                self.send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
                continue
            for m in (msg if isinstance(msg, list) else [msg]):
                if isinstance(m, dict):
                    self.on_message(m)
        return 0


def private_stdout():
    """The protocol's own copy of standard output; fd 1 then points at standard error."""
    proto = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return proto
