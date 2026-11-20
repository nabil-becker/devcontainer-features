"""Format v3: identity and permission (SPEC.md, "Format v3"; AOF's aof/tooling/design/register-v3-identity-permission.md,
ruled by the operator on 2026-11-11).

Identity is attested once, in an agents register, by an anchor: an `identity` packet says principal
P holds key K. A register carries that packet, byte for byte, in the operator-signed entry that
grants P (`grant`) or adds a key to P (`bind`), and carries a revocation (an `identity_revoke`
packet) the same way (`revoke`). So each register is still read alone: every reader of it reaches
the same verdict, and it crosses between stacks with nothing else.

Who may write is the engine's (the review's Break 2), never a plug-in's: a reader without a
capability Feature still applies every rule here.
"""
from __future__ import annotations

import hashlib

from . import core
from .core import Refused, _need, _is_id, _is_key, as_anchor, sp

VERSIONS = (3,)
MAX_CARRIED = 8192                      # bytes of a carried packet (the review: about 5 KiB with a full saw)
TYPES = ("agent", "operator")
TRUST_KINDS = ("register", "grant", "bind", "revoke", "ungrant")
ANCHOR_KINDS = ("identity", "identity_revoke")   # kinds of an agents register: an anchor's alone


def _principal(v) -> bool:
    return isinstance(v, str) and sp.PRINCIPAL_RE.fullmatch(v) is not None


def _raw(v, what: str) -> None:
    _need(isinstance(v, str) and v, f"{what}: a packet's text")
    _need(len(v.encode("utf-8")) <= MAX_CARRIED, f"{what}: at most {MAX_CARRIED} bytes")


def _check_register(d: dict) -> None:
    f = d.get("identity_from")
    _need(isinstance(f, list) and 1 <= len(f) <= 8 and all(isinstance(x, str) and core.REGISTER_RE.fullmatch(x) for x in f)
          and len(set(f)) == len(f), "register: identity_from, 1 to 8 register names")
    c = d.get("continues")
    if c is not None:
        _need(isinstance(c, dict) and isinstance(c.get("register"), str) and core.REGISTER_RE.fullmatch(c["register"])
              and isinstance(c.get("heads"), list) and all(_is_id(h) for h in c["heads"]), "register: continues")


def _check_grant(d: dict) -> None:
    _need(_principal(d.get("principal")), "grant: principal")
    _need(d.get("role") in TYPES, "grant: role, agent or operator")
    _raw(d.get("identity"), "grant: identity")


def _check_bind(d: dict) -> None:
    _raw(d.get("identity"), "bind: identity")
    if "revocation" in d:
        _raw(d["revocation"], "bind: revocation")


def _check_revoke(d: dict) -> None:
    _raw(d.get("revocation"), "revoke: revocation")


def _check_ungrant(d: dict) -> None:
    _need(_principal(d.get("principal")), "ungrant: principal")


def check_identity(d: dict) -> None:
    """An `identity` attestation's data: who holds which key, and what kind of principal it is. With
    an optional stable subject, an end (`until`, a credential's validUntil) and former names (`was`,
    alsoKnownAs), so it maps to a verifiable credential with no change of format (AGNTCY R2 to R4)."""
    _need(_principal(d.get("principal")), "identity: principal")
    _need(_is_key(d.get("key")), "identity: key")
    _need(d.get("type") in TYPES, "identity: type, agent or operator")
    if "subject" in d:
        _need(isinstance(d["subject"], str) and 0 < len(d["subject"]) <= 256, "identity: subject")
    if "until" in d:
        _need(isinstance(d["until"], str) and sp.AT_RE.fullmatch(d["until"]), "identity: until")
    if "was" in d:
        _need(isinstance(d["was"], list) and all(_principal(x) for x in d["was"]), "identity: was")


def check_identity_revoke(d: dict) -> None:
    """An `identity_revoke`: the key it ends, and the attestations it ends (a credential's status)."""
    _need(_is_key(d.get("key")), "identity_revoke: key")
    _need(isinstance(d.get("ends"), list) and all(_is_id(x) for x in d["ends"]), "identity_revoke: ends")
    if "reason" in d:
        _need(isinstance(d["reason"], str) and len(d["reason"]) <= 512, "identity_revoke: reason")


UNIVERSAL = {"register": _check_register, "grant": _check_grant, "bind": _check_bind, "revoke": _check_revoke,
             "ungrant": _check_ungrant, "ruling": core._check_ruling, "prune": core._check_prune,
             "identity": check_identity, "identity_revoke": check_identity_revoke}


# ---------------------------------------------------------------- a carried packet

def carried(raw: str, kind: str, carrier: core.Entry, state: "State", anchors: dict, upto: dict,
            retired_elsewhere: set, checked) -> sp.Packet:
    """A packet carried in an entry of this register, checked alone: format and fields (version 3),
    its kind, an agents register this register accepts, its signature, an anchor that signed it
    and is trusted for the carrier (the review's Break 1), and a key that is not an anchor's, but
    for the revocation of an anchor retired elsewhere, carried by another anchor (the 0.2.0 review, F1)."""
    try:
        p = sp.parse(raw.encode("utf-8"), lambda v: _carried_kind(v, kind), versions=VERSIONS)
    except Refused as r:
        raise Refused("bad-carried", f"{kind}: {r.code} {r.detail}".strip()) from None
    if p.domain not in state.identity_from:
        raise Refused("bad-carried", f"{kind}: from {p.domain}, which this register does not accept identity from")
    if p.key not in anchors or as_anchor(anchors[p.key]).principal != p.principal:
        raise Refused("bad-carried", f"{kind}: not signed by an anchor of this reader")
    if p.key in upto and carrier.id not in upto[p.key]:
        raise Refused("bad-carried", f"{kind}: its anchor is retired before this entry")
    if p.key in retired_elsewhere and state.is_revoked(p.key):
        raise Refused("bad-carried", f"{kind}: its anchor's revocation is carried here before this entry")
    whole = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    if not ((checked is not None and whole in checked) or core.signature_ok(p)):
        raise Refused("bad-carried", f"{kind}: bad signature")
    if checked is not None:
        checked.add(whole)                    # each carried signature checked once (the 0.2.0 review, F9)
    if p.data["key"] in anchors:
        ok = (kind == "identity_revoke" and p.data["key"] in retired_elsewhere
              and carrier.key in anchors and carrier.key != p.data["key"])
        if not ok:
            raise Refused("anchor-key", "an anchor's key changes only by the reader's anchors (or, retired "
                          "elsewhere, by its revocation carried here by another anchor)")
    return p


def _carried_kind(v: dict, kind: str) -> None:
    if v["kind"] != kind:
        raise Refused("bad-field", f"a {v['kind']}, not an {kind}")
    UNIVERSAL[kind](v["data"])


# ---------------------------------------------------------------- the state below an entry

class State:
    """What an entry's ancestors say about who may write: built per entry from its parents', so the
    verdict depends on the entry's ancestors only, never on arrival order."""
    __slots__ = ("register", "identity_from", "grants", "ungrants", "binds", "revoked")

    def __init__(self):
        self.register: str | None = None             # the `register` entry's id
        self.identity_from: frozenset[str] = frozenset()
        self.grants: frozenset[tuple] = frozenset()   # (entry id, principal, role, key)
        self.ungrants: frozenset[tuple] = frozenset() # (entry id, principal)
        self.binds: frozenset[tuple] = frozenset()    # (entry id, principal, key)
        self.revoked: frozenset[tuple] = frozenset()  # (entry id, key)

    @staticmethod
    def join(states: list["State"]) -> "State":
        s = State()
        for x in states:
            if x.register and s.register and x.register != s.register:
                raise Refused("bad-field", "two register entries among its ancestors")
            s.register = s.register or x.register
            s.identity_from |= x.identity_from
            s.grants |= x.grants
            s.ungrants |= x.ungrants
            s.binds |= x.binds
            s.revoked |= x.revoked
        return s

    def copy(self) -> "State":
        return State.join([self])

    def is_revoked(self, key: str) -> bool:
        return any(r[1] == key for r in self.revoked)


def _ancestor(a: str, b: str, out: core.Ledger) -> bool:
    """Whether entry a is among b's ancestors (both valid)."""
    return a in core._ancestors(b, out.valid)


def _stands(entry: str, principal: str, s: State, out: core.Ledger) -> bool:
    """Whether a grant or bind of P stands below an entry: every ungrant of P among the ancestors
    comes before it. An ungrant concurrent with it wins (the review)."""
    return all(_ancestor(u, entry, out) for u, p in s.ungrants if p == principal)


def live_grant(s: State, principal: str, out: core.Ledger) -> tuple | None:
    """P's grant that stands below an entry, or None. Two that stand with different roles: refused."""
    live = [g for g in s.grants if g[1] == principal and _stands(g[0], principal, s, out)]
    roles = {g[2] for g in live}
    if len(roles) > 1:
        raise Refused("wrong-principal", f"{principal} is granted as {sorted(roles)} at once")
    return live[0] if live else None


def live_keys(s: State, principal: str, out: core.Ledger) -> set[str]:
    """P's keys below an entry: from grants and binds that stand (so a re-grant after an ungrant
    brings back no earlier key: the 0.2.0 review, F5), less every revoked key."""
    keys = {g[3] for g in s.grants if g[1] == principal and _stands(g[0], principal, s, out)}
    keys |= {b[2] for b in s.binds if b[1] == principal and _stands(b[0], principal, s, out)}
    return {k for k in keys if not s.is_revoked(k)}


def decide(e: core.Entry, out: core.Ledger, anchors: dict, state_of: dict, upto: dict,
           retired_elsewhere: set = frozenset(), checked=None) -> None:
    """Check 7 for a v3 entry: who may write it, and what its kind asks of its writer."""
    s = State.join([state_of[p] for p in e.parents if p in state_of])
    if e.key in upto and e.id not in upto[e.key]:
        raise Refused("retired-anchor", f"this anchor is retired at {as_anchor(anchors[e.key]).checkpoint(e.domain)[:12]}"
                      + ("" if upto[e.key] else ", an entry this reader does not have"))
    if e.key in retired_elsewhere and s.is_revoked(e.key):
        raise Refused("retired-anchor", "this anchor's revocation is carried here before this entry")
    if e.key in anchors:
        if as_anchor(anchors[e.key]).principal != e.principal:
            raise Refused("wrong-principal", f"the anchor writes as {as_anchor(anchors[e.key]).principal}")
        role, anchor = "operator", True
    else:
        role, anchor = _role(e, s, out), False

    def carry(raw, kind):
        return carried(raw, kind, e, s, anchors, upto, retired_elsewhere, checked)

    k = e.kind
    if k in ANCHOR_KINDS and not anchor:
        raise Refused("not-operator", f"an {k} is an anchor's")
    if k == "identity" and e.data["key"] in anchors:
        raise Refused("anchor-key", "an anchor's key changes only by the reader's anchors")
    if k in ("ruling",) + TRUST_KINDS and role != "operator":
        raise Refused("not-operator")
    if k == "prune" and not anchor:
        raise Refused("not-operator", "a prune is an anchor's")
    if k == "ruling":
        core._check_ruling_in(e, out)
    if k == "prune":
        core._check_prune_in(e, out)

    n = s.copy()
    if k == "register":
        if not anchor:
            raise Refused("not-operator", "the register entry is an anchor's")
        if e.parents:
            raise Refused("bad-field", "the register entry is the register's first: no parents (the 0.2.0 review, F4)")
        n.register, n.identity_from = e.id, frozenset(e.data["identity_from"])
    elif k in TRUST_KINDS:
        if not s.register:
            raise Refused("no-register", "no register entry among its ancestors says which identities it accepts")
        if k == "grant":
            ident = carry(e.data["identity"], "identity")
            if ident.data["principal"] != e.data["principal"]:
                raise Refused("wrong-principal", "the carried identity names another principal")
            if e.data["role"] == "operator" and ident.data["type"] != "operator":
                raise Refused("not-operator", "an agent's identity is never granted as an operator")
            _bound_elsewhere(s, ident.data["key"], ident.data["principal"])
            n.grants = s.grants | {(e.id, e.data["principal"], e.data["role"], ident.data["key"])}
        elif k == "bind":
            ident = carry(e.data["identity"], "identity")
            p = ident.data["principal"]
            g = live_grant(s, p, out)
            if g is None:
                raise Refused("not-granted", f"{p} has no grant here to add a key to")
            if g[2] == "operator" and ident.data["type"] != "operator":
                raise Refused("not-operator", "an agent's identity is never bound to an operator's grant (the 0.2.0 review, F2)")
            _bound_elsewhere(s, ident.data["key"], p)
            n.binds = s.binds | {(e.id, p, ident.data["key"])}
            if "revocation" in e.data:
                rev = carry(e.data["revocation"], "identity_revoke")
                if rev.data["key"] not in live_keys(s, p, out):
                    raise Refused("bad-field", "bind: the revocation is of a key this principal does not hold here")
                n.revoked = s.revoked | {(e.id, rev.data["key"])}
        elif k == "revoke":
            rev = carry(e.data["revocation"], "identity_revoke")
            n.revoked = s.revoked | {(e.id, rev.data["key"])}
        elif k == "ungrant":
            n.ungrants = s.ungrants | {(e.id, e.data["principal"])}
    state_of[e.id] = n


def _bound_elsewhere(s: State, key: str, principal: str) -> None:
    if s.is_revoked(key):
        raise Refused("revoked-key", "a revoked key is never bound again: give the principal a new key")
    others = {g[1] for g in s.grants if g[3] == key} | {b[1] for b in s.binds if b[2] == key}
    if others - {principal}:
        raise Refused("wrong-principal", f"the key is already bound to {sorted(others - {principal})}")


def _role(e: core.Entry, s: State, out: core.Ledger) -> str:
    """Who may write a v3 entry with a key that is no anchor: a key bound to its principal by a
    carried identity in a grant or bind that stands, not revoked, and a grant of that principal
    that stands."""
    if s.is_revoked(e.key):
        raise Refused("revoked-key")
    holders = {g[1] for g in s.grants if g[3] == e.key} | {b[1] for b in s.binds if b[2] == e.key}
    if not holders:
        raise Refused("unknown-key")
    if holders != {e.principal}:
        raise Refused("wrong-principal", f"the key is bound to {sorted(holders)}")
    g = live_grant(s, e.principal, out)
    if g is None:
        raise Refused("not-granted", f"{e.principal} has no grant here that stands")
    if e.key not in live_keys(s, e.principal, out):
        raise Refused("not-granted", "this key was bound before an ungrant; the grant that stands does not carry it")
    return g[2]


def report(out: core.Ledger, flag) -> None:
    """Flags for a person (never a refusal): an entry written concurrently with the revocation of
    its key, and a grant and an ungrant of one principal written concurrently."""
    revokes = []
    for i, e in out.valid.items():
        if e.kind in ("revoke", "bind") and e.data.get("revocation"):
            try:
                key = sp.parse(e.data["revocation"].encode("utf-8"), versions=VERSIONS).data["key"]
            except Refused:
                continue
            revokes.append((i, key))
    for r, key in revokes:
        before_r = core._ancestors(r, out.valid)
        for i, e in out.valid.items():
            if e.key == key and i not in before_r and r not in core._ancestors(i, out.valid):
                flag(i, "concurrent-with-revocation")
    grants = [(i, e.data["principal"]) for i, e in out.valid.items() if e.kind == "grant"]
    ungrants = [(i, e.data["principal"]) for i, e in out.valid.items() if e.kind == "ungrant"]
    for g, p in grants:
        for u, q in ungrants:
            if p == q and not _ancestor(g, u, out) and not _ancestor(u, g, out):
                flag(g, "concurrent-grant")
                flag(u, "concurrent-grant")
