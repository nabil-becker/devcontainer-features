#!/usr/bin/env python3
"""The ledger, wherever it is kept (`devhost-ledger`): Markdown files in the ledger directory, or an
agentic-register register (`DEVHOST_LEDGER_REGISTER`). Standard library only.

Usage:
  ledger.py where                          one line: where the ledger is
  ledger.py show [--month YYYY-MM]         the ledger as Markdown, oldest first (all months, or one)
  ledger.py tail [CHARS]                   the last CHARS characters of that Markdown (the scribe's context)
  ledger.py add --as P [--key K] FILE      sign the Markdown entries of FILE into the register as `work`
                                           entries (the scribe); prints one id per line
  ledger.py add-runs --as P [--key K] FILE sign the run records of FILE (one JSON object a line, already in
                                           the register's `run` shape) as `run` entries
  ledger.py review FILE                    keep FILE (a `## Review YYYY-MM-DD` section) as a review, in register
                                           mode only: <reviews dir>/YYYY-MM-DD.md, never replaced
  ledger.py carry-reviews FILE...          copy the `## Review` sections of monthly files into the reviews folder
                                           (the cut-over to register mode); a review already there is skipped
  ledger.py mirror                         bring the register's mirror level, only when its folder is there
  ledger.py archive-costs --as P [--key K] --out ARCHIVE [--dry-run] FILE...
                                           the cost history (the .jsonl stores and .md reports) as one archive
                                           file, created once, and one signed `work` entry recording it
  ledger.py restore-costs ARCHIVE DIR      give the archived source files back, byte for byte, into DIR
  ledger.py back-runs --as P [--key K] RUNS CURSOR
                                           the backs' metrics lines of RUNS (runs.jsonl) after the line
                                           number kept in CURSOR, as `run` entries; CURSOR moves on

Every reader of the ledger goes through `months(root)`: in file mode it reads the monthly files; in
register mode it renders the register's `work` entries in the devhost's own entry shape
(`### YYYY-MM-DD <title>` and `- **Field:**` lines, the date being the original one for an entry imported
from the old files), one text per month, so the briefing, the cost report, the site and the ledger
review read both alike. The register is the truth; the Markdown is a view, generated, never edited.

A review is not an entry (an entry is signed, and the host that runs the review holds no key): in register
mode it is a file, `<reviews dir>/YYYY-MM-DD.md` (`DEVHOST_REVIEWS_DIR`, else `<DEVHOST_RECORDS_DIR>/reviews`,
else `<ledger dir>/reviews`), created once by `devhost-ledger review` and never replaced, with an `At:` line;
the view puts it between the entries by that time, as a `## Review YYYY-MM-DD` section, as the monthly files
did. A review carried over from the monthly files has no `At:` and sits after its day's entries.

The register is read and written only through the `agentic-register` command (`DEVHOST_AGENTIC_REGISTER`
names another, for the tests): `query` to read, `add` to write, so its signatures, its guard and its
append-only store are never bypassed. The Markdown of a new entry is parsed by the register's own
importer (`register.backfill`, from `AGENTIC_REGISTER_LIB`, default /usr/local/lib/agentic-register), so a
new entry and an imported one have the same fields.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import MONTHLY, ledger_dir, ledger_register, read_text, rel, repo_root, reviews_dir  # noqa: E402

TEXT_FIELDS = (("Session", "session"), ("Engineer", "engineer"), ("Branch", "branch"), ("Operator", "operator"),
               ("Asked", "asked"), ("Skill", "skill"))
LIST_FIELDS = (("Came out", "came_out"),)
AFTER_FRICTION = (("Learned", "learned"), ("Decisions", "decisions"), ("For the repository", "for_repository"),
                  ("Decisions needed", "decisions_needed"))
KNOWN = {f for _, f in TEXT_FIELDS + LIST_FIELDS + AFTER_FRICTION} | {
    "title", "friction", "measures", "cost", "corrects", "corrects_note", "backfill"}
REVIEW_FILE = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:-(\d+))?\.md$")
REVIEW_AT = re.compile(r"^At: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s*$", re.M)
REVIEW_SOURCE = re.compile(r"^Source: (\S+):(\d+)\s*$", re.M)


_CACHE: dict[tuple[str, str], list[tuple[str, str]]] = {}


class RegisterError(RuntimeError):
    """The register could not be read or written: said in one line."""


def command() -> str:
    return os.environ.get("DEVHOST_AGENTIC_REGISTER", "").strip() or "agentic-register"


def _ar(args: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    try:
        return subprocess.run([command(), *args], capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RegisterError(f"{command()} could not run: {exc}") from exc


def register_entries(name: str) -> list[dict]:
    """Every valid entry of the register, in its order: {id, at, principal, kind, data}."""
    done = _ar(["query", "--json", "--register", name,
                "SELECT id, at, principal, kind, data FROM entries ORDER BY n"])
    if done.returncode != 0:
        raise RegisterError((done.stderr.strip().splitlines() or [f"{command()} query failed"])[-1])
    try:
        rows = json.loads(done.stdout or "[]")
    except ValueError as exc:
        raise RegisterError(f"{command()} query returned no JSON") from exc
    out = []
    for r in rows:
        data = r.get("data")
        if isinstance(data, str):
            try:
                data = json.loads(data)
            except ValueError:
                data = {}
        out.append({"id": r.get("id", ""), "at": str(r.get("at") or ""), "principal": r.get("principal", ""),
                    "kind": r.get("kind", ""), "data": data if isinstance(data, dict) else {}})
    return out


def entry_date(e: dict) -> str:
    """The entry's date: the original one for an imported entry, else the day it was written."""
    b = e["data"].get("backfill")
    if isinstance(b, dict) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(b.get("date", ""))[:10]):
        return str(b["date"])[:10]
    return e["at"][:10]


def _items(value) -> list[str]:
    if isinstance(value, list):
        return [str(v) for v in value if str(v).strip()]
    return [str(value)] if str(value or "").strip() else []


def _field(lines: list[str], label: str, value) -> None:
    items = _items(value)
    if not items:
        return
    if len(items) == 1:
        lines.append(f"- **{label}:** {items[0]}")
    else:
        lines.append(f"- **{label}:**")
        lines += [f"  - {x}" for x in items]


def render_entry(e: dict, titles: dict[str, str]) -> str:
    """One work entry in the devhost's shape (scribe/entry-template.md)."""
    d = e["data"]
    lines = [f"### {entry_date(e)} {str(d.get('title', '')).strip()}", ""]
    for label, f in TEXT_FIELDS + LIST_FIELDS:
        _field(lines, label, d.get(f))
    friction = d.get("friction")
    if isinstance(friction, list) and friction:
        texts = [(f"[{x.get('tag')}] " if x.get("tag") and x.get("tag") != "untagged" else "") + str(x.get("text", ""))
                 for x in friction if isinstance(x, dict)]
        _field(lines, "Friction", " ".join(texts) if len(texts) > 1 else texts)
    for label, f in AFTER_FRICTION:
        _field(lines, label, d.get(f))
    for k in sorted(set(d) - KNOWN):          # a field this view does not know is shown, never dropped
        if isinstance(d[k], (str, int, float)) or isinstance(d[k], list):
            _field(lines, k.replace("_", " ").capitalize(), d[k] if not isinstance(d[k], (int, float)) else str(d[k]))
    if d.get("measures"):
        lines.append(f"- **Measures:** {d['measures']}")
    elif isinstance(d.get("cost"), dict) and d["cost"].get("note"):
        lines.append(f"- **Measures:** {d['cost']['note']}")
    if d.get("corrects"):
        lines.append(f"- **Corrects:** {titles.get(d['corrects'], d['corrects'][:12])}")
    elif d.get("corrects_note"):
        lines.append(f"- **Corrects:** {d['corrects_note']}")
    return "\n".join(lines) + "\n"


def _place(e: dict) -> tuple[str, str]:
    """Where an entry sits in time: its date, and its time of day when it was written at the time (an
    imported entry has only its original date, and keeps the register's order within that day)."""
    b = e["data"].get("backfill")
    return entry_date(e), ("" if isinstance(b, dict) else e["at"][11:19])


def review_files(folder: Path) -> list[tuple[tuple[str, str], str]]:
    """The reviews kept as files (register mode): ((date, time of day), text). `At:` in the text gives the
    time; a review without it sits after its day's entries, unless it was carried over from a monthly file
    (`Source: <file>:<line>`): then render_months puts it where it stood among the imported entries."""
    out = []
    if not folder.is_dir():
        return out
    found = [(m, p) for p in folder.iterdir() if (m := REVIEW_FILE.match(p.name)) and p.is_file()]
    for m, p in sorted(found, key=lambda x: (x[0].group(1), int(x[0].group(2) or 1))):
        text = read_text(p).strip() + "\n"
        at = REVIEW_AT.search(text)
        out.append(((m.group(1), at.group(1)[11:19] if at else "~"), text))
    return out


def render_months(entries: list[dict], label: str = "register",
                  reviews: list[tuple[tuple[str, str], str]] | None = None) -> list[tuple[str, str]]:
    """The work entries, and the reviews between them, as one Markdown text per month, oldest month first."""
    titles = {e["id"]: f"{entry_date(e)} {e['data'].get('title', '')}" for e in entries if e["kind"] == "work"}
    items = [(_place(e), n, render_entry(e, titles)) for n, e in enumerate(entries) if e["kind"] == "work"]
    imported = [(e["data"]["backfill"], _place(e), n) for n, e in enumerate(entries)
                if e["kind"] == "work" and isinstance(e["data"].get("backfill"), dict)]
    for k, (place, text) in enumerate(reviews or []):
        src = REVIEW_SOURCE.search(text)
        after = [(p, n) for b, p, n in imported if src and b.get("source") == src.group(1)
                 and isinstance(b.get("line"), int) and b["line"] > int(src.group(2))]
        if after:   # just before the first imported entry that followed it in its monthly file
            p, n = min(after, key=lambda x: (x[0], x[1]))
            items.append((p, n - 0.5, text))
        else:
            items.append((place, len(entries) + k, text))
    by_month: dict[str, list[str]] = {}
    for place, _, text in sorted(items, key=lambda x: (x[0][0], x[0][1], x[1])):
        by_month.setdefault(place[0][:7], []).append(text)
    return [(f"{label}/{m}", f"# Ledger, {m}\n\n" + "\n".join(by_month[m])) for m in sorted(by_month)]


def months(root: Path) -> list[tuple[str, str]]:
    """The ledger as (where, Markdown) per month, oldest first, whichever way it is kept.

    Register mode raises RegisterError when the register cannot be read: a reader says so rather than
    showing an empty ledger."""
    name = ledger_register()
    if name:
        key = (name, str(reviews_dir(root)))
        if key not in _CACHE:   # one query per process: the briefing and the report read it several times
            _CACHE[key] = render_months(register_entries(name), f"register:{name}", review_files(reviews_dir(root)))
        return _CACHE[key]
    folder = ledger_dir(root)
    files = sorted(p for p in folder.glob("*.md") if MONTHLY.match(p.name)) if folder.is_dir() else []
    return [(rel(root, p), read_text(p)) for p in files]


def month_text(root: Path, month: str) -> str:
    return next((t for where, t in months(root) if where.endswith(f"{month}.md") or where.endswith(f"/{month}")), "")


def add_review(root: Path, text: str, at: str) -> Path:
    """Keep a review (register mode): `<reviews dir>/YYYY-MM-DD.md` (a second one that day `-2`, ...), with
    its `At:` line, created once and never replaced. The text starts `## Review YYYY-MM-DD`."""
    m = re.match(r"^## Review (\d{4}-\d{2}-\d{2})", text.lstrip())
    if not m:
        raise RegisterError("a review starts with '## Review YYYY-MM-DD'")
    body = text.strip() + "\n"
    if not REVIEW_AT.search(body):
        first, _, rest = body.partition("\n")
        body = f"{first}\n\nAt: {at}\n{rest}"
    folder = reviews_dir(root)
    folder.mkdir(parents=True, exist_ok=True)
    for n in range(1, 100):
        path = folder / (f"{m.group(1)}.md" if n == 1 else f"{m.group(1)}-{n}.md")
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        return path
    raise RegisterError(f"too many reviews on {m.group(1)} in {folder}")


def review_sections(text: str, source: str = "") -> list[str]:
    """The `## Review YYYY-MM-DD` sections of a monthly Markdown file, each up to the next heading; with
    `source`, each says where it stood (`Source: <source>:<line>`), so the view keeps its place."""
    out: list[list[str]] = []
    inside = False
    for number, line in enumerate(text.splitlines(), 1):
        if re.match(r"^## Review \d{4}-\d{2}-\d{2}", line):
            out.append([line] + (["", f"Source: {source}:{number}"] if source else []))
            inside = True
        elif re.match(r"^#{1,3} ", line):
            inside = False
        elif inside:
            out[-1].append(line)
    return ["\n".join(s).strip() + "\n" for s in out]


def backfill_source(path: Path) -> str:
    """The file as agentic-register's import named it: from the top of its git repository."""
    path = Path(path).resolve()
    for parent in path.parents:
        if (parent / ".git").exists():
            return path.relative_to(parent).as_posix()
    return path.name


def carry_reviews(root: Path, files: list[Path]) -> list[str]:
    """Copy the reviews of the monthly files into the reviews folder, once: a review already there (the
    same text) is skipped, so running it again adds nothing. They get no `At:` line (their time is not
    known) but a `Source:` line, so each sits where it stood among the imported entries."""
    folder = reviews_dir(root)
    have = {read_text(p).strip() for p in folder.glob("*.md")} if folder.is_dir() else set()
    out = []
    for f in files:
        for section in review_sections(read_text(f), backfill_source(f)):
            if section.strip() in have:
                out.append(f"already kept: {section.splitlines()[0]}")
                continue
            m = re.match(r"^## Review (\d{4}-\d{2}-\d{2})", section)
            folder.mkdir(parents=True, exist_ok=True)
            for n in range(1, 100):
                path = folder / (f"{m.group(1)}.md" if n == 1 else f"{m.group(1)}-{n}.md")
                try:
                    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                except FileExistsError:
                    continue
                with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as h:
                    h.write(section)
                have.add(section.strip())
                out.append(f"kept {path}")
                break
    return out


def where(root: Path) -> str:
    name = ledger_register()
    return f"register {name} (agentic-register)" if name else f"{rel(root, ledger_dir(root))}/"


# Writing (register mode only)

def _backfill_module():
    lib = os.environ.get("AGENTIC_REGISTER_LIB", "").strip() or "/usr/local/lib/agentic-register"
    if lib not in sys.path:
        sys.path.insert(0, lib)
    try:
        from register import backfill  # type: ignore
    except ImportError as exc:
        raise RegisterError(f"the agentic-register library is not at {lib} (AGENTIC_REGISTER_LIB): {exc}") from exc
    return backfill


def parse_entries(text: str) -> list[dict]:
    """The Markdown entries of `text` as `work` data, by the register's own importer, without its backfill mark."""
    backfill = _backfill_module()
    out = []
    for d in backfill.markdown_records(text, "devhost-scribe"):
        mark = d.pop("backfill", {})
        if isinstance(mark, dict) and mark.get("corrects_title"):
            d["corrects_note"] = mark["corrects_title"]
        out.append(d)
    return out


def _resolve_corrects(records: list[dict], entries: list[dict]) -> None:
    """A correction names the entry it replaces by date and title; name it by id where the title is known."""
    ids: dict[str, str] = {}
    for e in entries:
        if e["kind"] == "work" and e["data"].get("title"):
            t = str(e["data"]["title"])
            ids[t.lower()] = e["id"]
            ids[f"{entry_date(e)} {t}".lower()] = e["id"]
    for d in records:
        note = str(d.get("corrects_note", "")).strip().rstrip(".").lower()
        if note and note in ids:
            d["corrects"] = ids[note]
            d.pop("corrects_note")


def _add(name: str, who: str, key: str | None, kind: str, data: dict) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(data, f)
        path = f.name
    try:
        args = ["add", "--json", "--register", name, "--as", who, "--kind", kind, "--file", path]
        if key:
            args += ["--key", key]
        done = _ar(args, timeout=120)
    finally:
        os.unlink(path)
    try:
        reply = json.loads(done.stdout or "{}")
    except ValueError:
        reply = {}
    if done.returncode != 0 or not reply.get("id"):
        why = reply.get("refused") and f"refused, {reply.get('refused')}: {reply.get('detail')}"
        raise RegisterError(why or (done.stderr.strip().splitlines() or [f"{command()} add failed"])[-1])
    return str(reply["id"])


def add_markdown(text: str, who: str, key: str | None = None) -> list[str]:
    name = ledger_register()
    if not name:
        raise RegisterError("DEVHOST_LEDGER_REGISTER is not set: the ledger is the Markdown files")
    records = parse_entries(text)
    if any(d.get("corrects_note") for d in records):
        _resolve_corrects(records, register_entries(name))
    _CACHE.clear()
    return [_add(name, who, key, "work", d) for d in records]


def add_runs(records: list[dict], who: str, key: str | None = None) -> list[str]:
    name = ledger_register()
    if not name:
        raise RegisterError("DEVHOST_LEDGER_REGISTER is not set: the ledger is the Markdown files")
    return [_add(name, who, key, "run", d) for d in records]


def mirror_timeout() -> int:
    try:
        return max(1, int(os.environ.get("DEVHOST_MIRROR_TIMEOUT", "") or 300))
    except ValueError:
        return 300


def mirror() -> str:
    """Bring the register's mirror level (`agentic-register mirror`), only when its folder is there: a shared
    folder that is not mounted leaves an empty mount point, and a copy written into it would be hidden as
    soon as the mount comes back. Returns the command's line; raises RegisterError when not done."""
    name = ledger_register()
    if not name:
        raise RegisterError("DEVHOST_LEDGER_REGISTER is not set: no register to mirror")
    done = _ar(["registers", "--json"])
    try:
        rows = json.loads(done.stdout or "[]")
    except ValueError:
        rows = []
    target = next((r.get("mirror") for r in rows if r.get("name") == name), None)
    if not target:
        raise RegisterError(f"the register {name} has no mirror (the registers option)")
    if not Path(target).is_dir():
        raise RegisterError(f"the mirror folder {target} is not there (the shared folder not mounted?); not mirrored")
    # Bounded: the scribe holds its job lock while it mirrors, and a slow folder (rclone's FUSE mount reads a
    # file in about half a second) must not hold it for half an hour. The copy is only adds, so a cut-off run
    # is safe and the next one carries on. DEVHOST_MIRROR_TIMEOUT, seconds (default 300).
    limit = mirror_timeout()
    try:
        done = _ar(["mirror", "--register", name], timeout=limit)
    except RegisterError as exc:
        if "timed out" in str(exc):
            raise RegisterError(f"mirror stopped after {limit}s (DEVHOST_MIRROR_TIMEOUT)") from exc
        raise
    line = (done.stdout.strip().splitlines() or done.stderr.strip().splitlines() or ["mirror said nothing"])[-1]
    if done.returncode != 0:
        raise RegisterError(line)
    return line


ARCHIVE_TITLE = "Cost history archived to cold storage"
_TS = re.compile(r'"ts":\s*"(\d{4}-\d{2}-\d{2}T[^"]*)"')


def _sha256(data: bytes) -> str:
    import hashlib
    return hashlib.sha256(data).hexdigest()


def build_cost_archive(files: list[Path]) -> tuple[bytes, dict]:
    """The cost history of `files` (the cost stores `.jsonl` and the reports `.md`) as one cold-storage archive:
    one JSON line per line of each source, `{"source", "line", "raw"}`, sources in name order, so every source
    comes back byte for byte (`restore_cost_archive`). Returns the archive's bytes and what the register entry
    says of it: records, the period (the first and last `ts` of the stores), each source's name, size, lines and
    sha256."""
    out: list[str] = []
    sources, stamps, records = [], [], 0
    for f in sorted(files, key=lambda x: Path(x).name):
        data = Path(f).read_bytes()
        name = backfill_source(Path(f))
        lines = data.decode("utf-8").split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        for n, raw in enumerate(lines, 1):
            out.append(json.dumps({"source": name, "line": n, "raw": raw}, ensure_ascii=False, separators=(",", ":")))
        if name.endswith(".jsonl"):
            records += len(lines)
            stamps += [m.group(1) for raw in lines for m in [_TS.search(raw)] if m]
        sources.append({"source": name, "bytes": len(data), "lines": len(lines), "sha256": _sha256(data),
                        "ends_with_newline": data.endswith(b"\n")})
    archive = ("\n".join(out) + "\n").encode("utf-8")
    return archive, {"sha256": _sha256(archive), "bytes": len(archive), "records": records, "lines": len(out),
                     "from": min(stamps)[:10] if stamps else None, "to": max(stamps)[:10] if stamps else None,
                     "sources": sources}


def restore_cost_archive(archive: bytes) -> dict[str, bytes]:
    """The source files of an archive, byte for byte (the check that it lost nothing)."""
    parts: dict[str, list[str]] = {}
    for line in archive.decode("utf-8").splitlines():
        r = json.loads(line)
        parts.setdefault(r["source"], []).append(r["raw"])
    return {s: ("\n".join(lines) + "\n").encode("utf-8") for s, lines in parts.items()}


def archive_costs(files: list[Path], out: Path, who: str, key: str | None = None, dry_run: bool = False) -> str:
    """Archive the cost history into `out` (created once, never replaced: an archive already there must have the
    same bytes) and record it in the register as one signed `work` entry holding its path, size, sha256, period
    and record count and each source's hash; the history itself is too large for an entry (agentic-register's
    MAX_BODY, 64 KiB). Running it again adds nothing: an entry with the same archive sha256 is found first."""
    name = ledger_register()
    if not name:
        raise RegisterError("DEVHOST_LEDGER_REGISTER is not set: no register to record the archive in")
    archive, info = build_cost_archive(files)
    for source in info["sources"]:   # lost nothing: every source comes back byte for byte
        back = restore_cost_archive(archive).get(source["source"], b"")
        if _sha256(back if source["ends_with_newline"] else back[:-1]) != source["sha256"]:
            raise RegisterError(f"the archive does not give back {source['source']} byte for byte; nothing written")
    info["path"] = str(out)
    summary = (f"{info['records']} cost records and {len(info['sources'])} files, {info['from']} to {info['to']}, "
               f"in {out} ({info['bytes']:,} bytes, sha256 {info['sha256'][:12]})")
    have = [e for e in register_entries(name) if e["kind"] == "work"
            and isinstance(e["data"].get("archive"), dict) and e["data"]["archive"].get("sha256") == info["sha256"]]
    if dry_run:
        return ("already recorded: " if have else "would archive: ") + summary
    if have:
        return f"already recorded in entry {have[0]['id'][:12]}: {summary}"
    out = Path(out)
    if out.exists():
        if _sha256(out.read_bytes()) != info["sha256"]:
            raise RegisterError(f"{out} exists with other contents; it is never replaced")
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(out, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        with os.fdopen(fd, "wb") as h:
            h.write(archive)
        if _sha256(out.read_bytes()) != info["sha256"]:
            raise RegisterError(f"{out} reads back different from what was written; no entry recorded")
    data = {"title": f"{ARCHIVE_TITLE} ({info['from']} to {info['to']})",
            "came_out": [summary, "The cost stores (.jsonl) and reports (.md) leave git with the records (records-out-of-git); "
                         "each source's sha256 is in `archive`, and `devhost-ledger restore-costs <archive> <dir>` "
                         "gives them back byte for byte."],
            "archive": info}
    _CACHE.clear()
    i = _add(name, who, key, "work", data)
    return f"recorded in entry {i[:12]}: {summary}"


def back_run_record(r: dict) -> dict | None:
    """One back's metrics line (runs.jsonl, written by the runner) in the register's `run` shape."""
    if not isinstance(r, dict) or not r.get("job"):
        return None
    model = str(r.get("model") or "none")
    tokens = {"model": model}
    for src, dst in (("input_tokens", "input"), ("output_tokens", "output"),
                     ("cache_write_tokens", "cache_write"), ("cache_read_tokens", "cache_read")):
        if isinstance(r.get(src), int):
            tokens[dst] = r[src]
    cost = {"tokens": [tokens]}
    if isinstance(r.get("cost_usd"), (int, float)):
        cost["usd_micro"] = round(r["cost_usd"] * 1_000_000)
    out = {"member": f"back {r['job']}", "model": model, "outcome": str(r.get("status") or "unknown"), "cost": cost,
           "at_run": str(r.get("ts", "")), "session": str(r.get("sid", "")), "engineer": str(r.get("engineer", ""))}
    if isinstance(r.get("duration_s"), (int, float)):
        out["ms"] = int(round(r["duration_s"] * 1000))
    if r.get("undone"):
        out["undone"] = int(r["undone"])
    return out


def back_runs(runs: Path, cursor: Path, who: str, key: str | None = None) -> list[str]:
    """The metrics lines after the cursor as `run` entries; the cursor moves past each one written."""
    try:
        lines = runs.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    try:
        start = int(cursor.read_text(encoding="utf-8").strip() or 0)
    except (OSError, ValueError):
        start = 0
    ids = []
    for n in range(start, len(lines)):
        try:
            rec = back_run_record(json.loads(lines[n]))
        except ValueError:
            rec = None
        if rec is not None:
            ids += add_runs([rec], who, key)
        cursor.write_text(str(n + 1), encoding="utf-8")
    return ids


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="devhost-ledger", description="The ledger, as Markdown files or a register.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("where")
    s = sub.add_parser("show")
    s.add_argument("--month")
    t = sub.add_parser("tail")
    t.add_argument("chars", nargs="?", type=int, default=8000)
    for n in ("add", "add-runs"):
        a = sub.add_parser(n)
        a.add_argument("--as", dest="who", required=True)
        a.add_argument("--key")
        a.add_argument("file")
    r = sub.add_parser("review")
    r.add_argument("file")
    sub.add_parser("mirror")
    ac = sub.add_parser("archive-costs")
    ac.add_argument("--as", dest="who", required=True)
    ac.add_argument("--key")
    ac.add_argument("--out", required=True)
    ac.add_argument("--dry-run", action="store_true")
    ac.add_argument("files", nargs="+")
    rc = sub.add_parser("restore-costs")
    rc.add_argument("archive")
    rc.add_argument("dir")
    c = sub.add_parser("carry-reviews")
    c.add_argument("files", nargs="+")
    b = sub.add_parser("back-runs")
    b.add_argument("--as", dest="who", required=True)
    b.add_argument("--key")
    b.add_argument("runs")
    b.add_argument("cursor")
    a = p.parse_args(argv)
    root = repo_root()
    try:
        if a.cmd == "where":
            print(where(root))
        elif a.cmd == "show":
            texts = [t for w, t in months(root) if not a.month or w.endswith((f"{a.month}.md", f"/{a.month}"))]
            print("\n".join(texts), end="")
        elif a.cmd == "tail":
            print("\n".join(t for _, t in months(root))[-a.chars:], end="")
        elif a.cmd == "add":
            print("\n".join(add_markdown(Path(a.file).read_text(encoding="utf-8"), a.who, a.key)))
        elif a.cmd == "add-runs":
            records = [json.loads(line) for line in Path(a.file).read_text(encoding="utf-8").splitlines() if line.strip()]
            print("\n".join(add_runs(records, a.who, a.key)))
        elif a.cmd == "review":
            if not ledger_register():
                raise RegisterError("in file mode a review is appended to the monthly file, as before")
            print(add_review(root, Path(a.file).read_text(encoding="utf-8"), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        elif a.cmd == "archive-costs":
            print(archive_costs([Path(f) for f in a.files], Path(a.out), a.who, a.key, a.dry_run))
        elif a.cmd == "restore-costs":
            for name, data in restore_cost_archive(Path(a.archive).read_bytes()).items():
                target = Path(a.dir) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                print(target)
        elif a.cmd == "mirror":
            print(mirror())
        elif a.cmd == "carry-reviews":
            print("\n".join(carry_reviews(root, [Path(f) for f in a.files])))
        elif a.cmd == "back-runs":
            print("\n".join(back_runs(Path(a.runs), Path(a.cursor), a.who, a.key)))
    except RegisterError as exc:
        print(f"devhost-ledger: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
