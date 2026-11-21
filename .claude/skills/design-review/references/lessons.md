# Lessons from the sessions behind this skill

Raw notes, kept as they were learned. Two sessions, 2026-11-19 to 2026-11-21: the component
registry design and build (Component-Registery-Feature) and the facilitator (Facilitator-Feature).

## What the Operator asked for, in their words

- "Put it on a board, the console is hard to read. I'm a visual learner and a weak reader."
- "The html never renders the diagrams well and I cant move them." (HTML + Mermaid rejected.)
- "Refresh the artifacts. Remove the one off artifacts, we dont need all of these."
- "State of the arch needs rebuilding." (A long table read badly; three columns read well.)
- "Refresh and clean up the boards."
- "Explain A1 to me" / "So with option 2, what would the configs look like?" (explanations and
  examples go on the board, next to the decision).
- "No I meant lets go over A3, not lets do a3 as recommended." (A question is not a ruling.)
- "Before I talk about facets, I'm noticing the statements around the layers [are not]
  consistent, and I want to make sure we are on the same page." (Restate the model on a board.)

## What worked

- One board per standard artifact; the State board as the entry point with links to the rest and
  a card back on each board.
- Three columns on State: built (green), in progress (peach), next (white, numbered).
- A decision drawn as inputs on the left and options as cards on the right, with a concrete
  example (the agents list says opus, the registry says sonnet → which runs).
- "What would the configs look like": the actual files side by side, then a table of results.
- Recolouring a card green with "decided <date>" the moment it was ruled.
- Folding one-off explanation boards into the standard boards, then deleting the one-offs.
- Collapsing superseded alternatives (RDF graph, first merge-rule idea, query syntax options) to
  one "Decided: ..." line each; the board got about 1,400 units shorter.
- Giving a board refresh to a Sonnet subagent with: the boards' URLs, what is true now (versions,
  PRs, rulings with dates), what to remove, the colour rule, and "list each contradiction with git
  you fixed".
- A compact "Open now" table (call, question, recommendation) answered in shorthand ("AA-AI y",
  "1234 y"); a "Decided so far" table (call, decision, where recorded).

## What went wrong

- Boards grew to about 200 elements and got cluttered; sections overflowed into each other because
  agents guessed heights without seeing the render. Fix: fewer words, fewer elements, generous
  section heights, one board per artifact, prune on every refresh.
- Colours drifted between boards. Fix: one colour table for the review (green/peach/white/blue).
- Boards went stale after every merge and release. Fix: refresh after every ruling, merge or
  release, from git.
- Rationale for a ruling lived only in chat; the board had one line. Fix: record the ruling and its
  reason in the proposal or ADR at once.
- Call letters ran out and collided with slice names (A to CF). Fix: a prefix per area, short
  sequences, never shared with slice or PR names.
- One-off boards multiplied (an explanation, a model restatement, a query-syntax comparison).
  Fix: put explanations on the standard board where the subject lives.
- Five deletes sent at once all failed; one at a time worked. Deletes need the Operator's
  confirmation each.
- A board text "release due" stayed after the release ran. Fix: re-read the facts before the
  refresh brief; say "released through X" not "due".
- "lets do A3" was read as a ruling and two agents were told to build it; it had to be retracted.
  Fix: only shorthand answers to an explicit question ("A3 y", "option 2") are rulings.
- A test wrote into the real Claude skills folder through an installed adapter; a refresh of a
  board also once used the wrong state. Not board-specific, but: test and render in isolation.

## Facts about the Whiteboard type worth remembering

- Content lives in the board's own store (ArtifactData), never in files. Create a board by
  publishing with the Whiteboard `type_url` and a title, then fill it with `batch` writes.
- Read before writing to a board this conversation did not just write: `board/meta` and the
  `elements` list. Every write to an existing document needs `if_version`; one stale pin refuses
  the whole batch (atomic) - re-read and resend.
- At most 50 writes per batch. New ids `e<n>` above the highest on the board.
- `board/meta.order` lists every id back to front, containers first; update it after adding or
  deleting. Delete arrows with the element they point at.
- A section's title sits 28 units above its box; keep content 24 inside. 24 between neighbours,
  64 where an arrow runs, 144 where it carries a label.
- Text width: about half the font size per character; body text is 16, small 14, large 28,
  title 48. A box too small for its words is drawn larger over its neighbours - size generously.
- Strikethrough (`~~`) is not a supported mark; say "not chosen" in words instead.
- Link cards (`type: link`, 320 x 56, `kind: whiteboard`) connect boards; one per target.
- A list result shows versions only for the first 50 documents in its text; read the rest from
  the saved files' (id, version) pairs carefully.
- Nobody sees the render while writing; report that the layout is unchecked and invite the
  Operator to drag things.
