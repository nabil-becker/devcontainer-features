#!/usr/bin/env python3
"""The briefing (`devhost-briefing`): where the repository's records stand, with no model.

Usage: briefing.py [--json] [--no-refresh]

Says, in a few sentences: the ledger entries since the last review and whether a review is due
(`DEVHOST_REVIEW_EVERY`, 25 by default), what the backs left pending, how many backlog items and decisions for the
Operator are open, a warning when `gh` is not logged in or git has no GitHub credential helper (silent without gh),
a warning when local-features/devhost (or src/devhost) is newer than the installed devhost
(`$DEVHOST_SHARE/VERSION`), any night-shift report not yet reviewed, and the month-to-date agent spend
on this machine. Refreshes this month's cost report (`costs-YYYY-MM-<engineer>.md` in the ledger
directory) on the way, unless --no-refresh. The SessionStart hook prints it as --json, for the
inter's context and a one-line message; the entrypoint prints the text when stdin is a terminal.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import branches  # noqa: E402
import report  # noqa: E402
from devhost_common import (DECISIONS_HEADING, REVIEWED_MARKER, backlog_path, ledger_dir, month,  # noqa: E402
                            night_shift_dir, rel, review_every, repo_root, state_dir)

ENTRY = re.compile(r"^### (\d{4}-\d{2}-\d{2})", re.M)
REVIEW = re.compile(r"^## Review (\S+)", re.M)
FRICTION = re.compile(r"^- \*\*Friction:\*\*\s*(.*)$", re.M)
DEFAULT_SHARE = "/usr/local/share/devhost"  # where install.sh puts the share/ tree and its VERSION file


def ledger_status(root: Path) -> list[str]:
    folder = ledger_dir(root)
    files = sorted(folder.glob("[0-9][0-9][0-9][0-9]-[0-9][0-9].md")) if folder.is_dir() else []
    text = "".join(f.read_text(encoding="utf-8", errors="replace") + "\n" for f in files)
    reviews = list(REVIEW.finditer(text))
    since = text[reviews[-1].end():] if reviews else text
    entries = ENTRY.findall(since)
    friction = [f for f in FRICTION.findall(since) if not f.strip().lower().startswith("none")]
    where = f"the last review ({reviews[-1].group(1)})" if reviews else "the start (no review yet)"
    lines = [f"Ledger ({rel(root, folder)}/): {len(entries)} entries since {where}, {len(friction)} with friction."]
    if len(entries) >= review_every():
        lines.append("Review due: run /ledger-review (it reads the cost report first).")
    return lines


def pending(root: Path) -> list[str]:
    out = []
    state = state_dir()
    if not state.is_dir():
        return out
    for job in sorted(p for p in state.glob("*") if p.is_dir()):
        items = []
        for f in sorted(job.glob("pending-*"), key=lambda p: p.stat().st_mtime)[-1:]:
            text = f.read_text(encoding="utf-8", errors="replace").strip()
            if text:
                items.append(text)
        log = job / "job.log"
        if log.exists():
            last = log.read_text(encoding="utf-8", errors="replace").strip().splitlines()[-1:]
            if last and "status=pending" in last[0]:
                items.append(last[0].split("notice=", 1)[-1])
        if items:
            out.append(f"The {job.name} left something pending: " + "; ".join(dict.fromkeys(items)) + ".")
    return out


def backlog_status(root: Path) -> list[str]:
    path = backlog_path(root)
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    parts = text.split(DECISIONS_HEADING, 1)
    open_items = len(re.findall(r"^- \[ \]", parts[0], re.M))
    open_decisions = len(re.findall(r"^- \[ \]", parts[1], re.M)) if len(parts) > 1 else 0
    return [f"{rel(root, path)}: {open_items} open items, {open_decisions} decisions for the Operator."]


def night_shift_status(root: Path) -> list[str]:
    folder = night_shift_dir(root)
    waiting = sorted(p.stem for p in folder.glob("????-??-??.md")
                     if REVIEWED_MARKER not in p.read_text(encoding="utf-8", errors="replace")) if folder.is_dir() else []
    return [f"Night-shift report not yet reviewed: {', '.join(waiting)} (say 'morning report')."] if waiting else []


def branch_status(root: Path) -> list[str]:
    """One line when branches carry unfinished work, merged ones were left behind or a name breaks the rule."""
    try:
        line = branches.summary(branches.leftovers(root))
    except Exception:  # no gh, no network, no git: the briefing never fails a session start
        return []
    return [line] if line else []


GH_FIX = ("In a container terminal run `gh auth login --web --git-protocol https`, then `gh auth setup-git`.")


def _run(args: list[str], root: Path) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(args, cwd=str(root), capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None


def gh_auth(root: Path) -> list[str]:
    """One line when `gh` is installed but not logged in, or git has no credential helper for github.com.

    Silent when all is well and when gh is absent (the gh Feature is optional). The command is
    `DEVHOST_GH` when set, as in branches.py, so tests point it at a fake."""
    exe = shutil.which(os.environ.get("DEVHOST_GH", "").strip() or "gh")
    if not exe:
        return []
    status = _run([exe, "auth", "status"], root)
    if status is None:
        return []
    problems = []
    if status.returncode != 0:
        problems.append("gh is not logged in to GitHub")
    helpers = _run(["git", "config", "--get-all", "credential.https://github.com.helper"], root)
    generic = _run(["git", "config", "--get-all", "credential.helper"], root)
    if not any(p is not None and p.stdout.strip() for p in (helpers, generic)):
        problems.append("git has no credential helper for github.com")
    if not problems:
        return []
    return [f"GitHub writes (push, pull requests) will fail: {' and '.join(problems)}. {GH_FIX}"]


def _version(text: str) -> tuple[int, ...] | None:
    m = re.match(r"^\s*v?(\d+(?:\.\d+)*)", text)
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def stale_install(root: Path) -> list[str]:
    """One line when local-features/devhost (or src/devhost) is newer than the installed devhost (the backs run the installed one)."""
    share = Path(os.environ.get("DEVHOST_SHARE", "").strip() or DEFAULT_SHARE)
    try:
        installed = (share / "VERSION").read_text(encoding="utf-8").strip()
        meta = next(p for p in (root / "local-features" / "devhost" / "devcontainer-feature.json",
                                root / "src" / "devhost" / "devcontainer-feature.json") if p.is_file())
        source = str(json.loads(meta.read_text(encoding="utf-8"))["version"])
    except (OSError, ValueError, KeyError, TypeError, StopIteration):
        return []
    have, want = _version(installed), _version(source)
    if have is None or want is None or want <= have:
        return []
    return [f"devhost {installed} is installed, src has {source}: rebuild for the fixes to take effect."]


def briefing(root: Path, refresh: bool = True) -> str:
    this_month = month()
    lines = ledger_status(root) + stale_install(root) + pending(root) + backlog_status(root) + branch_status(root) + gh_auth(root) + night_shift_status(root)
    try:
        if refresh:
            report.write_report(root, this_month)
        lines.append(report.summary(root, this_month) + " Details: devhost-report.")
    except Exception as exc:  # the briefing never fails a session start
        lines.append(f"Agent spend not computed ({type(exc).__name__}).")
    return " ".join(lines)


def main(argv: list[str]) -> int:
    text = briefing(repo_root(), refresh="--no-refresh" not in argv)
    if "--json" in argv:
        print(json.dumps({"systemMessage": text,
                          "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
