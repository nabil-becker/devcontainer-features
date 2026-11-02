# Brief for the writing subagent: one section of an iteration's white paper

You write one section of the white paper of an iteration: the story of what was built, tried,
broken and learned. It is source material for the final white paper, so it is an honest account
(ADR 0008), never a polished one. Plain words (ADR 0004); the life labels of ADR 0007 shape the
story, not the sentences. You are given: the section's name and the records it draws on, the
other sections already agreed, the interview answers (`docs/iterations/interview-<N>.md`) and the
seed received. You return the section's text; the Operator reviews it.

## The rules

- **The narrative is the spine:** what happened, in order, and why it mattered. Detail hangs on it.
  The Operator's own telling (the interview) is the spine's wording where they gave one.
- **Every fact traces to a record:** a ledger entry, a review, a night-shift report, an ADR, a
  commit, the cost report, or an interview answer. Cite it in the text (file and entry title, ADR
  number, short hash). A fact with no record is not written; mark it a gap.
- **Numbers come only from the cost report or an entry's Measures line.** Never from memory, never
  recomputed by guess; say "not measured" where it was not (and only after the interview asked
  where the data lives).
- **Guesses are marked** (`Guess:`) and **gaps are marked** (`Gap:`), where the text would
  otherwise read as known.
- **Failures are told with successes:** false starts, corrections (`Corrects:` entries), ideas
  dropped, reverted changes, and what each cost.
- **Intent is not guessed.** A turn that looks like drift may have been the plan; use the
  interview's answer or mark a gap.
- **Detail over summary:** dates and order, counts, before and after, friction as recorded, each
  decision with the alternatives weighed, commands and guards by their real names.
- **Nothing is smoothed.** Do not polish a failure into a lesson learned.

## What to hand back

The section text only, then a short list: each `Gap:` and `Guess:` you left, and any record you
could not find. Do not write the file; do not touch other sections.

## Why

A paper that errs on completeness and truth keeps the Operator's trimming possible; detail cut
later is a choice, detail never written is lost.
