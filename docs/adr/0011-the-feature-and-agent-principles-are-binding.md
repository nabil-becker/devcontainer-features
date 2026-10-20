# ADR-0011: The agent principles and the Feature requirements are binding

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-19 |
| **Deciders** | the Operator; proposed by the host |

## Context

What every Feature guarantees and how agents work here lived in README, CONTRIBUTING, the code,
briefs and ledger lessons. Two drafts collected them on 2026-10-16
(`docs/proposals/feature-principles.md`, `docs/proposals/agent-principles.md`): ten Feature
principles, each with how it is checked and a count of today's Features, and fourteen agent
principles, each with the ledger evidence it came from and what enforces it. The Operator
reviewed them on 2026-10-19 and accepted both. On 2026-10-20 the Operator trimmed the agent
principles to five generic ones and renamed the Feature principles non-functional requirements
(ADR 0013); this record states the result.

## Decision

`docs/principles/agents.md` (the five agent principles P1 to P5) and
`docs/principles/non-functional-requirements.md` (the Feature requirements NFR-1 to NFR-10) are
binding. Every work item that touches a Feature must meet the requirements, or record a backlog
item or a written exception in the Feature's NOTES; a failing requirement does not block a
release. A principle or requirement changes only by an ADR that supersedes this one for it. The
devhost ships all five principles to consumers; nothing is excluded (the old product-first rule is
part of P3's purpose). No Feature offers an MCP server for now; tasks are the agent API.

## Options considered

### Option 1: binding files, changed by ADR (chosen)

One place to cite, checkable rules, and a change leaves a record of why.

### Option 2: keep them as proposals

Nothing would hold a session or a Feature to them; the review that accepted them would be lost.

### Option 3: one ADR per principle

Many records for rules that were decided together; the files already carry the evidence.

## Consequences

- Reviews and briefs can cite a principle by id.
- Lint rules for the automatable requirements (`feature-principles-lint`) and a conformance
  table per Feature (`feature-conformance`) follow.
- `devhost-init` must ship the five principles to consumers (`agent-principles-ship`).
- "Today" counts and "Enforced by" lines go stale unless updated with the change that moves them.

## Change log

| Date | Change |
|---|---|
| 2026-10-19 | First draft, accepted by the Operator: ten Feature principles and fourteen agent principles. |
| 2026-10-20 | Restated for five agent principles (P1 to P5) and the Feature requirements renamed NFR-1 to NFR-10; the devhost ships all five; see ADR 0013. |
