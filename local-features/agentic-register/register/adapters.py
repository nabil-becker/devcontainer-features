"""Sources, sinks and stores around the core (SPEC.md, "Sources, sinks and stores").

A store keeps entry bytes by id and is never trusted: everything read from one is checked by the
core. A view is rebuilt from a ledger and is never read as the truth. `sync` is the one operation:
adding, merging, mirroring and indexing are all built on it.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import base64
import json
import os
import re
import signal
import sqlite3
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator, Protocol

from . import core

ENTRY_FILE = re.compile(r"([0-9a-f]{64})\.entry")


# ---------------------------------------------------------------- stores

class Store(Protocol):
    def put(self, i: str, raw: bytes) -> bool: ...     # True when new; a second put is a no-op
    def get(self, i: str) -> bytes | None: ...
    def ids(self) -> Iterable[str]: ...


def raws(store: Store) -> Iterator[bytes]:
    for i in store.ids():
        raw = store.get(i)
        if raw is not None:
            yield raw


class MemoryStore:
    """A store in memory, for tests and for staging."""

    def __init__(self):
        self._d: dict[str, bytes] = {}

    def put(self, i: str, raw: bytes) -> bool:
        if i in self._d:
            return False
        self._d[i] = raw
        return True

    def get(self, i: str) -> bytes | None:
        return self._d.get(i)

    def ids(self) -> list[str]:
        return sorted(self._d)


class DirStore:
    """A folder of `<id>.entry` files. Put-if-absent is atomic (a hard link never replaces), so
    several writers, processes or machines sharing the folder cannot overwrite each other."""

    def __init__(self, path: Path):
        self.path = Path(path)

    def put(self, i: str, raw: bytes) -> bool:
        if not core.ID_RE.fullmatch(i):
            raise ValueError(f"not an id: {i!r}")
        self.path.mkdir(parents=True, exist_ok=True)
        final = self.path / f"{i}.entry"
        if final.exists():
            return False
        fd, tmp = tempfile.mkstemp(dir=self.path, prefix=".put-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o444)
            try:
                os.link(tmp, final)
            except FileExistsError:
                return False
            return True
        finally:
            os.unlink(tmp)

    def get(self, i: str) -> bytes | None:
        try:
            return (self.path / f"{i}.entry").read_bytes()
        except FileNotFoundError:
            return None

    def ids(self) -> list[str]:
        if not self.path.is_dir():
            return []
        return sorted(m.group(1) for p in self.path.iterdir() if (m := ENTRY_FILE.fullmatch(p.name)))

    @contextmanager
    def writer_lock(self, key: str):
        """One writer per key at a time on this store, so two sessions of one agent do not fork."""
        self.path.mkdir(parents=True, exist_ok=True)
        lock = self.path / f".lock-{hashlib.sha256(key.encode()).hexdigest()[:16]}"
        with open(lock, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


# ---------------------------------------------------------------- the guard

GUARD_TIMEOUT = 10.0   # seconds, unless the register's guard_timeout says otherwise
GUARD_TIMEOUT_MAX = 300.0   # every writer of the register waits for it, holding the writer's lock
GUARD_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
GUARD_ERR_MAX = 4096        # bytes of the guard's stderr read; the refusal shows one line of it


def guard_env(register: str) -> dict[str, str]:
    """All a guard is given: a fixed PATH, the locale, and the register's name. Nothing else of the
    writer's environment (no tokens, no SSH agent, no BASH_ENV or LD_PRELOAD to change what it does)."""
    env = {"PATH": GUARD_PATH, "AGENTIC_REGISTER_GUARD_REGISTER": register}
    for k in ("LANG", "LC_ALL", "LC_CTYPE"):
        if k in os.environ:
            env[k] = os.environ[k]
    return env


def _printable(text: str) -> str:
    return "".join(c if c.isprintable() else "?" for c in text)


@dataclass(frozen=True)
class Guard:
    """An adopter's own check on what a writer puts in a register: a command run on every entry
    before it is signed (add, import, roster, every MCP write) and before an entry signed elsewhere
    is put into a store (sync, mirror). It reads the exact body bytes on standard input, with the
    register's name in $AGENTIC_REGISTER_GUARD_REGISTER, and exits 0 to let the entry through.
    Anything else refuses it (`guarded`), and nothing is written: a non-zero exit, a crash, a
    command that cannot run, or no answer within the timeout. The refusal names the exit and the
    first line of the guard's standard error; it never repeats the entry."""
    argv: tuple[str, ...]
    register: str
    timeout: float = GUARD_TIMEOUT

    def check(self, body: bytes) -> None:
        with tempfile.TemporaryFile() as errf:
            try:
                p = subprocess.Popen(list(self.argv), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errf,
                                     env=guard_env(self.register), cwd="/", start_new_session=True)
            except (OSError, ValueError) as e:
                raise core.Refused("guarded", f"the guard could not run: {getattr(e, 'strerror', None) or e}") from None
            try:
                p.communicate(body, timeout=self.timeout)
                timed_out = False
            except subprocess.TimeoutExpired:
                timed_out = True
            try:
                os.killpg(p.pid, signal.SIGKILL)   # the guard and anything it started, whatever it answered
            except OSError:
                pass
            p.wait()
            if p.stdin:
                try:
                    p.stdin.close()
                except OSError:
                    pass
            if timed_out:
                raise core.Refused("guarded", f"the guard gave no answer within {self.timeout:g}s") from None
            errf.seek(0)
            err = errf.read(GUARD_ERR_MAX)
        if p.returncode != 0:
            first = (err.decode("utf-8", errors="replace").strip().splitlines() or ["no reason given"])[0][:200]
            raise core.Refused("guarded", f"the guard refused the entry (exit {p.returncode}): {_printable(first)}")


UNGUARDED_REMOVALS_MAX = 8


def _ed25519_key(text) -> bool:
    """`ssh-ed25519 <base64>` whose blob really is an ed25519 public key: no room for free text."""
    if not isinstance(text, str) or text.count(" ") != 1:
        return False
    algo, b64 = text.split(" ")
    try:
        blob = base64.b64decode(b64, validate=True)
    except ValueError:
        return False
    name = b"ssh-ed25519"
    return (algo == "ssh-ed25519" and len(blob) == 4 + len(name) + 4 + 32
            and blob[:4 + len(name)] == len(name).to_bytes(4, "big") + name and blob[15:19] == (32).to_bytes(4, "big"))


def unguarded(kind: str, data: dict) -> bool:
    """An entry no guard is asked about: a roster entry that only removes keys (the operator's ruling
    D79), at most a few, each a real ed25519 public key and nothing else. It adds no free text, and a
    broken guard must never stop an operator removing a key. Anything more is guarded."""
    if kind != "roster" or not isinstance(data, dict) or set(data) != {"remove"}:
        return False
    rm = data["remove"]
    return (isinstance(rm, list) and 0 < len(rm) <= UNGUARDED_REMOVALS_MAX
            and all(isinstance(x, dict) and set(x) == {"key"} and _ed25519_key(x["key"]) for x in rm))


# ---------------------------------------------------------------- sync

@dataclass
class SyncReport:
    put: list[str] = field(default_factory=list)       # new in the sink
    already: int = 0                                     # valid, the sink had them
    held: dict[str, list[str]] = field(default_factory=dict)
    refused: dict[str, tuple[str, str]] = field(default_factory=dict)
    ledger: core.Ledger | None = None

    def __str__(self) -> str:
        return (f"{len(self.put)} new, {self.already} already there, {len(self.held)} held, "
                f"{len(self.refused)} refused")


def sync(sources: Iterable[Iterable[bytes]], sink: Store, anchors: dict[str, str],
         checked=None, register: str = core.LEGACY_REGISTER, kinds: dict | None = None,
         guard: Guard | None = None) -> SyncReport:
    """Check what the sources give plus what the sink holds, as entries of `register`; put the valid
    entries the sink lacks, parents first. Invalid, held and other registers' entries never reach it,
    nor does a ruled-out entry a counted prune names: a pruned line is never copied on. With a guard,
    each entry the sink lacks is put only if the guard lets its body through; one it refuses, and
    everything after it in this sync that descends from it, is reported refused (`guarded`)."""
    have = set(sink.ids())
    everything = list(raws(sink))
    for source in sources:
        everything.extend(source)
    led = core.read(everything, anchors, checked, register, kinds)
    report = SyncReport(held=dict(led.held), refused=dict(led.refused), ledger=led)
    guarded: set[str] = set()
    for i in led.order:
        if i in have:
            report.already += 1
            continue
        if i in led.still_there and i in led.ruled_out:
            continue                    # pruned: never copied on, so a store that left it out stays without
        if guard is not None:
            if any(p in guarded for p in led.valid[i].parents):
                guarded.add(i)
                report.refused[i] = ("guarded", "a parent was refused by the guard")
                continue
        if guard is not None and not unguarded(led.valid[i].kind, led.valid[i].value.get("data")):
            try:
                guard.check(led.valid[i].body)
            except core.Refused as r:
                guarded.add(i)
                report.refused[i] = (r.code, r.detail)
                continue
        if sink.put(i, led.valid[i].raw):
            report.put.append(i)
        else:
            report.already += 1
    return report


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def add(store: DirStore, private_key: Path, principal: str, kind: str, data: dict,
        anchors: dict[str, str], at: str | None = None, checked=None,
        register: str = core.LEGACY_REGISTER, kinds: dict | None = None, guard: Guard | None = None) -> str:
    """Sign a new entry as the next in this key's chain, naming the heads it saw, and put it in the
    store. Returns its id. Refuses when the key's own chain has forked: a person rules first. With a
    guard, the body is shown to it before signing, and only the bytes it let through are signed."""
    key = core.public_key(private_key)
    with store.writer_lock(key):
        led = core.read(raws(store), anchors, checked, register, kinds)
        mine = [e for e in led.valid.values() if e.key == key]
        if any(set(f) & {e.id for e in mine} for f in led.unruled_forks):
            raise core.Refused("bad-chain", "this key's chain has forked; an operator rules first (agentic-register forks)")
        mine = [e for e in mine if e.id not in led.ruled_out]   # a ruled fork goes on from the side kept
        last = max(mine, key=lambda e: e.seq, default=None)
        prev = last.id if last else None
        saw = [h for h in led.heads if h != prev][-core.MAX_SAW:]
        value = {"v": core.VERSION, "reg": register, "key": key, "as": principal,
                 "seq": (last.seq + 1) if last else 1, "prev": prev, "saw": sorted(saw), "at": at or now(),
                 "kind": kind, "data": data}
        body = None
        if guard is not None and not unguarded(kind, data):
            body = core.canonical(value)
            core.check_fields(value, kinds)    # a malformed entry is refused as such, before the guard sees it
            guard.check(body)
        raw = core.sign(value, private_key, kinds)
        if body is not None and raw.split(b"\n", 1)[0] != body:
            raise core.Refused("guarded", "the signed body is not the one the guard saw")
        i = core.entry_id(raw.split(b"\n", 1)[0])
        staged = MemoryStore()
        report = sync([raws(store), [raw]], staged, anchors, checked, register, kinds)
        if i not in report.ledger.valid:
            code, detail = report.refused.get(i, ("bad-chain", f"held: {report.held.get(i)}"))
            raise core.Refused(code, detail)
        if kind == "prune":       # SPEC.md, "Pruning": only what is ruled out, and never what a reader needs
            led2 = report.ledger
            its = set(core.ruled_out_by(led2, data["ruling"])) if data["ruling"] in led2.valid else set()
            for p in data["pruned"]:
                if p in led2.valid and (p not in its or led2.valid[p].kind in core.UNIVERSAL):
                    raise core.Refused("bad-field", f"prune: {p[:12]} is not ruled out, or is a {led2.valid[p].kind}")
                if p not in led2.valid:
                    raise core.Refused("bad-field", f"prune: {p[:12]} is not in this store; prune before deleting")
        store.put(i, raw)
        if hasattr(checked, "save"):
            checked.save()
        return i


def load_anchors(path: Path) -> dict:
    """Anchors from the reader's own configuration, one per line:
    `<principal> ssh-ed25519 <base64> [until=<entry id>]`. An anchor whose private key is lost
    stays, so the history it signed stays valid; one whose key is stolen is retired with `until`,
    never deleted (SPEC.md, "Anchors")."""
    out: dict = {}
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3 or not core.PRINCIPAL_RE.fullmatch(parts[0]) \
                or not core.KEY_RE.fullmatch(f"{parts[1]} {parts[2]}"):
            raise ValueError(f"{path}:{n}: expected '<principal> ssh-ed25519 <base64> [until=<entry id>]'")
        until = None
        for extra in parts[3:]:
            if extra.startswith("until="):
                until = extra[len("until="):]
                if not core.ID_RE.fullmatch(until):
                    raise ValueError(f"{path}:{n}: until= takes an entry id (64 hex characters)")
        out[f"{parts[1]} {parts[2]}"] = core.Anchor(parts[0], until) if until else parts[0]
    return out


class CheckedFile:
    """The reader's own record of good signatures, kept in a file of hashes (one per line)."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._s = set(self.path.read_text().split()) if self.path.exists() else set()
        self._new: list[str] = []

    def __contains__(self, h: str) -> bool:
        return h in self._s

    def add(self, h: str) -> None:
        if h not in self._s:
            self._s.add(h)
            self._new.append(h)

    def save(self) -> None:
        if self._new:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a") as f:
                f.write("".join(h + "\n" for h in self._new))
            self._new = []


# ---------------------------------------------------------------- views

SCHEMA = """
CREATE TABLE entries (id TEXT PRIMARY KEY, n INTEGER, key TEXT, principal TEXT, seq INTEGER,
                      prev TEXT, at TEXT, kind TEXT, title TEXT, data TEXT);
CREATE TABLE parents (id TEXT, parent TEXT);
CREATE TABLE heads (id TEXT PRIMARY KEY);
CREATE TABLE flags (id TEXT, flag TEXT);
CREATE TABLE forks (fork INTEGER, id TEXT, kept INTEGER);
CREATE TABLE held (id TEXT, waiting_for TEXT);
CREATE TABLE refused (id TEXT PRIMARY KEY, code TEXT, detail TEXT);
"""


def write_sqlite(led: core.Ledger, path: Path, views: str | None = None, extra=None) -> None:
    """Rebuild the index from a ledger: written beside, then moved over, so a reader never sees half."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    try:
        db.executescript(SCHEMA)
        if views is None:
            from .types import LEDGER_VIEWS as views
        db.executescript(views)
        if extra is not None:
            extra(db, led)
        for n, i in enumerate(led.order):
            e = led.valid[i]
            db.execute("INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?,?)",
                       (i, n, e.key, e.principal, e.seq, e.prev, e.at, e.kind,
                        e.data.get("title") if isinstance(e.data.get("title"), str) else None,
                        json.dumps(e.data, sort_keys=True)))
            db.executemany("INSERT INTO parents VALUES (?,?)", [(i, p) for p in e.parents])
        db.executemany("INSERT INTO heads VALUES (?)", [(h,) for h in led.heads])
        db.executemany("INSERT INTO flags VALUES (?,?)", [(i, f) for i, fs in led.flags.items() for f in fs])
        db.executemany("INSERT INTO forks VALUES (?,?,?)",
                       [(n, i, None if n not in led.rulings else int(led.rulings[n] == i))
                        for n, f in enumerate(led.forks) for i in f])
        db.executemany("INSERT INTO held VALUES (?,?)", [(i, p) for i, ps in led.held.items() for p in ps or [""]])
        db.executemany("INSERT INTO refused VALUES (?,?,?)", [(i, c, d) for i, (c, d) in led.refused.items()])
        db.commit()
    finally:
        db.close()
    os.replace(tmp, path)


def _usd(micro) -> str:
    return f"${micro / 1_000_000:.4f}"


def render_markdown(led: core.Ledger) -> str:
    """A readable view of the ledger, in its order. Generated: never edited, never the truth."""
    out = ["# Ledger", "", "Generated from the entries; do not edit. Newest last.", ""]
    if led.forks or led.flags or led.held or led.refused:
        out += ["## Needs a person", ""]
        out += [f"- fork: {', '.join(i[:12] for i in f)}" for f in led.unruled_forks]
        out += [f"- fork ruled: kept `{led.rulings[n][:12]}` of {', '.join(i[:12] for i in f)}"
                for n, f in enumerate(led.forks) if n in led.rulings]
        out += [f"- {', '.join(fs)}: {i[:12]}" for i, fs in sorted(led.flags.items())]
        out += [f"- held {i[:12]}: waiting for {', '.join(p[:12] for p in ps) or 'a held parent'}"
                for i, ps in sorted(led.held.items())]
        out += [f"- refused {i[:16]}: {c}" + (f" ({d})" if d else "") for i, (c, d) in sorted(led.refused.items())]
        out.append("")
    for i in led.order:
        e = led.valid[i]
        d = e.data
        if e.kind == "work":
            out += [f"### {e.at[:10]} {d['title']}", "", f"- **Id:** `{i[:12]}` by {e.principal}, {e.at}"]
            for label, f in (("Operator", "operator"), ("Session", "session"), ("Asked", "asked")):
                if f in d:
                    out.append(f"- **{label}:** {d[f]}")
            for label, f in (("Came out", "came_out"), ("Learned", "learned"), ("Decisions", "decisions"),
                             ("Decisions needed", "decisions_needed"), ("For the repository", "for_repository")):
                if d.get(f):
                    out.append(f"- **{label}:**")
                    out += [f"  - {x}" for x in d[f]]
            if d.get("friction"):
                out.append("- **Friction:**")
                out += [f"  - [{x['tag']}] {x['text']}" for x in d["friction"]]
            if "cost" in d:
                c = d["cost"]
                out.append("- **Cost:** " + "; ".join(
                    ([_usd(c["usd_micro"])] if "usd_micro" in c else []) + ([c["note"]] if "note" in c else [])))
            if "corrects" in d:
                out.append(f"- **Corrects:** `{d['corrects'][:12]}`")
            measures = [f"{label} {d[f]}" for label, f in (("agent", "agent"), ("item", "item"), ("PR #", "pr"),
                        ("started", "started_at"), ("merged", "merged_at"), ("conflicts", "conflicts"),
                        ("checks red", "checks_red")) if f in d]
            if measures:
                out.append("- **Measures:** " + "; ".join(m.replace("PR # ", "PR #") for m in measures))
        elif e.kind == "run":
            c = d["cost"]
            out.append(f"- run `{i[:12]}` {e.at}: {d['member']} on {d['model']}, {d['outcome']}"
                       + (f", {_usd(c['usd_micro'])}" if "usd_micro" in c else ""))
        elif e.kind == "roster":
            adds = ", ".join(f"{a['as']} ({a['role']})" for a in d.get("add", []))
            removes = len(d.get("remove", []))
            out.append(f"- roster `{i[:12]}` {e.at} by {e.principal}: "
                       + "; ".join(([f"added {adds}"] if adds else []) + ([f"removed {removes} key(s)"] if removes else [])))
        else:
            out.append(f"- {e.kind} `{i[:12]}` {e.at} by {e.principal}")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def write_markdown(led: core.Ledger, path: Path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(render_markdown(led))
    os.replace(tmp, path)


# ---------------------------------------------------------------- the change feed

def since(led: core.Ledger, cursor: list[str]) -> list[str]:
    """The valid entries new since a cursor, in the register's order.

    A cursor is the heads a reader had seen. New means: not one of them, nor behind one of them. An
    entry that arrives later from another branch is new however early it sorts, so nothing is
    skipped. Ids in the cursor this reader does not have yet are ignored (nothing is behind them).
    """
    seen: set[str] = set()
    todo = [c for c in cursor if c in led.valid]
    while todo:
        i = todo.pop()
        if i not in seen:
            seen.add(i)
            todo.extend(led.valid[i].parents)
    return [i for i in led.order if i not in seen]


def feed_line(led: core.Ledger, i: str, register: str) -> dict:
    e = led.valid[i]
    line = {"id": i, "register": register, "kind": e.kind, "from": e.principal, "at": e.at, "seq": e.seq,
            "data": e.data}
    if led.flags.get(i):
        line["flags"] = led.flags[i]
    return line
