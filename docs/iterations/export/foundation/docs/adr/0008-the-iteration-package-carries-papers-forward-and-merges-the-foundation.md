---
iteration: 3
date: 2026-10-20
sources:
  - docs/adr/0008-the-iteration-package-carries-papers-forward-and-merges-the-foundation.md
---
# ADR-0008: The iteration package carries papers forward, merges the foundation, and its papers are honest accounts

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

Each iteration of the Agentic Delivery OS ends by handing the next project what it needs to
start. The first two iterations had no such hand-over: DSNP (software project 1) read the article from the first
directly, and this repository was ported by reading both earlier repositories
(`docs/iterations.md`, `docs/proposals/iteration-package.md`). This repository will export the
first package. The Operator drafts the final white paper from the papers the iterations leave,
trims it, and releases the raw material with V1 of the Agentic Delivery OS, so what an
iteration writes down is the only thing that will survive of it: the records fade, and a
summary hides what it left out.

## Decision

The package holds what the iteration finds foundational, decided when the Operator calls the
iteration, not a fixed list, and never the OS tooling. White papers carry over unchanged. The
foundation is merged by each iteration and never nested: only the newest travels, and a trait
that proves a one-off is dropped again. The package received is saved in the repository as it
arrived, in `docs/iterations/package/`, with one part telling the agent that the file is the
source of the next export and must not be deleted. Adoption and production are conversations:
the package says what to ingest and why, not how to transform it. The format is Markdown with a
short front matter per file (iteration, date, sources), so people and agents read it without
tools.

A seed's white paper is an honest account, source material rather than polish:

- what went wrong is told with what went right, with what each cost;
- every fact traces to a record (ledger, review, report, ADR, commit), and numbers come from the
  cost report, never from memory;
- guesses are marked as guesses and gaps as gaps;
- nothing is smoothed for the reader; trimming is the Operator's job at the end;
- detail over summary, hung on the spine of the story: the narrative is what happened, in order,
  and why it mattered, and detail (dates, numbers, friction as recorded with its entry, each
  decision with the alternatives weighed, commands and guards by their real names, what each
  change made better or worse) hangs on it, because detail can be trimmed later but not
  recovered.

Earlier iterations are not reconstructed (no true-up): iteration 1's article is kept as used,
the first package carries it as DSNP (software project 1) received it, and this repository's paper names what came
over, so the lineage is recorded once. The package is assembled by a script and the judgement
work is done in a skill (AP-14).

## Options considered

### Option 1: papers carried, foundation merged, honest-accounts rules (chosen)

Every paper stays readable on its own and the foundation stays one set, so a package never
grows nested copies of itself. Completeness at the source keeps the Operator's trimming
possible. It costs larger papers and a discipline of tracing each fact.

### Option 2: a nested package, each iteration wrapping the one it received

The history would be whole in one place. It lost because the packages would grow by
repetition and the newest foundation would be buried under its ancestors.

### Option 3: a fixed list of what every package contains

Predictable to assemble. It lost because what is foundational is a finding of each iteration,
on the evidence of its frictions, learnings and measures; a list would freeze iteration 3's
view.

### Option 4: summaries, polished for the reader

Shorter papers, nearer to the final one. It lost because a summary hides what it left out and
the records fade; detail can be trimmed but not recovered.

### Option 5: reconstruct iterations 1 and 2 as packages (a true-up)

A complete lineage in the same shape. It lost because it would rewrite a story that happened
differently: no package existed, and no record shows the article was read here.

## Consequences

- The papers will be long and detailed; trimming them is the Operator's work at the end.
- Every iteration must keep complete records (the ledger, reviews, cost reports), since the
  paper's facts trace to them.
- A script (assembling, with tests) and a skill (what is foundational, the paper, the foundation)
  are still to be built, when the Operator calls the iteration; whether the journalist stays a
  back or becomes only the skill is open.
- The other projects are aligned on the story only and produce nothing for it.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft; accepted by the Operator in the session. |
| 2026-10-20 | The projects' names in the papers added in brackets: iteration 1 is "the office", iteration 2 (DSNP) "software project 1" (the Operator, closing interview 3, question 41). |
