#!/usr/bin/env python3
"""The guards (`devhost-verify`): what the tooling refuses, run at commit time in seconds.

Usage: verify.py [--quiet]      --quiet prints only the failures; exit 1 on any finding.

Each guard is a function returning `file:line: message` strings (never a secret or a forbidden
word itself), and needs only git and python3:

- `ledger_append_only`: a line of a monthly ledger file (`YYYY-MM.md` in the ledger directory)
  that exists on the base ref (`DEVHOST_BASE_REF`, else origin/main, main, origin/develop,
  develop) cannot change or go; a note, not a failure, when there is no base ref.
- `ledger_shape`: a monthly file starts `# Ledger, YYYY-MM` and its headings are only
  `### YYYY-MM-DD <title>` and `## Review YYYY-MM-DD`; the directory holds monthly files,
  `costs-YYYY-MM-<engineer>.md` cost reports and a README, nothing else.
- `secrets`: nothing tracked looks like a key, password, token, private key or signature;
  `.devhost/allowed-secrets.txt` (one value per line) lists the published or throwaway values.
- `forbidden_words`: none of `DEVHOST_FORBIDDEN_WORDS` and none of the redact names
  (`DEVHOST_REDACT_FILE`) appears in a tracked text file; reported as `forbidden word #N`.
- `adrs`: `NNNN-title.md` records are numbered consecutively from 0001, titled
  `# ADR-NNNN: `, carry the fixed sections and a known status word, and are in the index.
- `taskfile`: every task in `Taskfile.yml` has a `desc` (`default` excepted).
- `skills`: every `.claude/skills/<dir>/SKILL.md` has frontmatter `name: <dir>` and a description.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import (COST_REPORT, MONTHLY, adr_dir, base_ref, forbidden_words as _forbidden,  # noqa: E402
                            git, ledger_dir, read_text, redact_file, redact_names, rel, repo_root,
                            tracked_files)

TEXT_SUFFIXES = {
    ".py", ".md", ".yml", ".yaml", ".json", ".toml", ".txt", ".ps1", ".psm1", ".sql", ".bicep",
    ".bicepparam", ".html", ".css", ".js", ".ts", ".sh", ".cfg", ".ini", ".env", ".xml", ".csv", "",
}
SECRET_PATTERNS = {
    "storage account key": re.compile(r"AccountKey=([A-Za-z0-9+/]{60,}={0,2})"),
    "password in a connection string": re.compile(r"(?i)(?:password|pwd)=([^;\s\"'{}$<>]{6,})"),
    "private key block": re.compile(r"(-----BEGIN [A-Z ]*PRIVATE KEY-----)"),
    "shared access signature": re.compile(r"(?i)(?:sharedaccesssignature=|[?&]sig=)([A-Za-z0-9%+/]{20,})"),
    "GitHub token": re.compile(r"\b(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,})\b"),
    "Anthropic key": re.compile(r"\b(sk-ant-[A-Za-z0-9_-]{20,})\b"),
    "AWS key id": re.compile(r"\b(AKIA[0-9A-Z]{16})\b"),
    "Slack token": re.compile(r"\b(xox[bp]-[A-Za-z0-9-]{10,})\b"),
    "client secret": re.compile(r"(?i)client[_-]?secret\s*[:=]\s*[\"']?([A-Za-z0-9~._-]{30,})"),
}
ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9-]+\.md$")
ADR_SECTIONS = ("## Context", "## Decision", "## Options considered", "## Consequences", "## Change log")
ADR_STATUSES = {"proposed", "accepted", "rejected", "superseded"}
LEDGER_HEADING = re.compile(r"^(### \d{4}-\d{2}-\d{2} \S|## Review \d{4}-\d{2}-\d{2})")
TASK_LINE = re.compile(r"^  ([a-z][\w:-]*):\s*$")
FRONTMATTER = re.compile(r"^---\r?\n(.*?)\r?\n---\r?\n", re.S)


def text_files(root: Path) -> list[Path]:
    skip = {redact_file(root).resolve()}
    return [p for p in tracked_files(root)
            if p.suffix.lower() in TEXT_SUFFIXES and p.is_file() and p.resolve() not in skip]


# The ledger


def ledger_append_only(root: Path, notes: list[str] | None = None) -> list[str]:
    base = base_ref(root)
    if base is None:
        if notes is not None:
            notes.append("ledger append-only guard skipped: no base ref (DEVHOST_BASE_REF, origin/main, main, origin/develop, develop)")
        return []
    folder = ledger_dir(root)
    names = {p.name for p in folder.glob("*.md") if MONTHLY.match(p.name)} if folder.is_dir() else set()
    listed = git(root, "ls-tree", "--name-only", f"{base}:{rel(root, folder)}")
    names |= {n for n in (listed or "").splitlines() if MONTHLY.match(n)}
    findings = []
    for name in sorted(names):
        path = f"{rel(root, folder)}/{name}"
        if git(root, "cat-file", "-e", f"{base}:{path}") is None:
            continue
        diff = git(root, "diff", "-U0", base, "--", path)
        if not diff:
            continue
        old_line = 0
        for line in diff.splitlines():
            hunk = re.match(r"^@@ -(\d+)", line)
            if hunk:
                old_line = int(hunk.group(1))
            elif line.startswith("-") and not line.startswith("---"):
                findings.append(f"{path}:{old_line}: ledger line on {base} changed or removed; add a correcting entry instead")
                old_line += 1
            elif line.startswith(" "):
                old_line += 1
    return findings


def ledger_shape(root: Path) -> list[str]:
    folder = ledger_dir(root)
    if not folder.is_dir():
        return []
    findings = []
    for path in sorted(folder.glob("*.md")):
        where = rel(root, path)
        text = read_text(path)
        if MONTHLY.match(path.name):
            if not text.startswith(f"# Ledger, {path.stem}\n"):
                findings.append(f"{where}:1: must start with '# Ledger, {path.stem}'")
            for number, line in enumerate(text.splitlines(), 1):
                if re.match(r"^#{2,3} ", line) and not LEDGER_HEADING.match(line):
                    findings.append(f"{where}:{number}: headings are '### YYYY-MM-DD <title>' or '## Review YYYY-MM-DD' only")
        elif path.name == "README.md":
            continue
        elif COST_REPORT.match(path.name):
            if not text.startswith("# Agent costs, "):
                findings.append(f"{where}:1: not a generated cost report")
        else:
            findings.append(f"{where}:1: the ledger directory holds YYYY-MM.md, costs-YYYY-MM-<engineer>.md and README.md only")
    return findings


# Secrets and words


def allowed_secrets(root: Path) -> set[str]:
    path = root / ".devhost" / "allowed-secrets.txt"
    try:
        return {w.strip() for w in read_text(path).splitlines() if w.strip() and not w.startswith("#")}
    except OSError:
        return set()


ENV_TEMPLATE = re.compile(r"^\.env\.(example|sample|template|dist)$")


def env_files(root: Path) -> list[str]:
    """Tracked `.env` and `.env.*` files (templates `.env.example` and the like are fine)."""
    return [f"{rel(root, p)}: a tracked env file; ignore it, keep a .env.example instead"
            for p in tracked_files(root)
            if (p.name == ".env" or p.name.startswith(".env.")) and not ENV_TEMPLATE.match(p.name)]


def secrets(root: Path) -> list[str]:
    allowed = allowed_secrets(root)
    findings = env_files(root)
    for path in text_files(root):
        if path.name == "allowed-secrets.txt":
            continue
        where = rel(root, path)
        for number, line in enumerate(read_text(path).splitlines(), 1):
            for what, pattern in SECRET_PATTERNS.items():
                for match in pattern.finditer(line):
                    if match.group(1) not in allowed:
                        findings.append(f"{where}:{number}: looks like a {what}")
    return findings


def forbidden_words(root: Path) -> list[str]:
    words = [w.lower() for w in _forbidden(root) + redact_names(root) if w]
    if not words:
        return []
    findings = []
    for path in text_files(root):
        where = rel(root, path)
        for number, line in enumerate(read_text(path).splitlines(), 1):
            low = line.lower()
            for index, word in enumerate(words, 1):
                if word in low:
                    findings.append(f"{where}:{number}: forbidden word #{index}")
    return findings


# Conventions


def adrs(root: Path) -> list[str]:
    folder = adr_dir(root)
    if not folder.is_dir():
        return []
    findings = []
    index = folder / "README.md"
    listing = read_text(index) if index.exists() else None
    if listing is None:
        findings.append(f"{rel(root, index)}:1: the ADR index is missing")
    if not (folder / "0000-template.md").exists():
        findings.append(f"{rel(root, folder / '0000-template.md')}:1: the ADR template is missing")
    records = sorted(p for p in folder.iterdir() if ADR_FILE.match(p.name) and not p.name.startswith("0000"))
    numbers = [int(ADR_FILE.match(p.name).group(1)) for p in records]
    if numbers != list(range(1, len(numbers) + 1)):
        findings.append(f"{rel(root, folder)}:0: ADR numbers are not consecutive from 0001: {numbers}")
    for path in records:
        where = rel(root, path)
        text = read_text(path)
        number = ADR_FILE.match(path.name).group(1)
        if not text.startswith(f"# ADR-{number}: "):
            findings.append(f"{where}:1: the title line must be '# ADR-{number}: Title'")
        for heading in ADR_SECTIONS:
            if f"\n{heading}\n" not in text:
                findings.append(f"{where}:1: lacks the section '{heading}'")
        status = re.search(r"^\| \*\*Status\*\* \| ([^|]+) \|", text, re.M)
        if not status:
            findings.append(f"{where}:1: the status row is missing")
        elif status.group(1).strip().split()[0] not in ADR_STATUSES:
            findings.append(f"{where}:1: the status must start with one of {sorted(ADR_STATUSES)}")
        if listing is not None and f"]({path.name})" not in listing:
            findings.append(f"{rel(root, index)}:1: {path.name} is not in the index")
    return findings


def taskfile(root: Path) -> list[str]:
    path = root / "Taskfile.yml"
    if not path.exists():
        return []
    findings = []
    in_tasks, name, line_no, described = False, None, 0, True
    for number, line in enumerate(read_text(path).splitlines() + ["EOF:"], 1):
        if re.match(r"^\S", line):
            if name and not described:
                findings.append(f"Taskfile.yml:{line_no}: task '{name}' has no desc")
            name, described = None, True
            in_tasks = line.startswith("tasks:")
            continue
        if not in_tasks:
            continue
        m = TASK_LINE.match(line)
        if m:
            if name and not described:
                findings.append(f"Taskfile.yml:{line_no}: task '{name}' has no desc")
            name, line_no, described = m.group(1), number, m.group(1) == "default"
        elif name and re.match(r"^    desc:\s*\S", line):
            described = True
    return findings


def skills(root: Path) -> list[str]:
    folder = root / ".claude" / "skills"
    if not folder.is_dir():
        return []
    findings = []
    for skill in sorted(p for p in folder.iterdir() if p.is_dir()):
        path = skill / "SKILL.md"
        where = rel(root, path)
        if not path.exists():
            findings.append(f"{where}:1: missing")
            continue
        m = FRONTMATTER.match(read_text(path))
        if not m:
            findings.append(f"{where}:1: no frontmatter")
            continue
        meta = {}
        for line in m.group(1).splitlines():
            if ":" in line and not line.startswith((" ", "\t")):
                key, value = line.split(":", 1)
                meta[key.strip()] = value.strip().strip("\"'")
        if meta.get("name") != skill.name:
            findings.append(f"{where}:2: frontmatter name {meta.get('name')!r} is not the directory name {skill.name!r}")
        if not meta.get("description"):
            findings.append(f"{where}:2: frontmatter needs a description saying what the skill does and when to use it")
    return findings


GUARDS = (ledger_append_only, ledger_shape, secrets, forbidden_words, adrs, taskfile, skills)


def run(root: Path) -> tuple[dict[str, list[str]], list[str]]:
    notes: list[str] = []
    results = {}
    for guard in GUARDS:
        results[guard.__name__] = guard(root, notes) if guard is ledger_append_only else guard(root)
    return results, notes


def main(argv: list[str]) -> int:
    quiet = "--quiet" in argv
    root = repo_root()
    results, notes = run(root)
    failed = 0
    for name, findings in results.items():
        if findings:
            failed += len(findings)
            print(f"FAIL {name}")
            for finding in findings:
                print(f"  {finding}")
        elif not quiet:
            print(f"ok   {name}")
    if not quiet:
        for note in notes:
            print(f"note {note}")
    if failed:
        print(f"devhost-verify: {failed} finding(s)")
        return 1
    if not quiet:
        print("devhost-verify: all guards passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
