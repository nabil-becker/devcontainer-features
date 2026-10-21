#!/usr/bin/env python3
"""The shutdown readiness check (`devhost-shutdown-check`): is it safe to stop the devhost?

Usage: shutdown.py [--root DIR]      exit 0 when ready, 1 when any rule fails; one line per finding.

The rules (ADR-0015), each a function returning finding strings:

- `tree`: the working tree is clean: no modified, staged or untracked file (ignored files do not count).
- `pushed`: the current branch has an upstream and no commit the upstream lacks. No upstream, or a
  detached HEAD, is a finding: nothing says where the work would be safe.
- `locks`: no back's lock is held (`$DEVHOST_STATE/<job>/lock`, taken with flock and tested without
  blocking). A held tester lock is reported as a test run in progress.
- `pending`: no back has a stretch waiting to be logged: a non-empty `$DEVHOST_STATE/<job>/pending-<session>`
  file (the scribe writes what it held back there).
- `branches`: no branch has commits that add to main and no pull request ("unfinished work"; needs a
  logged-in `gh`, else skipped). A branch whose pull request merged and still exists is a note.
- `night_shift`: the newest report in the night-shift directory is not mid-plan. Mid-plan means its
  `Result:` line is missing or has no `Ended`, or an item still reads `: planned` (the shape in
  `docs/night-shift/README.md`; the night-shift skill fills the Result line when it stops).

Stashes are listed as a note, never a failure. The last turn of a session always leaves one more back
run behind: the `shutdown-devhost` skill waits for it before it runs this check again.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import fcntl
except ImportError:  # no flock on this platform: the lock rule cannot run
    fcntl = None

import branches as branch_rules
from devhost_common import git, night_shift_dir, rel, repo_root, state_dir

MAX_LISTED = 10


def _listed(lines: list[str]) -> str:
    shown = ", ".join(lines[:MAX_LISTED])
    return shown + (f", and {len(lines) - MAX_LISTED} more" if len(lines) > MAX_LISTED else "")


def tree(root: Path) -> list[str]:
    out = git(root, "status", "--porcelain")
    if out is None:
        return ["git status failed: cannot tell whether the working tree is clean"]
    lines = [line for line in out.splitlines() if line.strip()]
    untracked = [line[3:] for line in lines if line.startswith("??")]
    changed = [line[3:] for line in lines if not line.startswith("??")]
    findings = []
    if changed:
        findings.append(f"{len(changed)} changed file(s) not committed: {_listed(changed)}")
    if untracked:
        findings.append(f"{len(untracked)} untracked file(s): {_listed(untracked)}")
    return findings


def pushed(root: Path) -> list[str]:
    branch = (git(root, "branch", "--show-current") or "").strip()
    if not branch:
        return ["detached HEAD: no branch to be pushed"]
    upstream = git(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if upstream is None:
        return [f"branch {branch} has no upstream: nothing says it is pushed"]
    ahead = (git(root, "rev-list", "--count", "@{u}..HEAD") or "0").strip()
    if ahead != "0":
        return [f"branch {branch} has {ahead} commit(s) not pushed to {upstream.strip()}"]
    return []


def _held(lock: Path) -> bool:
    """True when another process holds the flock on `lock`; never blocks, never creates the file."""
    if fcntl is None:
        return False
    try:
        with open(lock, "rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(handle, fcntl.LOCK_UN)
    except OSError:
        return False
    return False


def _jobs(state: Path) -> list[Path]:
    return sorted(d for d in state.glob("*") if d.is_dir()) if state.is_dir() else []


def locks(root: Path) -> list[str]:
    findings = []
    for job in _jobs(state_dir()):
        if _held(job / "lock"):
            findings.append("a tester run is in progress (its lock is held)" if job.name == "tester"
                            else f"the {job.name} back is running (its lock is held)")
    return findings


def pending(root: Path) -> list[str]:
    findings = []
    for job in _jobs(state_dir()):
        waiting = [p for p in sorted(job.glob("pending-*")) if p.is_file() and p.stat().st_size > 0]
        if waiting:
            findings.append(f"the {job.name} back has {len(waiting)} stretch(es) waiting to be logged "
                            f"({', '.join(p.name for p in waiting[:3])})")
    return findings


def night_shift(root: Path) -> list[str]:
    folder = night_shift_dir(root)
    reports = sorted(p for p in folder.glob("*.md") if re.match(r"\d{4}-\d{2}-\d{2}\.md$", p.name)) if folder.is_dir() else []
    if not reports:
        return []
    newest = reports[-1]
    text = newest.read_text(encoding="utf-8", errors="replace")
    name = rel(root, newest)
    result = re.search(r"^Result:.*$", text, re.M)
    if result is None or "Ended" not in result.group(0):
        return [f"night shift {name} is mid-plan: its Result line is missing or has no Ended"]
    if re.search(r"^### .*: planned\s*$", text, re.M):
        return [f"night shift {name} has an item still planned"]
    return []


def _leftovers(root: Path) -> branch_rules.Leftovers | None:
    try:
        return branch_rules.leftovers(root)
    except Exception:  # never fails the check
        return None


def unfinished_branches(root: Path) -> list[str]:
    found = _leftovers(root)
    return [f"branch {name} has commits that add to main and no pull request (unfinished work)"
            for name in (found.unfinished if found else [])]


def notes(root: Path) -> list[str]:
    out = []
    found = _leftovers(root)
    for name in (found.merged if found else []):
        out.append(f"branch {name}: its pull request merged and it still exists (task devhost:branches PRUNE=1)")
    stashes = [s for s in (git(root, "stash", "list") or "").splitlines() if s.strip()]
    if stashes:
        out.append(f"{len(stashes)} stash(es): {_listed(stashes)}")
    return out


RULES = (tree, pushed, unfinished_branches, locks, pending, night_shift)


def run(root: Path) -> tuple[list[str], list[str]]:
    findings: list[str] = []
    for rule in RULES:
        findings.extend(rule(root))
    return findings, notes(root)


def main(argv: list[str]) -> int:
    root = repo_root()
    if "--root" in argv:
        root = Path(argv[argv.index("--root") + 1]).resolve()
    findings, extra = run(root)
    for line in findings:
        print(f"NOT READY {line}")
    for line in extra:
        print(f"note {line}")
    if findings:
        print(f"devhost-shutdown-check: {len(findings)} finding(s)")
        return 1
    print("devhost-shutdown-check: ready to stop")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
