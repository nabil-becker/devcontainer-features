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

Qualified handles (slice N3, ruling H5): an agent of another node is named `@<handle>.<node>`, for example
`@b1.spoke-b`. The separator is `.` because neither a handle (`[a-z0-9_-]`) nor a node id (`[a-z0-9-]`; a host
name's dots become `-`) can hold one, so the split is never ambiguous. In a conversation shared with other nodes
every member is a qualified principal; a bare `@b1` still reaches the one member whose handle is b1, and when
several members have that handle it is delivered to none of them, with a notice that lists their qualified names
(no guess, no precedence for this node's own). A `.word` after a mention whose word names no known node is
punctuation, as before (so a standalone node sees no change).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

MENTION_RE = re.compile(r"(?<![A-Za-z0-9_.@-])@([A-Za-z0-9][A-Za-z0-9_-]{0,63})(?:\.([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))?")
SEP = "."


def split(name: str) -> tuple[str, str | None]:
    """(handle, node) of `handle.node`; (name, None) for a bare handle."""
    h, sep, n = name.partition(SEP)
    return (h, n) if sep else (name, None)


def qualify(handle: str, node: str) -> str:
    return f"{handle}{SEP}{node}"


def mentions(text: str, nodes: set | frozenset = frozenset()) -> list[str]:
    """Every @mention, lower-cased, each once: `handle`, or `handle.node` when the node is one of `nodes` (else the
    dot was punctuation)."""
    out: list[str] = []
    for m in MENTION_RE.finditer(text or ""):
        h = m.group(1).lower()
        if m.group(2) and m.group(2) in nodes:
            h = qualify(h, m.group(2))
        if h not in out:
            out.append(h)
    return out


def match(name: str, members: list[str], me: str | None = None) -> list[str]:
    """The members a name (from `to` or a mention) names: itself; a qualified name of this node's own member,
    which is bare in a conversation this node keeps alone; or, for a bare handle, every member with that handle
    (more than one: ambiguous)."""
    if name in members:
        return [name]
    h, n = split(name)
    if n is not None:
        return [h] if n == me and h in members else []
    return [m for m in members if split(m)[0] == name]


@dataclass
class Decision:
    to: list[str]
    rule: str
    mentions: list[str] = field(default_factory=list)
    notices: list[tuple[str, str]] = field(default_factory=list)     # (code, text)


def route(thread: dict, messages: dict, author: str, text: str, to: list[str] | None = None,
          reply_to: str | None = None, fallback: str | None = None, known: set[str] | frozenset = frozenset(),
          me: str | None = None, nodes: set | frozenset = frozenset()) -> Decision:
    """Who a new message goes to. `thread`: the conversation's thread (kind, members); `messages`: its
    messages by id (for the asker of a reply); `known`: every registered handle (to tell a handle that
    is not in this conversation from one that does not exist); `me` and `nodes`: this node's id and every node
    it knows (qualified handles)."""
    members = list(thread["members"])
    named: list[str] = []
    for h in [x.lower().lstrip("@") for x in (to or [])] + mentions(text, nodes):
        if h not in named:
            named.append(h)
    notices: list[tuple[str, str]] = []
    if "all" in named:
        return Decision([m for m in members if m != author], "all", mentions(text, nodes))
    if named:
        out = []
        for name in named:
            got = match(name, members, me)
            if len(got) > 1:
                notices.append(("unknown-handle", f"@{name} names {len(got)} members: "
                                + ", ".join(f"@{g}" for g in sorted(got)) + "; the mention was not delivered (name one)"))
                continue
            h = got[0] if got else name
            if h == author:
                continue
            if h in members:
                if h not in out:
                    out.append(h)
            elif h in known:
                notices.append(("not-member", f"@{h} is not in this conversation; the mention was not delivered "
                                              f"(start a conversation with them: say with conversation new and to)"))
            else:
                notices.append(("unknown-handle", f"@{h} is no participant (who lists the handles); the mention was not delivered"))
        if out:
            return Decision(out, "mention", mentions(text, nodes), notices)
        if notices:
            return Decision([], "none", mentions(text, nodes), notices)
    if reply_to and reply_to in messages:
        asker = messages[reply_to]["from"]
        if asker != author and asker in members:
            return Decision([asker], "asker", mentions(text, nodes), notices)
    others = [m for m in members if m != author]
    if thread["kind"] == "direct":
        return Decision(others, "direct", mentions(text, nodes), notices)
    if fallback and fallback in others:
        return Decision([fallback], "fallback", mentions(text, nodes), notices)
    return Decision(others, "broadcast", mentions(text, nodes), notices)
