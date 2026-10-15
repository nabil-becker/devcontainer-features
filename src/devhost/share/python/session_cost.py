#!/usr/bin/env python3
"""What the agents cost, from Claude Code's own transcripts, with no model (`devhost-costs`).

Usage:
  session_cost.py [--since ISO] [--session ID]       the newest (or named) session of this
                                                      repository: total, by model, by con
  session_cost.py --measures FILE... [--since ISO] [--main N]
                                                      one line for a ledger entry's Measures
                                                      (the scribe job calls this)

Transcripts live under `$CLAUDE_CONFIG_DIR/projects/` (default `~/.claude/projects/`), in the
folder named after the repository's path with every character that is not a letter or digit
turned into "-" (`/workspaces/repo` -> `-workspaces-repo`), plus the folders of worktrees under
it. Each session is `<id>.jsonl`; its subagents (cons) are `<id>/subagents/agent-<id>.jsonl`,
with the agent's type in `agent-<id>.meta.json`. Only the usage, model, id and timestamp fields
are read, never message content.

Every price is a **list-price estimate**, not a charge: on a subscription it measures use. Each
model reply is priced once (a reply is written once per content block). Cache writes are priced
at their 5-minute or 1-hour rate when the transcript says which, else at the 1-hour rate, so
the estimate errs high. A model the table does not know is priced as Opus, for the same reason.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import repo_root  # noqa: E402

# The one price table, a LIST-PRICE ESTIMATE in USD per million tokens (input, output) by model
# family; the report and the briefing use it too. A model whose name holds none of these
# families is priced as "opus", the dearest, so the estimate errs high. Cache reads cost 0.1x
# input; cache writes 1.25x (5-minute) or 2x (1-hour) input. Update the numbers here only.
PRICES = {"opus": (5.0, 25.0), "sonnet": (3.0, 15.0), "haiku": (1.0, 5.0)}
PRICE_NOTE = ("list-price estimate (Opus $5/$25, Sonnet $3/$15, Haiku $1/$5 per million tokens "
              "in/out; unknown models priced as Opus), not a charge")


def family(model: str | None) -> str:
    for name in PRICES:
        if name in (model or "").lower():
            return name
    return "other"


def price(model: str | None) -> tuple[float, float]:
    return PRICES.get(family(model), PRICES["opus"])


def cost(usage: dict, model: str | None) -> float:
    pin, pout = price(model)
    split = usage.get("cache_creation") or {}
    w5, w1 = split.get("ephemeral_5m_input_tokens"), split.get("ephemeral_1h_input_tokens")
    if isinstance(w5, int) and isinstance(w1, int):
        writes = w5 * pin * 1.25 + w1 * pin * 2
    else:
        writes = usage.get("cache_creation_input_tokens", 0) * pin * 2
    return (usage.get("input_tokens", 0) * pin + writes
            + usage.get("cache_read_input_tokens", 0) * pin * 0.1
            + usage.get("output_tokens", 0) * pout) / 1e6


@dataclass
class Tally:
    replies: int = 0
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0
    cost: float = 0.0
    first: str = ""
    last: str = ""

    def add(self, usage: dict, model: str | None, ts: str) -> None:
        self.replies += 1
        self.input += usage.get("input_tokens", 0)
        self.output += usage.get("output_tokens", 0)
        self.cache_read += usage.get("cache_read_input_tokens", 0)
        self.cache_write += usage.get("cache_creation_input_tokens", 0)
        self.cost += cost(usage, model)
        if ts:
            self.first = min(self.first or ts, ts)
            self.last = max(self.last, ts)


@dataclass
class Reply:
    """One priced model reply: which transcript it came from, never what it said."""
    sid: str
    kind: str          # inter | con
    agent_type: str    # the con's type; "" for an inter session
    agent_id: str
    model: str
    ts: str
    usage: dict = field(default_factory=dict)

    @property
    def cost(self) -> float:
        return cost(self.usage, self.model)


def projects_dir() -> Path:
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return Path(config) / "projects"


def project_folders(root: Path | None = None) -> list[Path]:
    name = re.sub(r"[^A-Za-z0-9]", "-", str(root or repo_root()))
    base = projects_dir()
    if not base.is_dir():
        return []
    return sorted(p for p in base.iterdir() if p.is_dir() and (p.name == name or p.name.startswith(name + "-")))


def agent_type_of(transcript: Path) -> str:
    meta = transcript.with_name(transcript.name[: -len(".jsonl")] + ".meta.json")
    try:
        return str(json.loads(meta.read_text(encoding="utf-8")).get("agentType") or "agent")
    except (OSError, ValueError):
        return "agent"


def read_replies(path: Path, sid: str, kind: str, agent_type: str = "", agent_id: str = "") -> list[Reply]:
    """One Reply per model reply. A reply is written once per content block, and the earlier
    records can carry a partial output count, so the record with the most output tokens wins."""
    replies: dict = {}
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return []
    with handle:
        for line in handle:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            m = r.get("message") if isinstance(r.get("message"), dict) else {}
            if not isinstance(m.get("usage"), dict):
                continue
            key = m.get("id") or r.get("uuid") or len(replies)
            seen = replies.get(key)
            if seen is not None and seen.usage.get("output_tokens", 0) >= m["usage"].get("output_tokens", 0):
                continue
            ts = seen.ts if seen is not None else str(r.get("timestamp") or "")
            replies[key] = Reply(sid, kind, agent_type, agent_id, str(m.get("model") or "unknown"), ts, m["usage"])
    return list(replies.values())


def session_replies(main: Path) -> list[Reply]:
    """An inter session and its cons."""
    sid = main.name[: -len(".jsonl")]
    replies = read_replies(main, sid, "inter")
    for sub in sorted(glob.glob(str(main.with_suffix("") / "subagents" / "*.jsonl"))):
        p = Path(sub)
        replies += read_replies(p, sid, "con", agent_type_of(p), p.name[: -len(".jsonl")])
    return replies


def all_sessions(root: Path | None = None) -> list[Path]:
    return sorted((p for folder in project_folders(root) for p in folder.glob("*.jsonl")), key=lambda p: p.stat().st_mtime)


def tally(replies, key=lambda r: "all") -> dict[str, Tally]:
    out: dict[str, Tally] = {}
    for r in replies:
        out.setdefault(key(r), Tally()).add(r.usage, r.model, r.ts)
    return out


def money(x: float) -> str:
    return f"${x:.2f}"


def measures_line(files: list[str], since: str = "", main: int = 1) -> str:
    """One line for a ledger entry's Measures: the first `main` files are the worker's own
    transcript(s), the rest its cons'."""
    own, cons = [], []
    for i, name in enumerate(files):
        p = Path(name)
        rs = read_replies(p, "", "inter" if i < main else "con", "" if i < main else agent_type_of(p))
        rs = [r for r in rs if not since or r.ts >= since]
        (own if i < main else cons).extend(rs)
    parts = []
    if own:
        t = tally(own)["all"]
        models = ", ".join(f"{m} {money(v.cost)}" for m, v in sorted(tally(own, lambda r: r.model).items()))
        parts.append(f"{money(t.cost)} ({models}; {t.replies} replies, "
                     f"{t.input + t.cache_read + t.cache_write:,} tokens in, {t.output:,} out)")
    if cons:
        c = tally(cons)["all"]
        kinds = ", ".join(f"{k} {money(v.cost)}" for k, v in sorted(tally(cons, lambda r: f"{r.agent_type} on {r.model}").items()))
        parts.append(f"cons {money(c.cost)} ({kinds})")
    if not parts:
        return "no priced replies in this stretch"
    return "; ".join(parts) + "; list-price estimate"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--since", default="", help="only replies at or after this ISO timestamp (UTC)")
    p.add_argument("--session", help="a session id; default the newest session of this repository")
    p.add_argument("--measures", nargs="+", metavar="FILE", help="one Measures line for these transcripts")
    p.add_argument("--main", type=int, default=1, help="with --measures: how many of the files are the worker's own")
    a = p.parse_args(argv)
    if a.measures:
        print(measures_line(a.measures, a.since, a.main))
        return 0
    sessions = all_sessions()
    if a.session:
        sessions = [s for s in sessions if s.name == a.session + ".jsonl"]
    if not sessions:
        print("$0.00: no session transcript found under " + str(projects_dir()))
        return 0
    replies = [r for r in session_replies(sessions[-1]) if not a.since or r.ts >= a.since]
    total = tally(replies).get("all", Tally())
    print(f"{money(total.cost)} since {a.since or 'the session start'} ({total.replies} replies; {PRICE_NOTE})")
    for model, t in sorted(tally(replies, lambda r: r.model).items()):
        print(f"  model {model}: {money(t.cost)} ({t.replies} replies, {t.output:,} tokens out)")
    for who, t in sorted(tally(replies, lambda r: "inter" if r.kind == "inter" else f"con {r.agent_id} ({r.agent_type})").items()):
        print(f"  {who}: {money(t.cost)} ({t.replies} replies)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
