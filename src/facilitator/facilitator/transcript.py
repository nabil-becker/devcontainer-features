"""A conversation as a person reads it: the transcript as text lines or as JSON, for `facilitator
transcript` (the read-only admin command) and the MCP tool `transcript` (a person's session). Since
0.2.0 a person talks through their own CLI's MCP session; the terminal chat is gone."""
from __future__ import annotations


class TranscriptError(RuntimeError):
    pass


def hms(at: str) -> str:
    return at[11:19]


def via_text(v: dict | None) -> str:
    """` (via HTTP, authenticated by bearer token, client X)`: the node vouches that this authenticated client wrote it."""
    if not v:
        return ""
    auth = {"bearer": "bearer token", "oauth": "OAuth"}.get(v.get("auth"), v.get("auth"))
    return f" (via {v.get('transport', '?').upper()}, authenticated by {auth}, client {v.get('client')}" \
           + (f", issuer {v['issuer']}" if v.get("issuer") else "") + (f", subject {v['subject']}" if v.get("subject") else "") + ")"


def events(proj: dict, led) -> list[tuple[str, str]]:
    """(entry id, one line) for each message, route and notice, in the register's order."""
    out = []
    routes_by_entry = {r["entry"]: r for rs in proj["routes"].values() for r in rs}
    msgs_by_entry = {m["entry"]: m for m in proj["messages"].values()}
    notices_by_entry = {n["entry"]: n for n in proj["notices"]}
    conts = {c["entry"]: c for c in proj["continues"]}
    for i in led.order:
        if i in msgs_by_entry:
            m = msgs_by_entry[i]
            hop = f" [{m['hops']} hop{'s' if m['hops'] != 1 else ''}]" if m["hops"] else ""
            out.append((i, f"{hms(m['at'])} @{m['from']}{hop}{via_text(m.get('via'))}: {m['text']}"))
        elif i in routes_by_entry:
            r = routes_by_entry[i]
            held = {h["principal"]: h["reason"] for h in r["held"]}
            to = ", ".join(f"@{h}" + (f" (held: {held[h]})" if h in held else "") for h in r["to"]) or "nobody"
            out.append((i, f"           -> {to}  [{r['rule']}]"))
        elif i in notices_by_entry:
            out.append((i, f"           ! {notices_by_entry[i]['text']}"))
        elif i in conts:
            out.append((i, f"{hms(conts[i]['at'])} @{conts[i]['from']} continued the conversation"))
    return out


def transcript(fac, conv: str, limit: int | None = None) -> dict:
    """The conversation as JSON; with `limit`, its last `limit` messages and the notices from the first of
    them on (`omitted` says how many messages were left out)."""
    led, proj, flags = fac.record.read(conv)
    if proj["thread"] is None:
        raise TranscriptError(f"no conversation {conv}")
    order = proj["order"][-limit:] if limit else proj["order"]
    since = proj["messages"][order[0]]["at"] if order and limit else ""
    msgs = []
    for mid in order:
        m = proj["messages"][mid]
        msgs.append({"message_id": mid, "from": m["from"], "at": m["at"], "text": m["text"], "hops": m["hops"],
                     "root": m["root"], "reply_to": m.get("reply_to"), "refs": m.get("refs", []), "entry": m["entry"],
                     "via": m.get("via"),
                     "routes": [{"rule": r["rule"], "to": r["to"], "held": r["held"],
                                 "tasks": [{**t, "state": proj["tasks"][t["task"]]["state"]} for t in r["tasks"]]}
                                for r in proj["routes"].get(mid, [])]})
    return {"conversation": conv, "kind": proj["thread"]["kind"], "members": proj["thread"]["members"],
            "humans": proj["thread"]["humans"], "messages": msgs,
            "notices": [{"code": n["code"], "text": n["text"], "at": n["at"]} for n in proj["notices"] if n["at"] >= since],
            "flags": flags, "omitted": len(proj["order"]) - len(order)}


def lines(fac, conv: str, limit: int | None = None) -> list[str]:
    """The conversation as text, one line per message, route, notice and continue; with `limit`, from the
    first of its last `limit` messages on."""
    led, proj, _ = fac.record.read(conv)
    if proj["thread"] is None:
        raise TranscriptError(f"no conversation {conv}")
    ev = events(proj, led)
    omitted = 0
    if limit and len(proj["order"]) > limit:
        first = proj["messages"][proj["order"][-limit]]["entry"]
        at = next(n for n, (i, _) in enumerate(ev) if i == first)
        omitted = len(proj["order"]) - limit
        ev = ev[at:]
    head = [f"conversation {conv} ({proj['thread']['kind']}: {', '.join(proj['thread']['members'])})"]
    if omitted:
        head.append(f"({omitted} earlier message(s) not shown)")
    return head + [line for _, line in ev]
