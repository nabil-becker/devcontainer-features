"""What the devhost scripts share; standard library only.

Every path and name is a `DEVHOST_*` environment variable with a default, the same names the
job runner uses, so a repository can keep its records elsewhere without changing a script:

- `DEVHOST_ROOT`: the repository; else `CLAUDE_PROJECT_DIR`; else the nearest directory above the
  current one with `.claude/settings.json`; else the current directory.
- `DEVHOST_STATE`: where the jobs keep their state (`/var/lib/devcontainer-features/devhost`).
- `DEVHOST_LEDGER_DIR`, `DEVHOST_BACKLOG`, `DEVHOST_LEXICON`, `DEVHOST_ADR_DIR`,
  `DEVHOST_NIGHT_SHIFT_DIR`: the records, relative to the root unless absolute.
- `DEVHOST_ENGINEER`: whose machine this is, as a slug; else `operator`. Never the git identity: the handle
  is committed (entries, the cost report's file name) and a git name may be a person's name.
- `DEVHOST_REVIEW_EVERY`: ledger entries between reviews (25); the briefing says a review is due then.
- `DEVHOST_MONTHLY_TARGET`: a monthly list-price spend in dollars to measure against; unset by default.
  A tracking point, never a cap: nothing warns or blocks.
- `DEVHOST_FORBIDDEN_WORDS`: words (separated by `;`) that may appear nowhere in the repository.
- `DEVHOST_REDACT_FILE` (`.devhost/redact-names.txt`, ignored by git): names replaced, whole
  word, by `DEVHOST_REDACT_WITH` (`the Operator`) in everything a job writes, and refused by
  `devhost-verify` like the forbidden words.
- `DEVHOST_BASE_REF`: what the append-only guard compares against; else the first of
  `origin/main`, `main`, `origin/develop`, `develop` that exists.

No person is named in these scripts or their templates: the person is "the Operator".
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path

DEFAULT_STATE = "/var/lib/devcontainer-features/devhost"
DECISIONS_HEADING = "## Decisions for the Operator"
REVIEWED_MARKER = "Reviewed by the Operator"
MONTHLY = re.compile(r"^\d{4}-\d{2}\.md$")
COST_REPORT = re.compile(r"^costs-(\d{4}-\d{2})-([a-z0-9-]+)\.md$")


def repo_root() -> Path:
    for candidate in (os.environ.get("DEVHOST_ROOT"), os.environ.get("CLAUDE_PROJECT_DIR")):
        if candidate and Path(candidate).is_dir():
            return Path(candidate).resolve()
    here = Path.cwd().resolve()
    for folder in (here, *here.parents):
        if (folder / ".claude" / "settings.json").is_file():
            return folder
    return here


def _path(root: Path, var: str, default: str) -> Path:
    value = os.environ.get(var, "").strip() or default
    return Path(value) if Path(value).is_absolute() else Path(root) / value


def state_dir() -> Path:
    return Path(os.environ.get("DEVHOST_STATE", "").strip() or DEFAULT_STATE)


def ledger_dir(root: Path) -> Path:
    return _path(root, "DEVHOST_LEDGER_DIR", "docs/ledger")


def backlog_path(root: Path) -> Path:
    return _path(root, "DEVHOST_BACKLOG", "TODO.md")


def lexicon_path(root: Path) -> Path:
    return _path(root, "DEVHOST_LEXICON", "LEXICON.md")


def adr_dir(root: Path) -> Path:
    return _path(root, "DEVHOST_ADR_DIR", "docs/adr")


def model_dir(root: Path) -> Path:
    return _path(root, "DEVHOST_MODEL_DIR", "docs/model")


def night_shift_dir(root: Path) -> Path:
    return _path(root, "DEVHOST_NIGHT_SHIFT_DIR", "docs/night-shift")


def redact_file(root: Path) -> Path:
    return _path(root, "DEVHOST_REDACT_FILE", ".devhost/redact-names.txt")


def redact_with() -> str:
    return os.environ.get("DEVHOST_REDACT_WITH", "").strip() or "the Operator"


def rel(root: Path, path: Path) -> str:
    """A path as the repository names it (forward slashes), for messages."""
    try:
        return Path(path).resolve().relative_to(Path(root).resolve()).as_posix()
    except ValueError:
        return Path(path).as_posix()


def git(root: Path, *args: str) -> str | None:
    """Run git in the repository; None when git is unavailable or the command fails."""
    try:
        done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
    except OSError:
        return None
    return done.stdout if done.returncode == 0 else None


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def engineer(root: Path) -> str:
    return slug(os.environ.get("DEVHOST_ENGINEER", "")) or "operator"


DEFAULT_REVIEW_EVERY = 25


def review_every() -> int:
    """Entries between ledger reviews: `DEVHOST_REVIEW_EVERY` when a positive integer, else 25."""
    try:
        n = int(os.environ.get("DEVHOST_REVIEW_EVERY", "").strip())
    except ValueError:
        return DEFAULT_REVIEW_EVERY
    return n if n > 0 else DEFAULT_REVIEW_EVERY


def monthly_target() -> float | None:
    """The monthly spend tracking point in dollars (`DEVHOST_MONTHLY_TARGET`), or None when unset."""
    try:
        n = float(os.environ.get("DEVHOST_MONTHLY_TARGET", "").strip().lstrip("$"))
    except ValueError:
        return None
    return n if n > 0 else None


def money_target(n: float) -> str:
    return f"${n:,.0f}" if n == int(n) else f"${n:,.2f}"


def _words(text: str) -> list[str]:
    return [w.strip() for w in text.splitlines() if w.strip() and not w.strip().startswith("#")]


def forbidden_words(root: Path) -> list[str]:
    words = [w.strip() for w in os.environ.get("DEVHOST_FORBIDDEN_WORDS", "").split(";")]
    return [w for w in words if w]


def redact_names(root: Path) -> list[str]:
    path = redact_file(root)
    try:
        return _words(path.read_text(encoding="utf-8"))
    except OSError:
        return []


def redact(text: str, names: list[str], replacement: str | None = None, whole_word: bool = True) -> str:
    """Replace each name, case-insensitively, keeping a possessive; whole words unless told not to."""
    replacement = replacement or redact_with()
    edge = r"\b" if whole_word else ""
    for name in sorted(names, key=len, reverse=True):  # longest first: "Ann Lee" before "Ann"
        text = re.sub(edge + re.escape(name) + r"(?:'s|’s)" + edge, replacement + "'s", text, flags=re.I)
        text = re.sub(edge + re.escape(name) + edge, replacement, text, flags=re.I)
    return text


def redact_text(text: str, root: Path) -> str:
    """Both rules of the name guard: the redact names as whole words, the forbidden words anywhere."""
    text = redact(text, redact_names(root))
    return redact(text, forbidden_words(root), whole_word=False)


def base_ref(root: Path) -> str | None:
    wanted = os.environ.get("DEVHOST_BASE_REF", "").strip()
    for ref in ([wanted] if wanted else ["origin/main", "main", "origin/develop", "develop"]):
        if git(root, "rev-parse", "--verify", "--quiet", ref) is not None:
            return ref
    return None


def tracked_files(root: Path) -> list[Path]:
    """Every file under version control; outside git, every file in the tree but `.git`."""
    listed = git(root, "ls-files", "-z")
    if listed is not None:
        return [root / name for name in listed.split("\0") if name]
    return [p for p in Path(root).rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts]


def read_text(path: Path) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


def write_text(path: Path, text: str) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def today() -> str:
    return time.strftime("%Y-%m-%d", time.gmtime())


def month() -> str:
    return time.strftime("%Y-%m", time.gmtime())
