#!/usr/bin/env python3
"""Per-Feature changelogs: src/<id>/CHANGELOG.md (Keep a Changelog), shown in the Feature's README.

Usage: changelog.py <command> [args]

  render          put a "## Changes" section into every src/<id>/README.md: the latest 3 entries of the
                  CHANGELOG in full and a link to the whole file. `task docs` runs it after
                  `devcontainer features generate-docs`, which knows nothing of the CHANGELOG.
  check           fail when a Feature's `version` has no `## [version]` entry in its CHANGELOG.md, or
                  when its README's "## Changes" section is not what `render` would write (stale: run
                  `task docs`). Part of `task lint`. Docker-free.
  draft <id> [--base REF]
                  print a draft entry for the commits that touched src/<id> since REF (default
                  origin/main, else main), with the version now in devcontainer-feature.json and
                  today's date, for the author to edit into words for a user of the Feature: what
                  changed for them and whether they must act. `task changelog:draft FEATURE=<id>`.
  backfill        (one time, used to write the first CHANGELOGs; kept for a Feature added later and
                  for the record) walk `git log` per Feature, read `version` from
                  devcontainer-feature.json at every commit, group the commit subjects under each
                  version with the date of its last commit, and move a NOTES.md's "Changes in x.y.z"
                  sections into the entries. Rewrites CHANGELOG.md and NOTES.md; skips a Feature
                  that already has a CHANGELOG.md unless --force.

Stdlib only; needs git for draft and backfill.
"""
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO_URL = "https://github.com/nabil-becker/devcontainer-features"
KEEP = 3
KINDS = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security")
ENTRY = re.compile(r"^## \[([^\]]+)\][ \t]*(?:-[ \t]*(\S.*))?$", re.M)
FOOTER = "\n---\n\n_Note:"
CHANGES = re.compile(r"\n## Changes\n.*?(?=" + re.escape(FOOTER) + ")", re.S)
HEADER = """# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.
"""


def features():
    return sorted(p.parent for p in (ROOT / "src").glob("*/devcontainer-feature.json"))


def version_of(folder):
    return json.loads((folder / "devcontainer-feature.json").read_text())["version"]


def parse(text):
    """The entries of a CHANGELOG as [(version, date, body)], in file order."""
    marks = list(ENTRY.finditer(text))
    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        out.append((m.group(1), (m.group(2) or "").strip(), text[m.end():end].strip("\n")))
    return out


def shift(body):
    """Entry headings one level down (### Added -> #### Added), leaving code fences alone."""
    lines, fenced = [], False
    for line in body.split("\n"):
        if line.startswith("```"):
            fenced = not fenced
        lines.append("#" + line if line.startswith("#") and not fenced else line)
    return "\n".join(lines)


def section(folder):
    """The README's "## Changes" section for a Feature, or None without a CHANGELOG."""
    path = folder / "CHANGELOG.md"
    if not path.is_file():
        return None
    parts = ["## Changes", ""]
    for version, date, body in parse(path.read_text())[:KEEP]:
        parts += [f"### [{version}]" + (f" - {date}" if date else ""), "", shift(body), ""]
    url = f"{REPO_URL}/blob/main/src/{folder.name}/CHANGELOG.md"
    parts += [f"The full history is in [CHANGELOG.md]({url}).", ""]
    return "\n".join(parts)


def render():
    for folder in features():
        readme, new = folder / "README.md", section(folder)
        if new is None or not readme.is_file():
            continue
        text = CHANGES.sub("", readme.read_text())
        if FOOTER not in text:
            print(f"{readme}: no generated footer, run generate-docs first", file=sys.stderr)
            sys.exit(1)
        head, tail = text.rsplit(FOOTER, 1)
        readme.write_text(head.rstrip("\n") + "\n\n" + new + FOOTER + tail)


def check():
    problems = []
    for folder in features():
        rel = folder.relative_to(ROOT)
        path = folder / "CHANGELOG.md"
        if not path.is_file():
            problems.append(f"{rel}/CHANGELOG.md is missing")
            continue
        version = version_of(folder)
        if version not in [v for v, _, _ in parse(path.read_text())]:
            problems.append(f"{rel}: version {version} has no '## [{version}] - YYYY-MM-DD' entry in CHANGELOG.md")
            continue
        readme = folder / "README.md"
        found = CHANGES.search(readme.read_text() if readme.is_file() else "")
        if not found or found.group(0).strip("\n") != section(folder).strip("\n"):
            problems.append(f"{rel}/README.md is stale against CHANGELOG.md (run: task docs)")
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        sys.exit(1)
    print("every Feature's version has a CHANGELOG entry and its README shows it")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def subject_entry(subject):
    """(kind, text) for a Conventional Commit subject; a PR number becomes a link."""
    m = re.match(r"^(\w+)(?:\([^)]*\))?(!)?:[ \t]*(.*)$", subject)
    kind, text = "Changed", subject
    if m:
        kind = {"feat": "Added", "fix": "Fixed"}.get(m.group(1), "Changed")
        text = m.group(3)
    pr = re.search(r"\s*\(#(\d+)\)\s*$", text)
    if pr:
        text = text[:pr.start()] + f" ([#{pr.group(1)}]({REPO_URL}/pull/{pr.group(1)}))"
    return kind, text[:1].upper() + text[1:]


def entry_body(subjects):
    groups = {k: [] for k in KINDS}
    for s in subjects:
        kind, text = subject_entry(s)
        groups[kind].append(text)
    out = []
    for kind in KINDS:
        if groups[kind]:
            out += [f"### {kind}", ""] + [f"- {t}" for t in groups[kind]] + [""]
    return "\n".join(out).rstrip("\n")


def draft(ident, base=None):
    folder = ROOT / "src" / ident
    if not (folder / "devcontainer-feature.json").is_file():
        sys.exit(f"no Feature src/{ident}")
    if base is None:
        refs = git("branch", "-a", "--list", "origin/main", "main", "--format=%(refname:short)").split()
        base = "origin/main" if "origin/main" in refs else "main"
    log = git("log", "--no-merges", "--format=%s", f"{base}..HEAD", "--", f"src/{ident}").splitlines()
    subjects = list(reversed(log)) or ["(no commit yet: describe the change)"]
    print(f"## [{version_of(folder)}] - {datetime.date.today().isoformat()}\n")
    print(entry_body(subjects))
    print("\n<!-- Draft from commit subjects. Rewrite for a user of the Feature: what changed for them, "
          "whether they must act. -->")


def feature_commits(ident):
    """[(sha, date, subject, version)] oldest first, for commits that changed more than the README."""
    out = []
    path = f"src/{ident}"
    raw = git("log", "--no-merges", "--reverse", "--name-only", "--format=%x01%H%x09%cs%x09%s", "--", path)
    for block in raw.split("\x01")[1:]:
        head, *files = block.strip("\n").split("\n")
        sha, date, subject = head.split("\t", 2)
        if all(f in ("", f"{path}/README.md", f"{path}/CHANGELOG.md") for f in files):
            continue
        shown = subprocess.run(["git", "-C", str(ROOT), "show", f"{sha}:{path}/devcontainer-feature.json"],
                               capture_output=True, text=True)
        if shown.returncode:
            continue
        try:
            version = json.loads(shown.stdout)["version"]
        except (ValueError, KeyError):
            continue
        out.append((sha, date, subject, version))
    return out


def semver(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def take_notes(folder):
    """Pull the "Changes in x.y.z" sections out of NOTES.md: ({version: body}, remaining text)."""
    path = folder / "NOTES.md"
    lines = path.read_text().split("\n")
    found, keep, i = {}, [], 0
    while i < len(lines):
        m = re.match(r"^(#{2,3}) Changes in (\d+\.\d+\.\d+)[ \t]*$", lines[i])
        if not m:
            keep.append(lines[i])
            i += 1
            continue
        level, j = len(m.group(1)), i + 1
        while j < len(lines) and not re.match(rf"^#{{1,{level}}} ", lines[j]):
            j += 1
        found[m.group(2)] = "\n".join(lines[i + 1:j]).strip("\n")
        i = j
    return found, re.sub(r"\n{3,}", "\n\n", "\n".join(keep)).lstrip("\n")


def backfill(force):
    for folder in features():
        ident, path = folder.name, folder / "CHANGELOG.md"
        if path.exists() and not force:
            print(f"{ident}: CHANGELOG.md exists, skipped (--force to redo)")
            continue
        groups = []  # [version, date, subjects]
        for _, date, subject, version in feature_commits(ident):
            if groups and groups[-1][0] == version:
                groups[-1][1] = date
                groups[-1][2].append(subject)
            else:
                groups.append([version, date, [subject]])
        notes, rest = take_notes(folder)
        have = {g[0] for g in groups}
        for version in sorted(set(notes) - have, key=semver):
            print(f"{ident}: NOTES has Changes in {version}, no commit set that version; dated like the next one")
            later = [g for g in groups if semver(g[0]) > semver(version)]
            groups.append([version, later[0][1] if later else datetime.date.today().isoformat(), []])
        groups.sort(key=lambda g: semver(g[0]), reverse=True)
        entries = []
        for version, date, subjects in groups:
            body = "### Changed\n\n" + notes[version] if version in notes else entry_body(subjects)
            entries.append(f"## [{version}] - {date}\n\n{body}\n")
        oldest = groups[-1][0] if groups else ""
        newest = groups[0][0] if groups else ""
        marker = (f"Entries from {oldest} to {newest} were generated from the commit history "
                  f"(`.github/scripts/changelog.py backfill`) and the \"Changes in x.y.z\" sections "
                  f"that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.\n")
        path.write_text(HEADER + "\n" + marker + "\n" + "\n".join(entries))
        (folder / "NOTES.md").write_text(rest.rstrip("\n") + "\n")
        print(f"{ident}: {len(groups)} versions, {len(notes)} from NOTES.md")


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "render":
        render()
    elif cmd == "check":
        check()
    elif cmd == "draft" and len(argv) >= 2:
        draft(argv[1], argv[argv.index("--base") + 1] if "--base" in argv else None)
    elif cmd == "backfill":
        backfill("--force" in argv)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
