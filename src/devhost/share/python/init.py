#!/usr/bin/env python3
"""Scaffold a repository with the way of working (`devhost-init [--force]`).

Writes, from the templates beside this script, only the files that do not exist yet and lists
each as `kept` or `wrote`, the way the bootstrap does. `--force` rewrites the templates
(lexicon, process, skills, the CLAUDE.md section, the READMEs) but never the records: the
backlog, the ledger directory's contents and the ADRs stay as they are. Special cases:

- `.claude/settings.json`: written when absent (the hooks for the briefing and the jobs, and
  the permissions); when present, the block to merge by hand is printed instead.
- `.githooks/pre-commit`: written only when `.githooks/` is absent (`exec devhost-verify --quiet`).
- `.gitignore`: the line `.devhost/redact-names.txt` is appended when missing.
- `.devhost/CLAUDE.devhost.md` is a section for the repository's CLAUDE.md to include with a
  line `@.devhost/CLAUDE.devhost.md`; CLAUDE.md itself is never written.

The templates hold `{{REPO_NAME}}` and `{{DATE}}`, nothing else is substituted.
"""
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import read_text, repo_root, today, write_text  # noqa: E402

TEMPLATES = Path(__file__).resolve().parent / "templates"

# template (under templates/) -> target (under the repository root). Dot-directories are
# spelled without the dot in templates/ so that nothing skips them as hidden.
FILES = {
    "LEXICON.md": "LEXICON.md",
    "PROCESS.md": "PROCESS.md",
    "TODO.md": "TODO.md",
    "docs/ledger/README.md": "docs/ledger/README.md",
    "docs/adr/0000-template.md": "docs/adr/0000-template.md",
    "docs/adr/README.md": "docs/adr/README.md",
    "docs/night-shift/README.md": "docs/night-shift/README.md",
    "claude/skills/close-session/SKILL.md": ".claude/skills/close-session/SKILL.md",
    "claude/skills/ledger-review/SKILL.md": ".claude/skills/ledger-review/SKILL.md",
    "claude/skills/plant-a-seed/SKILL.md": ".claude/skills/plant-a-seed/SKILL.md",
    "claude/skills/plant-a-seed/INTERVIEW.md": ".claude/skills/plant-a-seed/INTERVIEW.md",
    "claude/skills/drop-a-seed/SKILL.md": ".claude/skills/drop-a-seed/SKILL.md",
    "claude/skills/drop-a-seed/journalist.md": ".claude/skills/drop-a-seed/journalist.md",
    "claude/skills/night-shift/SKILL.md": ".claude/skills/night-shift/SKILL.md",
    "claude/skills/new-adr/SKILL.md": ".claude/skills/new-adr/SKILL.md",
    "claude/skills/publish-site/SKILL.md": ".claude/skills/publish-site/SKILL.md",
    "devhost/gitignore": ".devhost/.gitignore",
    "devhost/CLAUDE.devhost.md": ".devhost/CLAUDE.devhost.md",
}
# Records: never overwritten, even with --force.
RECORDS = {"TODO.md", "docs/adr/0000-template.md", "docs/adr/README.md"}
SETTINGS = ("claude/settings.json", ".claude/settings.json")
PRE_COMMIT = ("githooks/pre-commit", ".githooks/pre-commit")
GITIGNORE_LINES = (".devhost/redact-names.txt",)


def fill(text: str, root: Path) -> str:
    return text.replace("{{REPO_NAME}}", root.name).replace("{{DATE}}", today())


def put(root: Path, template: str, target: str, force: bool, out: list[str]) -> bool:
    """Write the file unless it exists (or force); returns True when written."""
    dest = root / target
    if dest.exists() and not (force and target not in RECORDS):
        out.append(f"  kept      {target} (exists)")
        return False
    write_text(dest, fill(read_text(TEMPLATES / template), root))
    out.append(f"  wrote     {target}")
    return True


def gitignore(root: Path, out: list[str]) -> None:
    path = root / ".gitignore"
    text = read_text(path) if path.exists() else ""
    present = {line.strip() for line in text.splitlines()}
    missing = [line for line in GITIGNORE_LINES if line not in present]
    if not missing:
        out.append("  kept      .gitignore (has the devhost lines)")
        return
    if text and not text.endswith("\n"):
        text += "\n"
    write_text(path, text + "".join(f"{line}\n" for line in missing))
    out.append(f"  wrote     .gitignore (+{', '.join(missing)})")


def pre_commit(root: Path, out: list[str]) -> None:
    hooks = root / ".githooks"
    template, target = PRE_COMMIT
    if hooks.exists():
        out.append(f"  kept      {target} (.githooks/ exists; add 'devhost-verify --quiet' to your hook)")
        return
    dest = root / target
    write_text(dest, read_text(TEMPLATES / template))
    if os.name != "nt":
        dest.chmod(dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    out.append(f"  wrote     {target} (run: git config core.hooksPath .githooks)")


def settings(root: Path, out: list[str], extra: list[str]) -> None:
    template, target = SETTINGS
    dest = root / target
    if dest.exists():
        out.append(f"  kept      {target} (exists; merge the block printed below by hand)")
        extra.append(f"Merge into {target}:\n" + read_text(TEMPLATES / template))
        return
    write_text(dest, read_text(TEMPLATES / template))
    out.append(f"  wrote     {target}")


def scaffold(root: Path, force: bool = False) -> tuple[list[str], list[str]]:
    """Returns (the kept/wrote listing, the texts to print after it)."""
    out: list[str] = []
    extra: list[str] = []
    for template, target in FILES.items():
        put(root, template, target, force, out)
    settings(root, out, extra)
    pre_commit(root, out)
    gitignore(root, out)
    claude_md = root / "CLAUDE.md"
    include = "@.devhost/CLAUDE.devhost.md"
    if not claude_md.exists() or include not in read_text(claude_md):
        extra.append(f"Add this line to CLAUDE.md so sessions read the way of working: {include}")
    return out, extra


def main(argv: list[str]) -> int:
    force = "--force" in argv
    root = repo_root()
    print(f"devhost-init in {root}" + (" (--force: templates rewritten, records kept)" if force else ""))
    out, extra = scaffold(root, force)
    print("\n".join(out))
    for text in extra:
        print()
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
