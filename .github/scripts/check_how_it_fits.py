#!/usr/bin/env python3
"""Fail when a Feature's NOTES.md has no "## How it fits" section or the section has no "Used in:" line.

Every Feature says, near the top of its README, what it connects to (a diagram), what data it keeps
and in which storage tier (a table), and which reference architectures use it ("Used in: ..." with
links, or "Used in: none yet"). The README is generated from src/<id>/NOTES.md, so the check reads
NOTES.md. The "Used in:" line must sit inside the section (before the next "## " heading).
Usage: check_how_it_fits.py [ROOT]. Docker-free, stdlib only.
"""
import re
import sys
from pathlib import Path

HEADING = re.compile(r"^## How it fits[ \t]*$", re.M)
NEXT = re.compile(r"^## ", re.M)
USED_IN = re.compile(r"^Used in:[ \t]*\S", re.M)


def check(root):
    findings = []
    for notes in sorted(root.glob("src/*/NOTES.md")):
        rel = notes.relative_to(root)
        text = notes.read_text()
        head = HEADING.search(text)
        if not head:
            findings.append(f'{rel}: no "## How it fits" section')
            continue
        rest = text[head.end():]
        following = NEXT.search(rest)
        section = rest[:following.start()] if following else rest
        if not USED_IN.search(section):
            findings.append(f'{rel}: "## How it fits" has no "Used in:" line (links, or "Used in: none yet")')
    return findings


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    findings = check(root)
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        print("Add the section to the Feature's NOTES.md, right after its opening (see CONTRIBUTING.md).", file=sys.stderr)
        return 1
    print("NOTES.md: every Feature has a \"How it fits\" section with a \"Used in:\" line")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
