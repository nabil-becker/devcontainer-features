# ADR-0013: The agent principles are trimmed to five generic ones

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

On 2026-10-19 the Operator accepted fourteen agent principles (AP-1 to AP-14, ADR 0011), each
with ledger evidence. On 2026-10-20 the work on the iteration interview (`docs/proposals/iteration-package.md`)
produced five principles that are taught to a new Operator. They are generic: every Operator sets
them up for their own project. The fourteen are specific to this repository and its history, and
fourteen rules are too many to teach or to carry into another project. The Operator's call:
this is the next iteration, trimming the fat.

## Decision

The five principles replace the fourteen: P1 Separate personalization from process, P2 Continuous
improvement, P3 The agent knows its place, P4 Claims need evidence, P5 Right-size the work.
They are in `docs/principles/agents.md`. The fourteen are retired as principles. They are
kept as the learnings that inform the five, in `docs/proposals/agent-principles.md`, and this
table records where each one went.

| Old id | Slug | Now under | How |
|---|---|---|---|
| AP-1 | operator-decides | P4 | the operator is the judge |
| AP-2 | host-judges-cons-do | P5 | inters plan, cons do |
| AP-3 | report-is-not-evidence | P4 | the claimant carries the burden of proof |
| AP-4 | a-check-must-be-able-to-fail | P4 | evidence includes a check shown able to fail |
| AP-5 | size-by-blast-radius | P5 | the smallest thing that fits |
| AP-6 | every-unit-leaves-data | P2 | the ledger records friction and resource use |
| AP-7 | append-only-corrections | P2 | the ledger is append-only |
| AP-8 | backs-only-add | P3 | boundaries |
| AP-9 | plain-words-themes-as-labels | P1 | the shared language |
| AP-10 | nothing-leaves-unattended | P3 | boundaries |
| AP-11 | identities-are-unclaimable | P3 | boundaries |
| AP-12 | tasks-are-the-api | P3 | tooling |
| AP-13 | product-first | P3 | purpose |
| AP-14 | script-agent-ladder | P5 | the smallest thing that fits |

## Options considered

### Option 1: keep the fourteen

They are evidenced and already accepted. But they describe this repository, not a method another
Operator can adopt, and a person cannot be taught fourteen rules in an interview.

### Option 2: trim to five generic principles (chosen)

The five are what the interview teaches, and each Operator sets them up. The learnings still
inform them: the evidence is cited in the "Why" of each principle.

### Option 3: scrap them with no record

Loses the reasoning, and the ledger and ADRs still cite the old ids.

## Consequences

- P4 ("Claims need evidence", with the court as its picture) and P5 ("Right-size the work") were named and worded with the Operator on 2026-10-20.
- Old AP ids in the ledger, ADRs and the proposal stay as history and resolve through the table
  above.
- `devhost-init` ships the five (`agent-principles-ship`); nothing is left out for consumers.
- ADR 0011 is restated for the five and for the Feature requirements (NFR-1 to NFR-10, the old
  FP-1 to FP-10 renamed, same content and order).
- The enforcement gaps listed with the fourteen (a mechanical hand-off check, a spend cap,
  `guard-corrects-none`) remain open under the principle that now holds them.

## Change log

| Date | Change |
|---|---|
| 2026-10-20 | First draft, accepted by the Operator. |
