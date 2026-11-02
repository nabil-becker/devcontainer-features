"""The agentic register's MCP server: newline-delimited JSON-RPC 2.0 on standard input and output.

Every tool runs the same command as the task of the same name (REQUIREMENTS.md, R6 and R7), so
an agent and an operator can never get different behaviour. No dependency beyond Python.

The tools it offers are all of them, or only those the `mcpTools` option names (and
$AGENTIC_REGISTER_MCP_TOOLS: with both, only what both name). A tool it does not offer is not
listed and cannot be called.
"""
from __future__ import annotations

import io
import json
import os
import sys
from contextlib import redirect_stderr, redirect_stdout

from . import cli

PROTOCOL = "2025-06-18"

_store = {"register": {"type": "string", "description": "the register (default: the first; see agentic_register_registers)"},
          "store": {"type": "string", "description": "the store folder (default: the register's)"}}
_writer = {"as": {"type": "string", "description": "the principal who writes (default: AGENTIC_REGISTER_AS)"}}

TOOLS = [
    {"name": "agentic_register_version", "task": "version", "description": "What is installed, and which binary runs it.",
     "properties": {}, "required": []},
    {"name": "agentic_register_registers", "task": "registers",
     "description": "List the registers: name, type, store, how many entries.", "properties": {}, "required": []},
    {"name": "agentic_register_forks", "task": "forks",
     "description": "List the register's forks, with their entries and whether each is ruled. Only an operator can rule.",
     "properties": {**_store}, "required": []},
    {"name": "agentic_register_check", "task": "check", "description": "Say what is ready and what is not.",
     "properties": {**_store, **_writer}, "required": []},
    {"name": "agentic_register_add", "task": "add",
     "description": "Sign an entry as the next in your chain and put it in the store. kind 'work' needs data.title.",
     "properties": {**_store, **_writer, "kind": {"type": "string", "description": "work (default), run, or another kind"},
                    "data": {"type": "object", "description": "the entry's data (SPEC.md, Kinds)"}},
     "required": ["data"]},
    {"name": "agentic_register_verify", "task": "verify",
     "description": "Check every entry in the store; reports refusals, held entries, forks and flags.",
     "properties": {**_store}, "required": []},
    {"name": "agentic_register_sync", "task": "sync", "description": "Merge entries from other store folders into the store.",
     "properties": {**_store, "from": {"type": "array", "items": {"type": "string"}, "description": "store folders to read"}},
     "required": ["from"]},
    {"name": "agentic_register_show", "task": "show", "description": "The ledger as Markdown, in its order.",
     "properties": {**_store}, "required": []},
    {"name": "agentic_register_query", "task": "query",
     "description": "Read-only SQL on a fresh index. Tables: entries(id, n, key, principal, seq, prev, at, kind, title, data), "
                    "parents, heads, flags, forks, held, refused; views costs(id, at, principal, kind, usd_micro, who) and items(id, title, agent, item, pr, started_at, merged_at, lead_minutes, conflicts, checks_red, usd_micro, corrected, backfill).",
     "properties": {**_store, "sql": {"type": "string"}}, "required": ["sql"]},
]

_conv = {"register": {"type": "string", "description": "the messages register (default: the first of that type)"},
         "as": {"type": "string", "description": "who you are (default: AGENTIC_REGISTER_AS)"}}
_s = {"type": "string"}
CONVERSATION_TOOLS = [
    {"name": "agentic_register_threads", "task": "threads", "description": "The threads you are in, with unread counts (sub-threads rolled up).",
     "properties": {**_conv}, "required": []},
    {"name": "agentic_register_thread", "task": "thread", "positional": ["thread"], "switches": ["mark_read"],
     "description": "One thread: its messages, members, sub-threads and tasks. mark_read moves your read marker to its end.",
     "properties": {**_conv, "thread": _s, "mark_read": {"type": "boolean"}}, "required": ["thread"]},
    {"name": "agentic_register_inbox", "task": "inbox", "description": "What is unread for you, per thread, and your open tasks.",
     "properties": {**_conv}, "required": []},
    {"name": "agentic_register_new_thread", "task": "new-thread", "positional": ["thread"],
     "flags": {"kind": "--kind", "members": "--members", "title": "--title", "parent": "--parent", "from_entry": "--from-entry"},
     "description": "Start a thread: group (default) or direct (two members), or a sub-thread with parent. members: comma-separated.",
     "properties": {**_conv, "thread": _s, "kind": {"type": "string", "enum": ["group", "direct"]}, "members": _s, "title": _s,
                    "parent": _s, "from_entry": _s}, "required": ["thread"]},
    {"name": "agentic_register_send", "task": "send",
     "flags": {"thread": "--thread", "text": "--text", "reply_to": "--reply-to", "mention": "--mention", "task_id": "--task-id"},
     "repeat": {"refs": "--ref"},
     "description": "Post a message to a thread. reply_to: a message_id; mention: comma-separated; refs: threads it is about.",
     "properties": {**_conv, "thread": _s, "text": _s, "reply_to": _s, "mention": _s, "task_id": _s,
                    "refs": {"type": "array", "items": _s}}, "required": ["thread"]},
    {"name": "agentic_register_mark_read", "task": "mark-read", "flags": {"thread": "--thread", "upto": "--upto"},
     "description": "Move your read marker in a thread (default: to its last message).",
     "properties": {**_conv, "thread": _s, "upto": _s}, "required": ["thread"]},
    {"name": "agentic_register_invite", "task": "invite", "flags": {"thread": "--thread", "principal": "--principal"},
     "description": "Invite a principal to a thread you are in.", "properties": {**_conv, "thread": _s, "principal": _s},
     "required": ["thread", "principal"]},
    {"name": "agentic_register_leave", "task": "leave", "flags": {"thread": "--thread"},
     "description": "Leave a thread.", "properties": {**_conv, "thread": _s}, "required": ["thread"]},
    {"name": "agentic_register_tasks", "task": "tasks", "switches": ["all"],
     "description": "Tasks you asked for or were given; open ones unless all.", "properties": {**_conv, "all": {"type": "boolean"}},
     "required": []},
    {"name": "agentic_register_ask", "task": "ask",
     "flags": {"thread": "--thread", "to": "--to", "title": "--title", "text": "--text", "task": "--task"},
     "description": "Ask a member of a thread for something: a message and an A2A task, assigned to them.",
     "properties": {**_conv, "thread": _s, "to": _s, "title": _s, "text": _s, "task": _s}, "required": ["thread", "to", "title"]},
    {"name": "agentic_register_task_status", "task": "task-status", "flags": {"task": "--task", "state": "--state", "text": "--text"},
     "description": "Move a task you were given on (working, input_required, completed, failed, rejected), or cancel one you asked for.",
     "properties": {**_conv, "task": _s, "state": {"type": "string", "enum": ["working", "input_required", "auth_required", "completed",
                                                                            "failed", "canceled", "rejected"]}, "text": _s},
     "required": ["task", "state"]},
]
TOOLS += CONVERSATION_TOOLS
TOOLS.append({"name": "agentic_register_watch", "task": "watch", "flags": {"since": "--since"},
              "description": "What is new in a register since a cursor: one JSON line per entry, then the next cursor to pass "
                             "back. Without since: everything. (A tool call does not follow; poll with the cursor.)",
              "properties": {**_store, "since": {"type": "string"}}, "required": []})


PREFIX = "agentic_register_"


def exposed() -> list[dict]:
    """The tools this server offers. Each list is comma-separated names, in full (agentic_register_add)
    or short (add, new-thread); empty means every tool. A name that is no tool is an error, not a skip."""
    names = [t["name"] for t in TOOLS]
    allowed = None
    for where, raw in (("the mcpTools option", cli.options().get("MCPTOOLS", "")),
                       ("AGENTIC_REGISTER_MCP_TOOLS", os.environ.get("AGENTIC_REGISTER_MCP_TOOLS", ""))):
        want = set()
        for x in (v.strip() for v in raw.split(",")):
            if not x:
                continue
            n = x if x.startswith(PREFIX) else PREFIX + x.replace("-", "_")
            if n not in names:
                raise SystemExit(f"agentic-register: {where} names {x!r}, which is no MCP tool; the tools are "
                                 + ", ".join(names))
            want.add(n)
        if want:
            allowed = want if allowed is None else allowed & want
    return [t for t in TOOLS if allowed is None or t["name"] in allowed]


def argv_for(tool: dict, args: dict) -> list[str]:
    argv = [tool["task"]]
    if tool["task"] not in ("version", "show", "query"):
        argv.append("--json")
    if args.get("register") and "register" in tool["properties"]:
        argv += ["--register", str(args["register"])]
    if args.get("store") and "store" in tool["properties"]:
        argv += ["--store", str(args["store"])]
    if args.get("as") and "as" in tool["properties"]:
        argv += ["--as", str(args["as"])]
    if tool["task"] == "add":
        argv += ["--kind", str(args.get("kind") or "work"), "--data", json.dumps(args.get("data") or {})]
    elif tool["task"] == "sync":
        for f in args.get("from") or []:
            argv += ["--from", str(f)]
    elif tool["task"] == "query":
        argv.append(str(args["sql"]))
    argv += [str(args[k]) for k in tool.get("positional", []) if k in args]
    for k, flag in tool.get("flags", {}).items():
        if args.get(k) not in (None, ""):
            argv += [flag, str(args[k])]
    for k, flag in tool.get("repeat", {}).items():
        for v in args.get(k) or []:
            argv += [flag, str(v)]
    argv += ["--" + k.replace("_", "-") for k in tool.get("switches", []) if args.get(k)]
    return argv


def call(name: str, args: dict) -> dict:
    try:
        offered = exposed()
    except SystemExit as e:
        return {"content": [{"type": "text", "text": str(e.code)}], "isError": True}
    tool = next((t for t in offered if t["name"] == name), None)
    if tool is None:
        return {"content": [{"type": "text", "text": f"no tool {name}"}], "isError": True}
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv_for(tool, args or {}))
    except SystemExit as e:  # argparse, or a message for the user
        code = e.code if isinstance(e.code, int) else 1
        if not isinstance(e.code, int) and e.code:
            err.write(str(e.code))
    except KeyError as e:
        code = 1
        err.write(f"missing argument {e}")
    text = (out.getvalue() + err.getvalue()).strip() or f"exit {code}"
    return {"content": [{"type": "text", "text": text}], "isError": code != 0}


def handle(msg: dict) -> dict | None:
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:  # a notification: no reply
        return None
    if method == "initialize":
        asked = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        result = {"protocolVersion": asked, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "agentic-register", "version": cli.version()}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [{"name": t["name"], "description": t["description"],
                             "inputSchema": {"type": "object", "properties": t["properties"], "required": t["required"]}}
                            for t in exposed()]}
    elif method == "tools/call":
        p = msg.get("params") or {}
        result = call(p.get("name", ""), p.get("arguments") or {})
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def serve(stdin=None, stdout=None) -> int:
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    try:
        exposed()   # a tool list that names no tool stops the server before it offers anything
    except SystemExit as e:
        print(e.code, file=sys.stderr)
        return 1
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "not JSON"}}
        else:
            reply = handle(msg) if isinstance(msg, dict) else \
                {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "not a request"}}
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()
    return 0
