#!/usr/bin/env python3
"""Git merge driver for TODO.md (merge=devhost-todo in .gitattributes): union, then one line per id.

Usage: merge_todo.py <ancestor> <ours> <theirs>   (git's %O %A %B); the result is written to <ours>.

A line merge that keeps both sides' added lines (git merge-file --union, what merge=union did),
then, for backlog items (`- [ ] **<id> ...` / `- [x] **<id> ...`) that now appear more than once
(a line both sides changed, such as a tick), keeps one at the first one's place: the ticked one,
else the longer. Everything else stays as union left it. Stdlib only; needs git.
"""
import re
import subprocess
import sys
from pathlib import Path

ITEM = re.compile(r"^- \[([ xX])\] \*\*([a-z0-9][\w-]*)[ *]")


def dedupe(lines):
    best = {}
    for line in lines:
        found = ITEM.match(line)
        if found:
            ticked, ident = found.group(1) != " ", found.group(2)
            rank = (ticked, len(line))
            if ident not in best or rank > best[ident][0]:
                best[ident] = (rank, line)
    out, seen = [], set()
    for line in lines:
        found = ITEM.match(line)
        if not found:
            out.append(line)
            continue
        ident = found.group(2)
        if ident not in seen:
            seen.add(ident)
            out.append(best[ident][1])
    return out


def main(argv):
    ancestor, ours, theirs = argv[1:4]
    subprocess.run(["git", "merge-file", "--union", ours, ancestor, theirs], check=False)
    path = Path(ours)
    text = path.read_text()
    lines = text.split("\n")
    path.write_text("\n".join(dedupe(lines)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
