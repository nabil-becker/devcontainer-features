#!/usr/bin/env python3
"""The name guard: no person's name and no forbidden word reaches what a back writes.

Usage: devhost-redact [file ...]   files are fixed in place; with no files, stdin -> stdout.

Two lists, one reader (python/devhost_common.py), so the backs and a repository's own check agree:
- the names in DEVHOST_REDACT_FILE (`.devhost/redact-names.txt` at the root, ignored by git,
  one per line) become DEVHOST_REDACT_WITH ("the Operator"; a possessive stays one), matched
  as whole words, case-insensitively;
- the words of DEVHOST_FORBIDDEN_WORDS (`;`-separated, a client's name for instance) become
  the same, wherever they occur, inside a longer word too.
The root is DEVHOST_ROOT, else CLAUDE_PROJECT_DIR, else the nearest checkout.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))
from devhost_common import redact_text as redact, repo_root  # noqa: E402


def main(argv: list[str]) -> int:
    root = repo_root()
    if not argv:
        sys.stdout.write(redact(sys.stdin.read(), root))
        return 0
    for name in argv:
        path = Path(name)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        fixed = redact(text, root)
        if fixed != text:
            path.write_text(fixed, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
