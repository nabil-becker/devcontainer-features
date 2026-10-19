---
name: journalist
description: Draft an iteration's white paper, the story of what was built, tried, broken and learned, in conversation with the Operator, then hand it to devhost-package. Use it when the Operator calls the iteration ("write the paper", "export the seed", "package this iteration") or asks for the white paper or the iteration package. The paper is source material for the final white paper, so it is an honest account (ADR 0008), never a polished one.
---

# Write the iteration's white paper

The paper is the only thing of this iteration that travels unchanged, and the Operator drafts the
final white paper from it. The rules are ADR 0008's: what to write is below, how it is assembled
is `devhost-package`. Plain words (ADR 0004); the life labels of ADR 0007 shape the story, not
the sentences. You draft; the Operator decides and trims, at the end.

## The rules

- **The narrative is the spine:** what happened, in order, and why it mattered. Detail hangs on it.
- **Every fact traces to a record:** a ledger entry, a review, a night-shift report, an ADR, a
  commit, the cost report. Cite it in the text (file and entry title, ADR number, short hash).
  A fact with no record is not written; ask the Operator or mark it a gap.
- **Numbers come only from the cost report or an entry's Measures line.** Never from memory, never
  recomputed by guess; say "not measured" where it was not.
- **Guesses are marked** (`Guess:`) and **gaps are marked** (`Gap:`), where the text would
  otherwise read as known. Example: how iteration 3 got its context beyond the porting commit.
- **Failures are told with successes:** the false starts, corrections (`Corrects:` entries), ideas
  dropped, reverted changes, and what each cost.
- **Detail over summary:** dates and order, counts, before and after, friction as recorded, each
  decision with the alternatives weighed, commands and guards by their real names.
- **Nothing is smoothed.** Do not polish a failure into a lesson learned.

## Steps

1. **Read the records in order:** `docs/ledger/*.md` oldest first (skip an entry a later one
   `Corrects:`, but keep the correction in the story), each `## Review` section, `docs/night-shift/`,
   `docs/adr/`, the cost reports `docs/ledger/costs-*.md` (`task devhost:report` rebuilds one), and
   `git log` for dates and hashes. Read the papers received (`docs/iterations/package/papers/`)
   and `docs/proposals/iteration-package.md` for what the series needs.
2. **Propose an outline.** Sections in story order, each with the records it will draw on, the gaps
   you already see and your candidates for the foundation (what showed its worth, on the evidence
   of frictions, learnings and measures). Wait for the Operator to agree or reshape it.
3. **Draft section by section.** After each, show it and ask: what is wrong, missing or
   unclear? Revise from the answer. Write to `docs/iterations/papers/iteration-<N>.md`.
4. **Settle the foundation with the Operator.** One path per line in
   `docs/iterations/foundation.txt` (`#` comments; `!path` marks a file copied untouched). It
   holds only what the Operator names; the tooling is not foundation (the OS is not the package).
5. **The Operator trims at the end.** Offer, never apply, cuts. Check once more that every
   number and claim still has its source and every guess its marker.
6. **Hand over.** Run `task devhost:package -- --iteration <N> --paper docs/iterations/papers/iteration-<N>.md`
   (add `--out` for another folder). Exit 2 is a refusal with its reason (missing manifest entry,
   output folder not empty, a received paper that changed): fix the cause, never work around it.
   Read `PACKAGE.md` with the Operator, then `task devhost:verify` and `/close-session`.

## Why

The records fade and a summary hides what it left out; detail can be trimmed later but never
recovered. A paper that errs on completeness and truth keeps the Operator's trimming possible.
