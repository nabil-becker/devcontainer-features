#!/usr/bin/env python3
"""Branches named for the work (`devhost-branches`): the rule, the list, the cleanup, the push check.

Usage:
  branches.py new <backlog-id> [type]   create <type>/<backlog-id>/<n> from origin/main and switch to it
  branches.py [--prune] [--no-fetch]    list every local and remote branch; --prune deletes the finished ones
  branches.py --check-push [remote url] the pre-push hook: reads git's stdin lines, exit 1 on a refusal

The rule (decided 2026-10-20): every branch is `<type>/<backlog-id>/<n>`. `<type>` is one of
`feature`, `fix`, `docs`, `chore`; `<backlog-id>` is an id in the backlog (the word after `**`
in `TODO.md`, ticked or not); `<n>` is the workstream number, always present, from 1 (a parallel
stream on the same item, such as a subagent in a worktree, takes the next number). `main`, `HEAD`
and tags are exempt. A branch covering several items is named for the main one; the pull request
lists all ids; commits name their own. Work with no item gets one first (the backs' records use
the standing item `records`).

Why: a branch's work items are visible from its name, and branches left behind were unfinished
workflows: work pushed with no pull request, a push to a branch whose pull request had merged
(GitHub recreates it and its commits miss `main`), local branches never deleted after a merge.

What a branch "adds" is what a merge into the base (`origin/main`, else `main`) would change:
`git merge-tree --write-tree <base> <branch>`, then `git diff --shortstat <base> <tree>`. A squash
merge hides a branch from `git branch --merged` but not from this: the tree equals the base's and
the branch adds nothing. When main has moved on over the same lines since, a squash-merged
branch "still adds" their older form; a branch whose every ref is the head commit of one of its
merged pull requests counts as merged anyway, since that commit is exactly what was merged (a
commit after the merge keeps it). `--prune` deletes, locally and on `origin`, only a branch that
adds nothing, or sits at a merged pull request's head, and whose pull request merged (or that is
contained in the base), never the current branch, `main` or a branch that still adds something,
and removes the worktree of a branch it deletes. Pull request states come from `gh` (command overridable with `DEVHOST_GH`) in one call;
without a logged-in `gh` they are "unknown" and only a branch contained in the base is pruned.

GitHub note: renaming a branch on GitHub CLOSES the pull requests whose head is that branch
(found 2026-10-20: #9 and #29 closed and had to be reopened as #30 and #31). A branch with an open
pull request is renamed by pushing the new name, opening a new pull request that says it replaces
the old one, and closing the old one.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import backlog_path, base_ref, repo_root  # noqa: E402

REMOTE = "origin"
TYPES = ("feature", "fix", "docs", "chore")
EXEMPT = ("main", "HEAD")
NAME = re.compile(r"^(" + "|".join(TYPES) + r")/([a-z0-9][a-z0-9-]*)/(\d+)$")
ITEM = re.compile(r"^- \[[ xX]\] \*\*(\S+)\s+(.*?)\*\*", re.M)
ZERO = re.compile(r"^0+$")
RULE = "<type>/<backlog-id>/<n> (type: " + ", ".join(TYPES) + "; the id from TODO.md; n from 1)"


class Branch(NamedTuple):
    name: str
    local: bool
    remote: bool
    refs: tuple[str, ...]
    ahead: int  # commits not on the base, the most any ref has
    adds: str | None  # "nothing", a shortstat, or None when it could not be told
    pr: str | None  # "none", "open", "merged", "closed", or None when unknown
    current: bool
    worktree: str | None
    at_merged_head: bool = False  # every ref is the head commit of a merged pull request


class Leftovers(NamedTuple):
    unfinished: list[str]  # commits that add something, no pull request
    merged: list[str]  # pull request merged, branch still there
    badnames: list[str]  # names that break the rule
    pr_known: bool


def _run(root: Path, *args: str) -> tuple[int, str]:
    try:
        done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
    except OSError:
        return 127, ""
    return done.returncode, done.stdout


def _root() -> Path:
    if os.environ.get("DEVHOST_ROOT", "").strip():
        return repo_root()
    code, out = _run(Path.cwd(), "rev-parse", "--show-toplevel")
    return Path(out.strip()) if code == 0 and out.strip() else repo_root()


def items(root: Path) -> dict[str, str]:
    """Backlog id -> title, ticked or not; empty when there is no backlog."""
    path = backlog_path(root)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    return {m.group(1): m.group(2).strip() for m in ITEM.finditer(text)}


def parse(name: str) -> tuple[str, str, int] | None:
    m = NAME.match(name)
    return (m.group(1), m.group(2), int(m.group(3))) if m else None


def next_n(names: list[str], item: str) -> int:
    """The next free workstream number of `item` over every branch name (any type)."""
    taken = [p[2] for p in map(parse, names) if p and p[1] == item]
    return max(taken, default=0) + 1


# ---- gh -------------------------------------------------------------------------------------

def _gh(*args: str) -> list | None:
    exe = shutil.which(os.environ.get("DEVHOST_GH", "").strip() or "gh")
    if not exe:
        return None
    try:
        done = subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=30)
        return json.loads(done.stdout) if done.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def _state(states: list[str]) -> str:
    for wanted in ("OPEN", "MERGED", "CLOSED"):
        if wanted in states:
            return wanted.lower()
    return "none"


def pr_rows(root: Path, use_gh: bool = True) -> list | None:
    """Every pull request's head branch, state and head commit (one `gh` call); None when `gh` is
    unavailable, not logged in or offline."""
    if not use_gh:
        return None
    return _gh_in(root, "pr", "list", "--state", "all", "--limit", "1000", "--json", "headRefName,state,headRefOid")


def merged_heads(rows: list | None) -> dict[str, set[str]]:
    """Branch name -> the head commits of its merged pull requests."""
    heads: dict[str, set[str]] = {}
    for row in rows or []:
        if str(row.get("state", "")) == "MERGED" and row.get("headRefOid"):
            heads.setdefault(row.get("headRefName", ""), set()).add(str(row["headRefOid"]))
    return heads


def pr_states(root: Path, use_gh: bool = True, rows: list | None = None) -> dict[str, str] | None:
    """Branch name -> "open" / "merged" / "closed" for every branch that ever had a pull request;
    None when `gh` is unavailable, not logged in or offline."""
    rows = pr_rows(root, use_gh) if rows is None else rows
    if rows is None:
        return None
    seen: dict[str, list[str]] = {}
    for row in rows:
        seen.setdefault(row.get("headRefName", ""), []).append(str(row.get("state", "")))
    return {name: _state(states) for name, states in seen.items()}


def _gh_in(root: Path, *args: str) -> list | None:
    cwd = os.getcwd()
    try:
        os.chdir(root)
        return _gh(*args)
    except OSError:
        return None
    finally:
        os.chdir(cwd)


def pr_state_of(root: Path, name: str) -> str | None:
    rows = _gh_in(root, "pr", "list", "--state", "all", "--head", name, "--json", "number,state")
    return None if rows is None else _state([str(r.get("state", "")) for r in rows])


# ---- gathering --------------------------------------------------------------------------------

def fetch(root: Path) -> None:
    _run(root, "fetch", "--prune", "--quiet", REMOTE)


def _worktrees(root: Path) -> dict[str, str]:
    """Branch name -> path, for every linked worktree (the main one is left out)."""
    code, out = _run(root, "worktree", "list", "--porcelain")
    found: dict[str, str] = {}
    if code != 0:
        return found
    blocks = [b for b in out.split("\n\n") if b.strip()]
    for block in blocks[1:]:
        path = branch = None
        for line in block.splitlines():
            if line.startswith("worktree "):
                path = line[len("worktree "):]
            elif line.startswith("branch refs/heads/"):
                branch = line[len("branch refs/heads/"):]
        if path and branch:
            found[branch] = path
    return found


def branch_refs(root: Path) -> dict[str, list[str]]:
    """Branch name -> its refs (`refs/heads/x`, `refs/remotes/origin/x`), the exempt ones left out."""
    code, out = _run(root, "for-each-ref", "--format=%(refname)", "refs/heads", f"refs/remotes/{REMOTE}")
    names: dict[str, list[str]] = {}
    for ref in out.splitlines() if code == 0 else []:
        name = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref[len(f"refs/remotes/{REMOTE}/"):]
        if name == "HEAD" or not name:
            continue
        names.setdefault(name, []).append(ref)
    return names


def adds(root: Path, base: str, ref: str) -> str | None:
    """What merging `ref` into `base` would change: "nothing" or a shortstat; None when it cannot be told."""
    code, out = _run(root, "merge-tree", "--write-tree", base, ref)
    tree = out.splitlines()[0].strip() if out.strip() else ""
    if code not in (0, 1) or not re.fullmatch(r"[0-9a-f]{40,64}", tree):
        return None
    code, stat = _run(root, "diff", "--shortstat", base, tree)
    if code != 0:
        return None
    return stat.strip() or "nothing"


def gather(root: Path, use_gh: bool = True) -> list[Branch]:
    base = base_ref(root)
    rows = pr_rows(root, use_gh)
    states = pr_states(root, use_gh, rows)
    heads = merged_heads(rows)
    work = _worktrees(root)
    current = _run(root, "branch", "--show-current")[1].strip()
    out = []
    for name, refs in sorted(branch_refs(root).items()):
        ahead, found = 0, []
        for ref in refs:
            n = _run(root, "rev-list", "--count", f"{base}..{ref}")[1].strip() if base else "0"
            ahead = max(ahead, int(n) if n.isdigit() else 0)
            found.append(adds(root, base, ref) if base else None)
        added = None if None in found else next((a for a in found if a != "nothing"), "nothing")
        pr = None if states is None else states.get(name, "none")
        tips = {_run(root, "rev-parse", ref)[1].strip() for ref in refs}
        at_head = bool(heads.get(name)) and tips <= heads[name]
        out.append(Branch(name, any(r.startswith("refs/heads/") for r in refs),
                          any(r.startswith("refs/remotes/") for r in refs), tuple(refs), ahead, added, pr,
                          name == current, work.get(name), at_head))
    return out


def leftovers(root: Path, use_gh: bool = True, branches: list[Branch] | None = None) -> Leftovers:
    """The counts the briefing and the shutdown check report."""
    branches = gather(root, use_gh) if branches is None else branches
    unfinished, merged, bad = [], [], []
    known = any(b.pr is not None for b in branches) or not branches
    for b in branches:
        if b.name in EXEMPT:
            continue
        if parse(b.name) is None:
            bad.append(b.name)
        if b.pr == "merged":
            merged.append(b.name)
        elif b.pr == "none" and b.ahead > 0 and b.adds != "nothing":
            unfinished.append(b.name)
    return Leftovers(unfinished, merged, bad, known)


def summary(found: Leftovers) -> str:
    """The briefing's line, empty when there is nothing to say."""
    parts = []
    if found.unfinished:
        parts.append(f"{len(found.unfinished)} with work and no pull request")
    if found.merged:
        parts.append(f"{len(found.merged)} merged and not deleted")
    if found.badnames:
        parts.append(f"{len(found.badnames)} named against the rule")
    if not parts:
        return ""
    tail = "" if found.pr_known else "; pull requests not checked (gh unavailable)"
    return "Branches: " + ", ".join(parts) + f" (task devhost:branches){tail}."


# ---- the commands -----------------------------------------------------------------------------

def describe(b: Branch, backlog: dict[str, str]) -> str:
    parsed = parse(b.name)
    if b.name in EXEMPT:
        item = "base branch"
    elif parsed is None:
        item = "name breaks the rule"
    elif parsed[1] in backlog:
        item = f'{parsed[1]}: {backlog[parsed[1]]}'
    else:
        item = "not an item"
    where = "+".join(w for w, on in (("local", b.local), ("remote", b.remote)) if on)
    pr = "unknown" if b.pr is None else b.pr
    added = "unknown" if b.adds is None else b.adds
    mark = " (current)" if b.current else ""
    return f"{b.name}{mark}  [{where}]  {item}  | PR {pr}  | adds {added}"


def listing(branches: list[Branch], backlog: dict[str, str]) -> list[str]:
    return [describe(b, backlog) for b in branches] or ["no branches"]


def keep_reason(b: Branch) -> str | None:
    """None when the branch may be deleted, else why it stays."""
    if b.name in EXEMPT:
        return "the base branch"
    if b.current:
        return "it is the current branch"
    if b.adds is None:
        return "what it adds could not be told"
    if b.adds != "nothing" and not (b.pr == "merged" and b.at_merged_head):
        return f"it still adds to main ({b.adds})"
    if b.pr == "open":
        return "its pull request is open"
    if b.pr == "merged":
        return None
    if b.worktree:
        return f"checked out in a worktree and its pull request is {b.pr or 'unknown'} (a fresh branch looks empty)"
    if b.ahead == 0:
        return None
    return "its pull request has not merged" if b.pr is not None else "its pull request state is unknown"


def prune(root: Path, use_gh: bool = True) -> list[str]:
    out = []
    for b in gather(root, use_gh):
        why = keep_reason(b)
        if why:
            if b.name not in EXEMPT:
                out.append(f"kept {b.name}: {why}")
            continue
        if b.worktree:
            code, _ = _run(root, "worktree", "remove", b.worktree)
            if code != 0:
                out.append(f"kept {b.name}: its worktree {b.worktree} could not be removed (changes in it?)")
                continue
        done = []
        if b.local:
            if _run(root, "branch", "-D", b.name)[0] == 0:
                done.append("local")
            else:
                out.append(f"kept {b.name}: git branch -D failed")
                continue
        if b.remote:
            code, _ = _run(root, "push", "--quiet", REMOTE, "--delete", b.name)
            done.append("remote" if code == 0 else "remote delete FAILED")
        what = ", adds nothing" if b.adds == "nothing" else ", at its merged pull request's head"
        out.append(f"deleted {b.name} ({', '.join(done)}): " + ("pull request merged" if b.pr == "merged" else "contained in main")
                   + what + (f", worktree {b.worktree} removed" if b.worktree else ""))
    return out or ["nothing to prune"]


def new_branch(root: Path, item: str, kind: str = "feature") -> tuple[int, str]:
    if kind not in TYPES:
        return 2, f"type {kind!r} is not one of {', '.join(TYPES)}"
    backlog = items(root)
    if item not in backlog:
        return 2, (f"{item!r} is not an item in {backlog_path(root).name}: add the item first "
                   f"(records of the backs use the standing item `records`)")
    fetch(root)
    base = f"{REMOTE}/main"
    if _run(root, "rev-parse", "--verify", "--quiet", base)[0] != 0:
        base = base_ref(root) or "main"
    name = f"{kind}/{item}/{next_n(list(branch_refs(root)), item)}"
    code, _ = _run(root, "switch", "--no-track", "-c", name, base)
    if code != 0:
        return 1, f"git switch -c {name} {base} failed"
    return 0, f"on {name}, from {base}"


# ---- the pre-push hook ------------------------------------------------------------------------

def check_push(root: Path, lines: list[str], gh_state=pr_state_of) -> list[str]:
    """Refusals for the ref updates git hands the pre-push hook ("<local ref> <local sha> <remote ref> <remote sha>")."""
    problems = []
    backlog = items(root)
    for line in lines:
        parts = line.split()
        if len(parts) < 3 or not parts[2].startswith("refs/heads/"):
            continue  # tags and other refs are exempt
        if ZERO.match(parts[1]):
            continue  # deleting a remote branch is always allowed
        name = parts[2][len("refs/heads/"):]
        if name in EXEMPT:
            continue
        parsed = parse(name)
        if parsed is None:
            problems.append(f"refusing to push {name}: the name breaks the rule {RULE}; "
                            f"fix: task devhost:branch -- <backlog-id>, then git cherry-pick or git branch -m")
            continue
        if backlog and parsed[1] not in backlog:
            problems.append(f"refusing to push {name}: {parsed[1]!r} is not an item in {backlog_path(root).name}; "
                            f"fix: add the item, or rename the branch to an existing id")
            continue
        state = gh_state(root, name)
        if state is None:
            print(f"devhost-branches: warning: gh unavailable, not checking whether {name} has a merged pull request",
                  file=sys.stderr)
        elif state == "merged":
            names = list(branch_refs(root))
            problems.append(f"refusing to push {name}: its pull request merged, so a push recreates the branch and its "
                            f"commits miss main; fix: new branch from origin/main named {parsed[0]}/{parsed[1]}/"
                            f"{next_n(names, parsed[1])} (task devhost:branch -- {parsed[1]} {parsed[0]}), "
                            f"then git cherry-pick the new commits")
    return problems


def main(argv: list[str]) -> int:
    root = _root()
    if "--check-push" in argv:
        problems = check_push(root, sys.stdin.read().splitlines())
        for p in problems:
            print(f"pre-push: {p}", file=sys.stderr)
        return 1 if problems else 0
    if argv[:1] == ["new"]:
        if len(argv) not in (2, 3):
            print("usage: devhost-branches new <backlog-id> [feature|fix|docs|chore]", file=sys.stderr)
            return 2
        code, message = new_branch(root, argv[1], argv[2] if len(argv) == 3 else "feature")
        print(message, file=sys.stderr if code else sys.stdout)
        return code
    if "--prune" in argv:
        if "--no-fetch" not in argv:
            fetch(root)
        print("\n".join(prune(root)))
        return 0
    if "--no-fetch" not in argv:
        fetch(root)
    branches = gather(root)
    print("\n".join(listing(branches, items(root))))
    found = leftovers(root, branches=branches)
    print(summary(found) or "Branches: all finished work is merged and every name follows the rule.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
