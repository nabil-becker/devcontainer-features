"""The `conversation` register type, given by the facilitator Feature (its NOTES, "The record").

One conversation is one register (`c-<8 hex>`), and every message in it is a signed entry: a
sign-packet packet, signed with the key of the participant it is from. The field names are those
of AOF's `messages` type (A2A-shaped: a thread is an A2A context, a delivery an A2A task with A2A's
states), with the facilitator's lineage added to a message (`root`, `hops`) and two kinds only the
facilitator writes (`route`, `notice`).

This module is self-contained (it imports only the engine), so it loads both into the
facilitator's own engine copy and into the register-engine Feature's types folder.

Kinds:
    thread    {thread, kind: group|direct, members[], humans[], title?}     by facilitator; the first entry after the roster
    message   {thread, message_id, parts[], root, hops, reply_to?, mentions?, to?, refs?, via?}   by a member
              (via: the node signed for an HTTP client, slice N4)
    route     {thread, message_id, rule, to[], tasks[{task, assignee}], held[{principal, reason}]}   by facilitator
    status    {task, state, text?}               by the task's assignee: working, completed (A2A task states)
    notice    {thread, code, text, refs?}        by facilitator: why something was held, paused or dropped
    continue  {thread, upto}                     by a human member: lets a paused chain run another hop limit

A second type, `audit` (slice N5a, ruling HC3), keeps the node's enrolment audit as a signed register: one kind,
`enrolment` {event, subject, by, claimed?, detail?, line?}, written by the facilitator only (see audit.py).

Flags (kept, shown to a person; the entry is ignored where it says so):
    unknown-thread   an entry before or without its thread (ignored)
    not-a-member     a message by a principal that is not a member (ignored)
    not-facilitator  a thread, route or notice not written by `facilitator` (ignored)
    not-human        a continue by a member that is not a human (ignored)
    unknown-message  a route for, or a reply_to naming, a message that does not exist
    unknown-task     a status for a task that no route made (ignored)
    not-assignee     a status by someone other than the task's assignee (ignored)
    second-thread    a second thread entry (ignored)
"""
from __future__ import annotations

import re

from registerengine import core
from registerengine.registertypes import RegisterType

ID_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
FACILITATOR = "facilitator"
STATES = ("submitted", "working", "input_required", "completed", "failed", "canceled", "rejected")
SET_STATES = STATES[1:]          # submitted is the route's; the assignee moves it on
RULES = ("mention", "all", "direct", "asker", "fallback", "broadcast", "continue", "none")
NOTICES = ("stale", "hop-limit", "budget", "unknown-handle", "not-member", "paused", "resumed", "rate",
           "approval", "approved", "denied")      # the last three: a first-contact message held, and a person's answer (slice N4)
VIA_TRANSPORTS = ("http",)
VIA_AUTHS = ("bearer", "oauth")
MAX_TEXT = 32768


def _need(ok, what: str) -> None:
    if not ok:
        raise core.Refused("bad-field", what)


def _id(d: dict, f: str, kind: str) -> None:
    _need(isinstance(d.get(f), str) and ID_RE.fullmatch(d[f]), f"{kind}.{f}: a plain id")


def _principal(v) -> bool:
    return isinstance(v, str) and core.PRINCIPAL_RE.fullmatch(v) is not None


def _principals(v, what: str) -> None:
    _need(isinstance(v, list) and all(_principal(x) for x in v) and len(set(v)) == len(v),
          f"{what}: a list of principals, no duplicates")


def _hops(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 10000


def _refs(v) -> None:
    _need(isinstance(v, list) and all(isinstance(r, dict) and set(r) <= {"thread", "message_id"} and "thread" in r
                                      and all(isinstance(x, str) and ID_RE.fullmatch(x) for x in r.values())
                                      for r in v), "refs: a list of {thread} or {thread, message_id}")


def _thread(d: dict) -> None:
    _need(set(d) <= {"thread", "kind", "members", "humans", "title"}, "thread: unknown field")
    _id(d, "thread", "thread")
    _need(d.get("kind") in ("group", "direct"), "thread.kind: group or direct")
    _principals(d.get("members"), "thread.members")
    _principals(d.get("humans", []), "thread.humans")
    _need(set(d.get("humans", [])) <= set(d["members"]), "thread.humans: members only")
    _need(d["kind"] != "direct" or len(d["members"]) == 2, "thread: a direct thread has exactly two members")
    _need(d["kind"] != "group" or len(d["members"]) >= 2, "thread: a group has two or more members")
    _need("title" not in d or (isinstance(d["title"], str) and 0 < len(d["title"]) <= 200), "thread.title")


def _parts(parts) -> None:
    _need(isinstance(parts, list) and len(parts) == 1, "message.parts: one text part")
    p = parts[0]
    _need(isinstance(p, dict) and set(p) == {"kind", "text"} and p["kind"] == "text"
          and isinstance(p["text"], str) and p["text"].strip() and len(p["text"]) <= MAX_TEXT,
          f"message.parts: {{kind: text, text}} with 1 to {MAX_TEXT} characters")


def _via(d: dict) -> None:
    """`via` (ADR-0068, ADR-0070): the node signed this packet on behalf of an HTTP client."""
    if "via" not in d:
        return
    v = d["via"]
    _need(isinstance(v, dict) and set(v) <= {"transport", "auth", "client", "issuer", "subject"}
          and v.get("transport") in VIA_TRANSPORTS and v.get("auth") in VIA_AUTHS
          and isinstance(v.get("client"), str) and ID_RE.fullmatch(v["client"])
          and ("issuer" not in v or (isinstance(v["issuer"], str) and 0 < len(v["issuer"]) <= 200))
          and ("subject" not in v or (isinstance(v["subject"], str) and 0 < len(v["subject"]) <= 200)),
          "via: {transport: http, auth: bearer|oauth, client, issuer?, subject?}")


def _message(d: dict) -> None:
    _need(set(d) <= {"thread", "message_id", "parts", "root", "hops", "reply_to", "mentions", "to", "refs", "via"},
          "message: unknown field")
    _via(d)
    _id(d, "thread", "message")
    _id(d, "message_id", "message")
    _parts(d.get("parts"))
    _id(d, "root", "message")
    _need(_hops(d.get("hops")), "message.hops: an integer, 0 or more")
    _need("reply_to" not in d or (isinstance(d["reply_to"], str) and ID_RE.fullmatch(d["reply_to"])),
          "message.reply_to: a message_id")
    for f in ("mentions", "to"):
        if f in d:
            _principals(d[f], f"message.{f}")
    if "refs" in d:
        _refs(d["refs"])
    _need((d["hops"] == 0) == (d["root"] == d["message_id"]),
          "message: a message is its own root exactly when its hops are 0 (a human's)")


def _route(d: dict) -> None:
    _need(set(d) == {"thread", "message_id", "rule", "to", "tasks", "held"}, "route: thread, message_id, rule, to, tasks, held")
    _id(d, "thread", "route")
    _id(d, "message_id", "route")
    _need(d["rule"] in RULES, f"route.rule: one of {', '.join(RULES)}")
    _principals(d["to"], "route.to")
    _need(isinstance(d["tasks"], list) and all(isinstance(t, dict) and set(t) == {"task", "assignee"}
                                               and isinstance(t["task"], str) and ID_RE.fullmatch(t["task"])
                                               and _principal(t["assignee"]) for t in d["tasks"]),
          "route.tasks: a list of {task, assignee}")
    _need(isinstance(d["held"], list) and all(isinstance(h, dict) and set(h) == {"principal", "reason"}
                                              and _principal(h["principal"]) and h["reason"] in NOTICES
                                              for h in d["held"]),
          "route.held: a list of {principal, reason}")


def _status(d: dict) -> None:
    _need(set(d) <= {"task", "state", "text", "via"}, "status: unknown field")
    _via(d)
    _id(d, "task", "status")
    _need(d.get("state") in SET_STATES, f"status.state: one of {', '.join(SET_STATES)}")
    _need("text" not in d or (isinstance(d["text"], str) and 0 < len(d["text"]) <= 2000), "status.text")


def _notice(d: dict) -> None:
    _need(set(d) <= {"thread", "code", "text", "refs"}, "notice: unknown field")
    _id(d, "thread", "notice")
    _need(d.get("code") in NOTICES, f"notice.code: one of {', '.join(NOTICES)}")
    _need(isinstance(d.get("text"), str) and 0 < len(d["text"]) <= 2000, "notice.text")
    if "refs" in d:
        _refs(d["refs"])


def _continue(d: dict) -> None:
    _need(set(d) == {"thread", "upto"}, "continue: thread, upto")
    _id(d, "thread", "continue")
    _id(d, "upto", "continue")


KINDS = {"thread": _thread, "message": _message, "route": _route, "status": _status, "notice": _notice,
         "continue": _continue}


def project(led) -> tuple[dict, dict[str, list[str]]]:
    """(the conversation, flags). The conversation, in the register's order:
    {"thread": {...} or None, "messages": {message_id: {...}}, "order": [message_id...],
     "routes": {message_id: [route...]}, "tasks": {task: {...}}, "notices": [...], "continues": [...]}"""
    flags: dict[str, list[str]] = {}

    def flag(i: str, what: str) -> None:
        if what not in flags.setdefault(i, []):
            flags[i].append(what)

    conv: dict = {"thread": None, "messages": {}, "order": [], "routes": {}, "tasks": {}, "notices": [],
                  "continues": [], "events": []}
    for i in led.order:
        e = led.valid[i]
        if e.kind not in KINDS:
            continue
        d, who = e.data, e.principal
        th = conv["thread"]
        if e.kind == "thread":
            if who != FACILITATOR:
                flag(i, "not-facilitator")
            elif th is not None:
                flag(i, "second-thread")
            else:
                conv["thread"] = {**d, "humans": list(d.get("humans", [])), "entry": i, "at": e.at}
            continue
        if th is None or (e.kind != "status" and d.get("thread") != th["thread"]):
            flag(i, "unknown-thread")
            continue
        if e.kind == "message":
            if who not in th["members"]:
                flag(i, "not-a-member")
                continue
            if d["message_id"] in conv["messages"]:
                flag(i, "unknown-message")
                continue
            if "reply_to" in d and d["reply_to"] not in conv["messages"]:
                flag(i, "unknown-message")
            m = {**d, "from": who, "entry": i, "at": e.at, "key": e.key, "text": d["parts"][0]["text"]}
            conv["messages"][d["message_id"]] = m
            conv["order"].append(d["message_id"])
            conv["events"].append(("message", d["message_id"]))
        elif e.kind == "route":
            if who != FACILITATOR:
                flag(i, "not-facilitator")
                continue
            if d["message_id"] not in conv["messages"]:
                flag(i, "unknown-message")
                continue
            r = {**d, "entry": i, "at": e.at}
            conv["routes"].setdefault(d["message_id"], []).append(r)
            for t in d["tasks"]:
                conv["tasks"].setdefault(t["task"], {"task": t["task"], "assignee": t["assignee"],
                                                     "message_id": d["message_id"], "state": "submitted",
                                                     "at": e.at, "history": [("submitted", e.at, i)]})
            conv["events"].append(("route", d["message_id"]))
        elif e.kind == "status":
            t = conv["tasks"].get(d["task"])
            if t is None:
                flag(i, "unknown-task")
                continue
            if who != t["assignee"]:
                flag(i, "not-assignee")
                continue
            if t["state"] in ("completed", "failed", "canceled", "rejected"):
                continue           # a terminal state stands
            t["state"] = d["state"]
            t["history"].append((d["state"], e.at, i))
        elif e.kind == "notice":
            if who != FACILITATOR:
                flag(i, "not-facilitator")
                continue
            conv["notices"].append({**d, "entry": i, "at": e.at})
            conv["events"].append(("notice", len(conv["notices"]) - 1))
        elif e.kind == "continue":
            if who not in th["humans"]:
                flag(i, "not-human")
                continue
            conv["continues"].append({**d, "from": who, "entry": i, "at": e.at})
            conv["events"].append(("continue", len(conv["continues"]) - 1))
    return conv, flags


AUDIT_EVENTS = ("enrolled", "approved", "denied", "revoked", "forget",                    # an HTTP client's token and its approval (slice N4)
                "join-requested", "join-approved", "join-denied", "node-revoked",   # a node's join and its cut-off (slice N5a)
                "secret-rotated",
                "message-approved", "message-denied")                                  # a person's answer to a held message (cross-node-approval)
SUBJECT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@:/-]{0,127}")


def _enrolment(d: dict) -> None:
    _need(set(d) <= {"event", "subject", "by", "claimed", "detail", "line"}, "enrolment: unknown field")
    _need(d.get("event") in AUDIT_EVENTS, f"enrolment.event: one of {', '.join(AUDIT_EVENTS)}")
    _need(isinstance(d.get("subject"), str) and SUBJECT_RE.fullmatch(d["subject"]), "enrolment.subject: a client or node name")
    _need(isinstance(d.get("by"), str) and 0 < len(d["by"]) <= 128, "enrolment.by: who acted")
    _need("claimed" not in d or (isinstance(d["claimed"], str) and len(d["claimed"]) <= 40), "enrolment.claimed: the time of the replayed line")
    _need("detail" not in d or (isinstance(d["detail"], str) and len(d["detail"]) <= 500), "enrolment.detail")
    _need("line" not in d or (isinstance(d["line"], str) and re.fullmatch(r"[0-9a-f]{64}", d["line"])),
          "enrolment.line: the SHA-256 of the line of http/audit.jsonl this entry replays")


AUDIT_KINDS = {"enrolment": _enrolment}


def audit_project(led) -> tuple[dict, dict[str, list[str]]]:
    """(the audit, flags): {"events": [{event, subject, by, at, claimed?, detail?, line?, entry}], "lines": {sha: entry id}},
    in the register's order. Only the facilitator's own entries count: an enrolment by anyone else is flagged and ignored."""
    flags: dict[str, list[str]] = {}
    out: dict = {"events": [], "lines": {}}
    for i in led.order:
        e = led.valid[i]
        if e.kind != "enrolment":
            continue
        if e.principal != FACILITATOR:
            flags.setdefault(i, []).append("not-facilitator")
            continue
        out["events"].append({**e.data, "at": e.at, "entry": i})
        if e.data.get("line"):
            out["lines"].setdefault(e.data["line"], i)
    return out, flags


TYPES = [RegisterType("conversation", KINDS, description="the facilitator's conversations: group and direct, A2A-shaped",
                      project=project, outside_git=True, feature="facilitator"),
         RegisterType("audit", AUDIT_KINDS, description="the node's signed audit of enrolments: HTTP clients (token, approve, deny, "
                      "revoke) and nodes (join requests, approvals, cut-offs, secret rotations); each entry signed by the facilitator",
                      project=audit_project, outside_git=True, feature="facilitator")]
