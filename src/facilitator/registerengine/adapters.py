"""Sources, sinks and stores around the core (SPEC.md, "Sources, sinks and stores").

A store keeps entry bytes by id and is never trusted: everything read from one is checked by the
core. A view is rebuilt from a ledger and is never read as the truth. `sync` is the one operation:
adding, merging, mirroring and indexing are all built on it.
"""
from __future__ import annotations

import datetime as dt
import errno
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


def raws(store: Store, only: Iterable[str] | None = None) -> Iterator[bytes]:
    """The store's entries, each read once. With `only`, just those ids: the others are never read
    (on a network or cloud folder each read is the cost)."""
    for i in (store.ids() if only is None else sorted(only)):
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


# What os.link raises where a filesystem has no hard links (rclone's FUSE mount, OneDrive, SMB).
NO_LINK = {errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EXDEV, errno.ENOSYS, errno.EMLINK}


def _whole(path: Path, i: str) -> bool:
    """True when the file at `path` is a whole entry for id `i`: its first line hashes to `i` and
    its signature's armour is closed. A write cut short fails one or the other."""
    try:
        raw = path.read_bytes()
    except OSError:
        return False
    body, _, armour = raw.partition(b"\n")
    return core.entry_id(body) == i and armour.endswith(core.ARMOR_END.encode() + b"\n")


class DirStore:
    """A folder of `<id>.entry` files, where a put never replaces an entry already there.

    Put-if-absent is a hard link, which never replaces, so several writers, processes or machines
    sharing the folder cannot overwrite each other. Where the filesystem has no hard links (a FUSE,
    OneDrive or SMB folder), it falls back to creating the file with O_EXCL, which refuses an
    existing name. An id is the hash of the entry's body, so two writers of one id write one body;
    a file that is not a whole entry for its name (a write cut short) is not an entry, and the
    next put of that id replaces it."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._no_link = False       # found once that this folder has no hard links: go straight to O_EXCL

    def put(self, i: str, raw: bytes) -> bool:
        if not core.ID_RE.fullmatch(i):
            raise ValueError(f"not an id: {i!r}")
        self.path.mkdir(parents=True, exist_ok=True)
        final = self.path / f"{i}.entry"
        exists = final.exists()
        if exists and _whole(final, i):
            return False
        if self._no_link and not exists:
            return self._put_exclusive(final, raw)      # one write, not a temporary file and then the entry
        fd, tmp = tempfile.mkstemp(dir=self.path, prefix=".put-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o444)
            if final.exists():
                # Not a whole entry (checked above): a cut-short write. Replace it with this one.
                os.replace(tmp, final)
                return True
            try:
                os.link(tmp, final)
            except FileExistsError:
                return False
            except OSError as e:
                if e.errno not in NO_LINK:
                    raise
                self._no_link = True
                return self._put_exclusive(final, raw)
            return True
        finally:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass

    @staticmethod
    def _put_exclusive(final: Path, raw: bytes) -> bool:
        """Put-if-absent without a hard link: O_CREAT|O_EXCL refuses a name already there, and a
        failed write removes its own partial file. O_EXCL is only as strong as the filesystem: on a
        network or cloud folder it is checked against what this machine sees, so two machines may
        both write one id at once; they write the same body, and the copy that lands is a valid
        entry either way."""
        try:
            fd = os.open(final, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o444)
        except FileExistsError:
            return False
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
        except BaseException:
            try:
                os.unlink(final)
            except OSError:
                pass
            raise
        return True

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

GUARD_TIMEOUT = core.sp.guard.TIMEOUT           # seconds, unless the register's guard_timeout says otherwise
GUARD_TIMEOUT_MAX = core.sp.guard.TIMEOUT_MAX   # every writer of the register waits for it, holding the writer's lock
GUARD_PATH = core.sp.guard.PATH
GUARD_REGISTER_VAR = "REGISTER_ENGINE_GUARD_REGISTER"   # the register a guard is asked about


def guard_env(register: str) -> dict[str, str]:
    """All a guard is given: a fixed PATH, the locale, the register's name (and sign-packet's domain and
    direction). Nothing else of the writer's environment (no tokens, no SSH agent, no BASH_ENV)."""
    return core.sp.guard.env(register, "egress", ((GUARD_REGISTER_VAR, register),))


@dataclass(frozen=True)
class Guard:
    """An adopter's own check on what a writer puts in a register: a command run on every entry
    before it is signed (add, import, roster, every MCP write) and before an entry signed elsewhere
    is put into a store (sync, mirror). It is sign-packet's guard (its SPEC.md, "Guards"), run as
    egress, with the register's name also in $REGISTER_ENGINE_GUARD_REGISTER: it reads the exact
    body bytes on standard input and exits 0 to let the entry through. Anything else refuses it
    (`guarded`), and nothing is written. The refusal names the exit and the first line of the
    guard's standard error; it never repeats the entry."""
    argv: tuple[str, ...]
    register: str
    timeout: float = GUARD_TIMEOUT

    @property
    def runner(self):
        return core.sp.guard.Guard(tuple(self.argv), self.timeout, ((GUARD_REGISTER_VAR, self.register),))

    def check(self, body: bytes) -> None:
        self.runner.check(body, self.register, "egress", noun="entry")


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
    """An entry no guard is asked about, so a broken guard never stops an operator taking a writer's
    access away (the operator's ruling D79): a format-2 roster entry that only removes keys, at most
    a few, each a real ed25519 public key and nothing else; a format-3 `ungrant` (a principal and
    nothing else). Anything with free text, a v3 `revoke` among them (its carried reason), is guarded."""
    if kind == "ungrant":
        return isinstance(data, dict) and set(data) == {"principal"} and isinstance(data["principal"], str) \
            and core.PRINCIPAL_RE.fullmatch(data["principal"]) is not None
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
         guard: Guard | None = None, read_sink: bool = True, fmt: int = 2) -> SyncReport:
    """Check what the sources give plus what the sink holds, as entries of `register`; put the valid
    entries the sink lacks, parents first. Invalid, held and other registers' entries never reach it,
    nor does a ruled-out entry a counted prune names: a pruned line is never copied on. With a guard,
    each entry the sink lacks is put only if the guard lets its body through; one it refuses, and
    everything after it in this sync that descends from it, is reported refused (`guarded`).

    read_sink=False reads only the sink's names, not its entries: use it when the sources already hold
    every entry the new ones need (a mirror filled from its live store). An id is the hash of its
    body and a put never replaces an entry, so a name the sink has is the same entry."""
    core.need_kinds(kinds)
    have = set(sink.ids())
    everything = list(raws(sink)) if read_sink else []   # read_sink=False: the sources hold the context
    for source in sources:
        everything.extend(source)
    led = core.read(everything, anchors, checked, register, kinds, fmt)
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
        register: str = core.LEGACY_REGISTER, kinds: dict | None = None, guard: Guard | None = None,
        fmt: int = 2) -> str:
    """Sign a new entry as the next in this key's chain, naming the heads it saw, and put it in the
    store. Returns its id. Refuses when the key's own chain has forked: a person rules first. With a
    guard, the body is shown to it before signing, and only the bytes it let through are signed."""
    core.need_kinds(kinds)
    key = core.public_key(private_key)
    with store.writer_lock(key):
        led = core.read(raws(store), anchors, checked, register, kinds, fmt)
        mine = [e for e in led.valid.values() if e.key == key]
        if any(set(f) & {e.id for e in mine} for f in led.unruled_forks):
            raise core.Refused("bad-chain", "this key's chain has forked; an operator rules first (the forks command)")
        mine = [e for e in mine if e.id not in led.ruled_out]   # a ruled fork goes on from the side kept
        last = max(mine, key=lambda e: e.seq, default=None)
        prev = last.id if last else None
        saw = [h for h in led.heads if h != prev][-core.MAX_SAW:]
        value = {"v": 3 if fmt == 3 else core.VERSION, "reg": register, "key": key, "as": principal,
                 "seq": (last.seq + 1) if last else 1, "prev": prev, "saw": sorted(saw), "at": at or now(),
                 "kind": kind, "data": data}
        body = None
        if guard is not None and not unguarded(kind, data):
            body = core.canonical(value)
            core.check_fields(value, kinds, fmt)    # a malformed entry is refused as such, before the guard sees it
            guard.check(body)
        raw = core.sign(value, private_key, kinds, fmt)
        if body is not None and raw.split(b"\n", 1)[0] != body:
            raise core.Refused("guarded", "the signed body is not the one the guard saw")
        i = core.entry_id(raw.split(b"\n", 1)[0])
        staged = MemoryStore()
        report = sync([raws(store), [raw]], staged, anchors, checked, register, kinds, fmt=fmt)
        if i not in report.ledger.valid:
            code, detail = report.refused.get(i, ("bad-chain", f"held: {report.held.get(i)}"))
            raise core.Refused(code, detail)
        if kind == "prune":       # SPEC.md, "Pruning": only what is ruled out, and never what a reader needs
            led2 = report.ledger
            its = set(core.ruled_out_by(led2, data["ruling"])) if data["ruling"] in led2.valid else set()
            for p in data["pruned"]:
                if p in led2.valid and (p not in its or led2.valid[p].kind in core.UNIVERSAL + ("register", "grant", "bind", "revoke", "ungrant")):
                    raise core.Refused("bad-field", f"prune: {p[:12]} is not ruled out, or is a {led2.valid[p].kind}")
                if p not in led2.valid:
                    raise core.Refused("bad-field", f"prune: {p[:12]} is not in this store; prune before deleting")
        store.put(i, raw)
        if hasattr(checked, "save"):
            checked.save()
        return i


def load_anchors(path: Path) -> dict:
    """Anchors from the reader's own configuration, one per line:
    `<principal> ssh-ed25519 <base64> [until=<entry id>] [until=<register>:<entry id>]...`. An anchor
    whose private key is lost stays, so the history it signed stays valid; one whose key is stolen is
    retired with `until`, never deleted: `until=<entry id>` in every register, `until=<register>:<id>`
    in that register (repeatable), so a key retired by one register's entry is not cut off from
    every other register at once (SPEC.md, "Anchors")."""
    out: dict = {}
    form = "'<principal> ssh-ed25519 <base64> [until=<entry id>] [until=<register>:<entry id>]...'"
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3 or not core.PRINCIPAL_RE.fullmatch(parts[0]) \
                or not core.KEY_RE.fullmatch(f"{parts[1]} {parts[2]}"):
            raise ValueError(f"{path}:{n}: expected {form}")
        until, checkpoints = None, []
        for extra in parts[3:]:
            if not extra.startswith("until="):
                raise ValueError(f"{path}:{n}: {extra!r}: expected {form}")
            v = extra[len("until="):]
            reg, sep, i = v.rpartition(":")
            if sep:
                if not core.REGISTER_RE.fullmatch(reg) or not core.ID_RE.fullmatch(i) or reg in dict(checkpoints):
                    raise ValueError(f"{path}:{n}: until=<register>:<entry id>, once per register")
                checkpoints.append((reg, i))
            else:
                if until is not None or not core.ID_RE.fullmatch(v):
                    raise ValueError(f"{path}:{n}: until= takes an entry id (64 hex characters), once")
                until = v
        out[f"{parts[1]} {parts[2]}"] = (core.Anchor(parts[0], until, tuple(checkpoints))
                                         if until or checkpoints else parts[0])
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
        if views:
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
        if i not in seen and i in led.valid:   # a pruned parent is not in the register: nothing behind it to walk
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
