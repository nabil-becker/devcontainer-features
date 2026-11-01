#!/usr/bin/env python3
"""The register guard: what no entry of an agentic-register register may carry.

Usage: devhost-register-guard --root=<absolute repository path> [--forbidden=<word>,<word>]
       the entry's body on standard input (agentic-register's guard protocol)

Exit 0 lets the entry through. Exit 1 refuses it and says on standard error which rule, never the
matched text (the refusal reaches the writer, an agent among them): `refused: redact name #N`,
`refused: forbidden word #N`, `refused: looks like a <kind of secret>`. Exit 2: the guard itself
cannot run (a bad argument, a name list that exists and cannot be read); agentic-register treats
that as a refusal too.

The rules are the ones `devhost-verify` applies to tracked files, from the same code:
- every name in the repository's redact file (`<root>/.devhost/redact-names.txt`, ignored by git),
  anywhere in the body, case-insensitively (a substring, as verify does);
- every forbidden word: `--forbidden` (comma-separated) and `DEVHOST_FORBIDDEN_WORDS` (`;`);
- every secret pattern of verify.py (`SECRET_PATTERNS`), minus the values in
  `<root>/.devhost/allowed-secrets.txt`.
A body that is JSON is read twice, as written and decoded (so a name with an accent is found
either way). A redact file that does not exist means no names, as in verify.

Why arguments: agentic-register runs a guard with a fixed PATH, in `/`, with none of the writer's
environment, so the repository cannot be found from the environment or the working directory.
`--root` is an absolute path in the quote-free `registers` form (no `:`, `;`, quote or space);
`--forbidden` stands in for the environment variable the guard never gets.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import forbidden_words as _env_forbidden, redact_names  # noqa: E402
from verify import SECRET_PATTERNS, allowed_secrets  # noqa: E402


def renderings(body: str) -> list[str]:
    """The body as written, and decoded when it is JSON (never an exception)."""
    texts = [body]
    try:
        texts.append(json.dumps(json.loads(body), ensure_ascii=False))
    except ValueError:
        pass
    return texts


def refusal(body: str, root: Path, forbidden: list[str]) -> str | None:
    """The first rule the body breaks, as a short message with no matched text; None when it is clean."""
    lows = [t.lower() for t in renderings(body)]
    for index, name in enumerate(redact_names(root), 1):
        if any(name.lower() in low for low in lows):
            return f"redact name #{index}"
    for index, word in enumerate(forbidden, 1):
        if any(word.lower() in low for low in lows):
            return f"forbidden word #{index}"
    allowed = allowed_secrets(root)
    for what, pattern in SECRET_PATTERNS.items():
        for text in renderings(body):
            for match in pattern.finditer(text):
                if match.group(1) not in allowed:
                    return f"looks like a {what}"
    return None


def parse(argv: list[str]) -> tuple[Path, list[str]]:
    root = None
    forbidden = list(_env_forbidden(Path("/")))
    for arg in argv:
        if arg.startswith("--root="):
            root = Path(arg[len("--root="):])
        elif arg.startswith("--forbidden="):
            forbidden += [w.strip() for w in arg[len("--forbidden="):].split(",") if w.strip()]
        else:
            raise ValueError("an argument it does not know")
    if root is None or not root.is_absolute():
        raise ValueError("--root=<absolute path> is required")
    return root, forbidden


def main(argv: list[str]) -> int:
    try:
        root, forbidden = parse(argv)
        # An existing but unreadable name list must stop the guard, not let everything through.
        names = root / ".devhost" / "redact-names.txt"
        if os.path.lexists(names):
            names.read_bytes()
        body = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    except (ValueError, OSError) as err:
        print(f"guard cannot run: {err.args[0] if isinstance(err, ValueError) else 'a file it must read is unreadable'}", file=sys.stderr)
        return 2
    found = refusal(body, root, forbidden)
    if found:
        print(f"refused: {found}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
