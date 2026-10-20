---
iteration: 3
date: 2026-10-20
sources:
  - docs/adr/0003-backs-only-add-so-change-stakes-become-amend-items.md
---
# ADR-0003: Backs only add, so a stake that asks for a change becomes an amend item

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

The backs may only add to their records; a guard undoes anything else (the secretary may add and
tick backlog items, never reword, remove or reorder). A diagnosis of the backs' failures found
that in two of the four runs where the guard undid the secretary's edit, the host's own stake had
asked the secretary to reword an existing item. The secretary tried, the guard undid it, the
stake stayed pending, and the secretary retried on every turn. The same diagnosis found the
guard logged only the old line, not what the edit tried to change, so one undone run could not
be explained. It also found the scribe's mistakes were pipeline faults (clipped hand-offs, jobs
dropped under a lock), not a model that was too small; the one "Friction: none" it copied was
honest copying of a con that had hidden its workaround.

## Decision

A back never rewords an existing record, and nobody asks it to. A stake that asks the secretary
to change an item is turned into a new `amend-<id>` backlog item naming the item and the change,
and the host or the Operator makes the change by hand. The secretary does not retry the same
stake on later turns. An undone run logs what the edit tried to change. The scribe stays on the
smallest model; it reads the con's full Friction, For the repository and Decisions needed
sections, never clipped, and writes "not reported" rather than "none" when a section is missing.
A con's Friction includes the problems it worked around, not only those that blocked it.

## Options considered

### Option 1: amend items, scribe stays on the small model (chosen)

It keeps the rule that backs only add, so the guard stays simple and trustworthy, and it fixes
the causes the evidence pointed at instead of the model.

### Option 2: let the secretary reword on a stake

It would end the retries, but it breaks the add-only rule that the guard and the lexicon rest
on, and every other back would then ask for the same exception.

### Option 3: move the scribe to a larger model

The measured faults were clipping and dropped jobs, which a larger model would not have seen
either; it would cost more for no change in what the scribe is shown.

## Consequences

- The backlog gains `amend-<id>` items for changes only a person may make; the host works them
  down.
- A stake never asks a back to reword, remove or reorder; it asks for an addition.
- The guard's log shows what each undone edit attempted, so a repeated undo can be explained.
- The scribe's ledger entries tell "none" from "not reported", so a missing section is visible at
  review.
- The fixes land in the devhost Feature and need a release before consumers have them.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
