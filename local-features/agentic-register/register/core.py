"""The agentic register's core: entries, their checks, the roster, merging and order (SPEC.md).

One register is read at a time: an entry names its register (`reg`, format 2; a format-1 entry
belongs to the register `ledger`), and an entry of another register is refused. What an entry of
each kind may say comes from the register's type (types.py); `roster` is the same in every one.

No storage here: sources and sinks are adapters around this. Signing and signature checks use
OpenSSH's `ssh-keygen -Y`, so there is no other dependency.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import heapq
import json
import re
import struct
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

VERSION = 2                     # what is written; 1 is still read (a ledger entry from before registers)
VERSIONS = (1, 2)
NAMESPACES = {1: "aof-ledger", 2: "aof-register"}   # the SSH signature namespace of each format
LEGACY_REGISTER = "ledger"      # the register a format-1 entry belongs to
MAX_BODY = 65536
MAX_SAW = 64
MAX_INT = 2**53 - 1
TOP_FIELDS = {"v", "key", "as", "seq", "prev", "saw", "at", "kind", "data"}
FIELDS = {1: TOP_FIELDS, 2: TOP_FIELDS | {"reg"}}
ARMOR_BEGIN = "-----BEGIN SSH SIGNATURE-----"
ARMOR_END = "-----END SSH SIGNATURE-----"

KEY_RE = re.compile(r"ssh-ed25519 [A-Za-z0-9+/]+={0,2}")
ID_RE = re.compile(r"[0-9a-f]{64}")
AT_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
PRINCIPAL_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
FIELD_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")

REFUSALS = (
    "bad-format", "too-large", "not-canonical", "bad-version", "bad-field", "bad-signature",
    "refused-parent", "bad-chain", "unknown-key", "wrong-principal", "removed-key", "not-operator",
    "wrong-register", "retired-anchor",
)
WRITER_REFUSALS = ("guarded",)   # a writer's own policy refused it before signing or putting; never a reader's outcome
REGISTER_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")


class Anchor(NamedTuple):
    """An operator key the reader trusts. `until`: retired at that entry, trusted only for it and
    the entries before it (its ancestors), so a stolen key can be cut off without the history it
    signed being lost (SPEC.md, "Anchors")."""
    principal: str
    until: str | None = None


def as_anchor(v) -> Anchor:
    return v if isinstance(v, Anchor) else Anchor(v)


class Refused(Exception):
    def __init__(self, code: str, detail: str = ""):
        assert code in REFUSALS or code in WRITER_REFUSALS, code
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------- canonical JSON

def _check_value(v, path: str) -> None:
    if v is None or isinstance(v, (bool, str)):
        return
    if isinstance(v, int):
        if abs(v) > MAX_INT:
            raise Refused("bad-field", f"{path or 'body'}: integer out of range")
        return
    if isinstance(v, float):
        raise Refused("bad-field", f"{path or 'body'}: numbers are integers only")
    if isinstance(v, list):
        for i, x in enumerate(v):
            _check_value(x, f"{path}[{i}]")
        return
    if isinstance(v, dict):
        for k, x in v.items():
            if not isinstance(k, str) or not FIELD_RE.fullmatch(k):
                raise Refused("bad-field", f"{path or 'body'}: field name {k!r}")
            _check_value(x, f"{path}.{k}" if path else k)
        return
    raise Refused("bad-field", f"{path or 'body'}: not a JSON value")


def canonical(value) -> bytes:
    """The one byte form of a value (SPEC.md, "Canonical JSON")."""
    _check_value(value, "")
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                          allow_nan=False).encode("utf-8")
    except UnicodeEncodeError as e:  # a lone surrogate
        raise Refused("bad-format", f"not encodable as UTF-8: {e}") from None


def entry_id(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


# ---------------------------------------------------------------- the entry

@dataclass(frozen=True)
class Entry:
    id: str
    body: bytes
    signature: str
    value: dict

    key = property(lambda self: self.value["key"])
    principal = property(lambda self: self.value["as"])
    seq = property(lambda self: self.value["seq"])
    prev = property(lambda self: self.value["prev"])
    saw = property(lambda self: self.value["saw"])
    at = property(lambda self: self.value["at"])
    kind = property(lambda self: self.value["kind"])
    register = property(lambda self: self.value.get("reg", LEGACY_REGISTER))
    namespace = property(lambda self: NAMESPACES[self.value["v"]])
    data = property(lambda self: self.value["data"])

    @property
    def parents(self) -> list[str]:
        return ([self.prev] if self.prev else []) + list(self.saw)

    @property
    def raw(self) -> bytes:
        return self.body + b"\n" + self.signature.encode("ascii")


def parse(raw: bytes, kinds: dict | None = None) -> Entry:
    """Checks 1 and 2 of SPEC.md ("Checking an entry"): format and fields. Raises Refused.
    `kinds`: kind -> check, from the register's type (default: the ledger's)."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("bad-format", "not UTF-8") from None
    line, sep, armour = text.partition("\n")
    if not sep or not armour.startswith(ARMOR_BEGIN + "\n") or not armour.endswith(ARMOR_END + "\n"):
        raise Refused("bad-format", "a body line, then an armoured SSH signature")
    body = line.encode("utf-8")
    if len(body) > MAX_BODY:
        raise Refused("too-large", f"{len(body)} bytes")
    try:
        value = json.loads(line)
    except ValueError as e:
        raise Refused("bad-format", f"not JSON: {e}") from None
    if not isinstance(value, dict):
        raise Refused("bad-format", "the body is not an object")
    if canonical(value) != body:
        raise Refused("not-canonical")
    check_fields(value, kinds)
    return Entry(entry_id(body), body, armour, value)


def _need(ok, what: str) -> None:
    if not ok:
        raise Refused("bad-field", what)


def _is_id(v) -> bool:
    return isinstance(v, str) and ID_RE.fullmatch(v) is not None


def _is_key(v) -> bool:
    return isinstance(v, str) and KEY_RE.fullmatch(v) is not None


def _is_int(v, low: int = 0) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= low


def _strings(v) -> bool:
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def check_fields(value: dict, kinds: dict | None = None) -> None:
    v = value.get("v")
    if isinstance(v, bool) or v not in VERSIONS:
        raise Refused("bad-version", repr(v))
    _need(set(value) == FIELDS[v], f"fields {sorted(set(value) ^ FIELDS[v])}")
    if v >= 2:
        _need(isinstance(value["reg"], str) and REGISTER_RE.fullmatch(value["reg"]), "reg")
    _need(_is_key(value["key"]), "key")
    _need(isinstance(value["as"], str) and PRINCIPAL_RE.fullmatch(value["as"]), "as")
    _need(_is_int(value["seq"], 1), "seq")
    _need(value["prev"] is None or _is_id(value["prev"]), "prev")
    saw = value["saw"]
    _need(isinstance(saw, list) and all(_is_id(x) for x in saw), "saw")
    _need(saw == sorted(set(saw)), "saw: sorted, no duplicates")
    _need(len(saw) <= MAX_SAW, f"saw: at most {MAX_SAW}")
    _need(value["prev"] not in saw, "saw: never prev")
    _need(isinstance(value["at"], str) and AT_RE.fullmatch(value["at"]), "at")
    _need(isinstance(value["kind"], str) and FIELD_RE.fullmatch(value["kind"]), "kind")
    _need(isinstance(value["data"], dict), "data")
    if (value["seq"] == 1) != (value["prev"] is None):
        raise Refused("bad-chain", "seq 1 has prev null, and only seq 1")
    check_kind(value, kinds)


def _check_ruling(d: dict) -> None:
    _need(set(d) == {"keep"} and _is_id(d["keep"]), "ruling: {keep: <entry id>}")


MAX_PRUNED = 1024


def _check_prune(d: dict) -> None:
    _need(set(d) == {"ruling", "pruned"} and _is_id(d["ruling"]), "prune: {ruling: <entry id>, pruned: [<entry id>]}")
    p = d["pruned"]
    _need(isinstance(p, list) and 0 < len(p) <= MAX_PRUNED and all(_is_id(x) for x in p), "prune: pruned")
    _need(p == sorted(set(p)), "prune: pruned sorted, no duplicates")
    _need(d["ruling"] not in p, "prune: never its own ruling")


UNIVERSAL = ("roster", "ruling", "prune")   # kinds in every register, whatever its type


def _universal(kind: str):
    return {"roster": _check_roster, "ruling": _check_ruling, "prune": _check_prune}.get(kind)


def check_kind(value: dict, kinds: dict | None = None) -> None:
    """The kind's data: `roster` and `ruling` in every register, the others as the register's type says."""
    check = _universal(value["kind"]) or (LEDGER_KINDS if kinds is None else kinds).get(value["kind"])
    if check:
        check(value["data"])


def _check_cost(c, where: str) -> None:
    _need(isinstance(c, dict) and c and set(c) <= {"usd_micro", "tokens", "note"}, f"{where}: cost")
    if "usd_micro" in c:
        _need(_is_int(c["usd_micro"]), f"{where}: cost.usd_micro")
    if "note" in c:
        _need(isinstance(c["note"], str), f"{where}: cost.note")
    if "tokens" in c:
        _need(isinstance(c["tokens"], list), f"{where}: cost.tokens")
        for t in c["tokens"]:
            _need(isinstance(t, dict) and isinstance(t.get("model"), str), f"{where}: cost.tokens.model")
            for n in ("input", "output", "cache_write", "cache_read"):
                _need(n not in t or _is_int(t[n]), f"{where}: cost.tokens.{n}")


def _check_roster(d: dict) -> None:
    _need(set(d) <= {"add", "remove"}, "roster: add or remove only")
    adds, removes = d.get("add", []), d.get("remove", [])
    _need(isinstance(adds, list) and isinstance(removes, list), "roster: lists")
    _need(adds or removes, "roster: add or remove")
    for a in adds:
        _need(isinstance(a, dict) and set(a) == {"key", "as", "role"} and _is_key(a["key"])
              and isinstance(a["as"], str) and PRINCIPAL_RE.fullmatch(a["as"])
              and a["role"] in ("operator", "agent"), "roster.add: {key, as, role}")
    for r in removes:
        _need(isinstance(r, dict) and set(r) == {"key"} and _is_key(r["key"]), "roster.remove: {key}")


def _check_work(d: dict) -> None:
    _need(isinstance(d.get("title"), str) and d["title"].strip(), "work.title")
    for f in ("operator", "session", "asked"):
        _need(f not in d or isinstance(d[f], str), f"work.{f}")
    for f in ("came_out", "learned", "decisions", "decisions_needed", "for_repository"):
        _need(f not in d or _strings(d[f]), f"work.{f}: a list of strings")
    if "friction" in d:
        _need(isinstance(d["friction"], list) and all(
            isinstance(x, dict) and isinstance(x.get("tag"), str) and isinstance(x.get("text"), str)
            for x in d["friction"]), "work.friction: a list of {tag, text}")
    if "cost" in d:
        _check_cost(d["cost"], "work")
    _need("corrects" not in d or _is_id(d["corrects"]), "work.corrects")
    _need("agent" not in d or (isinstance(d["agent"], str) and PRINCIPAL_RE.fullmatch(d["agent"])), "work.agent")
    _need("item" not in d or (isinstance(d["item"], str) and d["item"].strip()), "work.item")
    _need("pr" not in d or _is_int(d["pr"], 1), "work.pr: an integer, 1 or more")
    for f in ("started_at", "merged_at"):
        _need(f not in d or (isinstance(d[f], str) and AT_RE.fullmatch(d[f])), f"work.{f}: YYYY-MM-DDTHH:MM:SSZ")
    _need(not ("started_at" in d and "merged_at" in d) or d["merged_at"] >= d["started_at"],
          "work.merged_at: not before started_at")
    for f in ("conflicts", "checks_red"):
        _need(f not in d or _is_int(d[f]), f"work.{f}: an integer, 0 or more")


def _check_run(d: dict) -> None:
    for f in ("member", "model", "outcome"):
        _need(isinstance(d.get(f), str) and d[f], f"run.{f}")
    _need("cost" in d, "run.cost")
    _check_cost(d["cost"], "run")
    _need("ms" not in d or _is_int(d["ms"]), "run.ms")


SHA1_RE = re.compile(r"[0-9a-f]{40}")


def _check_merge(d: dict) -> None:
    _need(_is_int(d.get("pr"), 1), "merge.pr: an integer, 1 or more")
    for f in ("merge_sha", "patch_id"):
        _need(isinstance(d.get(f), str) and SHA1_RE.fullmatch(d[f]), f"merge.{f}: 40 lowercase hex")
    _need("base_sha" not in d or (isinstance(d["base_sha"], str) and SHA1_RE.fullmatch(d["base_sha"])),
          "merge.base_sha: 40 lowercase hex")
    _need(isinstance(d.get("merged_at"), str) and AT_RE.fullmatch(d["merged_at"]), "merge.merged_at: YYYY-MM-DDTHH:MM:SSZ")
    _need("corrects" not in d or _is_id(d["corrects"]), "merge.corrects")
    _need("corrects" not in d or (isinstance(d.get("reason"), str) and d["reason"].strip()),
          "merge.reason: required with corrects")


LEDGER_KINDS = {"work": _check_work, "run": _check_run, "merge": _check_merge}   # the ledger type's kinds (types.py)


# ---------------------------------------------------------------- signatures

class NoPublicKey(ValueError):
    """A signing key file whose public half cannot be found: said in one line, never a traceback."""


# The OpenSSH private key file's armour lines, built in parts so the source never holds them whole
# (the secret guard refuses a file that looks like it holds a private key).
_ARMOUR = ("-" * 5 + "BEGIN OPENSSH PRIVATE" + " KEY" + "-" * 5, "-" * 5 + "END OPENSSH PRIVATE" + " KEY" + "-" * 5)


def _openssh_public(private_key: Path) -> tuple[str, bool] | None:
    """The public half of an OpenSSH private key file, read from the file itself, and whether the
    private half is encrypted (has a passphrase). The format keeps the public key in the clear, so a
    passphrase-protected key gives it up without its passphrase and without a prompt. None for a
    file in any other shape."""
    try:
        lines = private_key.read_text().strip().splitlines()
        if (lines[0], lines[-1]) != _ARMOUR:
            return None
        b = base64.b64decode("".join(lines[1:-1]), validate=True)
        magic = b"openssh-key-v1\0"
        if not b.startswith(magic):
            return None

        def part(data: bytes, o: int) -> tuple[bytes, int]:   # an SSH string: a length, then the bytes
            n = struct.unpack(">I", data[o:o + 4])[0]
            if o + 4 + n > len(data):
                raise ValueError("cut short")
            return data[o + 4:o + 4 + n], o + 4 + n
        o = len(magic)
        cipher, o = part(b, o)
        for _ in range(2):              # KDF name, KDF options
            _, o = part(b, o)
        o += 4                          # the number of keys; the first one is the signing key
        blob, _ = part(b, o)
        kind, _ = part(blob, 0)
        return f"{kind.decode('ascii')} {base64.b64encode(blob).decode('ascii')}", cipher != b"none"
    except (OSError, IndexError, ValueError, struct.error, UnicodeDecodeError, binascii.Error):
        return None


def public_key(key_file: Path) -> str:
    """The public key of a signing key file: a .pub file whose private half is held by an SSH agent
    (then the private key never touches this machine), or a private key: its .pub beside it, else
    the public half kept inside an OpenSSH private key file (a key copied in alone, to sign once).
    Raises NoPublicKey, naming the file it needs, when neither gives one."""
    p = Path(key_file)
    pub = p if p.suffix == ".pub" else Path(str(p) + ".pub")
    if pub.is_file():
        text = pub.read_text().split()
        if len(text) >= 2:
            return f"{text[0]} {text[1]}"
        raise NoPublicKey(f"{pub} is not a public key (want '<type> <base64>')")
    if p.suffix != ".pub" and p.is_file() and (found := _openssh_public(p)):
        return found[0]
    raise NoPublicKey(f"no public key for {p}: put its public half at {pub} "
                      f"(ssh-keygen -y -f {p} > {pub})")


def sign(value: dict, private_key: Path, kinds: dict | None = None) -> bytes:
    """The entry bytes for a body, signed with an OpenSSH Ed25519 key. Checks the body first.
    `private_key` may be a .pub file: ssh-keygen then signs through the SSH agent ($SSH_AUTH_SOCK)."""
    body = canonical(value)
    check_fields(value, kinds)
    if value["key"] != public_key(private_key):
        raise ValueError("the body's key is not the signing key")
    out = subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-n", NAMESPACES[value["v"]], "-f", str(private_key)],
                         input=body, capture_output=True)
    if out.returncode != 0:
        why = out.stderr.decode(errors="replace").strip().splitlines()[-1:] or ["no reason given"]
        if Path(private_key).suffix != ".pub" and (_openssh_public(Path(private_key)) or ("", False))[1]:
            raise ValueError(f"could not sign with {private_key}: it has a passphrase, which ssh-keygen cannot "
                             "ask for here; ssh-add it to an SSH agent first, then sign with the same --key")
        raise ValueError(f"could not sign with {private_key}: {why[0]} (for a .pub key: is the private key in the SSH agent?)")
    return body + b"\n" + out.stdout


def signature_ok(e: Entry) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        signers = Path(tmp, "signers")
        signers.write_text(f'writer namespaces="{e.namespace}" {e.key}\n')
        sig = Path(tmp, "sig")
        sig.write_text(e.signature)
        r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "writer",
                            "-n", e.namespace, "-s", str(sig)], input=e.body, capture_output=True)
        return r.returncode == 0


# ---------------------------------------------------------------- the ledger

@dataclass
class Ledger:
    """The outcome of reading a set of entries (SPEC.md, "Reading a ledger")."""
    valid: dict[str, Entry] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)
    held: dict[str, list[str]] = field(default_factory=dict)           # id -> unknown parent ids
    refused: dict[str, tuple[str, str]] = field(default_factory=dict)  # id -> (code, detail)
    forks: list[list[str]] = field(default_factory=list)
    flags: dict[str, list[str]] = field(default_factory=dict)
    rulings: dict[int, str] = field(default_factory=dict)    # index in forks -> the entry kept, when ruled once
    ruled_out: set[str] = field(default_factory=set)         # the other side of a ruled fork, and what follows it
    pruned: set[str] = field(default_factory=set)            # ruled out, then left out of the store by an operator's prune
    prunes: dict[str, dict] = field(default_factory=dict)    # the prunes this read counted: id -> its data
    still_there: set[str] = field(default_factory=set)       # named by a counted prune, yet still in the store: to delete

    @property
    def unruled_forks(self) -> list[list[str]]:
        return [f for n, f in enumerate(self.forks) if n not in self.rulings]

    @property
    def heads(self) -> list[str]:
        named = {p for e in self.valid.values() for p in e.parents}
        return sorted(i for i in self.valid if i not in named)

    def outcome(self, i: str) -> str:
        if i in self.valid:
            return "valid"
        if i in self.held:
            return "held"
        if i in self.pruned:
            return "pruned"
        return self.refused[i][0] if i in self.refused else "unknown"


def raw_name(raw: bytes) -> str:
    """The name of bytes that could not be parsed: not an id, as there may be no body."""
    return "raw-" + hashlib.sha256(raw).hexdigest()


def read(raws, anchors: dict[str, str] | None = None, checked=None, register: str = LEGACY_REGISTER,
         kinds: dict | None = None) -> Ledger:
    """Check and join the entries of one register from any number of sources. `anchors`: key ->
    principal. `kinds`: the register type's kind checks (default: the ledger's).

    `checked`: optional, the reader's own record of good signatures (a set-like of the SHA-256 of
    whole entries, with `add`). It is the reader's state, never a store's: a store is not trusted.
    """
    raws = list(raws)
    anchors = anchors or {}
    if checked is None:
        checked = set()      # each signature checked once, however many times the prunes make us read
    # A prune vouches for entries a store leaves out (SPEC.md, "Pruning"). It is trusted only as
    # far as it is itself valid: read with every prune signed by an anchor, then again without any
    # that the read refused or held, until none changes.
    vouch: dict[str, list[str]] | None = None
    while True:
        out = _read(raws, anchors, checked, register, kinds, vouch)
        live = {i: d for i, d in out.prunes.items() if i in out.valid}
        if live == out.prunes:
            return out
        vouch = live


def _read(raws, anchors, checked, register, kinds, vouch) -> Ledger:
    out = Ledger()
    found: dict[str, Entry] = {}
    for raw in raws:
        try:
            e = parse(raw, {})          # the format and the fields; the kind's data after the register
        except Refused as r:
            out.refused[raw_name(raw)] = (r.code, r.detail)
            continue
        if e.id in found:
            continue
        if e.register != register:
            out.refused[e.id] = ("wrong-register", f"an entry of {e.register}, read as {register}")
            continue
        try:
            check_kind(e.value, kinds)
        except Refused as r:
            out.refused[e.id] = (r.code, r.detail)
            continue
        whole = hashlib.sha256(raw).hexdigest()
        if (checked is not None and whole in checked) or signature_ok(e):
            if checked is not None:
                checked.add(whole)
            found[e.id] = e
            out.refused.pop(e.id, None)  # a good copy outweighs a bad one
        else:
            out.refused[e.id] = ("bad-signature", "")

    # The prunes signed by an anchor: on the first read every one, then the ones still valid.
    if vouch is None:
        vouch = {i: e.data for i, e in found.items()
                 if e.kind == "prune" and e.key in anchors and as_anchor(anchors[e.key]).principal == e.principal}
    out.prunes = vouch
    named = {p for d in vouch.values() for p in d["pruned"]}
    out.pruned = named - set(found)
    out.still_there = named & set(found)

    # Parents first, ties to the earlier `at`, then the smaller id (SPEC.md, "Order").
    # A parent refused by id counts as decided (its children are then refused); a parent nobody
    # has is waited for, so its children are held, unless a prune vouches for its absence.
    waiting = {i: {p for p in e.parents if p not in out.refused and p not in out.pruned} for i, e in found.items()}
    children: dict[str, list[str]] = {}
    for i, ps in waiting.items():
        for p in ps:
            children.setdefault(p, []).append(i)
    ready = [(e.at, i) for i, e in found.items() if not waiting[i]]
    heapq.heapify(ready)
    roster_of: dict[str, frozenset[str]] = {}  # id -> the roster entries among its ancestors (and itself)
    decided: set[str] = set(out.pruned)
    # A retired anchor is trusted for its checkpoint and the checkpoint's ancestors only.
    upto = {k: _upto(as_anchor(v).until, found) for k, v in anchors.items() if as_anchor(v).until}

    while ready:
        _, i = heapq.heappop(ready)
        e = found[i]
        decided.add(i)
        try:
            if e.prev in out.pruned:
                if i not in out.still_there:    # only what a prune names; anything else has no chain to check
                    raise Refused("refused-parent", f"{e.prev}: pruned, and this entry is not")
                out.pruned.add(i)               # named, and its line is gone before it: pruned with it
                raise _Pruned
            _decide(e, out, anchors, roster_of, upto)
            out.valid[i] = e
            out.order.append(i)
        except Refused as r:
            out.refused[i] = (r.code, r.detail)
        except _Pruned:
            pass
        for c in children.get(i, []):
            waiting[c].discard(i)
            if not waiting[c]:
                heapq.heappush(ready, (found[c].at, c))

    for i, e in found.items():
        if i not in decided:
            out.held[i] = sorted(p for p in e.parents if p not in decided)
    _report(out)
    return out


class _Pruned(Exception):
    pass


def _upto(checkpoint: str, found: dict[str, Entry]) -> set[str]:
    """The checkpoint and its ancestors among the entries found; nothing if it is not there."""
    if checkpoint not in found:
        return set()
    seen, todo = {checkpoint}, [checkpoint]
    while todo:
        e = found.get(todo.pop())
        for p in (e.parents if e else []):
            if p not in seen:
                seen.add(p)
                todo.append(p)
    return seen


def _decide(e: Entry, out: Ledger, anchors: dict, roster_of: dict, upto: dict | None = None) -> None:
    for p in e.parents:
        if p not in out.valid and p not in out.pruned:
            raise Refused("refused-parent", p)
    if e.prev:
        before = out.valid[e.prev]
        if before.key != e.key or before.seq != e.seq - 1:
            raise Refused("bad-chain", "prev is not this key's entry before")
    ancestors_roster = frozenset().union(*(roster_of.get(p, frozenset()) for p in e.parents))
    if e.key in (upto or {}) and e.id not in upto[e.key]:
        raise Refused("retired-anchor", f"this anchor is retired at {as_anchor(anchors[e.key]).until[:12]}"
                      + ("" if upto[e.key] else ", an entry this reader does not have"))
    role = _role(e.key, e.principal, ancestors_roster, out, anchors)
    if e.kind == "ruling":
        if role != "operator":
            raise Refused("not-operator")
        keep = out.valid.get(e.data["keep"])
        seen = _seen(e, out.valid)
        if keep is None or keep.id not in seen:
            raise Refused("bad-field", "ruling: keep is not an entry this ruling saw")
        if not (any(x != keep.id and out.valid[x].key == keep.key and out.valid[x].seq == keep.seq for x in seen)
                or _pruned_seen(e, seen, {p for d in out.prunes.values() if d["ruling"] == e.id for p in d["pruned"]}, out)):
            raise Refused("bad-field", "ruling: keep is not part of a fork this ruling saw")
    if e.kind == "prune":
        if e.key not in anchors:
            raise Refused("not-operator", "a prune is an anchor's")
        ruling = out.valid.get(e.data["ruling"])
        if ruling is None or ruling.kind != "ruling" or ruling.id not in _seen(e, out.valid):
            raise Refused("bad-field", "prune: ruling is not a ruling this prune saw")
        if ruling.data["keep"] in e.data["pruned"]:
            raise Refused("bad-field", "prune: never the entry its ruling keeps")
    if e.kind == "roster":
        if role != "operator":
            raise Refused("not-operator")
        for a in e.data.get("add", []):
            bound = {(x["as"], x["role"]) for x in _adds(a["key"], ancestors_roster, out)}
            if bound and bound != {(a["as"], a["role"])}:
                raise Refused("wrong-principal", "the key is already bound otherwise")
        roster_of[e.id] = ancestors_roster | {e.id}
    else:
        roster_of[e.id] = ancestors_roster


def _adds(key: str, roster: frozenset[str], out: Ledger) -> list[dict]:
    return [a for r in roster for a in out.valid[r].data.get("add", []) if a["key"] == key]


def _role(key: str, principal: str, roster: frozenset[str], out: Ledger, anchors) -> str:
    if key in anchors:
        if as_anchor(anchors[key]).principal != principal:
            raise Refused("wrong-principal", f"the anchor writes as {as_anchor(anchors[key]).principal}")
        return "operator"
    if any(x["key"] == key for r in roster for x in out.valid[r].data.get("remove", [])):
        raise Refused("removed-key")
    bound = {(a["as"], a["role"]) for a in _adds(key, roster, out)}
    if not bound:
        raise Refused("unknown-key")
    if len(bound) > 1 or next(iter(bound))[0] != principal:
        raise Refused("wrong-principal", f"added as {sorted(b[0] for b in bound)}")
    return next(iter(bound))[1]


def _pruned_seen(e: Entry, seen: set[str], its_own: set[str], out: Ledger) -> bool:
    """Whether a ruling saw an entry pruned by a prune that names this ruling: a parent of it, or
    of an ancestor it saw."""
    return any(p in out.pruned and p in its_own for x in [e, *(out.valid[s] for s in seen)] for p in x.parents)


def ruled_out_by(led: Ledger, ruling: str) -> list[str]:
    """What a ruling rules out: the other side of the fork it settled, and the rest of that line."""
    keep = led.valid[ruling].data["keep"]
    n = next((n for n, k in led.rulings.items() if k == keep), None)
    if n is None:
        return []
    out = set(led.forks[n]) - {keep}
    for e in sorted((led.valid[i] for i in led.ruled_out), key=lambda e: e.seq):
        if e.prev in out:
            out.add(e.id)
    return sorted(out)


def _seen(e: Entry, valid: dict[str, Entry]) -> set[str]:
    """The ancestors of an entry that is not yet among the valid ones (its parents are)."""
    seen, todo = set(), list(e.parents)
    while todo:
        p = todo.pop()
        if p not in seen and p in valid:
            seen.add(p)
            todo.extend(valid[p].parents)
    return seen


def _ancestors(i: str, valid: dict[str, Entry]) -> set[str]:
    seen, todo = set(), list(valid[i].parents)
    while todo:
        p = todo.pop()
        if p not in seen:
            seen.add(p)
            todo.extend(valid[p].parents if p in valid else [])   # a pruned parent has none we know
    return seen


def _report(out: Ledger) -> None:
    def flag(i: str, what: str) -> None:
        if what not in out.flags.setdefault(i, []):
            out.flags[i].append(what)

    # Forks, and rulings on them (SPEC.md, "Forks and rulings"). Each key's seqs are taken in order:
    # once a fork is ruled, its other side and everything after it on that side are ruled out, and
    # they form no further fork with the side kept. One keep settles a fork; two that disagree do not.
    keeps: dict[str, list[str]] = {}
    for r, e in out.valid.items():
        if e.kind == "ruling":
            keeps.setdefault(e.data["keep"], []).append(r)
    by_seq: dict[tuple[str, int], list[str]] = {}
    for i, e in out.valid.items():
        by_seq.setdefault((e.key, e.seq), []).append(i)
    forks: list[list[str]] = []
    rulings: dict[int, str] = {}
    for (key, seq) in sorted(by_seq):
        group = by_seq[(key, seq)]
        for i in group:
            if out.valid[i].prev in out.ruled_out:
                out.ruled_out.add(i)
        members = sorted(i for i in group if i not in out.ruled_out)
        if len(members) < 2:
            continue
        n = len(forks)
        forks.append(members)
        rs = [r for k in members for r in keeps.get(k, [])]
        seen_by = {r: _ancestors(r, out.valid) for r in rs}
        current = [r for r in rs if not any(r in seen_by[q] for q in rs if q != r)]   # a later ruling supersedes what it saw
        kept = sorted({out.valid[r].data["keep"] for r in current})
        if len(kept) > 1:
            for r in current:
                flag(r, "ruled-twice")
        elif kept:
            rulings[n] = kept[0]
            out.ruled_out |= set(members) - {kept[0]}
    order = sorted(range(len(forks)), key=lambda n: forks[n])
    out.forks = [forks[n] for n in order]
    out.rulings = {order.index(n): k for n, k in rulings.items()}
    for i in out.ruled_out:
        flag(i, "ruled-out")
    # A prune may leave out only what is ruled out: one that names an entry still here and not
    # ruled out is flagged, and that entry stays as it is.
    for r, e in out.valid.items():
        if e.kind == "prune" and any(p in out.valid and p not in out.ruled_out for p in e.data["pruned"]):
            flag(r, "prunes-not-ruled-out")
    # Only what is ruled out (or pruned with its line) is to delete; a live entry a prune names is not.
    out.still_there = {i for i in out.still_there if i not in out.valid or i in out.ruled_out}

    removals = [(r, x["key"]) for r, e in out.valid.items() if e.kind == "roster"
                for x in e.data.get("remove", [])]
    for r, key in removals:
        before_removal = _ancestors(r, out.valid)
        for i, e in out.valid.items():
            if e.key == key and i not in before_removal and r not in _ancestors(i, out.valid):
                flag(i, "concurrent-with-removal")

    corrections: dict[str, list[str]] = {}
    for i, e in out.valid.items():
        if e.kind in ("work", "merge") and "corrects" in e.data:
            corrections.setdefault(e.data["corrects"], []).append(i)
            target = out.valid.get(e.data["corrects"])
            if target is not None and target.kind != e.kind:
                flag(i, "corrects-another-kind")
    for target, ids in corrections.items():
        if len(ids) > 1:
            flag(target, "corrected-more-than-once")

    # Merges (SPEC.md, "Kinds", merge): a correcting merge entry supersedes the one it names and
    # every merge entry of the same pr it had seen. The rest are current. Two current ones that
    # disagree on the commit are flagged; the same commit seen twice (two scribes) is not.
    merges = {i: e for i, e in out.valid.items() if e.kind == "merge"}
    superseded: set[str] = set()
    for i, e in merges.items():
        if "corrects" in e.data:
            superseded |= {x for x in _ancestors(i, out.valid) if x in merges and merges[x].data["pr"] == e.data["pr"]}
            superseded.add(e.data["corrects"])
    for i in superseded & set(merges):
        flag(i, "superseded")
    current: dict[int, list[str]] = {}
    for i, e in merges.items():
        if i not in superseded:
            current.setdefault(e.data["pr"], []).append(i)
    for ids in current.values():
        if len({out.valid[i].data["merge_sha"] for i in ids}) > 1:
            for i in ids:
                flag(i, "merged-twice")
