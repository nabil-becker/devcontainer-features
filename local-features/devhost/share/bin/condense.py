#!/usr/bin/env python3
"""Condense the new part of a Claude Code transcript for a back.

Usage: devhost-condense <transcript.jsonl> <from-byte-offset> [session|sub]

"session" reads a host session: the engineer's messages, the host's visible replies, which
tools ran (paths and commands, never their output), cons' hand-backs. "sub" reads a
subagent's own transcript (a con): the first message is the brief, later ones come from the
host, the replies are the con's. Thinking, tool output, attachments and bookkeeping records
are dropped, so a back reads a fraction of the session.

Prints the condensed text to stdout and, on the last line of stderr, the byte offset the
transcript was read up to. Stakes ("Stake for the librarian: ...") are lifted whole to the
top. One level only: a con's con is not followed.
"""
import json
import re
import sys

MAX_CHARS = 40000          # keep the latest part if the new stretch is longer
CLIP = 1500                # per message
# A stake: one line anyone leaves for a back, "Stake for the librarian: <what needs what>".
# Only a real one: not quoted in backticks, and no "<placeholder>" (the format itself, as the
# documents and replies quote it, is not a stake). It must stand on a line of its own: a
# stake mid-paragraph is missed, by design.
STAKE = re.compile(r"^[^\w`]*stake for (?:the )?([a-z]+)\W*:\s*(.+)$", re.I | re.M)
PLACEHOLDER = re.compile(r"<[a-z][a-z ]*>|^\W*$", re.I)
REMINDER = re.compile(r"<system-reminder[^>]*>.*?</system-reminder[^>]*>", re.S)
HANDBACK = re.compile(r"(Outcome:.*?)(?:</(?:agent-message|result|task-notification)>|\Z)", re.S)


def clip(text, n=CLIP):
    text = text.strip()
    return text if len(text) <= n else text[:n] + " [...]"


HAND_HEAD = re.compile(r"^[#*_\s>-]*(Outcome|Outputs?|Friction|For the repository|Decisions needed)\b", re.I | re.M)
KEEP = ("friction", "for the repository", "decisions needed")
HANDOFF_WHOLE = 3000       # a hand-off this short is kept as it is
HANDOFF_REST = 8000        # the rest of a longer one, after its key sections


def handoff(text):
    """A hand-off, with Friction, For the repository and Decisions needed never cut.

    Hand-offs put a long Outputs section first, so a plain clip loses exactly the sections the
    ledger is for. Over HANDOFF_WHOLE chars those three sections come first, in full, then
    the rest, clipped at HANDOFF_REST with a "[clipped N chars]" marker.
    """
    text = text.strip()
    if len(text) <= HANDOFF_WHOLE:
        return text
    marks = list(HAND_HEAD.finditer(text))
    if not marks:
        return clip_marked(text, HANDOFF_REST)
    pieces = [text[:marks[0].start()]]
    keep, rest = [], [pieces[0]]
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        (keep if m.group(1).lower() in KEEP else rest).append(text[m.start():end])
    rest = "".join(rest).strip()
    if not keep:
        return clip_marked(text, HANDOFF_REST)
    out = "\n".join(k.strip() for k in keep)
    return out + "\n[rest of the hand-off, key sections above]\n" + clip_marked(rest, HANDOFF_REST)


def clip_marked(text, n):
    text = text.strip()
    return text if len(text) <= n else text[:n] + f" [clipped {len(text) - n} chars]"


def blocks(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return content if isinstance(content, list) else []


def tool_line(block, answerer):
    name = block.get("name", "?")
    inp = block.get("input") or {}
    if name == "SubagentHandback":
        return f"{answerer} FINAL REPLY: " + handoff(str(inp.get("message", "")))
    for key in ("description", "file_path", "command", "skill", "prompt"):
        if key in inp and isinstance(inp[key], str):
            return f"[tool {name}: {clip(inp[key], 200)}]"
    return f"[tool {name}]"


def main():
    path, start = sys.argv[1], int(sys.argv[2])
    sub = len(sys.argv) > 3 and sys.argv[3] == "sub"
    asker, answerer = ("HOST", "CON") if sub else ("ENGINEER", "HOST")
    first_user = [start == 0]
    out = []
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read()
    end = start + len(data)
    seen = set()
    stakes = []

    def collect_stakes(who, text):
        for target, what in STAKE.findall(text):
            if PLACEHOLDER.search(what):
                continue
            stakes.append(f"STAKE for {target.lower()} (from {who}): {what.strip()}")

    def handbacks(text):
        # A con's reply reaches the host inside a notification or a meta user record.
        if "Outcome:" not in text or not re.search(r"task-notification|hand-?back|agent-message", text, re.I):
            return
        for hb in HANDBACK.findall(text):
            hb = re.sub(r"\n\s+", "\n", hb).strip()
            if hb not in seen:
                seen.add(hb)
                out.append("CON REPLY: " + handoff(hb))

    for raw in data.splitlines():
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        if rec.get("isSidechain") and not sub:
            continue
        kind_rec = rec.get("type")
        if kind_rec == "attachment":
            att = rec.get("attachment") or {}
            if att.get("type") == "queued_command":
                prompt = att.get("prompt") or ""
                if "humanTurn" in att or "'kind': 'human'" in str(att.get("origin")):
                    collect_stakes(asker.lower(), prompt)
                    out.append(f"{asker} (mid-turn): " + clip(REMINDER.sub("", prompt)))
                else:
                    handbacks(prompt)
            continue
        if kind_rec not in ("user", "assistant"):
            continue
        role = kind_rec
        meta = rec.get("isMeta")  # skill bodies, injected context: not the engineer's words
        for b in blocks((rec.get("message") or {}).get("content")):
            kind = b.get("type")
            if kind == "text":
                text = b.get("text", "")
                if role == "user":
                    handbacks(text)
                    text = REMINDER.sub("", text)
                    if text.lstrip().startswith(("<command-", "<local-command", "<task-notification")):
                        continue  # slash-command and notification bookkeeping
                    if not meta:
                        collect_stakes(asker.lower(), text)
                    if text.strip() and not meta:
                        if sub and first_user[0]:
                            out.append("BRIEF: " + clip(text, 3000))
                        else:
                            out.append(asker + ": " + clip(text))
                        first_user[0] = False
                else:
                    collect_stakes(answerer.lower(), text)
                    if text.strip():
                        out.append(answerer + ": " + clip(text))
            elif kind == "tool_use" and role == "assistant":
                out.append(tool_line(b, answerer))
    text = "\n".join(out)
    if len(text) > MAX_CHARS:
        text = "[earlier part of this stretch omitted]\n" + text[-MAX_CHARS:]
    if stakes:  # always kept whole and first, so no back misses one
        text = "STAKES (explicit requests for backs):\n" + "\n".join(dict.fromkeys(stakes)) + "\n\n" + text
    sys.stdout.write(text)
    sys.stderr.write(f"{end}\n")


if __name__ == "__main__":
    main()
