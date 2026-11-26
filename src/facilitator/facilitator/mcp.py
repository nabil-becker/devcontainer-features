"""`facilitator mcp` (the handle from FACILITATOR_HANDLE, or `--as <handle>`): the MCP server a CLI starts
(stdio, JSON-RPC 2.0, one message per line). The attachment contract (proposal 4.2, ADR-0061 ruling 2;
the person's side from the Operator's MCP-only ruling of 2026-11-20). An agent gets four tools:

    receive {wait_seconds?}            blocks until a message is delivered to you, or the wait ends ("nothing yet")
    reply   {text, to?}                answers what receive handed you; no mention: back to the asker
    say     {text, conversation?, to?} a turn in another conversation (an id, or "new" with to)
    who     {}                         the handles, whether each is attached, your conversations

A person (a human of facilitator.yml, registered) gets six, none of which blocks:

    say        {text, conversation?, to?}   start a conversation ("new", or none: with the handles named) or
                                            write in one of yours (it answers its last message: one hop more)
    mail       {limit?}                     the unread messages of your conversations, then marked read
    transcript {conversation, limit?}       a conversation of yours, its last `limit` messages
    continue   {conversation}               a paused conversation runs another hop limit (the only reset)
    approve    {client}                     an HTTP client's or another node's agent's first contact, or a held message or
                                            conversation (an id from mail): what waits is delivered
    deny       {message}                    a held message or conversation: not delivered, the sender gets a signed notice
    who        {}

The tools offered follow the handle's kind in the roster; a tool of the other kind is refused. The
caller is authenticated by its token (FACILITATOR_TOKEN, which the harness, or the person, puts in the
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


def persona(handle: str, human: bool = False) -> str:
    if human:
        return (f"You are the session of @{handle}, a person, in the facilitator's conversations with agents. When "
                "the person asks you to talk to an agent ('ask @jester for a joke'), call say with their words, "
                "keeping the @handle (with no conversation a new one is made; pass conversation to write in one "
                "you are in). Answers do not come by themselves: call mail (it never waits) when the person asks, "
                "or when a line 'Facilitator: N new messages' appears, and show the person what came in. Never "
                "answer an agent on your own: say only what the person asked you to say, since every message "
                "counts as a hop. When a conversation is paused, tell the person; call continue only when they "
                "ask. When mail says an HTTP client waits for approval, or lists a HELD message from another node, tell the "
                "person and call approve (or deny) only when they ask, with the id mail shows. Use transcript to read a conversation and who to see the handles; never invent one.")
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
MAX_MAIL = 200
MAX_LINES = 500

HUMAN_TOOLS = [
    {"name": "say", "description": "Write to agents. With no conversation (or 'new'), starts one with the handles "
                                   "you @mention or pass in to; your message begins the chain. With a conversation "
                                   "id, writes in it, answering its last message (one hop more, like any message).",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "minLength": 1},
                                                      "conversation": {"type": "string"},
                                                      "to": {"type": "array", "items": {"type": "string"}}},
                     "required": ["text"], "additionalProperties": False}},
    {"name": "mail", "description": "The messages that came in, unread, from every conversation you are in, "
                                    "oldest conversation first, each in its order; they are then marked read. "
                                    "Never waits: 'no new messages' when there are none.",
     "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": MAX_MAIL,
                                                                "description": "at most this many (default 20); "
                                                                               "the rest stay unread"}},
                     "additionalProperties": False}},
    {"name": "transcript", "description": "A conversation you are in: every message with its routes and notices.",
     "inputSchema": {"type": "object", "properties": {"conversation": {"type": "string"},
                                                      "limit": {"type": "integer", "minimum": 1, "maximum": MAX_LINES,
                                                                "description": "its last this many messages "
                                                                               "(default 50)"}},
                     "required": ["conversation"], "additionalProperties": False}},
    {"name": "continue", "description": "Let a paused conversation (hop limit or message budget reached) run "
                                        "another hop limit; its last held message is delivered. Only a person "
                                        "may; it is the only thing that resets the hops.",
     "inputSchema": {"type": "object", "properties": {"conversation": {"type": "string"}},
                     "required": ["conversation"], "additionalProperties": False}},
    {"name": "approve", "description": "Approve what waits for a person: an HTTP client or another node's agent at first "
                                       "contact (pass its name), or a held message or conversation (pass its id, "
                                       "m-... or c-..., from mail's list). What waits is delivered. Only a person "
                                       "may; an agent or HTTP client never can.",
     "inputSchema": {"type": "object", "properties": {"client": {"type": "string", "description": "a client or "
                                                       "agent name, or a held message or conversation id"}},
                     "required": ["client"], "additionalProperties": False}},
    {"name": "deny", "description": "Deny a held message or conversation (its id, m-... or c-..., from mail's list): it "
                                    "is not delivered, and the sender gets a signed notice in the conversation. Only a "
                                    "person may.",
     "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}},
                     "required": ["message"], "additionalProperties": False}},
    TOOLS[3],
]


def mail_text(r: dict) -> str:
    """The mail tool's text: each conversation with its unread messages under it, in order."""
    if not r["messages"]:
        out = "no new messages"
    else:
        out, conv = [], None
        members = {c["conversation"]: c["members"] for c in r["conversations"]}
        paused = set(r["paused"])
        n = len(r["messages"])
        out.append(f"{n} new message{'s' if n != 1 else ''}:")
        for m in r["messages"]:
            if m["conversation"] != conv:
                conv = m["conversation"]
                out.append(f"conversation {conv} ({', '.join(members.get(conv, []))})"
                           + (" PAUSED: continue lets it go on" if conv in paused else ""))
            note = ("" if m["for_you"] else " (not addressed to you)") + (f" (held: {m['held']})" if m["held"] else "")
            out.append(f"  {m['message_id']} @{m['from']} [{m['hops']} hop{'s' if m['hops'] != 1 else ''}]{note}: {m['text']}")
        if r["more"]:
            out.append(f"{r['more']} more unread: call mail again")
        out = "\n".join(out)
    rest = [c for c in r["paused"] if c not in {m["conversation"] for m in r["messages"]}]
    if rest:
        out += f"\npaused, nothing new: {', '.join(rest)}"
    for h in r.get("held", []):
        age = h["age"]
        ago = f"{age // 86400} d" if age >= 86400 else f"{age // 3600} h" if age >= 3600 else f"{age // 60} min"
        out += (f"\nHELD {h['message_id']} from {h['from']} (node {h['node']}, {h['level']}, {h['mode']}) in {h['conversation']}, "
                f"{ago} ago: {h['line']}" + (" (older than 7 days: never delivered)" if h["expired"] else "")
                + f"\n  approve: the approve tool or facilitator approve {h['message_id']}; deny: the deny tool or facilitator deny {h['message_id']}")
    for a in r.get("approvals", []):
        out += (f"\nHTTP client {a['client']} waits for your approval ({a['held']} message(s) held in "
                f"{', '.join(a['conversations'])}; {a['id']}): the approve tool, or facilitator http approve {a['client']}")
    return out


class Server:
    def __init__(self, handle: str, make_session, wait_default: int, out=None, inp=None, human: bool = False):
        """`make_session()` returns a Session (app.Session) or raises; called on the first tool call, so the
        handshake works even when the session cannot (the tool call then says why). `human`: the handle's
        kind in the roster, which picks the tools listed; the session checks it again on every call."""
        self.handle = handle
        self.human = human
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
            if name in ("receive", "reply") and s.human:
                return text(f"{name} is an agent's tool; a person reads with mail and writes with say", err=True)
            if name in ("mail", "transcript", "continue", "approve", "deny") and not s.human:
                return text(f"{name} is refused: only a person (a human of facilitator.yml) may call it; "
                            f"@{self.handle} is an agent", err=True)
            if name == "mail":
                lim = args.get("limit", 20)
                if not isinstance(lim, int) or isinstance(lim, bool) or not 1 <= lim <= MAX_MAIL:
                    return text(f"limit: a whole number, 1 to {MAX_MAIL}", err=True)
                with self.tool_lock:
                    r = s.mail(lim)
                return text(mail_text(r), r)
            if name == "transcript":
                conv = args.get("conversation")
                lim = args.get("limit", 50)
                if not isinstance(conv, str) or not conv:
                    return text("transcript needs a conversation (who lists yours)", err=True)
                if not isinstance(lim, int) or isinstance(lim, bool) or not 1 <= lim <= MAX_LINES:
                    return text(f"limit: a whole number, 1 to {MAX_LINES}", err=True)
                with self.tool_lock:
                    ls = s.transcript(conv, lim)
                return text("\n".join(ls), {"conversation": conv, "lines": ls})
            if name == "continue":
                conv = args.get("conversation")
                if not isinstance(conv, str) or not conv:
                    return text("continue needs a conversation", err=True)
                with self.tool_lock:
                    r = s.continue_(conv)
                return text(f"continued {conv}: {r['message_id']} delivered to "
                            f"{', '.join('@' + h for h in r['to']) or 'nobody'}.", r)
            if name == "approve":
                client = args.get("client")
                if not isinstance(client, str) or not client:
                    return text("approve needs a client (mail names the ones that wait)", err=True)
                with self.tool_lock:
                    r = s.approve(client)
                if "answered" in r:
                    n = sum(1 for x in r["answered"] if x["delivered"])
                    return text(f"approved {client}: {n} message(s) delivered"
                                + (f", {len(r['answered']) - n} not (see the transcript)" if len(r["answered"]) != n else "") + ".", r)
                n = sum(1 for x in r["released"] if x["delivered"])
                return text(f"approved {client}: {n} held message(s) delivered"
                            + (f", {len(r['released']) - n} not (see the transcript)" if len(r["released"]) != n else "") + ".", r)
            if name == "deny":
                target = args.get("message")
                if not isinstance(target, str) or not target:
                    return text("deny needs a held message or conversation id (mail lists them)", err=True)
                with self.tool_lock:
                    r = s.deny(target)
                return text(f"denied {target}: {len(r['answered'])} message(s) not delivered; the sender is told by a signed notice.", r)
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
                              "instructions": persona(self.handle, self.human)})
        elif method == "ping":
            self.result(rid, {})
        elif method == "tools/list":
            self.result(rid, {"tools": HUMAN_TOOLS if self.human else TOOLS})
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
