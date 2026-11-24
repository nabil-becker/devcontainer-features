"""The record (proposal 4.6): one register-engine register of the `conversation` type per
conversation, in the volume; every entry a sign-packet packet signed by its writer's key.

The facilitator's key is the anchor (anchors): it writes each conversation's roster (the members'
keys) and its thread, routes and notices; each member writes its own messages and task states. A
conversation shared with other nodes (slice N3) also anchors the facilitator key of every other node one of
its members is on (from that node's admitted card), so each node's dispatcher routes its own members'
messages; every write is queued for those nodes (peers.Net.push)."""
from __future__ import annotations

import secrets
from pathlib import Path

from registerengine import adapters, core
from registerengine import registertypes

from . import clients as clients_mod
from .signer import Signer
from .state import State

FACILITATOR = "facilitator"
LIB = Path(__file__).resolve().parents[1]
INSTALLED = str(LIB).startswith("/usr/local/lib/")


class RecordError(RuntimeError):
    pass


def conversation_type():
    """The type from the facilitator's types folder: installed, under the engine's installed rules (root's
    folder, an isolated process); in a source tree or a test, the folder beside this package."""
    if not INSTALLED:
        # A source tree (tests): this package's own module, loaded as the engine would, without the
        # installed folder's ownership rules (a checkout is the user's, and may be group-writable).
        import importlib.util
        spec = importlib.util.spec_from_file_location("facilitator_types_source", LIB / "types.d" / "facilitator.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.TYPES[0]
    try:
        types = registertypes.load()
    except registertypes.TypesError as e:
        raise RecordError(f"the conversation type cannot be loaded: {e}") from None
    if "conversation" not in types:
        raise RecordError(f"no conversation type in {registertypes.TYPES_DIR}")
    return types["conversation"]


def audit_type():
    """The `audit` register type of the facilitator's types folder (slice N5a, ruling HC3), loaded as conversation_type is."""
    if not INSTALLED:
        import importlib.util
        spec = importlib.util.spec_from_file_location("facilitator_types_source", LIB / "types.d" / "facilitator.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return next(t for t in mod.TYPES if t.name == "audit")
    try:
        types = registertypes.load()
    except registertypes.TypesError as e:
        raise RecordError(f"the audit type cannot be loaded: {e}") from None
    if "audit" not in types:
        raise RecordError(f"no audit type in {registertypes.TYPES_DIR}")
    return types["audit"]


def new_id(prefix: str, n: int = 6) -> str:
    return f"{prefix}-{secrets.token_hex(n)}"


class Record:
    def __init__(self, state: State, signer: Signer, net=None):
        self.state = state
        self.signer = signer
        self.net = net if net is not None and net.active else None
        self.type = conversation_type()
        self.kinds = self.type.kinds
        self.checked: set = set()          # signatures already checked by this process

    # ------------------------------------------------------------ anchors and stores

    def facilitator_key(self) -> str:
        pub, _ = self.signer.ensure_key(FACILITATOR)
        line = f"{FACILITATOR} {pub}\n"
        try:
            current = self.state.anchors_file.read_text()
        except OSError:
            current = ""
        if current != line:
            self.state.anchors_file.write_text(line)
        return pub

    def anchors(self) -> dict:
        if not self.state.anchors_file.exists():
            self.facilitator_key()
        return adapters.load_anchors(self.state.anchors_file)

    def as_principal(self, conv: str, handle: str) -> str:
        """The principal a handle of this node writes as in a conversation: in one shared with other nodes,
        `handle.node` (ruling H5); in one this node keeps alone, the handle, as before."""
        if handle == FACILITATOR or self.net is None or self.net.meta(conv) is None:
            return handle
        return f"{handle}.{self.net.mesh.node_id}"

    def anchors_for(self, conv: str) -> dict:
        """The anchors of one conversation: this node's facilitator, and in a conversation shared with other
        nodes, theirs (lock two admitted their cards)."""
        a = self.anchors()
        if self.net is not None:
            extra = self.net.anchors_extra(conv)
            if extra:
                a = {**extra, **a}
        return a

    def store(self, conv: str) -> adapters.DirStore:
        return adapters.DirStore(self.state.conversations / conv)

    def conversations(self) -> list[str]:
        d = self.state.conversations
        if not d.is_dir():
            return []
        return sorted(p.name for p in d.iterdir() if p.is_dir() and core.REGISTER_RE.fullmatch(p.name)
                      and any(p.glob("*.entry")))

    def exists(self, conv: str) -> bool:
        return conv in self.conversations()

    # ------------------------------------------------------------ reading

    def read(self, conv: str, checked=None):
        """(the register as read, the conversation as projected, flags)."""
        if not core.REGISTER_RE.fullmatch(conv or ""):
            raise RecordError(f"not a conversation id: {conv!r}")
        led = core.read(adapters.raws(self.store(conv)), self.anchors_for(conv),
                        self.checked if checked is None else checked, conv, self.kinds)
        proj, flags = self.type.project(led)
        return led, proj, flags

    def roster_keys(self, led) -> dict[str, str]:
        """principal -> key, for the keys the register's roster entries added (and did not remove)."""
        out: dict[str, str] = {}
        removed = set()
        for i in led.order:
            e = led.valid[i]
            if e.kind == "roster":
                for a in e.data.get("add", []):
                    out[a["as"]] = a["key"]
                for r in e.data.get("remove", []):
                    removed.add(r["key"])
        return {p: k for p, k in out.items() if k not in removed}

    # ------------------------------------------------------------ writing

    def via(self, principal: str) -> dict | None:
        """`data.via` (ADR-0068, ADR-0070): the node signs for an HTTP client, and says so in every packet it signs
        on that client's behalf. None for everyone else."""
        if principal != FACILITATOR and self.state.roster().get(principal, {}).get("kind") == "http":
            return clients_mod.Clients(self.state).via(principal)
        return None

    def add(self, conv: str, principal: str, kind: str, data: dict) -> str:
        if principal != FACILITATOR:
            self.ensure_member_key(conv, principal)
        if kind in ("message", "status") and "via" not in data and (v := self.via(principal)):
            data = {**data, "via": v}
        try:
            i = adapters.add(self.store(conv), self.signer.signing_path(principal), self.as_principal(conv, principal), kind, data,
                             self.anchors_for(conv), checked=self.checked, register=conv, kinds=self.kinds)
        except core.Refused as e:
            raise RecordError(f"the record refused a {kind} by {principal}: {e}") from None
        if self.net is not None:
            self.net.push(conv)
        return i

    def ensure_member_key(self, conv: str, principal: str) -> None:
        """A member whose key changed since the conversation began (re-registered) is added again by the
        facilitator's roster entry, so its new key may write."""
        pub = self.signer.public(principal)
        if not pub:
            raise RecordError(f"{principal} has no key: facilitator register {principal}")
        led = core.read(adapters.raws(self.store(conv)), self.anchors_for(conv), self.checked, conv, self.kinds)
        keys = self.roster_keys(led)
        as_ = self.as_principal(conv, principal)
        if keys.get(as_) == pub:
            return
        change = {"add": [{"key": pub, "as": as_, "role": "agent"}]}
        if as_ in keys:
            change["remove"] = [{"key": keys[as_]}]
        self.add(conv, FACILITATOR, "roster", change)

    def create(self, kind: str, members: list[str], humans: list[str], title: str | None = None,
               remote: dict | None = None, node: str | None = None) -> str:
        """A new conversation: the facilitator's roster entry (every member's key), then its thread. `remote`:
        `handle.node` -> {node, key} of members on other nodes (their keys from admitted cards); the conversation
        is then shared with those nodes (`node` is this one), and every member is named `handle.node`."""
        self.facilitator_key()
        conv = new_id("c", 4)
        remote = remote or {}
        shared = bool(remote) and self.net is not None
        if shared:
            self.net.save_meta(conv, {(m if m in remote else f"{m}.{node}"): (remote[m]["node"] if m in remote else node)
                                      for m in members}, node)
        principal = (lambda m: m if m in remote else f"{m}.{node}") if shared else (lambda m: m)
        adds = []
        for m in members:
            pub = remote[m]["key"] if m in remote else self.signer.public(m)
            if not pub:
                raise RecordError(f"{m} has no key: facilitator register {m}")
            adds.append({"key": pub, "as": principal(m), "role": "agent"})
        self.add(conv, FACILITATOR, "roster", {"add": adds})
        thread = {"thread": conv, "kind": kind, "members": [principal(m) for m in members],
                  "humans": [principal(h) for h in humans if h in members]}
        if title:
            thread["title"] = title
        self.add(conv, FACILITATOR, "thread", thread)
        return conv
