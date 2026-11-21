---
name: review-boards
description: Write, refresh and clean up the Whiteboard boards of a design review - layout grid, sizes, the review's four colours, link cards, reading before writing, version pins, batches, consolidating one-off boards, and how to brief a subagent to refresh boards from git. Use it whenever a board is created or changed for a review (the design-review skill), when the Operator says "refresh the boards", "clean up the boards", "put it on a board", or when a board looks cluttered or stale.
---

# Writing review boards

The process (which boards, when, decisions) is the design-review skill. This skill is the craft.
Facts about the Whiteboard type, and what went wrong before: the design-review skill's
`references/lessons.md`.

## Before any write

1. Read the board: `board/meta` (title, order, version) and `elements` (limit 1000, saved to files
   when large). Note each element's version; pins are required.
2. Find where the new content belongs by the board's logic (the section about that subject), not
   the first free space. Compute the bottom edge from the elements' y + h when adding below.
3. Decide every position before writing: place one element, derive the next from it.

## Layout

- A board is a column of sections, about 1,500 wide. New sections go below, never past the right
  edge. Keep a fresh board within about 1,500 x 750.
- Top: title (size title), takeaway (size large, at most ten words), "current as of <date>".
- Sections: a container per subject, title inside its frame (it sits 28 above the box). Content 24
  inside the edges, 24 between neighbours, 64 between boxes joined by an arrow, 144 when the arrow
  has a label.
- Steps: a row of equal boxes (about 230 x 84 for two short lines), at most five per row.
- Cards in a column: equal width, a fixed step (e.g. 60 high, 84 step); a column of ten is the most
  that reads at a glance.
- Tables for anything compared point by point; never a grid of boxes. Column width at least 10 per
  letter of its longest word plus 26.
- Few words: a bold name and one short line per box. Explanations as one short text block per
  section, not paragraphs in boxes.
- Size boxes generously (half the font size per character, one and a half times per line); an
  overfull box draws over its neighbours.

## Colours: the same on every board of the review

green = built, accepted, decided · peach = in progress, later, a catch or risk · white = neutral,
not chosen · blue = one highlight, named in the board's text. Never more than four.

## Changing a board

- Change only what changes: `update` the changed fields, pinned to the version read. Never rebuild
  a board the Operator may have arranged.
- When something is decided: **delete its explanation section** (the options, the catch, worked
  examples, and every arrow into them), fold the outcome into the standing board where its
  subject lives (one or two lines or one small card, citing the PR or ADR), add one line to the
  State board's "Decided" list, and move the sections below up to close the gap. Status cards that
  stay (in progress, built) turn green with "decided <date>"; never keep "not chosen" options on a
  board.
- When something is superseded: delete the section (and every arrow pointing into it), add one line
  "Decided: <what>; <what was dropped>", and move the sections below up to close the gap.
- After adding or deleting: write `board/meta.order` with every remaining id, back to front,
  containers first.
- Batches of at most 50 writes; one stale pin refuses the whole batch: re-read and resend.

## Boards and links

- One board per standard artifact; the State board links to the other five (link cards, 320 x 56,
  `kind: whiteboard`), each other board has one card back to State under its title.
- Never a one-off board for an explanation: fold it into the board where the subject lives. To
  remove one-offs: move their content first, remove their link cards, then delete each board one at
  a time (each delete is confirmed by the Operator).

## Briefing a subagent to refresh

Give it: the board URLs; the source of truth (git paths on origin/main, read with `git show`, no
edits); what is true now in a short list (versions released and merged, open PRs, rulings with
dates); what to remove or collapse; the colour table; the layout rules above; "in place, pinned,
no new boards"; and "reply with what changed per board and each contradiction with git you fixed".
Run one board-writing agent at a time. Relay its report in a few lines, and say the layout was not
seen on screen.
