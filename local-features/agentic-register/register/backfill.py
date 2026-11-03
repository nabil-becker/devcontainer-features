"""Backfill: bring records kept before the ledger into it, marked so they are never taken for entries
written at the time (README.md, "Backfill").

Each record becomes an entry signed by whoever runs the import, the date it is imported, with a
`backfill` field: where it came from, its original date, and the SHA-256 of its original text.
The signature says "this import is faithful", not "I did this work". Importing twice adds nothing,
because entries already imported are recognised by that hash. The source stays where it is.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

HEADING = re.compile(r"^### (\d{4}-\d{2}-\d{2}) (.+?)\s*$")
OTHER_HEADING = re.compile(r"^#{1,3} ")       # a heading at an entry's level or above ends the entry
FIELD = re.compile(r"^- \*\*([^*]+?):\*\*\s?(.*)$")
PLAIN_FIELD = re.compile(r"^- ([A-Z][A-Za-z ]{0,39}?):\s?(.*)$")   # an entry written without the bold
ITEM = re.compile(r"^  +- (.*)$")
TAG = re.compile(r"^`?\[([a-z0-9_-]+(?:: [a-z0-9_-]+)?)\]`?\s*(.*)$")   # [tag], [skill: name], either in backticks
NONE = re.compile(r"^none\.?$", re.IGNORECASE)
# where a further tagged item starts on one friction line: after a full stop or semicolon, before a tag
INLINE_SPLIT = re.compile(r"(?<=[.;])\s+(?=`?\[[a-z][a-z0-9_-]*(?:: [a-z0-9_-]+)?\]`?)")

LISTS = {"Came out": "came_out", "Learned": "learned", "Decisions": "decisions",
         "Decisions needed": "decisions_needed", "For the repository": "for_repository"}
TEXTS = {"Operator": "operator", "Session": "session", "Asked": "asked"}


def _snake(label: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", label.lower()).strip("_")
    return s if re.fullmatch(r"[a-z][a-z0-9_]{0,63}", s) else "field"


def _friction(value: str) -> list[dict]:
    """One friction value as {tag, text} items. A line may hold several tagged items, each starting
    after a full stop or a semicolon (`[client] one; [tooling] two. [docs] three`): each is its own
    item. Tags side by side (`[tooling] [skill: x] text`) each get the text. Text before the first
    tag is an untagged item; a tag in the middle of a sentence stays in its text."""
    out = []
    for part in INLINE_SPLIT.split(value):
        part = part.strip().rstrip(";").rstrip()
        if not part:
            continue
        tags = []
        while m := TAG.match(part):
            tags.append(m.group(1))
            part = m.group(2)
        out += [{"tag": t, "text": part} for t in tags] or [{"tag": "untagged", "text": part}]
    return out or [{"tag": "untagged", "text": value}]


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def markdown_records(text: str, source: str) -> list[dict]:
    """The entries of a Markdown ledger (markdown_scan), without its warnings."""
    return markdown_scan(text, source)[0]


def _fences(lines: list[str]) -> tuple[list[tuple[int, int]], int | None]:
    """The fenced blocks of a file as (first, last) line indexes, both fence lines, paired in order;
    and the index of a fence that nothing closes, if any. A fence still open at the end of the file
    is a stray (a code block runs to the end of a ledger only by mistake): it is read as text, not
    code, so it hides nothing after it."""
    marks = [i for i, line in enumerate(lines) if line.startswith("```")]
    stray = marks.pop() if len(marks) % 2 else None
    return list(zip(marks[::2], marks[1::2])), stray


def markdown_scan(text: str, source: str) -> tuple[list[dict], list[dict]]:
    """The entries of a Markdown ledger in the `### YYYY-MM-DD <title>` / `- **Field:** ...` shape,
    in file order, and the warnings a reader should see before trusting the count.

    Headings inside fenced code (a template) are not entries: each one is a warning, so a fence
    that hides real entries shows in the dry run. A fence that nothing closes is read as text and
    is a warning too. An entry heading does not close a fence: a fence that is closed keeps a dated
    example out, and one that is not is caught above. Fence lines are never part of an entry's text.
    Another heading at an entry's level or above (`## Review ...`) ends the entry before it; its
    section is not an entry. An entry with no bold field is read in the plain `- Field: ...` shape."""
    lines = text.splitlines()
    pairs, stray = _fences(lines)
    inside = {i: (a, b) for a, b in pairs for i in range(a, b + 1)}
    warnings: list[dict] = []
    if stray is not None:
        warnings.append({"line": stray + 1, "problem": "unclosed-fence",
                         "detail": "a code fence opened here is never closed; read as text, not code"})
    blocks: list[tuple[int, list[str]]] = []
    open_ = False
    for i, line in enumerate(lines):
        if i == stray:
            continue
        if i in inside:
            a, b = inside[i]
            if HEADING.match(line):
                warnings.append({"line": i + 1, "problem": "heading-in-fence",
                                 "detail": f"an entry heading inside fenced code (lines {a + 1}-{b + 1}) is not imported"})
            continue
        if HEADING.match(line):
            blocks.append((i + 1, [line]))
            open_ = True
        elif OTHER_HEADING.match(line):   # a section that is not an entry (a review): not part of the one before
            open_ = False
        elif blocks and open_:
            blocks[-1][1].append(line)
    return [_record(ls, n, source) for n, ls in blocks], warnings


def _record(lines: list[str], line_no: int, source: str) -> dict:
    original = "\n".join(lines).rstrip() + "\n"
    date, title = HEADING.match(lines[0]).groups()
    fields: list[tuple[str, str, list[str]]] = []   # label, text on its line, items under it
    field = FIELD if any(FIELD.match(line) for line in lines[1:]) else PLAIN_FIELD
    for line in lines[1:]:
        if m := field.match(line):
            fields.append((m.group(1).strip(), m.group(2).strip(), []))
        elif not fields or not line.strip():
            continue
        elif m := ITEM.match(line):
            fields[-1][2].append(m.group(1).strip())
        elif fields[-1][2]:              # a continuation of the last item
            fields[-1][2][-1] += " " + line.strip()
        else:                            # a continuation of the field's own text
            label, t, items = fields[-1]
            fields[-1] = (label, (t + " " + line.strip()).strip(), items)

    data: dict = {"title": title}
    corrects_title = None
    for label, t, items in fields:
        values = ([t] if t else []) + items
        if label in TEXTS:
            data[TEXTS[label]] = " ".join(values)
        elif label in LISTS:
            data[LISTS[label]] = values
        elif label == "Friction":
            data["friction"] = [f for v in values for f in _friction(v)]
        elif label == "Cost":
            data["cost"] = {"note": " ".join(values)}
        elif label == "Corrects":
            corrects_title = None if NONE.match(" ".join(values)) else " ".join(values)
        else:
            data[_snake(label)] = " ".join(values)
    data["backfill"] = {"source": source, "line": line_no, "date": date, "sha256": _sha(original)}
    if corrects_title:
        data["backfill"]["corrects_title"] = corrects_title
    return data


def run_records(text: str, source: str) -> list[dict]:
    """The staff's model runs, one JSON object a line, as `run` entries' data."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        r = json.loads(line)
        tokens = {"model": str(r.get("model", ""))}
        for src, dst in (("input_tokens", "input"), ("output_tokens", "output"),
                         ("cache_write_tokens", "cache_write"), ("cache_read_tokens", "cache_read")):
            if isinstance(r.get(src), int):
                tokens[dst] = r[src]
        cost = {"tokens": [tokens]}
        if isinstance(r.get("cost_usd"), (int, float)):
            cost["usd_micro"] = round(r["cost_usd"] * 1_000_000)
        data = {"member": str(r.get("member") or "unknown"), "model": str(r.get("model") or "unknown"),
                "outcome": str(r.get("outcome") or "unknown"), "cost": cost,
                "backfill": {"source": source, "line": n, "date": str(r.get("ts", "")), "sha256": _sha(line)}}
        if isinstance(r.get("seconds"), (int, float)):
            data["ms"] = round(r["seconds"] * 1000)
        out.append(data)
    return out


def already(led) -> set[str]:
    """The SHA-256 of every original already imported into this ledger."""
    return {e.data["backfill"]["sha256"] for e in led.valid.values()
            if isinstance(e.data.get("backfill"), dict) and isinstance(e.data["backfill"].get("sha256"), str)}


def title_keys(data: dict, at: str = "") -> list[str]:
    """The names a correction may give an entry by: its title, and its date and title
    (`2026-10-21 <title>`, as the old ledger's `Corrects:` line wrote it). The date is the
    original's for a backfilled entry, else the day the entry was written."""
    t = data.get("title")
    if not isinstance(t, str):
        return []
    b = data.get("backfill")
    date = (b.get("date") if isinstance(b, dict) and isinstance(b.get("date"), str) else at)[:10]
    return [t] + ([f"{date} {t}"] if re.fullmatch(r"\d{4}-\d{2}-\d{2}", date) else [])


def resolve_corrects(records: list[dict], ids_by_title: dict[str, str]) -> None:
    """A correction named the entry it replaces by title, or by date and title; name it by id
    where that name is known (`ids_by_title` holds every name of `title_keys`)."""
    for d in records:
        t = d.get("backfill", {}).get("corrects_title")
        if t and t in ids_by_title:
            d["corrects"] = ids_by_title[t]


def source_name(path: Path) -> str:
    """The path as the record should name it: from the top of its git repository when it is in one."""
    path = path.resolve()
    for parent in [path.parent, *path.parents]:
        if (parent / ".git").exists():
            return str(path.relative_to(parent))
    return path.name
