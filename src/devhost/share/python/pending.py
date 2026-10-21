#!/usr/bin/env python3
"""The scribe's PENDING line, with a limit: an item carried three runs in a row is dropped.

Usage: pending.py <pending file> <the PENDING text the run printed>   prints the text to keep

The scribe writes its PENDING line as items separated by `;`. The job keeps that line in
`pending-<session id>` and hands it back on the next run. Without a limit an item the scribe
can never resolve (its start is gone, its end never comes) is carried for good. Here each
item has a run count in a sidecar next to the pending file (`<pending file>.counts`, JSON):
an item that comes back unchanged (case and spacing aside) counts one more, a new item
starts at one, and at LIMIT it is dropped, with a line on stderr for the job log. An item the
scribe rewords counts as new; the limit then catches only items that are carried as they are.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

LIMIT = 3
SEPARATOR = ";"


def split_items(text: str) -> list[str]:
    items = [" ".join(part.split()) for part in text.split(SEPARATOR)]
    return [item for item in items if item and item.lower() != "none"]


def key(item: str) -> str:
    return item.lower().rstrip(".")


def carry(previous: dict[str, int], text: str, limit: int = LIMIT) -> tuple[list[str], list[str], dict[str, int]]:
    """(kept items, dropped items, new counts) for the items the run printed."""
    kept, dropped, counts = [], [], {}
    for item in split_items(text):
        if key(item) in counts:
            continue
        count = previous.get(key(item), 0) + 1
        if count >= limit:
            dropped.append(item)
        else:
            kept.append(item)
            counts[key(item)] = count
    return kept, dropped, counts


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    pending, text = Path(argv[0]), argv[1]
    sidecar = pending.with_name(pending.name + ".counts")
    try:
        previous = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        previous = {}
    kept, dropped, counts = carry(previous if isinstance(previous, dict) else {}, text)
    try:
        sidecar.write_text(json.dumps(counts), encoding="utf-8")
    except OSError as err:
        print(f"pending counts not saved: {err}", file=sys.stderr)
    for item in dropped:
        print(f"dropped a pending item carried {LIMIT} runs: {item[:160]}", file=sys.stderr)
    sys.stdout.write(f"{SEPARATOR} ".join(kept))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
