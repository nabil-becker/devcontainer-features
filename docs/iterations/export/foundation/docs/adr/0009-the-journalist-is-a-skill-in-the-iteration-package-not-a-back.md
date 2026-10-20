---
iteration: 3
date: 2026-10-20
sources:
  - docs/adr/0009-the-journalist-is-a-skill-in-the-iteration-package-not-a-back.md
---
# ADR-0009: The journalist is a skill in the iteration package, not a back

| | |
|---|---|
| **Status** | superseded by [ADR 0014](0014-the-seed-is-exported-and-imported-by-two-skills-and-the-journalist-is-folded-into-the-export.md) |
| **Date** | 2026-10-17 |
| **Deciders** | the Operator; proposed by the host |

## Context

The journalist was proposed as a back that tells the story of the iterations
(`docs/proposals/journalist-back.md`). It was accepted on 2026-10-16 with a changed purpose: to
write the iteration's white paper when the Operator calls the iteration, rather than a piece per
ledger review. ADR-0008 then settled what the white paper is (an honest account, detail over
summary) and left one point open: whether the journalist stays a back or becomes only a skill
(`docs/proposals/iteration-package.md`). The forces: a back runs unattended after each turn with
a guard, a model tier and a per-run cost, while the white paper is written once per iteration, in
conversation with the Operator, who decides what is foundational and what the story is. Backs only
add and are never asked questions; this work is judgement that needs the questions.

## Decision

The journalist is a skill, not a back. It is part of the iteration package and ships with the
package's instructions. It writes the white paper in conversation with the Operator when the
iteration is called. No journalist back, trigger, guard or per-review journal piece is built.
The original proposal's sources (ledger, review, cost report, git log, night-shift reports) still
apply as the skill's inputs, and the honest-account rules of ADR-0008 bind its output.

## Options considered

### Option 1: a skill in the iteration package (chosen)

The work happens once per iteration and needs the Operator in the loop, which is what a skill
gives. It costs one conversation instead of a standing back, needs no guard or schedule, and
travels with the package to the next project.

### Option 2: a back, run after each ledger review

Pieces would accumulate on a rhythm without anyone asking. It lost because the white paper is
written once, not per review, a back cannot ask the Operator what matters, and it would add
standing cost (estimated at 3 to 10 percent of back spend) for work done rarely.

### Option 3: a back run once when the iteration is called

Keeps the guard and the unattended shape. It lost because nobody is present to make the
judgement calls, and the product is a read by the Operator, not a record.

## Consequences

- No new back, hook or guard; the cost is the conversation that writes the paper, tracked like
  any session.
- The skill must be written and shipped with the package's instructions (backlog item
  `journalist-skill`).
- `docs/proposals/journalist-back.md` stays as history; its sources and the trial's measures
  remain useful to the skill.
- The open point in ADR-0008's consequences (back or only the skill) is closed by this record.

## Change log

| Date | Change |
|---|---|
| 2026-10-17 | First draft; accepted by the Operator in the session. |
| 2026-10-20 | Superseded by ADR 0014: the journalist is a brief inside `drop-a-seed`, not a skill (the Operator, closing interview 3, question 13). |
