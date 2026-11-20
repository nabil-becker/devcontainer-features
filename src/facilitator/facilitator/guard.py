"""The guard module (proposal 4.5): loops and cost, bounded in the layer, deterministic, from the record.

- Hop limit (hopLimit, 6): a message whose hops pass the limit is written, flagged and not delivered;
  the conversation pauses. Since 0.2.0 (the Operator's ruling of 2026-11-20, option A) a person's message
  counts as a hop like any other: it continues the chain of the conversation it is written in, and only
  `continue` (the MCP tool, a human-kind caller only) lets the held chain run another hopLimit. A
  person's message in a new conversation is still a new chain's root (hops 0).
- Message budget (messageBudget, 40 per conversation, counted since the last `continue`): a participant's
  message past it is written and held the same way. A person's message is not held by the budget.
- Rate (rateLimit, 10 a minute per participant): a message past it is refused, not written; a person's
  is not counted.
- Paused: after a hop-limit or budget hold, every message, a person's too, is written and held until a
  person calls `continue`.
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
    continue on a message of that chain to the held message's hops - 1 + hopLimit."""
    top = limits.hop_limit
    for c in conv["continues"]:
        m = conv["messages"].get(c["upto"])
        if m and m["root"] == root:
            top = max(top, m["hops"] - 1 + limits.hop_limit)
    return top


def paused(conv: dict) -> str:
    """'' when the conversation runs; else why it is paused (hop-limit | budget)."""
    why = ""
    for kind, ref in conv["events"]:
        if kind == "notice" and conv["notices"][ref]["code"] in ("hop-limit", "budget"):
            why = conv["notices"][ref]["code"]
        elif kind == "continue":
            why = ""
    return why


def since_continue(conv: dict) -> int:
    """Messages written since the last continue (or since the start)."""
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
    already in `conv` when this is called. A person's message (`human`) is held by a pause and by the hop
    limit like any other (option A), never by the budget."""
    why = paused(conv)
    # the paused state counts notices only before this message: a notice for this message comes after it
    if why:
        return Verdict(False, "paused", f"the conversation is paused ({why}); only a person's continue resumes it", hops)
    if hops > allowed_hops(conv, root, limits):
        return Verdict(False, "hop-limit", f"hop limit {limits.hop_limit} reached: this message ({hops} hops from the "
                                           f"person's that began the chain) is kept and not delivered; a person's "
                                           f"continue lets it run another {limits.hop_limit}", hops)
    if not human and since_continue(conv) > limits.message_budget:
        return Verdict(False, "budget", f"message budget {limits.message_budget} reached in this conversation; "
                                        "a person's continue lets it run another budget", hops)
    return Verdict(True, hops=hops)
