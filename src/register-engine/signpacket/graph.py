"""Reading many packets: which are valid, in what order, which wait, which are refused, and which
are vouched absent (SPEC.md, "Reading packets").

Two steps. `collect` checks each packet alone (format, fields, domain, signature). `order` takes
them parents first and checks what needs the ancestors (every parent known, the chain), then asks
the layer on top (`decide`) for its own checks, such as who may write. Nothing here knows rosters,
kinds or registers.
"""
from __future__ import annotations

import hashlib
import heapq
from dataclasses import dataclass, field
from typing import Callable, Iterable

from .packet import DEFAULT_VERSIONS, MAX_BODY, Check, Packet, Refused, packet_id, parse, signature_ok


@dataclass
class Graph:
    """The outcome of reading a set of packets of one domain."""
    valid: dict[str, Packet] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)
    held: dict[str, list[str]] = field(default_factory=dict)           # id -> unknown parent ids
    refused: dict[str, tuple[str, str]] = field(default_factory=dict)  # id -> (code, detail)
    absent: set[str] = field(default_factory=set)        # vouched absent, and not here: a parent no one waits for
    still_there: set[str] = field(default_factory=set)   # vouched absent, yet here

    @property
    def heads(self) -> list[str]:
        named = {p for e in self.valid.values() for p in e.parents}
        return sorted(i for i in self.valid if i not in named)


def _refused_name(raw: bytes, r: Refused) -> str:
    """A packet refused for its version is named by its id (its body parsed), so a packet that names
    it as a parent is refused after it, not held for it; anything else that failed to parse has
    only its raw name."""
    if r.code == "bad-version":
        line = raw.split(b"\n", 1)[0]
        if len(line) <= MAX_BODY:
            return packet_id(line)
    return raw_name(raw)


def raw_name(raw: bytes) -> str:
    """The name of bytes that could not be parsed: not an id, as there may be no body."""
    return "raw-" + hashlib.sha256(raw).hexdigest()


def collect(raws: Iterable[bytes], domain: str, *, parse_check: Check | None = None, check: Check | None = None,
            checked=None, wrong_domain: tuple[str, str] = ("wrong-domain", "a packet of {got}, read as {want}"),
            refused: dict | None = None, verify: Callable[[Packet], bool] = signature_ok,
            cls: type[Packet] = Packet, versions: tuple[int, ...] = DEFAULT_VERSIONS
            ) -> tuple[dict[str, Packet], dict[str, tuple[str, str]]]:
    """Checks 1 to 4 of SPEC.md ("Checking a packet"), each packet alone: the format and fields
    (with the layer's `parse_check`), the domain, the layer's `check`, then the signature.

    `checked`: optional, the reader's own record of good signatures (a set-like of the SHA-256 of
    whole packets, with `add`). It is the reader's state, never a store's: a store is not trusted.
    `wrong_domain`: the code and detail a packet of another domain is refused with. `verify`: the
    signature check (signature_ok). `cls`: the class of what is returned, a Packet or a layer's own.
    Returns the packets found, by id, and the refused, by id (or raw_name when there is no body)."""
    found: dict[str, Packet] = {}
    refused = {} if refused is None else refused
    for raw in raws:
        try:
            e = parse(raw, parse_check, cls, versions)
        except Refused as r:
            refused[_refused_name(raw, r)] = (r.code, r.detail)
            continue
        if e.id in found:
            continue
        if e.domain != domain:
            refused[e.id] = (wrong_domain[0], wrong_domain[1].format(got=e.domain, want=domain))
            continue
        if check is not None:
            try:
                check(e.value)
            except Refused as r:
                refused[e.id] = (r.code, r.detail)
                continue
        whole = hashlib.sha256(raw).hexdigest()
        if (checked is not None and whole in checked) or verify(e):
            if checked is not None:
                checked.add(whole)
            found[e.id] = e
            refused.pop(e.id, None)  # a good copy outweighs a bad one
        else:
            refused[e.id] = ("bad-signature", "")
    return found, refused


class _Absent(Exception):
    pass


def order(found: dict[str, Packet], out: Graph, vouched: set[str] = frozenset(),
          decide: Callable[[Packet, Graph], None] | None = None) -> Graph:
    """Checks 5 and 6 of SPEC.md, and the order (SPEC.md, "Order"): parents first, ties to the
    earlier `at`, then the smaller id. `out` holds the refused from `collect`; it is filled in.

    A parent refused by id counts as decided (its children are then refused); a parent nobody has
    is waited for, so its children are held, unless `vouched` names it: then it is absent, and no
    one waits for it. A packet whose `prev` is absent is absent too if `vouched` names it, and is
    refused otherwise (its chain cannot be checked). `decide(packet, out)`: the layer's own checks,
    run once a packet's parents and chain are good; it raises Refused, and may read `out`."""
    out.absent = set(vouched) - set(found)
    out.still_there = set(vouched) & set(found)
    waiting = {i: {p for p in e.parents if p not in out.refused and p not in out.absent} for i, e in found.items()}
    children: dict[str, list[str]] = {}
    for i, ps in waiting.items():
        for p in ps:
            children.setdefault(p, []).append(i)
    ready = [(e.at, i) for i, e in found.items() if not waiting[i]]
    heapq.heapify(ready)
    decided: set[str] = set(out.absent)

    while ready:
        _, i = heapq.heappop(ready)
        e = found[i]
        decided.add(i)
        try:
            if e.prev in out.absent:
                if i not in out.still_there:    # only what is vouched for; anything else has no chain to check
                    raise Refused("refused-parent", f"{e.prev}: pruned, and this entry is not")
                out.absent.add(i)               # vouched for, and its line is gone before it: absent with it
                raise _Absent
            for p in e.parents:
                if p not in out.valid and p not in out.absent:
                    raise Refused("refused-parent", p)
            if e.prev:
                before = out.valid[e.prev]
                if before.key != e.key or before.seq != e.seq - 1:
                    raise Refused("bad-chain", "prev is not this key's entry before")
                if (before.value["v"] == 3) != (e.value["v"] == 3):
                    raise Refused("bad-chain", "a chain never continues across version 3 (a layer that moves starts a new domain)")
            if decide is not None:
                decide(e, out)
            out.valid[i] = e
            out.order.append(i)
        except Refused as r:
            out.refused[i] = (r.code, r.detail)
        except _Absent:
            pass
        for c in children.get(i, []):
            waiting[c].discard(i)
            if not waiting[c]:
                heapq.heappush(ready, (found[c].at, c))

    for i, e in found.items():
        if i not in decided:
            out.held[i] = sorted(p for p in e.parents if p not in decided)
    return out


def read(raws: Iterable[bytes], domain: str, *, vouched: set[str] = frozenset(), check: Check | None = None,
         checked=None, versions: tuple[int, ...] = DEFAULT_VERSIONS) -> Graph:
    """Collect and order the packets of one domain, with no layer on top."""
    found, refused = collect(raws, domain, check=check, checked=checked, versions=versions)
    return order(found, Graph(refused=refused), vouched)


def forks(valid: dict[str, Packet], skip: set[str] = frozenset()) -> list[list[str]]:
    """Every key's seq held by two or more valid packets, leaving out `skip`: sorted, each sorted.
    A fork is a key that wrote two packets as one seq (SPEC.md, "Forks")."""
    by_seq: dict[tuple[str, int], list[str]] = {}
    for i, e in valid.items():
        if i not in skip:
            by_seq.setdefault((e.key, e.seq), []).append(i)
    return sorted(sorted(g) for g in by_seq.values() if len(g) > 1)
