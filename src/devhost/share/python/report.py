#!/usr/bin/env python3
"""The monthly agent-cost report, per engineer (`devhost-report`); no model, no cost.

Usage: report.py [YYYY-MM] [--summary] [--stdout]
       report.py --log [N]        the last N lines of each job's log in the state directory

Covers every kind of agent run on this machine for the month: the inter sessions and their
cons, from Claude Code's transcripts (session_cost.py), and the backs, from the metrics line
each job run appends to `$DEVHOST_STATE/runs.jsonl` (one JSON object per line: `ts`, `job`,
`model`, `status` changed|nothing|pending|error, `undone`, `stakes`, `duration_s`,
`stretch_chars`, `cost_usd`, `output_tokens`; a missing field counts as zero). Writes
`<ledger dir>/costs-YYYY-MM-<engineer>.md`, committed with the ledger: numbers, models, session
and agent ids only, never content. With --summary it prints one line for the briefing instead.
Every figure is a list-price estimate, not a charge. The ledger review reads this report first.

Transcripts and run records live in volumes a rebuild can empty, so the report is built from a
store committed beside it, `costs-YYYY-MM-<engineer>.jsonl`: one line per priced reply or back
run (ids and numbers), merged with what this machine has, so regenerating never loses a month's
history. A `baseline` line carries figures whose records were lost before the store existed:
its tables add to the report's, and local records up to its `until` are already in it.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import session_cost as sc  # noqa: E402
from devhost_common import engineer, ledger_dir, month as this_month, rel, repo_root, state_dir, write_text  # noqa: E402

RUN_FIELDS = ("ts", "job", "model", "status", "undone", "stakes", "duration_s", "stretch_chars", "cost_usd", "output_tokens")


def back_runs(month: str) -> list[dict]:
    path = state_dir() / "runs.jsonl"
    runs = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return runs
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and str(r.get("ts", "")).startswith(month):
            runs.append(r)
    return runs


NO_CORRECTION = re.compile(r"^\s*none[\s.,;:!]*$", re.I)  # `Corrects: none` says the entry corrects nothing


def corrections(root: Path, month: str) -> int:
    path = ledger_dir(root) / f"{month}.md"
    if not path.exists():
        return 0
    text = path.read_text(encoding="utf-8", errors="replace")
    return sum(1 for v in re.findall(r"^- \*\*Corrects:\*\*(.*)$", text, re.M) if not NO_CORRECTION.match(v))


def m(x: float | None) -> str:
    return "-" if x is None else f"${x:.2f}"


def reply_key(r: sc.Reply) -> tuple:
    return (r.sid, r.agent_id, r.model, r.ts)


def run_key(r: dict) -> tuple:
    return (str(r.get("ts", "")), str(r.get("job", "")))


def store_path(root: Path, month: str) -> Path:
    return ledger_dir(root) / f"costs-{month}-{engineer(root)}.jsonl"


def read_store(root: Path, month: str) -> tuple[dict | None, list[sc.Reply], list[dict]]:
    baseline, replies, runs = None, [], []
    try:
        lines = store_path(root, month).read_text(encoding="utf-8").splitlines()
    except OSError:
        return baseline, replies, runs
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        if isinstance(rec.get("baseline"), dict):
            baseline = rec["baseline"]
        elif isinstance(rec.get("reply"), dict):
            replies.append(sc.Reply(**rec["reply"]))
        elif isinstance(rec.get("run"), dict):
            runs.append(rec["run"])
    return baseline, replies, runs


def collect(root: Path, month: str):
    """The month's records: the store's, plus this machine's that are newer than the baseline
    and not stored yet. Returns (baseline, replies, runs)."""
    baseline, replies, runs = read_store(root, month)
    until = str((baseline or {}).get("until", ""))
    seen_replies, seen_runs = {reply_key(r) for r in replies}, {run_key(r) for r in runs}
    for r in (r for s in sc.all_sessions(root) for r in sc.session_replies(s)):
        if r.ts.startswith(month) and r.ts > until and reply_key(r) not in seen_replies:
            seen_replies.add(reply_key(r))
            replies.append(r)
    for r in back_runs(month):
        if str(r.get("ts", "")) > until and run_key(r) not in seen_runs:
            seen_runs.add(run_key(r))
            runs.append({k: r[k] for k in RUN_FIELDS if k in r})
    replies.sort(key=lambda r: r.ts)
    runs.sort(key=lambda r: str(r.get("ts", "")))
    return baseline, replies, runs


def run_model(r: dict) -> str:
    return str(r.get("model") or "none")


def aggregate(replies: list[sc.Reply], runs: list[dict]) -> dict:
    """Every table of the report as additive numbers, so a baseline adds to it row by row."""
    agg: dict = {"sessions": {}, "cons": {}, "backs": {}, "models": {}, "days": {}}

    def model_row(fam: str) -> dict:
        return agg["models"].setdefault(fam, {"inters": 0.0, "cons": 0.0, "backs": 0.0, "n": 0, "out": 0})

    def day_row(day: str) -> dict:
        return agg["days"].setdefault(day, {"inters": 0.0, "cons": 0.0, "backs": 0.0})

    for r in replies:
        kind = "inters" if r.kind == "inter" else "cons"
        row = model_row(sc.family(r.model))
        row[kind] += r.cost
        row["n"] += 1
        row["out"] += r.usage.get("output_tokens", 0)
        day_row(r.ts[:10])[kind] += r.cost
        if r.kind == "inter":
            s = agg["sessions"].setdefault(r.sid, {"models": [], "replies": 0, "cost": 0.0, "first": r.ts, "last": r.ts})
            s["models"] = sorted(set(s["models"]) | {r.model})
            s["replies"] += 1
            s["cost"] += r.cost
            s["first"], s["last"] = min(s["first"], r.ts), max(s["last"], r.ts)
        else:
            c = agg["cons"].setdefault(f"{r.agent_type}|{r.model}", {"ids": [], "runs": 0, "replies": 0, "cost": 0.0})
            c["ids"] = sorted(set(c["ids"]) | {r.agent_id})
            c["replies"] += 1
            c["cost"] += r.cost
    for r in runs:
        cost = r.get("cost_usd", 0) or 0
        row = model_row(sc.family(run_model(r)))
        row["backs"] += cost
        row["n"] += 1
        row["out"] += r.get("output_tokens", 0) or 0
        day_row(str(r.get("ts", ""))[:10])["backs"] += cost
        b = agg["backs"].setdefault(str(r.get("job") or "unknown"), {
            "models": [], "runs": 0, "changed": 0, "nothing": 0, "pending": 0, "error": 0,
            "undone": 0, "stakes": 0, "cost": 0.0, "duration_s": 0.0, "stretch_chars": 0})
        b["models"] = sorted(set(b["models"]) | {run_model(r)})
        b["runs"] += 1
        if r.get("status") in ("changed", "nothing", "pending", "error"):
            b[r["status"]] += 1
        for k in ("undone", "stakes", "duration_s", "stretch_chars"):
            b[k] += r.get(k, 0) or 0
        b["cost"] += cost
    return agg


def add(agg: dict, tables: dict | None) -> dict:
    """agg plus a baseline's tables: numbers add, lists unite, first and last widen."""
    for table, rows in (tables or {}).items():
        if table not in agg or not isinstance(rows, dict):
            continue
        for key, row in rows.items():
            mine = agg[table].setdefault(key, {})
            for k, v in row.items():
                if isinstance(v, list):
                    mine[k] = sorted(set(mine.get(k, [])) | set(v))
                elif k in ("first", "last"):
                    have = mine.get(k) or v
                    mine[k] = min(have, v) if k == "first" else max(have, v)
                elif isinstance(v, (int, float)):
                    mine[k] = mine.get(k, 0) + v
    return agg


def con_runs(c: dict) -> int:
    return len(c.get("ids", [])) + c.get("runs", 0)  # a baseline counts runs it has no ids for


def tables(root: Path, month: str) -> dict:
    baseline, replies, runs = collect(root, month)
    return add(aggregate(replies, runs), (baseline or {}).get("tables"))


def totals(agg: dict) -> dict:
    return {
        "inters": sum(s.get("cost", 0) for s in agg["sessions"].values()),
        "sessions": len(agg["sessions"]),
        "cons": sum(c.get("cost", 0) for c in agg["cons"].values()),
        "con_runs": sum(con_runs(c) for c in agg["cons"].values()),
        "backs": sum(b.get("cost", 0) for b in agg["backs"].values()),
        "back_runs": sum(b.get("runs", 0) for b in agg["backs"].values()),
        "undone": sum(b.get("undone", 0) for b in agg["backs"].values()),
    }


def summary(root: Path, month: str) -> str:
    t = totals(tables(root, month))
    return (f"Agent spend {month} to date on this machine ({engineer(root)}), list-price estimate: "
            f"{m(t['inters'] + t['cons'] + t['backs'])} (inters {m(t['inters'])}, cons {m(t['cons'])}, "
            f"backs {m(t['backs'])} in {t['back_runs']} runs, {t['undone']} undone by guards; "
            f"{corrections(root, month)} ledger corrections).")


def report_path(root: Path, month: str) -> Path:
    return ledger_dir(root) / f"costs-{month}-{engineer(root)}.md"


def render_tables(root: Path, month: str, agg: dict) -> str:
    t = totals(agg)
    lines = [
        f"# Agent costs, {month}, {engineer(root)}",
        "",
        "Generated by `devhost-report` (and at every session start by the briefing) from this machine's",
        f"Claude Code transcripts and the backs' run records, kept in `{store_path(root, month).name}`",
        f"so a rebuild loses nothing. Every figure is a {sc.PRICE_NOTE}.",
        "Numbers and ids only. Read first by the ledger review: see \"What to look for\".",
        "Regenerated, never edited by hand.",
        "",
        f"Total: {m(t['inters'] + t['cons'] + t['backs'])}. Inter sessions: {m(t['inters'])} in {t['sessions']} sessions. "
        f"Cons: {m(t['cons'])} in {t['con_runs']} runs. "
        f"Backs: {m(t['backs'])} in {t['back_runs']} runs, {t['undone']} undone by guards. "
        f"Ledger corrections: {corrections(root, month)}.",
        "",
        "## By model",
        "",
        "| Model | Inters | Cons | Backs | Total | Replies or runs | Tokens out |",
        "|---|---|---|---|---|---|---|",
    ]
    for f, r in sorted(agg["models"].items()):
        i, c, b = r.get("inters", 0), r.get("cons", 0), r.get("backs", 0)
        lines.append(f"| {f} | {m(i)} | {m(c)} | {m(b)} | {m(i + c + b)} | {r.get('n', 0)} | {r.get('out', 0):,} |")
    lines += ["", "## Inter sessions", "", "| Session | Models | Replies | Cost | First | Last |", "|---|---|---|---|---|---|"]
    for sid, s in sorted(agg["sessions"].items(), key=lambda kv: kv[1].get("first", "")):
        lines.append(f"| {sid} | {', '.join(s.get('models', []))} | {s.get('replies', 0)} | {m(s.get('cost', 0))} | "
                     f"{s.get('first', '')[:16]} | {s.get('last', '')[:16]} |")
    lines += ["", "## Cons (subagents)", "",
              "| Agent type | Model | Runs | Replies | Cost | Per run |", "|---|---|---|---|---|---|"]
    for key, c in sorted(agg["cons"].items()):
        atype, _, model = key.partition("|")
        n = con_runs(c)
        lines.append(f"| {atype} | {model} | {n} | {c.get('replies', 0)} | {m(c.get('cost', 0))} | "
                     f"{m(c.get('cost', 0) / n if n else None)} |")
    lines += ["", "## Backs", "",
              "| Back | Model | Runs | Changed | Nothing | Pending | Error | Undone | Stakes | Cost | Per run | Per change | Avg s | Avg chars in |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for job, b in sorted(agg["backs"].items()):
        n, changed, cost = b.get("runs", 0), b.get("changed", 0), b.get("cost", 0)
        lines.append(
            f"| {job} | {', '.join(b.get('models', []))} | {n} | {changed} | {b.get('nothing', 0)} | "
            f"{b.get('pending', 0)} | {b.get('error', 0)} | {b.get('undone', 0)} | {b.get('stakes', 0)} | "
            f"{m(cost)} | {m(cost / n if n else None)} | {m(cost / changed if changed else None)} | "
            f"{b.get('duration_s', 0) / n if n else 0:.0f} | {b.get('stretch_chars', 0) / n if n else 0:.0f} |")
    lines += ["", "## By day", "", "| Day | Inters | Cons | Backs | Total |", "|---|---|---|---|---|"]
    for day, d in sorted(agg["days"].items()):
        i, c, b = d.get("inters", 0), d.get("cons", 0), d.get("backs", 0)
        lines.append(f"| {day} | {m(i)} | {m(c)} | {m(b)} | {m(i + c + b)} |")
    lines += [
        "",
        "## What to look for",
        "",
        "The point is right-sizing the models: each kind of work on the smallest model that does it",
        "well. At each review:",
        "",
        "- **A con type on a large model at a low cost per run**: bounded jobs that could run a tier",
        "  smaller; try it on the next brief and compare its entry's friction.",
        "- **Inter cost per session rising**: sessions read more than they need; look at the entries' friction",
        "  for missing pointers, tasks or skills.",
        "- **Back cost per change rising**, or high for one: its brief reads too much or its model is",
        "  oversized; trim the stretch or try a smaller model for that job.",
        "- **Nothing** runs a large share of a back's runs: it is woken too often; raise its threshold.",
        "- **Undone** above zero: it tried to change what it may only add to; tighten its brief.",
        "- **Ledger corrections**: the scribe got something wrong; read the corrected entries, adjust its brief.",
        "- **Stakes** frequent for one back: inters do not trust it to catch things; read what they asked.",
        "- **Error** runs: `devhost-report --log`.",
        "",
        "Each finding becomes one action in the review, like any other friction: a backlog item, a",
        "decision for the Operator, a change made now with its test, or no action with a reason.",
        "",
    ]
    return "\n".join(lines)


def render(root: Path, month: str) -> str:
    return render_tables(root, month, tables(root, month))


def job_log(n: int) -> str:
    out = []
    for log in sorted(state_dir().glob("*/job.log")):
        out.append(f"== {log.parent.name}")
        out += log.read_text(encoding="utf-8", errors="replace").splitlines()[-n:]
    return "\n".join(out) or f"no job runs recorded under {state_dir()}"


def write_report(root: Path, month: str) -> Path:
    """Stores this machine's new records, then writes the report from the store."""
    baseline, replies, runs = collect(root, month)
    lines = [json.dumps({"baseline": baseline}, sort_keys=True)] if baseline else []
    lines += [json.dumps({"reply": vars(r)}, sort_keys=True) for r in replies]
    lines += [json.dumps({"run": r}, sort_keys=True) for r in runs]
    if lines:
        write_text(store_path(root, month), "\n".join(lines) + "\n")
    out = report_path(root, month)
    write_text(out, render_tables(root, month, add(aggregate(replies, runs), (baseline or {}).get("tables"))))
    return out


def main(argv: list[str]) -> int:
    root = repo_root()
    if "--log" in argv:
        rest = argv[argv.index("--log") + 1:]
        print(job_log(int(rest[0]) if rest and rest[0].isdigit() else 3))
        return 0
    args = [a for a in argv if not a.startswith("--")]
    month = args[0] if args else this_month()
    if not re.fullmatch(r"\d{4}-\d{2}", month):
        print(f"not a month (YYYY-MM): {month}", file=sys.stderr)
        return 2
    if "--summary" in argv:
        print(summary(root, month))
        return 0
    if "--stdout" in argv:
        sys.stdout.write(render(root, month))
        return 0
    print(rel(root, write_report(root, month)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
