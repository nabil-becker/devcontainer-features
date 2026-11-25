# ADR-0085: The host merges its own green pull requests, except governance, a review the Operator asked for and consumer-facing bumps; releases stay the Operator's

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-25 |
| **Deciders** | the Operator; proposed by the host |

## Context

The repository is one person's. ADR 0040 left merging to the Operator. The ruleset on `main` no
longer requires an approval (pull request 251, ruling BP1, 2026-11-25): the Operator said that
all they did was tick the box to override the rule and then merge, which provided no value. Auto-merge
is allowed on the repository (ruling RW1). The required checks (`validate`, `lint`, `tests`, `DCO`)
remain, so a green pull request is the gate that matters.

## Decision

The host may merge its own pull requests when they are marked ready, every required check is green,
and no Operator decision on them is open. It merges with squash and reports each merge in its reply.

The host does not merge, and leaves to the Operator:

1. changes to repository governance or CI permissions (`Set-RepoGovernance.ps1`, workflow
   `permissions:`, secrets, CODEOWNERS);
2. a pull request the Operator asked to review;
3. a version bump that reaches the consumers (the office, DSNP) before they are told.

Starting releases stays the Operator's. The host's git job in ADR 0040 (commits, pushes, pull
requests, keeping the checkout current) stays; only its merging part is superseded.

## Options considered

### Option 1: the host merges its own green pull requests, with three exceptions (chosen)

Removes a step that was a self-override. The changes that carry risk beyond the checks (governance,
consumers) and anything the Operator wants to read stay with the Operator.

### Option 2: the Operator keeps merging

The approval it supported was a self-override and gave no value; every pull request waited on a
click that decided nothing.

### Option 3: the host merges everything

Governance and consumer-facing changes need the Operator's eyes whatever the checks say.

### Option 4: auto-merge on every pull request

Same effect as Option 1 but less visible: nothing in the reply says a merge happened, and the
exceptions would need to be enforced by switching it off per pull request.

## Consequences

- Fewer waits on the Operator; each merge is reported in the host's reply.
- The host must check the three exceptions before merging; a pull request touching them waits.
- The living rule documents say the host merges (`CLAUDE.md`, the devhost include and its template,
  `PROCESS.md`, `CONTEXT.md`, the reference architecture, the workflow and data-flow pages).

## Change log

| Date | Change |
|---|---|
| 2026-11-25 | First draft, accepted by the Operator (ruling BP2). |
