"""The `messages` register type: conversations and requests between agents and operators.

Shaped as A2A 1.0 (the Agent2Agent protocol): a message is an A2A Message, a thread is an A2A
context, a request is an A2A Task moving through A2A's task states. The register is the binding
inside the manor (no agent runs a server); a bridge carries the same objects over A2A's own
bindings outside. A2A has no group conversations: members, sub-threads and references to
threads are this register's A2A extension, `EXTENSION` below.

Field names are snake_case, as the format's canonical JSON requires (SPEC.md, "Canonical
JSON"); a bridge maps them one for one to A2A's camelCase (message_id -> messageId, context_id ->
contextId, task_id -> taskId, reference_task_ids -> referenceTaskIds).

Kinds:
    thread   {thread, title?, kind: group|direct, members[], parent?, from?}
    message  {thread, message_id, parts[], task_id?, reference_task_ids?, reply_to?, mentions?, refs?}
    invite   {thread, principal}          by a member
    leave    {thread}                     by yourself
    read     {thread, upto}               by yourself: your read marker
    task     {task, thread, assignee, title, message_id?}   a request; state submitted
    status   {task, state, text?}         the assignee moves it on; its creator may cancel it

Flags (kept, shown to a person, the entry ignored where it says so):
    not-a-member           a post, invite or read in a thread the writer is not in (ignored)
    unknown-thread         a thread, parent or message that does not exist (ignored)
    concurrent-membership  an invite and a leave of one principal at the same time
    unknown-task           a status for a task that does not exist (ignored)
    not-assignee           a status by someone who may not set it (ignored)
    after-terminal         a status whose writer saw the task completed, failed, canceled or rejected (ignored)
    concurrent-status      two different states set at the same time; beside a terminal state, the terminal one stands
"""
from __future__ import annotations

import re

from . import core

EXTENSION = "https://github.com/KGO-Solutions/agentic-operating-framework/aof/tooling/src/agentic-register/SPEC.md#the-messages-type"
ID_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
STATES = ("submitted", "working", "input_required", "auth_required", "completed", "failed", "canceled", "rejected")
TERMINAL = ("completed", "failed", "canceled", "rejected")
ASSIGNEE_STATES = ("working", "input_required", "auth_required", "completed", "failed", "rejected")
PART_KINDS = ("text", "data", "file")


def _need(ok, what: str) -> None:
    if not ok:
        raise core.Refused("bad-field", what)


def _id(d: dict, f: str, kind: str) -> None:
    _need(isinstance(d.get(f), str) and ID_RE.fullmatch(d[f]), f"{kind}.{f}: a plain id")


def _principals(v, what: str) -> None:
    _need(isinstance(v, list) and all(isinstance(x, str) and core.PRINCIPAL_RE.fullmatch(x) for x in v),
          f"{what}: a list of principals")


def _thread(d: dict) -> None:
    _id(d, "thread", "thread")
    _need(d.get("kind") in ("group", "direct"), "thread.kind: group or direct")
    _need("title" not in d or (isinstance(d["title"], str) and d["title"].strip()), "thread.title")
    if "members" in d:
        _principals(d["members"], "thread.members")
    else:
        _need("parent" in d, "thread.members: needed unless the thread has a parent")
    if "parent" in d:
        _id(d, "parent", "thread")
        _need(d["parent"] != d["thread"], "thread.parent: not the thread itself")
    if d["kind"] == "direct":
        _need(len(set(d.get("members", []))) == 2 and "parent" not in d,
              "thread: a direct thread has exactly two members, its creator one of them, and no parent")
    _need("from" not in d or core.ID_RE.fullmatch(str(d["from"])), "thread.from: a message's entry id")


def _parts(parts) -> None:
    _need(isinstance(parts, list) and parts, "message.parts: a non-empty list")
    for p in parts:
        _need(isinstance(p, dict) and p.get("kind") in PART_KINDS, f"message.parts: each one of {', '.join(PART_KINDS)}")
        if p["kind"] == "text":
            _need(isinstance(p.get("text"), str) and p["text"].strip(), "message.parts: a text part needs text")
        elif p["kind"] == "data":
            _need("data" in p, "message.parts: a data part needs data")
        else:
            _need(isinstance(p.get("name"), str) and (isinstance(p.get("uri"), str) or isinstance(p.get("bytes"), str)),
                  "message.parts: a file part needs a name and a uri or bytes")


def _message(d: dict) -> None:
    _id(d, "thread", "message")
    _id(d, "message_id", "message")
    _parts(d.get("parts"))
    _need("task_id" not in d or ID_RE.fullmatch(str(d["task_id"])), "message.task_id: a plain id")
    _need("reference_task_ids" not in d or (isinstance(d["reference_task_ids"], list)
                                            and all(isinstance(x, str) and ID_RE.fullmatch(x) for x in d["reference_task_ids"])),
          "message.reference_task_ids: a list of task ids")
    _need("reply_to" not in d or (isinstance(d["reply_to"], str) and ID_RE.fullmatch(d["reply_to"])), "message.reply_to: a message_id")
    if "mentions" in d:
        _principals(d["mentions"], "message.mentions")
    if "refs" in d:
        _need(isinstance(d["refs"], list) and all(
            isinstance(r, dict) and "thread" in r and set(r) <= {"thread", "message_id"} and all(isinstance(v, str) and ID_RE.fullmatch(v)
                                                                                     for v in r.values())
            for r in d["refs"]), "message.refs: a list of {thread} or {thread, message_id}")


def _invite(d: dict) -> None:
    _id(d, "thread", "invite")
    _need(isinstance(d.get("principal"), str) and core.PRINCIPAL_RE.fullmatch(d["principal"]), "invite.principal")


def _leave(d: dict) -> None:
    _id(d, "thread", "leave")


def _read(d: dict) -> None:
    _id(d, "thread", "read")
    _id(d, "upto", "read")


def _task(d: dict) -> None:
    _id(d, "task", "task")
    _id(d, "thread", "task")
    _need(isinstance(d.get("assignee"), str) and core.PRINCIPAL_RE.fullmatch(d["assignee"]), "task.assignee: a principal")
    _need(isinstance(d.get("title"), str) and d["title"].strip(), "task.title")
    _need("message_id" not in d or ID_RE.fullmatch(str(d["message_id"])), "task.message_id: a plain id")


def _status(d: dict) -> None:
    _id(d, "task", "status")
    _need(d.get("state") in STATES[1:], f"status.state: one of {', '.join(STATES[1:])}")
    _need("text" not in d or (isinstance(d["text"], str) and d["text"].strip()), "status.text")


KINDS = {"thread": _thread, "message": _message, "invite": _invite, "leave": _leave, "read": _read,
         "task": _task, "status": _status}


# ---------------------------------------------------------------- what the entries add up to

def project(led: core.Ledger) -> tuple[dict, dict[str, list[str]]]:
    """(the conversations, flags). Conversations: {"threads": {id: thread}, "tasks": {id: task}}."""
    from .backlog import ancestors
    anc = ancestors(led)
    concurrent = lambda a, b: a not in anc[b] and b not in anc[a]  # noqa: E731
    flags: dict[str, list[str]] = {}

    def flag(i: str, what: str) -> None:
        if what not in flags.setdefault(i, []):
            flags[i].append(what)

    threads: dict[str, dict] = {}
    thread_entry: dict[str, str] = {}
    msg_entry: dict[tuple[str, str], str] = {}           # (thread, message_id) -> entry id
    membership: dict[tuple[str, str], list[tuple[str, bool]]] = {}
    tasks: dict[str, dict] = {}

    def member(t: str, p: str) -> bool:
        return p in threads[t]["members"]

    for i in led.order:
        e = led.valid[i]
        if e.kind not in KINDS:
            continue
        d, who = e.data, e.principal
        if e.kind == "thread":
            t = d["thread"]
            if t in threads:
                flag(i, "unknown-thread")   # a second thread of one id: the first stands
                continue
            parent = d.get("parent")
            if parent is not None and (parent not in threads or thread_entry[parent] not in anc[i]):
                flag(i, "unknown-thread")
                continue
            if parent is not None and not member(parent, who):
                flag(i, "not-a-member")
                continue
            if "from" in d and (d["from"] not in led.valid or led.valid[d["from"]].kind != "message"
                                or led.valid[d["from"]].data["thread"] != parent):
                flag(i, "unknown-thread")
                continue
            members = set(d["members"]) if "members" in d else set(threads[parent]["members"])
            if d["kind"] == "direct" and who not in members:
                flag(i, "not-a-member")      # a direct thread between two others
                continue
            members.add(who)
            threads[t] = {"thread": t, "title": d.get("title", t), "kind": d["kind"], "members": members,
                          "parent": parent, "from": d.get("from"), "created_by": who, "at": e.at,
                          "messages": [], "children": [], "reads": {}}
            thread_entry[t] = i
            if parent is not None:
                threads[parent]["children"].append(t)
            continue

        t = d.get("thread")
        if e.kind in ("message", "invite", "leave", "read", "task"):
            if t not in threads:
                flag(i, "unknown-thread")
                continue
            if not member(t, who):
                flag(i, "not-a-member")
                continue
        if e.kind == "message":
            key = (t, d["message_id"])
            if key in msg_entry:
                flag(i, "unknown-thread")   # a message id used twice in a thread: the first stands
                continue
            msg_entry[key] = i
            threads[t]["messages"].append({"entry": i, "message_id": d["message_id"], "from": who, "at": e.at,
                                           "parts": d["parts"], "reply_to": d.get("reply_to"),
                                           "mentions": d.get("mentions", []), "refs": d.get("refs", []),
                                           "task_id": d.get("task_id")})
        elif e.kind in ("invite", "leave"):
            p = d["principal"] if e.kind == "invite" else who
            joining = e.kind == "invite"
            for j, was in membership.get((t, p), []):
                if was != joining and concurrent(i, j):
                    flag(i, "concurrent-membership")
                    flag(j, "concurrent-membership")
            membership.setdefault((t, p), []).append((i, joining))
            (threads[t]["members"].add if joining else threads[t]["members"].discard)(p)
        elif e.kind == "read":
            ids = [m["message_id"] for m in threads[t]["messages"]]
            if d["upto"] not in ids:
                flag(i, "unknown-thread")
                continue
            n = ids.index(d["upto"]) + 1
            threads[t]["reads"][who] = max(threads[t]["reads"].get(who, 0), n)
        elif e.kind == "task":
            if d["task"] in tasks:
                flag(i, "unknown-task")
                continue
            tasks[d["task"]] = {"task": d["task"], "thread": t, "assignee": d["assignee"], "title": d["title"],
                                "created_by": who, "at": e.at, "state": "submitted", "message_id": d.get("message_id"),
                                "history": [{"entry": i, "state": "submitted", "by": who, "at": e.at}]}
        elif e.kind == "status":
            task = tasks.get(d["task"])
            if task is None:
                flag(i, "unknown-task")
                continue
            allowed = (who == task["assignee"] and d["state"] in ASSIGNEE_STATES) or \
                      (who == task["created_by"] and d["state"] == "canceled")
            if not allowed:
                flag(i, "not-assignee")
                continue
            if task["state"] in TERMINAL:
                end = task["history"][-1]["entry"]
                if end in anc[i]:                 # its writer saw the task end
                    flag(i, "after-terminal")
                else:                             # at the same time as the end: the end stands, in any order
                    flag(i, "concurrent-status")
                    flag(end, "concurrent-status")
                continue
            for h in task["history"][1:]:
                if h["state"] != d["state"] and concurrent(i, h["entry"]):
                    flag(i, "concurrent-status")
                    flag(h["entry"], "concurrent-status")
            task["state"] = d["state"]
            task["history"].append({"entry": i, "state": d["state"], "by": who, "at": e.at, "text": d.get("text")})
    return {"threads": threads, "tasks": tasks}, flags


def unread(conv: dict, principal: str, thread: str) -> int:
    """Messages in one thread after the principal's read marker, not written by the principal."""
    t = conv["threads"][thread]
    seen = t["reads"].get(principal, 0)
    return sum(1 for m in t["messages"][seen:] if m["from"] != principal)


def inbox(conv: dict, principal: str) -> dict:
    """The principal's threads with unread messages, sub-threads rolled up into their parents."""
    threads = conv["threads"]

    def mine(t: str) -> bool:
        return principal in threads[t]["members"]

    def below(t: str) -> int:
        return sum((unread(conv, principal, c) if mine(c) else 0) + below(c) for c in threads[t]["children"])

    rows = []
    for t, x in threads.items():
        if not mine(t):
            continue
        own, sub = unread(conv, principal, t), below(t)
        if own or sub:
            last = x["messages"][-1] if x["messages"] else None
            rows.append({"thread": t, "title": x["title"], "kind": x["kind"], "parent": x["parent"], "unread": own,
                         "unread_in_sub_threads": sub,
                         "last": {"from": last["from"], "at": last["at"], "text": text_of(last)} if last else None})
    rows.sort(key=lambda r: (r["last"] or {}).get("at", ""), reverse=True)
    tasks = [{"task": k["task"], "thread": k["thread"], "title": k["title"], "state": k["state"], "from": k["created_by"]}
             for k in conv["tasks"].values() if k["assignee"] == principal and k["state"] not in TERMINAL]
    return {"principal": principal, "unread": sum(r["unread"] for r in rows), "threads": rows, "tasks": tasks}


def text_of(m: dict) -> str:
    return " ".join(p["text"] for p in m["parts"] if p["kind"] == "text")


def visible_refs(conv: dict, principal: str, refs: list[dict]) -> list[dict]:
    """A reference grants no access: a thread the principal is not in shows only that it exists."""
    out = []
    for r in refs:
        t = conv["threads"].get(r["thread"])
        out.append({**r, "visible": bool(t and principal in t["members"])})
    return out


def index(db, led: core.Ledger) -> None:
    conv, _ = project(led)
    db.executescript("""
        CREATE TABLE threads (thread TEXT PRIMARY KEY, title TEXT, kind TEXT, parent TEXT, created_by TEXT, at TEXT,
                              messages INTEGER);
        CREATE TABLE thread_members (thread TEXT, principal TEXT);
        CREATE TABLE messages (thread TEXT, n INTEGER, message_id TEXT, sender TEXT, at TEXT, text TEXT,
                               reply_to TEXT, entry TEXT);
        CREATE TABLE unread (principal TEXT, thread TEXT, unread INTEGER);
        CREATE TABLE tasks (task TEXT PRIMARY KEY, thread TEXT, title TEXT, assignee TEXT, created_by TEXT,
                            state TEXT, at TEXT);
        CREATE TABLE task_history (task TEXT, n INTEGER, state TEXT, by_principal TEXT, at TEXT, text TEXT);
        CREATE VIEW open_tasks AS SELECT * FROM tasks
          WHERE state NOT IN ('completed', 'failed', 'canceled', 'rejected') ORDER BY at;
    """)
    for t, x in conv["threads"].items():
        db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?)",
                   (t, x["title"], x["kind"], x["parent"], x["created_by"], x["at"], len(x["messages"])))
        db.executemany("INSERT INTO thread_members VALUES (?,?)", [(t, p) for p in sorted(x["members"])])
        db.executemany("INSERT INTO messages VALUES (?,?,?,?,?,?,?,?)",
                       [(t, n, m["message_id"], m["from"], m["at"], text_of(m), m["reply_to"], m["entry"])
                        for n, m in enumerate(x["messages"])])
        db.executemany("INSERT INTO unread VALUES (?,?,?)",
                       [(p, t, unread(conv, p, t)) for p in sorted(x["members"])])
    for k in conv["tasks"].values():
        db.execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?)",
                   (k["task"], k["thread"], k["title"], k["assignee"], k["created_by"], k["state"], k["at"]))
        db.executemany("INSERT INTO task_history VALUES (?,?,?,?,?,?)",
                       [(k["task"], n, h["state"], h["by"], h["at"], h.get("text")) for n, h in enumerate(k["history"])])


def render(led: core.Ledger) -> str:
    conv, flags = project(led)
    out = ["# Conversations", "", "Generated from the messages register; do not edit.", ""]
    if flags:
        out += ["## Needs a person", ""]
        out += [f"- {', '.join(fs)}: `{i[:12]}` ({led.valid[i].kind} by {led.valid[i].principal})" for i, fs in sorted(flags.items())]
        out.append("")

    def thread(t: str, depth: int) -> None:
        x = conv["threads"][t]
        out.append(f"{'#' * min(2 + depth, 6)} {x['title']} (`{t}`, {x['kind']}: {', '.join(sorted(x['members']))})")
        out.append("")
        for m in x["messages"]:
            reply = f" (re `{m['reply_to']}`)" if m["reply_to"] else ""
            out.append(f"- **{m['from']}** {m['at']}{reply}: {text_of(m)}")
        out.append("")
        for c in x["children"]:
            thread(c, depth + 1)

    for t, x in conv["threads"].items():
        if x["parent"] is None:
            thread(t, 0)
    if conv["tasks"]:
        out += ["## Tasks", ""]
        out += [f"- `{k['task']}` {k['state']}: {k['title']} ({k['created_by']} to {k['assignee']}, in `{k['thread']}`)"
                for k in conv["tasks"].values()]
    return "\n".join(out).rstrip() + "\n"


def a2a_parts(parts: list[dict]) -> list[dict]:
    """This register's parts as A2A 1.0 Parts: exactly one of text, data, url or raw, with filename and
    mediaType for a file, and no kind (A2A 1.0, "Part")."""
    out = []
    for p in parts:
        if p["kind"] == "text":
            out.append({"text": p["text"]})
        elif p["kind"] == "data":
            out.append({"data": p["data"]})
        else:
            q = {"url": p["uri"]} if "uri" in p else {"raw": p["bytes"]}
            q["filename"] = p["name"]
            if p.get("mime_type"):
                q["mediaType"] = p["mime_type"]
            out.append(q)
    return out


def to_a2a(m: dict, thread: str) -> dict:
    """One message as an A2A 1.0 Message (camelCase), for a bridge. The role is set by the bridge."""
    a = {"messageId": m["message_id"], "contextId": thread, "parts": a2a_parts(m["parts"]), "extensions": [EXTENSION],
         "metadata": {"aof": {"from": m["from"], "at": m["at"], "reply_to": m["reply_to"], "refs": m["refs"]}}}
    if m.get("task_id"):
        a["taskId"] = m["task_id"]
    return a

