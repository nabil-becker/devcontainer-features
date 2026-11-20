"""The record (proposal 4.6): one register-engine register of the `conversation` type per
conversation, in the volume; every entry a sign-packet packet signed by its writer's key.

The facilitator's key is the anchor (anchors): it writes each conversation's roster (the members'
keys) and its thread, routes and notices; each member writes its own messages and task states."""
from __future__ import annotations

import secrets
from pathlib import Path

from registerengine import adapters, core
from registerengine import registertypes

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


def new_id(prefix: str, n: int = 6) -> str:
    return f"{prefix}-{secrets.token_hex(n)}"


class Record:
    def __init__(self, state: State, signer: Signer):
        self.state = state
        self.signer = signer
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
        led = core.read(adapters.raws(self.store(conv)), self.anchors(), self.checked if checked is None else checked,
                        conv, self.kinds)
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

    def add(self, conv: str, principal: str, kind: str, data: dict) -> str:
        if principal != FACILITATOR:
            self.ensure_member_key(conv, principal)
        try:
            return adapters.add(self.store(conv), self.signer.signing_path(principal), principal, kind, data,
                                self.anchors(), checked=self.checked, register=conv, kinds=self.kinds)
        except core.Refused as e:
            raise RecordError(f"the record refused a {kind} by {principal}: {e}") from None

    def ensure_member_key(self, conv: str, principal: str) -> None:
        """A member whose key changed since the conversation began (re-registered) is added again by the
        facilitator's roster entry, so its new key may write."""
        pub = self.signer.public(principal)
        if not pub:
            raise RecordError(f"{principal} has no key: facilitator register {principal}")
        led = core.read(adapters.raws(self.store(conv)), self.anchors(), self.checked, conv, self.kinds)
        keys = self.roster_keys(led)
        if keys.get(principal) == pub:
            return
        change = {"add": [{"key": pub, "as": principal, "role": "agent"}]}
        if principal in keys:
            change["remove"] = [{"key": keys[principal]}]
        self.add(conv, FACILITATOR, "roster", change)

    def create(self, kind: str, members: list[str], humans: list[str], title: str | None = None) -> str:
        """A new conversation: the facilitator's roster entry (every member's key), then its thread."""
        self.facilitator_key()
        conv = new_id("c", 4)
        adds = []
        for m in members:
            pub = self.signer.public(m)
            if not pub:
                raise RecordError(f"{m} has no key: facilitator register {m}")
            adds.append({"key": pub, "as": m, "role": "agent"})
        self.add(conv, FACILITATOR, "roster", {"add": adds})
        thread = {"thread": conv, "kind": kind, "members": list(members), "humans": [h for h in humans if h in members]}
        if title:
            thread["title"] = title
        self.add(conv, FACILITATOR, "thread", thread)
        return conv
