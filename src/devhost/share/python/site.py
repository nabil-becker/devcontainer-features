#!/usr/bin/env python3
"""The repository's homepage (`devhost-site`): one self-contained HTML page built from the tracked docs and records.

Usage: site.py [--out DIR] [--standalone] [--prs] [--root DIR]

Collects the repository's tracked files (their working-tree content) into one JSON document: the
backlog, the ledger, the cost headlines, the Features, the records (ADRs, proposals, night-shift
reports, journal), optionally the open pull requests, and every tracked `*.md`. Every string
passes the name guard (`devhost_common.redact_text`) before it is embedded. The data goes into the
page template (`templates/site/index.html`, at the placeholder `<!--SITE-DATA-->`) as
`<script type="application/json" id="site-data">`, with `<` escaped, so a document can never end
the script. The output is `DIR/index.html` (default `.devhost/site/` at the repository root).

By default it is a FRAGMENT (no doctype, html, head or body): the Claude artifact host wraps it.
With --standalone it is a full document for any other host (GitHub Pages, a file share). The
page fetches nothing; the data is in it. The same tree gives the same bytes, except `meta.generated`.
With --prs the open pull requests are added through `gh pr list`; if gh fails, the page says so in
`meta.notes` and goes on. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import (COST_REPORT, DECISIONS_HEADING, MONTHLY, REVIEWED_MARKER, adr_dir, backlog_path,  # noqa: E402
                            git, ledger_dir, night_shift_dir, review_every, read_text, redact_text, rel, repo_root,
                            tracked_files, write_text)

SCHEMA = 1
PLACEHOLDER = "<!--SITE-DATA-->"
TEMPLATE = Path(__file__).resolve().parent / "templates" / "site" / "index.html"
GROUPS = ("Product", "Way of working", "Records", "Proposals", "Model", "Skills", "Other")

ITEM = re.compile(r"^- \[([ xX])\] \*\*(\S+)\s+(.*?)\*\*\s*(?:\(([^)]*)\))?\.?\s*(.*)$")
ENTRY = re.compile(r"^### (\d{4}-\d{2}-\d{2})\s+(.*?)\s*$")
REVIEW = re.compile(r"^## Review (\S+)")
FIELD = re.compile(r"^- \*\*([^:*]+):\*\*\s*(.*)$")
COST = re.compile(r"\$(\d+(?:\.\d+)?)")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def first_heading(text: str, fallback: str) -> str:
    fenced = False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced and line.startswith("# "):
            return line[2:].strip()
    return fallback


def group_of(path: str) -> str:
    parts = path.split("/")
    name = parts[-1]
    if parts[0] == ".claude":
        return "Skills"
    if path.startswith("docs/model"):
        return "Model"
    if path.startswith("docs/proposals"):
        return "Proposals"
    if path.startswith(("docs/ledger", "docs/adr", "docs/night-shift", "docs/journal")) or path == "docs/iterations.md":
        return "Records"
    if path in ("LEXICON.md", "PROCESS.md", "TODO.md") or name.startswith("CLAUDE") or parts[0] == ".devhost":
        return "Way of working"
    if path in ("README.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md") or parts[0] in ("src", "bootstrap"):
        return "Product"
    return "Other"


def remote_url(root: Path) -> str | None:
    url = (git(root, "remote", "get-url", "origin") or "").strip()
    m = re.match(r"^(?:git@|ssh://git@|https?://(?:[^@/]*@)?)([^:/]+)[:/](.+?)(?:\.git)?/?$", url)
    return f"https://{m.group(1)}/{m.group(2)}" if m else None


def parse_todo(text: str) -> dict:
    sections: list[dict] = []
    for line in text.splitlines():
        if line.startswith("## "):
            sections.append({"name": line[3:].strip(), "items": []})
        elif sections and (m := ITEM.match(line)):
            done = m.group(1).lower() == "x"
            body = m.group(5).strip()
            done_on = None
            if done:
                dm = re.search(r"Done (\d{4}-\d{2}-\d{2})", body)
                done_on = dm.group(1) if dm else None
            am = re.search(r"Added (\d{4}-\d{2}-\d{2})", body)
            sections[-1]["items"].append({"id": m.group(2), "title": m.group(3).strip(), "owner": (m.group(4) or "").strip(),
                                          "done": done, "added": am.group(1) if am else None, "done_on": done_on, "text": body})
        elif sections and sections[-1]["items"] and line[:1] in (" ", "\t") and line.strip():
            sections[-1]["items"][-1]["text"] += " " + line.strip()
    return {"sections": sections}


def parse_ledger(files: list[tuple[str, str]]) -> dict:
    """`files`: (repo path, text) of the monthly files, oldest first."""
    entries: list[dict] = []
    last_review, since = None, 0
    seen: dict[str, int] = {}
    for path, text in files:
        current = None
        field = None
        for line in text.splitlines():
            m = REVIEW.match(line)
            if m:
                last_review, since, current = m.group(1), 0, None
                continue
            m = ENTRY.match(line)
            if m:
                base = slug(f"{m.group(1)} {m.group(2)}")[:80]
                seen[base] = seen.get(base, 0) + 1
                current = {"date": m.group(1), "title": m.group(2), "path": path,
                           "anchor": base if seen[base] == 1 else f"{base}-{seen[base]}",
                           "fields": {}, "cost": None, "corrected_by": None}
                entries.append(current)
                since += 1
                field = None
                continue
            if line.startswith("## ") or line.startswith("# "):
                current = None
                continue
            if current is None:
                continue
            m = FIELD.match(line)
            if m:
                field = m.group(1).strip()
                current["fields"][field] = m.group(2).strip()
            elif field and line.strip():
                current["fields"][field] += " " + line.strip()
    for i, e in enumerate(entries):
        cm = COST.search(e["fields"].get("Measures", ""))
        e["cost"] = float(cm.group(1)) if cm else None
        target = e["fields"].get("Corrects")
        if target:
            wanted = target.lower()
            for earlier in reversed(entries[:i]):
                if earlier["title"].lower() in wanted or f"{earlier['date']} {earlier['title']}".lower() in wanted:
                    earlier["corrected_by"] = e["title"]
                    earlier["corrected_by_anchor"] = e["anchor"]
                    break
    entries.reverse()
    return {"last_review": last_review, "entries_since_review": since, "entries": entries}


def parse_costs(files: list[tuple[str, str]]) -> list[dict]:
    out = []
    for path, text in files:
        m = COST_REPORT.match(path.rsplit("/", 1)[-1])
        head = next((ln.strip() for ln in text.splitlines() if ln.startswith("Total:")), "")
        out.append({"path": path, "engineer": m.group(2) if m else "", "month": m.group(1) if m else "", "headline": head})
    return sorted(out, key=lambda c: (c["month"], c["engineer"]), reverse=True)


def status_of(text: str) -> str:
    m = re.search(r"^Status:\s*(.+)$", text, re.M) or re.search(r"^\|\s*\*\*Status\*\*\s*\|\s*(.*?)\s*\|", text, re.M)
    return m.group(1).strip() if m else ""


def pr_checks(rollup) -> str | None:
    states = []
    for c in rollup or []:
        states.append(str(c.get("conclusion") or c.get("state") or c.get("status") or "").upper())
    if not states:
        return None
    if any(s in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED") for s in states):
        return "failing"
    if any(s in ("", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "EXPECTED") for s in states):
        return "pending"
    return "passing"


def open_prs(root: Path, notes: list[str]) -> list[dict] | None:
    fields = "number,title,url,headRefName,baseRefName,isDraft,statusCheckRollup"
    try:
        done = subprocess.run(["gh", "pr", "list", "--json", fields], cwd=str(root), capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=60)
        if done.returncode != 0:
            raise OSError(done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "gh failed")
        prs = json.loads(done.stdout or "[]")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        notes.append(f"Open pull requests not included: {exc}")
        return None
    return [{"number": p.get("number"), "title": p.get("title"), "url": p.get("url"), "head": p.get("headRefName"),
             "base": p.get("baseRefName"), "draft": bool(p.get("isDraft")), "checks": pr_checks(p.get("statusCheckRollup"))}
            for p in prs]


def collect(root: Path, with_prs: bool = False) -> dict:
    root = Path(root)
    notes: list[str] = []
    files = {rel(root, p): p for p in tracked_files(root) if p.is_file()}
    texts: dict[str, str] = {}

    def text(path: str) -> str:
        if path not in texts:
            texts[path] = read_text(files[path])
        return texts[path]

    ledger_prefix = rel(root, ledger_dir(root)) + "/"
    adr_prefix = rel(root, adr_dir(root)) + "/"
    night_prefix = rel(root, night_shift_dir(root)) + "/"
    backlog = rel(root, backlog_path(root))

    def under(prefix: str, pattern: re.Pattern) -> list[str]:
        return sorted(p for p in files if p.startswith(prefix) and "/" not in p[len(prefix):] and pattern.match(p[len(prefix):]))

    todo = parse_todo(text(backlog)) if backlog in files else {"sections": []}
    months = under(ledger_prefix, MONTHLY)
    ledger = parse_ledger([(p, text(p)) for p in months])
    costs = parse_costs([(p, text(p)) for p in under(ledger_prefix, COST_REPORT)])

    features = []
    for p in sorted(files):
        m = re.match(r"^src/([^/]+)/devcontainer-feature\.json$", p)
        if not m:
            continue
        try:
            meta = json.loads(text(p))
        except ValueError:
            notes.append(f"{p} is not valid JSON")
            continue
        features.append({"id": meta.get("id", m.group(1)), "name": meta.get("name", ""), "version": meta.get("version", ""),
                         "description": meta.get("description", ""), "summary": summary_of(meta.get("description", "")),
                         "docs": [d for d in sorted(files) if d.startswith(f"src/{m.group(1)}/") and d.endswith(".md")]})

    adrs = []
    for p in under(adr_prefix, re.compile(r"^(\d{4})-.*\.md$")):
        number = re.match(r"(\d{4})", p[len(adr_prefix):]).group(1)
        if number == "0000":
            continue
        t = text(p)
        dm = DATE.search(re.search(r"\*\*Date\*\*\s*\|\s*(.*?)\s*\|", t).group(1)) if re.search(r"\*\*Date\*\*\s*\|", t) else None
        title = re.sub(r"^ADR[- ]?\d+:\s*", "", first_heading(t, p))
        adrs.append({"number": number, "title": title, "status": status_of(t), "date": dm.group(0) if dm else None, "path": p})
    proposals = []
    for p in sorted(f for f in files if re.match(r"^docs/proposals/[^/]+\.md$", f) and not f.endswith("/README.md")):
        t = text(p)
        proposals.append({"title": first_heading(t, p), "status": status_of(t), "path": p})
    night = [{"date": p.rsplit("/", 1)[-1][:-3], "path": p, "reviewed": REVIEWED_MARKER in text(p)}
             for p in under(night_prefix, re.compile(r"^\d{4}-\d{2}-\d{2}\.md$"))]
    journal = [{"date": p.rsplit("/", 1)[-1][:-3], "path": p}
               for p in sorted(f for f in files if re.match(r"^docs/journal/\d{4}-\d{2}-\d{2}\.md$", f))]

    docs = []
    for p in sorted(f for f in files if f.endswith(".md")):
        try:
            t = text(p)
        except OSError:
            continue  # tracked but deleted in the working tree
        docs.append({"path": p, "title": first_heading(t, p.rsplit("/", 1)[-1]), "group": group_of(p), "text": t})
    docs.sort(key=lambda d: (GROUPS.index(d["group"]), d["path"]))

    prs = open_prs(root, notes) if with_prs else None
    attention = attention_of(todo, ledger, night, proposals, prs)
    branch = (git(root, "rev-parse", "--abbrev-ref", "HEAD") or "").strip() or None
    return {"schema": SCHEMA,
            "meta": {"repo": root.name, "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "branch": branch,
                     "commit": (git(root, "rev-parse", "--short", "HEAD") or "").strip() or None,
                     "dirty": bool((git(root, "status", "--porcelain", "--untracked-files=no") or "").strip()),
                     "remote_url": remote_url(root), "notes": notes},
            "attention": attention, "todo": todo, "ledger": ledger, "costs": costs, "features": features,
            "records": {"adrs": adrs, "proposals": proposals, "night_shift": night, "journal": journal},
            "prs": prs, "docs": docs}


# The first sentence: a full stop that is not an abbreviation's, followed by a capital, a bracket or the end.
FIRST_SENTENCE = re.compile(r"^.*?(?<!\b(?:e\.g|i\.e|etc))\.(?=\s+[A-Z(]|\s*$)", re.S)


def summary_of(description: str) -> str:
    """A Feature's description cut to its first whole sentence, for the Features table."""
    m = FIRST_SENTENCE.match(description)
    return m.group(0) if m else description


def attention_of(todo: dict, ledger: dict, night: list, proposals: list, prs: list | None) -> list[dict]:
    out = []
    decisions = DECISIONS_HEADING[3:].strip().lower()
    for s in todo["sections"]:
        if s["name"].lower() == decisions:
            out += [{"kind": "decision", "title": i["title"], "detail": i["text"], "target": "backlog"} for i in s["items"] if not i["done"]]
    for s in todo["sections"]:
        if s["name"].lower() != decisions:
            out += [{"kind": "operator-item", "title": i["title"], "detail": i["text"], "target": "backlog"}
                    for i in s["items"] if not i["done"] and "the operator" in [o.strip().lower() for o in i["owner"].split(",")]]
    out += [{"kind": "night-report", "title": f"Night-shift report {n['date']} not reviewed",
             "detail": "Say 'morning report' to walk through it.", "target": "d~" + n["path"].replace("/", "~")}
            for n in night if not n["reviewed"]]
    if ledger["entries_since_review"] >= review_every():
        out.append({"kind": "review-due", "title": "Ledger review due",
                    "detail": f"{ledger['entries_since_review']} entries since the last review ({ledger['last_review'] or 'none yet'}).",
                    "target": "ledger"})
    out += [{"kind": "proposal", "title": p["title"], "detail": p["status"], "target": "d~" + p["path"].replace("/", "~")}
            for p in proposals if p["status"].lower().startswith(("draft", "open"))]
    out += [{"kind": "pr", "title": f"#{p['number']} {p['title']}", "detail": f"{p['head']} into {p['base']}"
             + (" (draft)" if p["draft"] else ""), "target": p["url"]} for p in prs or []]
    return out


def redacted(value, root: Path):
    """The name guard over every string of the data, keys included."""
    if isinstance(value, str):
        return redact_text(value, root)
    if isinstance(value, list):
        return [redacted(v, root) for v in value]
    if isinstance(value, dict):
        return {redact_text(k, root): redacted(v, root) for k, v in value.items()}
    return value


def render(data: dict, standalone: bool = False) -> str:
    template = TEMPLATE.read_text(encoding="utf-8")
    if PLACEHOLDER not in template:
        raise SystemExit(f"{TEMPLATE} has no {PLACEHOLDER}")
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    page = template.replace(PLACEHOLDER, f'<script type="application/json" id="site-data">{blob}</script>', 1)
    if not standalone:
        return page
    cut = page.index("</style>") + len("</style>") if "</style>" in page else 0
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            + page[:cut] + "</head><body>" + page[cut:] + "</body></html>\n")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="devhost-site", description="Build the repository's homepage: one self-contained HTML page.")
    ap.add_argument("--out", help="output folder (default: .devhost/site/ at the repository root)")
    ap.add_argument("--standalone", action="store_true", help="a full HTML document, for a host that does not wrap the page")
    ap.add_argument("--prs", action="store_true", help="add the open pull requests (needs gh)")
    ap.add_argument("--root", help="the repository (default: DEVHOST_ROOT, else found from the current directory)")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve() if args.root else repo_root()
    out = Path(args.out) if args.out else root / ".devhost" / "site"
    data = redacted(collect(root, with_prs=args.prs), root)
    target = out / "index.html"
    write_text(target, render(data, args.standalone))
    print(f"{target} ({target.stat().st_size:,} bytes; {len(data['docs'])} docs, {len(data['attention'])} needing the Operator)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
