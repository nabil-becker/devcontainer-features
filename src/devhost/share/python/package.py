#!/usr/bin/env python3
"""Assemble the iteration package (`devhost-package`), the seed an iteration exports.

    devhost-package --iteration 3 --paper docs/iterations/papers/iteration-3.md
    task devhost:package -- --iteration 3 --paper <new paper> [--out <folder>]

Options (paths are relative to the repository root unless absolute):

    --iteration N   the iteration being exported (required)
    --paper FILE    the new white paper (required)
    --received DIR  the package received, as it arrived (default docs/iterations/package; may be
                    missing for the first package)
    --papers DIR    papers kept in this repository, carried along too (default
                    docs/iterations/papers; may be missing)
    --foundation F  manifest of the foundation files: one repository-relative path per line,
                    `#` comments; a line `!path` marks an original, copied untouched
                    (default docs/iterations/foundation.txt)
    --readme FILE   the seed's README, copied untouched to the package root as README.md
                    (default docs/iterations/seed/README.md)
    --starter DIR   the starter folder, copied untouched to starter/
                    (default docs/iterations/starter)
    --skills LIST   comma-separated skill names whose folders .claude/skills/<name>/ are copied
                    whole and untouched to skills/<name>/
                    (default plant-a-seed,drop-a-seed,ledger-review,shutdown-devhost,restart-devhost)
    --out DIR       where the package is written; must be missing or empty
                    (default docs/iterations/export)
    --date D        YYYY-MM-DD (default today)

The package is a seed: a plain folder holding `README.md` (the entry point an agent is pointed
at), `starter/` (what the next place begins with), `skills/` (`plant-a-seed`, which imports it,
`drop-a-seed`, which exports the next one, `ledger-review`, and `shutdown-devhost` with
`restart-devhost`), `papers/` (every paper received,
byte for byte, the papers kept here, the new paper), `foundation/<repository path>` (the
manifest's files) and `PACKAGE.md`: iteration, date,
every file with its sha256 and kind (paper, original, derived, foundation), and the instruction
that the folder is the source of the next export and must not be deleted. A Markdown file the
script writes gets front matter (iteration, date, sources) only where it has none; a file it
only copies stays as it was: papers received and originals (non-Markdown, or marked `!`) are
never touched, a Markdown foundation file that gains front matter is `derived`.

Refuses, exit 2, writing nothing: a missing README, starter folder or skill folder, a manifest or
listed file that is missing, an output folder that
is not empty, a received package without a `PACKAGE.md`, a received paper that is missing or whose
sha256 differs from its index, two different files for one paper name.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import repo_root, today  # noqa: E402

INDEX = "PACKAGE.md"
ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*([0-9a-f]{64})\s*\|\s*(\w+)\s*\|\s*$")
DEFAULTS = {"received": "docs/iterations/package", "papers": "docs/iterations/papers",
            "foundation": "docs/iterations/foundation.txt", "readme": "docs/iterations/seed/README.md",
            "starter": "docs/iterations/starter",
            "skills": "plant-a-seed,drop-a-seed,ledger-review,shutdown-devhost,restart-devhost", "out": "docs/iterations/export"}


class Refused(Exception):
    """A refusal: reported on stderr, exit 2."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def has_front_matter(data: bytes) -> bool:
    return bool(re.match(rb"---\r?\n(.*?\r?\n)?---[ \t]*(\r?\n|$)", data, re.S))


def front_matter(iteration: str, date: str, sources: list[str]) -> bytes:
    lines = ["---", f"iteration: {iteration}", f"date: {date}", "sources:", *[f"  - {s}" for s in sources], "---", ""]
    return "\n".join(lines).encode("utf-8")


def resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def parse_manifest(root: Path, manifest: Path) -> list[tuple[str, bool]]:
    """(repository-relative path, is_original) per line; refuses a missing manifest or entry."""
    if not manifest.is_file():
        raise Refused(f"the foundation manifest {manifest} is missing: list the foundation files, one repository-relative path per line")
    entries: list[tuple[str, bool]] = []
    problems: list[str] = []
    for number, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        original = text.startswith("!")
        name = text[1:].strip() if original else text
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            problems.append(f"{manifest.name}:{number}: {name} is not a repository-relative path")
        elif not (root / path).is_file():
            problems.append(f"{manifest.name}:{number}: {name} is listed but is not a file")
        else:
            entries.append((path.as_posix(), original))
    if problems:
        raise Refused("the foundation manifest has entries that cannot be copied:\n  " + "\n  ".join(problems))
    return entries


def received_papers(folder: Path) -> list[tuple[str, bytes]]:
    """The papers of the package received, hash-checked against its index; none when it is missing."""
    if not folder.exists():
        return []
    index = folder / INDEX
    if not index.is_file():
        raise Refused(f"the package received at {folder} has no {INDEX}: it is not a package, so its papers cannot be checked")
    papers: list[tuple[str, bytes]] = []
    problems: list[str] = []
    for line in index.read_text(encoding="utf-8").splitlines():
        match = ROW.match(line)
        if not match or match.group(3) != "paper":
            continue
        name, expected = match.group(1), match.group(2)
        path = folder / name
        if not path.is_file():
            problems.append(f"{name}: listed in the received {INDEX} but missing")
            continue
        data = path.read_bytes()
        if sha256(data) != expected:
            problems.append(f"{name}: sha256 is {sha256(data)[:12]}..., the received {INDEX} says {expected[:12]}... (papers carry over unchanged)")
        else:
            papers.append((name, data))
    if problems:
        raise Refused("a paper received has changed or is gone:\n  " + "\n  ".join(problems))
    return papers


def assemble(root: Path, iteration: str, paper: Path, received: Path, papers_dir: Path, manifest: Path,
             out: Path, date: str, readme: Path, starter: Path, skills: list[str]) -> list[tuple[str, str, str]]:
    """Check everything, then write the package; returns (path, sha256, kind) per file."""
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise Refused(f"the output folder {out} is not empty: the package is written into a fresh folder")
    if not paper.is_file():
        raise Refused(f"the new paper {paper} is missing")
    foundation = parse_manifest(root, manifest)
    if not readme.is_file():
        raise Refused(f"the seed README {readme} is missing")
    if not starter.is_dir():
        raise Refused(f"the starter folder {starter} is missing")
    skill_files: list[tuple[str, Path]] = []
    for name in skills:
        folder = root / ".claude" / "skills" / name
        if not folder.is_dir():
            raise Refused(f"the skill {name} is missing: there is no folder {folder}")
        skill_files += [(f"skills/{name}/{p.relative_to(folder).as_posix()}", p) for p in sorted(folder.rglob("*")) if p.is_file()]
    plan: dict[str, tuple[bytes, str]] = {}  # package path -> (bytes, kind)

    def put_paper(name: str, data: bytes) -> None:
        key = f"papers/{name}"
        if key in plan and plan[key][0] != data:
            raise Refused(f"two different files for the paper {key}: rename one")
        plan[key] = (data, "paper")

    for name, data in received_papers(received):
        key = name if name.startswith("papers/") else f"papers/{name}"
        if key in plan and plan[key][0] != data:
            raise Refused(f"two different files for the paper {key}: rename one")
        plan[key] = (data, "paper")
    if papers_dir.is_dir():
        for path in sorted(p for p in papers_dir.iterdir() if p.is_file() and p.resolve() != paper.resolve()):
            put_paper(path.name, path.read_bytes())
    data = paper.read_bytes()
    if paper.suffix == ".md" and not has_front_matter(data):
        data = front_matter(iteration, date, [_display(root, paper)]) + data
    put_paper(paper.name, data)
    for name, original in foundation:
        data = (root / name).read_bytes()
        kind = "foundation"
        if original:
            kind = "original"
        elif name.endswith(".md") and not has_front_matter(data):
            data, kind = front_matter(iteration, date, [name]) + data, "derived"
        elif not name.endswith(".md"):
            kind = "original"
        plan[f"foundation/{name}"] = (data, kind)

    plan["README.md"] = (readme.read_bytes(), "original")
    for path in sorted(p for p in starter.rglob("*") if p.is_file()):
        plan[f"starter/{path.relative_to(starter).as_posix()}"] = (path.read_bytes(), "original")
    for key, path in skill_files:
        plan[key] = (path.read_bytes(), "original")

    out.mkdir(parents=True, exist_ok=True)
    files: list[tuple[str, str, str]] = []
    for key in sorted(plan):
        data, kind = plan[key]
        target = out / key
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if sha256(target.read_bytes()) != sha256(data):
            raise Refused(f"{key}: the copy does not match what was read (disk or permissions?)")
        files.append((key, sha256(data), kind))
    (out / INDEX).write_bytes(index_text(iteration, date, files, _display(root, received)).encode("utf-8"))
    return files


def _display(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def index_text(iteration: str, date: str, files: list[tuple[str, str, str]], received: str) -> str:
    rows = "\n".join(f"| `{name}` | {digest} | {kind} |" for name, digest, kind in files)
    skills = ", ".join(f"`{s}`" for s in sorted({name.split("/")[1] for name, _, _ in files if name.startswith("skills/")}))
    return "\n".join([
        front_matter(iteration, date, [received]).decode("utf-8").rstrip("\n"),
        "",
        f"# Iteration package, iteration {iteration}",
        "",
        f"Exported {date}. Papers carry over unchanged; the foundation is the newest, merged, never nested.",
        "",
        "This is a seed. Start at `README.md`; `starter/` is what the new place begins with, `skills/` holds the skills "
        f"({skills}): `plant-a-seed` imports the seed, `drop-a-seed` exports the next one.",
        "",
        "**Keep this folder in the repository. It is the source of the next export and must not be deleted.**",
        "",
        "Kinds: `paper` (carried or new, untouched except front matter on the new one), `original` (copied untouched: the README, the starter, the skills), "
        "`derived` (a Markdown file that gained front matter), `foundation` (copied as it was).",
        "",
        "| File | sha256 | Kind |",
        "|---|---|---|",
        rows,
        "",
    ])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="devhost-package", description=__doc__.split("\n")[0])
    parser.add_argument("--iteration", required=True)
    parser.add_argument("--paper", required=True)
    for name, default in DEFAULTS.items():
        parser.add_argument(f"--{name}", default=default)
    parser.add_argument("--date", default=None)
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code or 0)
    root = repo_root()
    try:
        files = assemble(root, args.iteration, resolve(root, args.paper), resolve(root, args.received),
                         resolve(root, args.papers), resolve(root, args.foundation), resolve(root, args.out),
                         args.date or today(), resolve(root, args.readme), resolve(root, args.starter),
                         [n.strip() for n in args.skills.split(",") if n.strip()])
    except Refused as exc:
        print(f"devhost-package: {exc}", file=sys.stderr)
        return 2
    kinds = {k: sum(1 for _, _, kk in files if kk == k) for k in ("paper", "original", "derived", "foundation")}
    print(f"wrote {len(files)} files and {INDEX} to {_display(root, resolve(root, args.out))}: "
          + ", ".join(f"{n} {k}" for k, n in kinds.items() if n))
    print("next: keep that folder in the repository as the source of the next export; never delete it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
