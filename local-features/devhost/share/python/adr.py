#!/usr/bin/env python3
"""Create the next architecture decision record from the template (`devhost-adr`).

    devhost-adr Short title of the decision
    task devhost:adr -- Short title of the decision

Numbers the file after the highest existing ADR in the ADR directory (`DEVHOST_ADR_DIR`,
default `docs/adr`), fills the template's title, number and date, and adds a row to the index
in that directory's `README.md`, so `devhost-verify` keeps passing. Prints the two paths.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from devhost_common import adr_dir, read_text, rel, repo_root, slug, today, write_text  # noqa: E402

ADR_FILE = re.compile(r"^(\d{4})-[a-z0-9-]+\.md$")


def next_number(folder: Path) -> int:
    numbers = [int(m.group(1)) for p in folder.iterdir() if (m := ADR_FILE.match(p.name))]
    return max(numbers, default=0) + 1


def create(root: Path, title: str, date: str | None = None) -> tuple[Path, Path]:
    """Write the record and its index row; returns (record, index)."""
    folder = adr_dir(root)
    template, index = folder / "0000-template.md", folder / "README.md"
    if not template.exists() or not index.exists():
        raise FileNotFoundError(f"{rel(root, folder)}/ needs 0000-template.md and README.md (run devhost-init)")
    name_slug = slug(title)
    if not name_slug:
        raise ValueError("the title needs at least one letter or digit")
    number = next_number(folder)
    name = f"{number:04d}-{name_slug}.md"
    date = date or today()
    text = read_text(template)
    text = text.replace("# ADR-NNNN: Title", f"# ADR-{number:04d}: {title}", 1)
    text = text.replace("| **Date** | YYYY-MM-DD |", f"| **Date** | {date} |", 1)
    text = text.replace("| YYYY-MM-DD | First draft. |", f"| {date} | First draft. |", 1)
    write_text(folder / name, text)
    listing = read_text(index)
    if not listing.endswith("\n"):
        listing += "\n"
    write_text(index, listing + f"| [{number:04d}]({name}) | {title} | proposed | {date} |\n")
    return folder / name, index


def main(argv: list[str]) -> int:
    title = " ".join(a.strip() for a in argv if a.strip())
    if not title or title.startswith("-"):
        print(__doc__)
        return 2
    root = repo_root()
    try:
        record, index = create(root, title)
    except (FileNotFoundError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"created {rel(root, record)} and added it to {rel(root, index)}")
    print("next: fill the sections; the status stays 'proposed' until the Operator accepts it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
