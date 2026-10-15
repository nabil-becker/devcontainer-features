"""What the devhost scripts share; standard library only.

The one reader of every DEVHOST_* setting (see the Feature's NOTES.md, "Settings"), so the
backs, the name guard and a repository's own checks all agree:

- `repo_root()`: DEVHOST_ROOT, else CLAUDE_PROJECT_DIR, else the nearest ancestor of the
  current directory holding `.claude/settings.json`, else the current directory.
- `state_dir()`: the job state directory (DEVHOST_STATE, the Feature's volume by default).
- `ledger_dir(root)`, `backlog(root)`, `lexicon(root)`, `adr_dir(root)`,
  `night_shift_dir(root)`: the records, relative to the root unless absolute.
- `redact_names(root)`: the names of DEVHOST_REDACT_FILE (`.devhost/redact-names.txt`,
  ignored by git, one per line, `#` comments), replaced whole-word by `redact_with()`.
- `forbidden_words(root)`: the words of DEVHOST_FORBIDDEN_WORDS (`;`-separated, meant for
  CI), replaced wherever they occur, inside a longer word too.
- `redact(text, root)`: both rules applied to a text.
- `engineer(root)`: DEVHOST_ENGINEER, else the git user name, as a slug; `unknown`.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

DEFAULT_STATE = "/var/lib/devcontainer-features/devhost"
DEFAULTS = {
    "DEVHOST_LEDGER_DIR": "docs/ledger",
    "DEVHOST_BACKLOG": "TODO.md",
    "DEVHOST_LEXICON": "LEXICON.md",
    "DEVHOST_ADR_DIR": "docs/adr",
    "DEVHOST_NIGHT_SHIFT_DIR": "docs/night-shift",
    "DEVHOST_REDACT_FILE": ".devhost/redact-names.txt",
    "DEVHOST_REDACT_WITH": "the Operator",
}


def setting(name: str) -> str:
    return os.environ.get(name) or DEFAULTS[name]


def repo_root() -> Path:
    explicit = os.environ.get("DEVHOST_ROOT")
    if explicit:
        return Path(explicit)
    project = os.environ.get("CLAUDE_PROJECT_DIR")
    if project and (Path(project) / ".claude" / "settings.json").is_file():
        return Path(project)
    here = Path.cwd().resolve()
    for candidate in (here, *here.parents):
        if (candidate / ".claude" / "settings.json").is_file():
            return candidate
    return here


def state_dir() -> Path:
    return Path(os.environ.get("DEVHOST_STATE") or DEFAULT_STATE)


def under(root: Path, name: str) -> Path:
    value = setting(name)
    return Path(value) if os.path.isabs(value) else Path(root) / value


def ledger_dir(root: Path) -> Path:
    return under(root, "DEVHOST_LEDGER_DIR")


def backlog(root: Path) -> Path:
    return under(root, "DEVHOST_BACKLOG")


def lexicon(root: Path) -> Path:
    return under(root, "DEVHOST_LEXICON")


def adr_dir(root: Path) -> Path:
    return under(root, "DEVHOST_ADR_DIR")


def night_shift_dir(root: Path) -> Path:
    return under(root, "DEVHOST_NIGHT_SHIFT_DIR")


def _words(lines: list[str]) -> list[str]:
    return [w.strip() for w in lines if w.strip() and not w.strip().startswith("#")]


def redact_names(root: Path) -> list[str]:
    path = under(root, "DEVHOST_REDACT_FILE")
    if not path.is_file():
        return []
    return _words(path.read_text(encoding="utf-8").splitlines())


def forbidden_words(root: Path) -> list[str]:
    return _words(os.environ.get("DEVHOST_FORBIDDEN_WORDS", "").split(";"))


def redact_with() -> str:
    return setting("DEVHOST_REDACT_WITH")


def _replace(text: str, words: list[str], replacement: str, whole_word: bool) -> str:
    edge = r"\b" if whole_word else ""
    for w in sorted(words, key=len, reverse=True):  # longest first: "Ann Lee" before "Ann"
        text = re.sub(edge + re.escape(w) + r"(?:'s|’s)" + edge, replacement + "'s", text, flags=re.I)
        text = re.sub(edge + re.escape(w) + edge, replacement, text, flags=re.I)
    return text


def redact(text: str, root: Path) -> str:
    text = _replace(text, redact_names(root), redact_with(), whole_word=True)
    return _replace(text, forbidden_words(root), redact_with(), whole_word=False)


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def engineer(root: Path) -> str:
    name = os.environ.get("DEVHOST_ENGINEER", "").strip()
    if not name:
        try:
            done = subprocess.run(["git", "-C", str(root), "config", "user.name"], capture_output=True, text=True)
            name = done.stdout.strip() if done.returncode == 0 else ""
        except OSError:
            name = ""
    return slug(name) or "unknown"
