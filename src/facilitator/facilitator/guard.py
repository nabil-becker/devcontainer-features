"""The guard module (proposal 4.5): loops and cost, bounded in the layer, deterministic, from the record.

- Hop limit (hopLimit, 6): a message whose hops pass the limit is written, flagged and not delivered;
  the conversation pauses. A human message resets hops (it starts a new chain); `/continue` lets the
  held chain run another hopLimit.
- Message budget (messageBudget, 40 per conversation, counted since the last `/continue`): a participant's
  message past it is written and held the same way. A human's message always goes through.
- Rate (rateLimit, 10 a minute per participant): a message past it is refused, not written.
- Paused: after a hop-limit or budget hold, every participant message is written and held until a
  human writes or continues.
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass


def _t(at: str) -> float:
    return dt.datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


@dataclass
class Limits:
    hop_limit: int = 6
    message_budget: int = 40
    rate_limit: int = 10


@dataclass
class Verdict:
    deliver: bool
    code: str = ""             # hop-limit | budget | paused | rate
    text: str = ""
    hops: int = 0


def allowed_hops(conv: dict, root: str, limits: Limits) -> int:
    """The highest hop count a message of the chain begun by `root` may have: hopLimit, raised by every
    /continue on a message of that chain to the held message's hops - 1 + hopLimit."""
    top = limits.hop_limit
    for c in conv["continues"]:
        m = conv["messages"].get(c["upto"])
        if m and m["root"] == root:
            top = max(top, m["hops"] - 1 + limits.hop_limit)
    return top


def paused(conv: dict) -> str:
    """'' when the conversation runs; else why it is paused (hop-limit | budget)."""
    why = ""
    humans = set(conv["thread"]["humans"]) if conv["thread"] else set()
    for kind, ref in conv["events"]:
        if kind == "notice" and conv["notices"][ref]["code"] in ("hop-limit", "budget"):
            why = conv["notices"][ref]["code"]
        elif kind == "continue":
            why = ""
        elif kind == "message" and conv["messages"][ref]["from"] in humans:
            why = ""
    return why


def since_continue(conv: dict) -> int:
    """Messages written since the last /continue (or since the start)."""
    last = None
    for n, (kind, _) in enumerate(conv["events"]):
        if kind == "continue":
            last = n
    return sum(1 for n, (kind, _) in enumerate(conv["events"]) if kind == "message" and (last is None or n > last))


def rate_ok(conv: dict, author: str, limits: Limits, now: float) -> bool:
    n = sum(1 for m in conv["messages"].values() if m["from"] == author and now - _t(m["at"]) < 60)
    return n < limits.rate_limit


def check(conv: dict, author: str, human: bool, hops: int, root: str, limits: Limits) -> Verdict:
    """Whether a message just written (its hops and root given) is delivered. The message itself is
    already in `conv` when this is called."""
    if human:
        return Verdict(True, hops=hops)
    why = paused(conv)
    # the paused state counts notices only before this message: a notice for this message comes after it
    if why:
        return Verdict(False, "paused", f"the conversation is paused ({why}); a human's message or /continue resumes it", hops)
    if hops > allowed_hops(conv, root, limits):
        return Verdict(False, "hop-limit", f"hop limit {limits.hop_limit} reached: this message ({hops} hops from the "
                                           f"human's) is kept and not delivered; /continue lets it run another "
                                           f"{limits.hop_limit}", hops)
    if since_continue(conv) > limits.message_budget:
        return Verdict(False, "budget", f"message budget {limits.message_budget} reached in this conversation; "
                                        "/continue lets it run another budget", hops)
    return Verdict(True, hops=hops)
