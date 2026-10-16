#!/usr/bin/env python3
"""The backs' guards: a job may only add to what it keeps; anything else is undone.

Usage: guards.py backlog <before> <after>       the secretary's guard on the backlog file
       guards.py docs <snapshot dir> <root>     the librarian's guard on the lexicon, the ADRs and the model

Importable too: `backlog_guard(before_lines, after_lines)` and `docs_guard(snapshot, root)`
return the first finding as a string, or None when the run kept the rules.

The backlog guard: every line of <before> is still in <after>, in the same order, either
unchanged or ticked (`- [ ]` -> `- [x]`, text kept, a suffix allowed); a suffix on an item's last
line is allowed, never on a heading or a blank line.

The docs guard: the snapshot holds the lexicon as `<its basename>` and the ADR directory's
`*.md` as `adr/` and the model directory's files as `model/` (same relative paths), as they were before the run. Every line of the old lexicon is still there,
unchanged and in order (new lines anywhere); every existing ADR keeps every line except its
`| **Status** |` row, which may change (an ADR is superseded by setting that line only); the ADR
index (`README.md`) keeps every line except an index row of an existing ADR (`| [NNNN](...) |`),
whose status column may change; new rows and new files may be added. Every line of an old model file
(`docs/model/`: the ontology, the themes, the views) is still there, unchanged and in order (new
lines and new files anywhere). New ADR files and model content are not this guard's business:
`devhost-verify` checks their shape and agreement.

The CLI exits 1 and prints the finding (backlog: then the rejected diff), so the job can restore the snapshot and log it.
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import adr_dir, lexicon_path, model_dir, rel  # noqa: E402

STATUS_ROW = re.compile(r"^\| \*\*Status\*\* \|")
INDEX_ROW = re.compile(r"^\| \[(\d{4})\]")


def lost_line(before: list[str], after: list[str], may_change=lambda old, new: False) -> str | None:
    """The first line of `before` not found, unchanged or as an allowed change, in order in `after`."""
    j = 0
    for old in before:
        while j < len(after) and not (after[j] == old or may_change(old, after[j])):
            j += 1
        if j == len(after):
            return old
        j += 1
    return None


def same_or_ticked(old: str, new: str) -> bool:
    if "- [ ]" in old:
        return new.startswith(old.replace("- [ ]", "- [x]", 1))
    return new.startswith(old) and old.strip() != "" and not old.lstrip().startswith("#")


def backlog_guard(before: list[str], after: list[str]) -> str | None:
    lost = lost_line(before, after, same_or_ticked)
    if lost is None:
        return None
    return (f"rule: an existing line may only be ticked ([ ] to [x], ' Done <date>.' appended), "
            f"never reworded, removed or reordered; changed or lost: {lost.strip()[:160]}")


def rejected_diff(before: list[str], after: list[str], cap: int = 1500) -> str:
    """The unified diff of a refused run, capped, for the job log."""
    text = "\n".join(difflib.unified_diff(before, after, "before", "after", lineterm="", n=0))
    return text if len(text) <= cap else text[:cap] + f"\n[diff clipped, {len(text) - cap} chars more]"


def status_change(old: str, new: str) -> bool:
    return bool(STATUS_ROW.match(old) and STATUS_ROW.match(new))


def index_change(old: str, new: str) -> bool:
    a, b = INDEX_ROW.match(old), INDEX_ROW.match(new)
    return bool(a and b and a.group(1) == b.group(1))


def lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines() if path.exists() else []


def docs_guard(snapshot: Path, root: Path) -> str | None:
    snapshot, root = Path(snapshot), Path(root)
    lexicon = lexicon_path(root)
    old = snapshot / lexicon.name
    if old.exists():
        lost = lost_line(lines(old), lines(lexicon))
        if lost is not None:
            return f"{rel(root, lexicon)}: changed or lost: {lost.strip()[:160]}"
    adrs = adr_dir(root)
    for adr in sorted((snapshot / "adr").glob("*.md")) if (snapshot / "adr").is_dir() else []:
        now = adrs / adr.name
        if not now.exists():
            return f"{rel(root, now)}: removed"
        rule = index_change if adr.name == "README.md" else status_change
        lost = lost_line(lines(adr), lines(now), rule)
        if lost is not None:
            return f"{rel(root, now)}: changed or lost: {lost.strip()[:160]}"
    models = model_dir(root)
    for old_model in sorted(p for p in (snapshot / "model").rglob("*") if p.is_file()) if (snapshot / "model").is_dir() else []:
        now = models / old_model.relative_to(snapshot / "model")
        if not now.exists():
            return f"{rel(root, now)}: removed"
        lost = lost_line(lines(old_model), lines(now))
        if lost is not None:
            return f"{rel(root, now)}: changed or lost: {lost.strip()[:160]}"
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] not in ("backlog", "docs"):
        print(__doc__)
        return 2
    if argv[0] == "backlog":
        before, after = lines(Path(argv[1])), lines(Path(argv[2]))
        finding = backlog_guard(before, after)
        if finding:
            print(finding)
            print(rejected_diff(before, after))
            return 1
    else:
        finding = docs_guard(Path(argv[1]), Path(argv[2]))
    if finding:
        print(finding)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
