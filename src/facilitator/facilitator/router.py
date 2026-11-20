"""The router module, deterministic (proposal 4.4; no model before slice 6).

1. The `to` argument and every `@handle` in the text deliver to those members, each once; `@all` to
   every member of the conversation but the writer. "Hey @jester tell @domain-expert-one a joke" goes to
   both (the Operator's ruling of 2026-11-20; the first version delivered only to the addressed ones).
   Every mention is recorded in the message (`mentions`). The hop count bounds the chain. A model can
   never redirect a mention.
2. No mention, in a direct conversation: the other member. In a group: the participant that
   facilitator.yml names as `fallback` (when it is a member), else every member but the writer.
3. A reply with no mention goes to the asker: the writer of the message it answers. (Checked before 2.)
4. Stale participants are not skipped: the dispatcher keeps their delivery waiting (dispatcher.py).
5. Every message is in the transcript, whoever it was for.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

MENTION_RE = re.compile(r"(?<![A-Za-z0-9_.@-])@([A-Za-z0-9][A-Za-z0-9_-]{0,63})")


def mentions(text: str) -> list[str]:
    out: list[str] = []
    for m in MENTION_RE.finditer(text or ""):
        h = m.group(1).lower()
        if h not in out:
            out.append(h)
    return out


@dataclass
class Decision:
    to: list[str]
    rule: str
    mentions: list[str] = field(default_factory=list)
    notices: list[tuple[str, str]] = field(default_factory=list)     # (code, text)


def route(thread: dict, messages: dict, author: str, text: str, to: list[str] | None = None,
          reply_to: str | None = None, fallback: str | None = None, known: set[str] | frozenset = frozenset()) -> Decision:
    """Who a new message goes to. `thread`: the conversation's thread (kind, members); `messages`: its
    messages by id (for the asker of a reply); `known`: every registered handle (to tell a handle that
    is not in this conversation from one that does not exist)."""
    members = list(thread["members"])
    named: list[str] = []
    for h in [x.lower().lstrip("@") for x in (to or [])] + mentions(text):
        if h not in named:
            named.append(h)
    notices: list[tuple[str, str]] = []
    if "all" in named:
        return Decision([m for m in members if m != author], "all", mentions(text))
    if named:
        out = []
        for h in named:
            if h == author:
                continue
            if h in members:
                out.append(h)
            elif h in known:
                notices.append(("not-member", f"@{h} is not in this conversation; the mention was not delivered "
                                              f"(start a group with them: /new group ...)"))
            else:
                notices.append(("unknown-handle", f"@{h} is no participant (who: /who); the mention was not delivered"))
        if out:
            return Decision(out, "mention", mentions(text), notices)
        if notices:
            return Decision([], "none", mentions(text), notices)
    if reply_to and reply_to in messages:
        asker = messages[reply_to]["from"]
        if asker != author and asker in members:
            return Decision([asker], "asker", mentions(text), notices)
    others = [m for m in members if m != author]
    if thread["kind"] == "direct":
        return Decision(others, "direct", mentions(text), notices)
    if fallback and fallback in others:
        return Decision([fallback], "fallback", mentions(text), notices)
    return Decision(others, "broadcast", mentions(text), notices)
