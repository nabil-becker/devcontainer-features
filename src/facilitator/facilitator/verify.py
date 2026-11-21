"""`facilitator verify --conv <id> [--message <id>]` (proposal 4.7): a query over the record, not a new
format. register-engine reads the conversation's register (every packet's format, signature and chain,
and its writer on the roster: the key is the one registered for the principal it writes as), the type
flags what the conversation does not allow; then each message's lineage is walked, by `reply_to` and
`refs`, back to a human-signed root, checking at each hop: the parent exists, in this conversation or a
referenced one; the hops are one more than the parent's; the root is the parent's; a message past the
hop limit was not delivered unless a human continued it; every `ref` names a message that exists.
Exit 0 a good chain, 1 a break, 2 bad usage (NFR-11's exit codes)."""
from __future__ import annotations

from . import guard
from .record import RecordError


class Walker:
    def __init__(self, fac):
        self.fac = fac
        self.cache: dict[str, tuple] = {}
        self.problems: list[str] = []
        self.partial: list[str] = []

    def conv(self, c: str):
        if c not in self.cache:
            try:
                led, proj, flags = self.fac.record.read(c, checked=set())     # every signature checked afresh
            except RecordError as e:
                self.cache[c] = (None, None, {"error": str(e)})
                return self.cache[c]
            self.cache[c] = (led, proj, flags)
            if not self.fac.record.exists(c):
                self.problems.append(f"{c}: no such conversation")
            for i, (code, detail) in led.refused.items():
                self.problems.append(f"{c}: entry {i[:12]} refused: {code} {detail}".rstrip())
            for i, waits in led.held.items():
                self.problems.append(f"{c}: entry {i[:12]} held, waiting for {', '.join(w[:12] for w in waits)}")
            for f in led.unruled_forks:
                self.problems.append(f"{c}: a fork: {', '.join(x[:12] for x in f)}")
            for i, fs in flags.items():
                self.problems.append(f"{c}: entry {i[:12]}: {', '.join(fs)}")
        return self.cache[c]

    def not_copied(self, c: str, other: str) -> bool:
        """`other` is a conversation this node does not hold, named from `c`, a replica of a conversation shared
        with another node: not copied here by policy, which is not a break."""
        return (other != c and self.fac.net.active and self.fac.net.meta(c) is not None
                and not self.fac.record.exists(other))

    def walk(self, c: str, mid: str) -> list[str]:
        """The chain from one message to its root, one line per hop; problems are collected."""
        lines, seen = [], set()
        while True:
            led, proj, _ = self.conv(c)
            if proj is None or proj["thread"] is None:
                self.problems.append(f"{c}: no conversation (or no thread entry)")
                return lines
            m = proj["messages"].get(mid)
            if m is None:
                self.problems.append(f"{c}/{mid}: no such message")
                return lines
            if (c, mid) in seen:
                self.problems.append(f"{c}/{mid}: a loop in the lineage")
                return lines
            seen.add((c, mid))
            e = led.valid[m["entry"]]
            who = ""
            if self.fac.net.active:
                b = self.fac.net.binding(e.key)
                if b:
                    card = self.fac.net.cards(history=True)[b[0]]
                    who = (f"  {b[1]} spiffe://{card['card']['domain']}/node/{b[0]} ({b[2]}"
                           + (", revoked since; signed before" if card.get("revoked") else "") + ")")
                else:
                    who = f"  this node ({self.fac.mesh.node_id})"
            lines.append(f"{c}/{mid}  hops {m['hops']}  from {m['from']}  signed by {e.key[:28]}...{who}  entry {m['entry'][:12]}")
            for r in m.get("refs", []):
                if "message_id" in r and not self.not_copied(c, r["thread"]):
                    _, rp, _ = self.conv(r["thread"])
                    if rp is None or r["message_id"] not in rp["messages"]:
                        self.problems.append(f"{c}/{mid}: refs {r['thread']}/{r['message_id']}, which does not exist")
            top = guard.allowed_hops(proj, m["root"], self.fac.limits_for(self.fac.level_of_message(proj, mid)))
            routes = proj["routes"].get(mid, [])
            if m["hops"] > top and any(r["tasks"] for r in routes):
                self.problems.append(f"{c}/{mid}: delivered at {m['hops']} hops, past the limit {top}, with no continue")
            if m["hops"] == 0:
                if m["from"] not in proj["thread"]["humans"]:
                    self.problems.append(f"{c}/{mid}: the root is by {m['from']}, not by a human of the conversation")
                if m["root"] != mid:
                    self.problems.append(f"{c}/{mid}: a root that names another root")
                return lines
            if m.get("reply_to"):
                pc, pm = c, m["reply_to"]
            elif m.get("refs") and "message_id" in m["refs"][0]:
                pc, pm = m["refs"][0]["thread"], m["refs"][0]["message_id"]
            else:
                self.problems.append(f"{c}/{mid}: {m['hops']} hops and no parent (no reply_to, no refs)")
                return lines
            if self.not_copied(c, pc):
                # a replica (slice N3): the lineage leaves this node's copy into a conversation it is not a member
                # of, so not copied here by policy (copy member); said so, with where to verify the rest
                self.partial.append(f"{c}/{mid}: its parent {pc}/{pm} is not copied to this node (copy member); "
                                    f"verify it on {self.fac.net.meta(c).get('home')}")
                return lines
            _, pp, _ = self.conv(pc)
            parent = (pp or {}).get("messages", {}).get(pm) if pp else None
            if parent is None:
                self.problems.append(f"{c}/{mid}: its parent {pc}/{pm} does not exist (a broken reply_to or ref)")
                return lines
            if parent["hops"] != m["hops"] - 1:
                self.problems.append(f"{c}/{mid}: hops {m['hops']}, its parent's {parent['hops']} (want one more)")
            if parent["root"] != m["root"]:
                self.problems.append(f"{c}/{mid}: root {m['root']}, its parent's {parent['root']}")
            last = m.get("refs", [])[-1:] or [{}]
            if last[0].get("message_id") != m["root"]:
                self.problems.append(f"{c}/{mid}: the last ref is not the root {m['root']}")
            c, mid = pc, pm


def verify(fac, conv: str, message: str | None = None) -> dict:
    w = Walker(fac)
    led, proj, _ = w.conv(conv)
    chains = {}
    if proj is not None and proj["thread"] is not None:
        mids = [message] if message else list(proj["order"])
        for mid in mids:
            chains[mid] = w.walk(conv, mid)
    elif proj is not None:
        w.problems.append(f"{conv}: no thread entry")
    return {"conversation": conv, "ok": not w.problems, "messages": len(chains), "chains": chains,
            "problems": list(dict.fromkeys(w.problems)), "partial": list(dict.fromkeys(w.partial)),
            "entries": len(led.valid) if led is not None else 0}
