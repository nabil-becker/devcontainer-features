"""The `backlog` register type: changes to items, and the backlog they add up to (SPEC.md, "Registers").

Each entry is one change to one item: `add`, `edit`, `tick`, `reopen`, `move` or `note`. The
backlog is what applying them in the register's order gives. Changes made at the same time (neither
writer had seen the other's) never block each other. They are flagged only when they disagree:

    two edits of one field to different values   concurrent-edit   (the later in order shows)
    a tick and a reopen of one item              concurrent-state
    two moves of one item                        concurrent-move
    two adds of one item                         added-twice       (the first stands)
    a change to an item never added              unknown-item      (ignored)

A tick beside a tick, an add beside a move of another item, or a note beside anything are not
conflicts. A person rules on a flag by writing the change that settles it.
"""
from __future__ import annotations

import hashlib
import json
import re

from . import core

ITEM_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
FIELDS = ("title", "owner", "outcome", "source", "section", "label")
DEFAULT_SECTION = "Items"


def _need(ok, what: str) -> None:
    if not ok:
        raise core.Refused("bad-field", what)


def _item(d: dict, kind: str) -> None:
    _need(isinstance(d.get("item"), str) and ITEM_RE.fullmatch(d["item"]), f"{kind}.item: a plain id")


def _strs(d: dict, kind: str, names) -> None:
    for f in names:
        _need(f not in d or isinstance(d[f], str), f"{kind}.{f}: a string")


def _add(d: dict) -> None:
    _item(d, "add")
    _need(isinstance(d.get("title"), str) and d["title"].strip(), "add.title")
    _strs(d, "add", FIELDS)
    _need("owner" not in d or core.PRINCIPAL_RE.fullmatch(d["owner"]), "add.owner: a principal")


def _edit(d: dict) -> None:
    _item(d, "edit")
    f = d.get("fields")
    _need(isinstance(f, dict) and f and set(f) <= set(FIELDS), f"edit.fields: some of {', '.join(FIELDS)}")
    _strs(f, "edit.fields", FIELDS)
    _need("title" not in f or f["title"].strip(), "edit.fields.title: not empty")
    _need("owner" not in f or core.PRINCIPAL_RE.fullmatch(f["owner"]), "edit.fields.owner: a principal")


def _state(kind: str):
    return lambda d: _item(d, kind)


def _move(d: dict) -> None:
    _item(d, "move")
    _need("after" in d and (d["after"] is None or (isinstance(d["after"], str) and ITEM_RE.fullmatch(d["after"]))),
          "move.after: an item id, or null for the top")
    _need(d["after"] != d["item"], "move.after: not the item itself")


def _note(d: dict) -> None:
    _item(d, "note")
    _need(isinstance(d.get("text"), str) and d["text"].strip(), "note.text")


KINDS = {"add": _add, "edit": _edit, "tick": _state("tick"), "reopen": _state("reopen"), "move": _move, "note": _note}


# ---------------------------------------------------------------- the backlog the changes add up to

def ancestors(led: core.Ledger) -> dict[str, set[str]]:
    anc: dict[str, set[str]] = {}
    for i in led.order:  # parents first
        s: set[str] = set()
        for p in led.valid[i].parents:
            s.add(p)
            s |= anc.get(p, set())
        anc[i] = s
    return anc


def project(led: core.Ledger) -> tuple[dict, dict[str, list[str]]]:
    """(the backlog, flags): {"order": [item ids], "items": {id: item}}, and id -> flags."""
    anc = ancestors(led)
    concurrent = lambda a, b: a not in anc[b] and b not in anc[a]  # noqa: E731
    flags: dict[str, list[str]] = {}

    def flag(i: str, what: str) -> None:
        if what not in flags.setdefault(i, []):
            flags[i].append(what)

    order: list[str] = []
    items: dict[str, dict] = {}
    setters: dict[tuple[str, str], list[tuple[str, str]]] = {}   # (item, field) -> [(entry id, value)]
    states: dict[str, list[tuple[str, bool]]] = {}
    moves: dict[str, list[str]] = {}

    def set_field(i: str, item: str, f: str, v: str) -> None:
        for j, w in setters.get((item, f), []):
            if w != v and concurrent(i, j):
                flag(i, "concurrent-edit")
                flag(j, "concurrent-edit")
        setters.setdefault((item, f), []).append((i, v))
        items[item][f] = v

    for i in led.order:
        e = led.valid[i]
        if e.kind not in KINDS:
            continue
        d, item = e.data, e.data["item"]
        if e.kind == "add":
            if item in items:
                flag(i, "added-twice")
                continue
            items[item] = {"item": item, "section": DEFAULT_SECTION, "done": False, "notes": [], "added_by": e.principal,
                           "added_at": e.at, "changes": [i]}
            order.append(item)
            for f in FIELDS:
                if f in d:
                    set_field(i, item, f, d[f])
            continue
        if item not in items:
            flag(i, "unknown-item")
            continue
        items[item]["changes"].append(i)
        if e.kind == "edit":
            for f, v in d["fields"].items():
                set_field(i, item, f, v)
        elif e.kind in ("tick", "reopen"):
            done = e.kind == "tick"
            for j, was in states.get(item, []):
                if was != done and concurrent(i, j):
                    flag(i, "concurrent-state")
                    flag(j, "concurrent-state")
            states.setdefault(item, []).append((i, done))
            items[item]["done"] = done
        elif e.kind == "move":
            for j in moves.get(item, []):
                if concurrent(i, j):
                    flag(i, "concurrent-move")
                    flag(j, "concurrent-move")
            moves.setdefault(item, []).append(i)
            after = d["after"]
            if after is not None and after not in items:
                flag(i, "unknown-item")
                continue
            order.remove(item)
            order.insert(0 if after is None else order.index(after) + 1, item)
        elif e.kind == "note":
            items[item]["notes"].append(d["text"])
    return {"order": order, "items": items}, flags


def index(db, led: core.Ledger) -> None:
    """The backlog as tables: backlog (one row per item, in order) and its notes."""
    state, _ = project(led)
    db.executescript("""
        CREATE TABLE backlog (item TEXT PRIMARY KEY, n INTEGER, title TEXT, owner TEXT, outcome TEXT,
                              source TEXT, section TEXT, label TEXT, done INTEGER, added_by TEXT, added_at TEXT,
                              changes INTEGER);
        CREATE TABLE backlog_notes (item TEXT, n INTEGER, text TEXT);
        CREATE VIEW open_items AS SELECT * FROM backlog WHERE done = 0 ORDER BY n;
    """)
    for n, item in enumerate(state["order"]):
        x = state["items"][item]
        db.execute("INSERT INTO backlog VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (item, n, x.get("title"), x.get("owner"), x.get("outcome"), x.get("source"), x.get("section"),
                    x.get("label"), int(x["done"]), x["added_by"], x["added_at"], len(x["changes"])))
        db.executemany("INSERT INTO backlog_notes VALUES (?,?,?)", [(item, k, t) for k, t in enumerate(x["notes"])])


def render(led: core.Ledger) -> str:
    """The backlog as Markdown, in the shape of a TODO.md: sections in the order they first appear."""
    state, flags = project(led)
    out = ["# Backlog", "", "Generated from the backlog register; do not edit. In priority order.", ""]
    if flags:
        out += ["## Needs a person", ""]
        out += [f"- {', '.join(fs)}: `{i[:12]}` ({led.valid[i].kind} of `{led.valid[i].data.get('item')}` "
                f"by {led.valid[i].principal})" for i, fs in sorted(flags.items())]
        out.append("")
    sections: list[str] = []
    for item in state["order"]:
        s = state["items"][item]["section"]
        if s not in sections:
            sections.append(s)
    for s in sections:
        out += [f"## {s}", ""]
        for item in state["order"]:
            x = state["items"][item]
            if x["section"] != s:
                continue
            owner = f" [owner: {x['owner']}]" if x.get("owner") else ""
            label = f"{x['label']} " if x.get("label") else "- "
            line = f"{label}[{'x' if x['done'] else ' '}] **`{item}`**{owner}: {x['title']}"
            if x.get("outcome"):
                line += f" Outcome: {x['outcome']}"
            if x.get("source"):
                line += f" ({x['source']})"
            out.append(line)
            out += [f"  - note: {t}" for t in x["notes"]]
        out.append("")
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------- backfill from a TODO.md

TODO_ITEM = re.compile(r"^(?:(-|\d+[a-z]?\.)\s+)\[( |x)\]\s+\*\*`([^`]+)`\*\*\s*(?:\[owner:\s*([a-z0-9_.-]+)\])?\s*:?\s*(.*)$")
HEADING = re.compile(r"^##\s+(.+?)\s*$")


def todo_records(text: str, source: str) -> list[tuple[str, dict]]:
    """A TODO.md's items as (kind, data): an `add` for each, then a `tick` for each one done, in
    file order, each marked as backfill with its source, line and the hash of its original text."""
    out: list[tuple[str, dict]] = []
    section = DEFAULT_SECTION
    block: list[str] | None = None
    start = 0
    head = None

    def flush():
        if block is None:
            return
        label, done, item, owner, first = head
        original = "\n".join(block) + "\n"
        title = " ".join([first.strip()] + [ln.strip() for ln in block[1:]]).strip()
        bf = {"source": source, "line": start, "sha256": hashlib.sha256(original.encode()).hexdigest()}
        data = {"item": item if ITEM_RE.fullmatch(item) else re.sub(r"[^a-z0-9_.-]+", "-", item.lower()).strip("-"),
                "title": title or item, "section": section, "backfill": bf}
        if owner:
            data["owner"] = owner
        if label != "-":
            data["label"] = label
        out.append(("add", data))
        if done == "x":
            out.append(("tick", {"item": data["item"], "backfill": {**bf, "tick": True}}))

    for n, line in enumerate(text.splitlines(), 1):
        if m := HEADING.match(line):
            flush()
            block = None
            section = m.group(1)
            continue
        if m := TODO_ITEM.match(line):
            flush()
            block, start, head = [line], n, m.groups()
            continue
        if block is not None and line.strip() and line[:1].isspace():
            block.append(line)
            continue
        if block is not None and not line.strip():
            flush()
            block = None
            continue
        if block is not None:  # a line that is neither an item, a heading nor indented ends the item
            flush()
            block = None
    flush()
    return out


def already(led: core.Ledger) -> set[str]:
    """The backfill keys already imported: the original's hash, and whether it was the tick."""
    return {json.dumps([e.data["backfill"]["sha256"], bool(e.data["backfill"].get("tick"))])
            for e in led.valid.values() if isinstance(e.data.get("backfill"), dict) and "sha256" in e.data["backfill"]}


def backfill_key(data: dict) -> str:
    return json.dumps([data["backfill"]["sha256"], bool(data["backfill"].get("tick"))])
