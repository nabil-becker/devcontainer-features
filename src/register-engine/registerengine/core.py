"""The register engine's core: registers on sign-packet's packets (SPEC.md).

An entry is a sign-packet packet (sign-packet's SPEC.md): its canonical form, signature, id and
chain are checked there. Here: what an entry of each kind may say, the roster, anchors, rulings,
prunes and the reading of one register. One register is read at a time: an entry names its
register (`reg`, format 2; a format-1 entry belongs to the register `ledger`), and an entry of
another register is refused. What an entry of each kind may say comes from the register's type, which a
capability Feature gives (types.py); `roster`, `ruling` and `prune` are the same in every one.

No storage here: sources and sinks are adapters around this.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

try:
    import signpacket as sp
except ImportError:   # beside this library: src/sign-packet in the source tree, /usr/local/lib/sign-packet installed
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sign-packet"))
    try:
        import signpacket as sp
    except ImportError:
        raise SystemExit("register-engine: needs the sign-packet Feature (its library, /usr/local/lib/sign-packet, "
                         "is not there); add it to devcontainer.json beside register-engine (README.md, \"Install\")") from None

SIGN_PACKET_MIN = (0, 5, 1)          # format v3 opt-in (versions=), and a deeply nested body refused, not a crash
if tuple(int(re.match(r"\d*", x).group() or 0) for x in (sp.__version__.split(".") + ["0", "0"])[:3]) < SIGN_PACKET_MIN:
    raise SystemExit(f"register-engine: needs sign-packet {'.'.join(map(str, SIGN_PACKET_MIN))} or later; "
                     f"{sp.__version__} is installed (update the sign-packet Feature)")

# The packet's format, from sign-packet (names kept from agentic-register, so the code reads as before).
VERSION, VERSIONS, NAMESPACES = sp.VERSION, sp.VERSIONS, sp.NAMESPACES
LEGACY_REGISTER = sp.LEGACY_DOMAIN      # the register a format-1 entry belongs to
MAX_BODY, MAX_SAW, MAX_INT = sp.MAX_BODY, sp.MAX_SAW, sp.MAX_INT
TOP_FIELDS, FIELDS = sp.packet.TOP_FIELDS, sp.packet.FIELDS
ARMOR_BEGIN, ARMOR_END = sp.packet.ARMOR_BEGIN, sp.packet.ARMOR_END
KEY_RE, ID_RE, AT_RE, PRINCIPAL_RE, FIELD_RE = sp.KEY_RE, sp.ID_RE, sp.AT_RE, sp.PRINCIPAL_RE, sp.FIELD_RE
REGISTER_RE = sp.DOMAIN_RE


class Entry(sp.Packet):
    """An entry: a sign-packet packet, whose domain is its register."""
    register = property(lambda self: self.domain)


Refused = sp.Refused
NoPublicKey = sp.NoPublicKey
canonical, entry_id, public_key, signature_ok, raw_name = sp.canonical, sp.packet_id, sp.public_key, sp.signature_ok, sp.raw_name

REFUSALS = (
    "bad-format", "too-large", "not-canonical", "bad-version", "bad-field", "bad-signature",
    "refused-parent", "bad-chain", "unknown-key", "wrong-principal", "removed-key", "not-operator",
    "wrong-register", "retired-anchor",
)
WRITER_REFUSALS = ("guarded",)   # a writer's own policy refused it before signing or putting; never a reader's outcome


class Anchor(NamedTuple):
    """An operator key the reader trusts. `until`: retired at that entry, in every register, trusted
    only for it and the entries before it (its ancestors), so a stolen key can be cut off without the
    history it signed being lost (SPEC.md, "Anchors"). `checkpoints`: (register, entry id) pairs, a
    checkpoint per register, for a key retired in some registers by their own entries."""
    principal: str
    until: str | None = None
    checkpoints: tuple = ()

    def checkpoint(self, register: str) -> str | None:
        """This register's checkpoint: its own, else the one for every register, else none."""
        own = [i for r, i in self.checkpoints if r == register]
        return own[0] if own else self.until

    @property
    def retired(self) -> bool:
        return bool(self.until or self.checkpoints)


def as_anchor(v) -> Anchor:
    return v if isinstance(v, Anchor) else Anchor(v)


# ---------------------------------------------------------------- an entry, as a register reads it

def need_kinds(kinds) -> None:
    """`kinds` is required (the security review of 0.1.0, F3): a caller that forgets it would read
    or sign every type-specific kind unchecked. `{}` says "unchecked" on purpose (the `log` type)."""
    if kinds is None:
        raise TypeError("kinds is required: pass the register type's kinds, or {} for unchecked")


def _versions(fmt: int) -> tuple[int, ...]:
    if fmt not in FORMATS:
        raise ValueError(f"no register format {fmt!r}; the formats are {FORMATS}")
    return (3,) if fmt == 3 else (1, 2)


def parse(raw: bytes, kinds: dict | None = None, fmt: int = 2) -> Entry:
    """Checks 1 and 2 of SPEC.md ("Checking an entry"): sign-packet's format and fields, then the
    kind's data. Raises Refused. `kinds`: kind -> check, from the register's type (default: none, so only the universal kinds are checked)."""
    need_kinds(kinds)
    return sp.parse(raw, lambda v: check_kind(v, kinds, fmt), Entry, _versions(fmt))


def check_fields(value: dict, kinds: dict | None = None, fmt: int = 2) -> None:
    need_kinds(kinds)
    sp.check_fields(value, lambda v: check_kind(v, kinds, fmt), _versions(fmt))


def sign(value: dict, private_key: Path, kinds: dict | None = None, fmt: int = 2) -> bytes:
    """The entry bytes for a body, signed with an OpenSSH Ed25519 key (sign-packet). Checks the body first."""
    need_kinds(kinds)
    return sp.sign(value, private_key, lambda v: check_kind(v, kinds, fmt), versions=_versions(fmt))


def _need(ok, what: str) -> None:
    if not ok:
        raise Refused("bad-field", what)


_is_id, _is_key, _is_int = sp.is_id, sp.is_key, sp.is_int


def _strings(v) -> bool:
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _check_ruling(d: dict) -> None:
    _need(set(d) == {"keep"} and _is_id(d["keep"]), "ruling: {keep: <entry id>}")


MAX_PRUNED = 1024


def _check_prune(d: dict) -> None:
    _need(set(d) == {"ruling", "pruned"} and _is_id(d["ruling"]), "prune: {ruling: <entry id>, pruned: [<entry id>]}")
    p = d["pruned"]
    _need(isinstance(p, list) and 0 < len(p) <= MAX_PRUNED and all(_is_id(x) for x in p), "prune: pruned")
    _need(p == sorted(set(p)), "prune: pruned sorted, no duplicates")
    _need(d["ruling"] not in p, "prune: never its own ruling")


READ_VERSIONS = (1, 2)        # format 2's packets: versions 1 and 2. Format 3's are version 3 alone (v3.py).
FORMATS = (2, 3)              # a register is one format, never both (SPEC.md, "Format v3")


UNIVERSAL = ("roster", "ruling", "prune")   # kinds in every register, whatever its type


def _universal(kind: str):
    return {"roster": _check_roster, "ruling": _check_ruling, "prune": _check_prune}.get(kind)


def check_kind(value: dict, kinds: dict | None = None, fmt: int = 2) -> None:
    """The kind's data. Format 2: `roster`, `ruling` and `prune` in every register. Format 3: the
    identity and permission kinds (v3.py). The others as the register's type says."""
    if fmt == 3:
        from . import v3
        if value.get("v") != 3:
            raise Refused("bad-version", f"{value.get('v')!r}: a format-3 register holds version-3 entries only")
        if value["kind"] == "roster":
            raise Refused("bad-field", "roster is format 2's: a format-3 register grants, binds and revokes")
        check = v3.UNIVERSAL.get(value["kind"]) or (kinds or {}).get(value["kind"])
    else:
        if value.get("v") not in READ_VERSIONS:    # sign-packet 0.5.0 knows version 3; these rules are v2's
            raise Refused("bad-version", f"{value.get('v')!r}: this reader reads format versions 1 and 2 only")
        check = _universal(value["kind"]) or (kinds or {}).get(value["kind"])
    if check:
        check(value["data"])


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


# ---------------------------------------------------------------- the register

@dataclass
class Ledger(sp.Graph):
    """The outcome of reading a register (SPEC.md, "Reading a register"): sign-packet's graph, and
    what the register adds. `pruned` is sign-packet's `absent`: ruled out, then left out of the
    store by an operator's prune."""
    forks: list[list[str]] = field(default_factory=list)
    flags: dict[str, list[str]] = field(default_factory=dict)
    rulings: dict[int, str] = field(default_factory=dict)    # index in forks -> the entry kept, when ruled once
    ruled_out: set[str] = field(default_factory=set)         # the other side of a ruled fork, and what follows it
    prunes: dict[str, dict] = field(default_factory=dict)    # the prunes this read counted: id -> its data

    @property
    def pruned(self) -> set[str]:
        return self.absent

    @pruned.setter
    def pruned(self, v: set[str]) -> None:
        self.absent = v

    @property
    def unruled_forks(self) -> list[list[str]]:
        return [f for n, f in enumerate(self.forks) if n not in self.rulings]

    def outcome(self, i: str) -> str:
        if i in self.valid:
            return "valid"
        if i in self.held:
            return "held"
        if i in self.pruned:
            return "pruned"
        return self.refused[i][0] if i in self.refused else "unknown"


def read(raws, anchors: dict[str, str] | None = None, checked=None, register: str = LEGACY_REGISTER,
         kinds: dict | None = None, fmt: int = 2) -> Ledger:
    """Check and join the entries of one register from any number of sources. `anchors`: key ->
    principal. `kinds`: the register type's kind checks (default: none).

    `checked`: optional, the reader's own record of good signatures (a set-like of the SHA-256 of
    whole entries, with `add`). It is the reader's state, never a store's: a store is not trusted.
    """
    need_kinds(kinds)
    _versions(fmt)
    raws = list(raws)
    anchors = anchors or {}
    if checked is None:
        checked = set()      # each signature checked once, however many times the prunes make us read
    # A prune vouches for entries a store leaves out (SPEC.md, "Pruning"). It is trusted only as
    # far as it is itself valid: read with every prune signed by an anchor, then again without any
    # that the read refused or held, until none changes.
    vouch: dict[str, list[str]] | None = None
    while True:
        out = _read(raws, anchors, checked, register, kinds, vouch, fmt)
        live = {i: d for i, d in out.prunes.items() if i in out.valid}
        if live == out.prunes:
            return out
        vouch = live


def _read(raws, anchors, checked, register, kinds, vouch, fmt=2) -> Ledger:
    # Each entry alone (sign-packet): format and fields, with the universal kinds' data; the
    # register; the type's kinds; the signature.
    found, refused = sp.collect(raws, register, parse_check=lambda v: check_kind(v, {}, fmt),
                                check=lambda v: check_kind(v, kinds, fmt), checked=checked,
                                wrong_domain=("wrong-register", "an entry of {got}, read as {want}"),
                                verify=lambda e: signature_ok(e), cls=Entry, versions=_versions(fmt))   # looked up here, so a test can count calls
    out = Ledger(refused=refused)
    # The prunes signed by an anchor: on the first read every one, then the ones still valid.
    if vouch is None:
        vouch = {i: e.data for i, e in found.items()
                 if e.kind == "prune" and e.key in anchors and as_anchor(anchors[e.key]).principal == e.principal}
    out.prunes = vouch
    named = {p for d in vouch.values() for p in d["pruned"]}
    roster_of: dict[str, frozenset[str]] = {}  # id -> the roster entries among its ancestors (and itself)
    # A retired anchor is trusted for its checkpoint and the checkpoint's ancestors only.
    # A retired anchor is trusted for this register's checkpoint and its ancestors only. One retired
    # in other registers alone: in format 2, for nothing here; in format 3, up to its revocation as
    # carried into this register by another anchor (v3.py; the review of 0.2.0, F1).
    upto, retired_elsewhere = {}, set()
    for k, v in anchors.items():
        a = as_anchor(v)
        cp = a.checkpoint(register)
        if cp:
            upto[k] = _upto(cp, found)
        elif a.retired:
            if fmt == 3:
                retired_elsewhere.add(k)
            else:
                upto[k] = set()
    # Parents first (sign-packet): every parent known or vouched absent by a counted prune, the
    # chain; then who may write, rulings and prunes.
    if fmt == 3:
        from . import v3
        state_of: dict = {}
        sp.order(found, out, named, lambda e, o: v3.decide(e, o, anchors, state_of, upto, retired_elsewhere, checked))
    else:
        sp.order(found, out, named, lambda e, o: _decide(e, o, anchors, roster_of, upto))
    _report(out, fmt)
    return out


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
    """Check 7, once sign-packet has checked the parents and the chain: who may write, rulings, prunes."""
    ancestors_roster = frozenset().union(*(roster_of.get(p, frozenset()) for p in e.parents))
    if e.key in (upto or {}) and e.id not in upto[e.key]:
        raise Refused("retired-anchor", f"this anchor is retired at {as_anchor(anchors[e.key]).until[:12]}"
                      + ("" if upto[e.key] else ", an entry this reader does not have"))
    role = _role(e.key, e.principal, ancestors_roster, out, anchors)
    if e.kind == "ruling":
        if role != "operator":
            raise Refused("not-operator")
        _check_ruling_in(e, out)
    if e.kind == "prune":
        if e.key not in anchors:
            raise Refused("not-operator", "a prune is an anchor's")
        _check_prune_in(e, out)
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


def _check_ruling_in(e: Entry, out: Ledger) -> None:
    """A ruling keeps one side of a fork it saw (both formats)."""
    keep = out.valid.get(e.data["keep"])
    seen = _seen(e, out.valid)
    if keep is None or keep.id not in seen:
        raise Refused("bad-field", "ruling: keep is not an entry this ruling saw")
    if not (any(x != keep.id and out.valid[x].key == keep.key and out.valid[x].seq == keep.seq for x in seen)
            or _pruned_seen(e, seen, {p for d in out.prunes.values() if d["ruling"] == e.id for p in d["pruned"]}, out)):
        raise Refused("bad-field", "ruling: keep is not part of a fork this ruling saw")


def _check_prune_in(e: Entry, out: Ledger) -> None:
    """A prune names a ruling it saw, and never the entry that ruling keeps (both formats)."""
    ruling = out.valid.get(e.data["ruling"])
    if ruling is None or ruling.kind != "ruling" or ruling.id not in _seen(e, out.valid):
        raise Refused("bad-field", "prune: ruling is not a ruling this prune saw")
    if ruling.data["keep"] in e.data["pruned"]:
        raise Refused("bad-field", "prune: never the entry its ruling keeps")


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


def _report(out: Ledger, fmt: int = 2) -> None:
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

    if fmt == 3:
        from . import v3
        v3.report(out, flag)
    removals = [(r, x["key"]) for r, e in out.valid.items() if e.kind == "roster"
                for x in e.data.get("remove", [])]
    for r, key in removals:
        before_removal = _ancestors(r, out.valid)
        for i, e in out.valid.items():
            if e.key == key and i not in before_removal and r not in _ancestors(i, out.valid):
                flag(i, "concurrent-with-removal")

    # A type's own flags (the ledger's corrections and merges, for one) are its project()'s.
