# ADR-0053: A pull request is marked ready when the agent's work is done, and only with high confidence that CI passes

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-04 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0040 gives the host the git work and the Operator the review and the merge. It does not say
what "ready for review" means on a pull request. In one session a pull request was marked ready
while it still collided with another one, its checks failed, and the host put it back to draft to
fix it. The Operator clarified the rule: ready or draft is the agent's status on the work, it does
not mirror the CI checks, and the agent should not mark a pull request ready without a high level
of confidence that CI will pass, so that a pull request does not flap between ready and draft.

## Decision

Ready is the agent's status on its own work: the work on the pull request is done and the Operator
may review it. It is independent of the CI result. The agent marks a pull request ready only with
high confidence that CI will pass, which it gets from the checks run locally (`task lint`, the
Feature tests where a Docker daemon is available) and a trial merge against current `main` and the
other ready pull requests that comes out clean. When CI is red on a ready pull request, the agent
fixes it in place and leaves it ready. A pull request goes back to draft only when the work itself
is not finished, for example when it must wait for another pull request to merge first.

## Options considered

### Option 1: ready is the agent's status, set only with high confidence (chosen)

Keeps "ready" meaning "my work is done" and stops the flapping, because the evidence is gathered
before the flag is set, not after CI reports.

### Option 2: ready mirrors CI (draft while red, ready when green)

Simple to read, but it makes the flag a restatement of CI and produces the cycle of mark ready, CI
fails, back to draft, fix, mark ready again, which hides when the work is actually done.

### Option 3: ready whenever the agent stops, whatever the evidence

Cheapest for the agent, but it puts pull requests in front of the Operator that are known to
collide or fail, and the review is spent on them.

## Consequences

- The Operator can read ready as "reviewable"; a red check on a ready pull request means a fix is
  coming in place, not that the work is open.
- The agent does more before the flag: local checks and a trial merge with current `main` and the
  other ready pull requests. A pull request that cannot pass these stays draft.
- This feeds the merge-flow review the Operator asked for (define, enforce, attest): the evidence
  checked before ready is the part to define and attest.
- `PROCESS.md` does not yet state the rule; the host adds it there.

## Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft, accepted by the Operator. |
