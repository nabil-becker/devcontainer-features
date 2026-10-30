# ADR-0039: An architecture review comes before every ruling, and NFR-13 says we manage the environment, not the CLI

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-29 |
| **Deciders** | the Operator; proposed by the host |

## Context

The Operator asked for two things on the Claude CLI adapter: Remote Control on or off by default,
and a session name template, because a remote session list showed four or five sessions all named
after the same agent handle. Placing them raised the question of which layer owns what: a Feature
option, a CLI adapter, the agents spec, the launcher, or a consumer's own config. The Operator drew
the line: provide agent-agnostic functionality for the environment (which agent, its state, its
skills) without taking over each CLI's own features. The host's split followed NFR-12
(ADR-0037), but nothing in the process made such a placement check happen before the Operator
ruled, and nothing in the requirements said where the line sits. A subagent that built the review
skill also claimed NFR-11 and NFR-12 had been added without an ADR; they had ADR-0035 and ADR-0037,
and ADR-0011 says a requirement changes through an ADR.

## Decision

- **An architecture review comes before every ruling on a design.** A reviewer subagent that sees
  only the proposal, not the author's conclusions, checks it against the non-functional
  requirements, the ADRs, the CLI capability matrix, the lexicon and NFR-13, and says which layer
  each piece belongs in. It writes a dated "Architecture review" section (verdict, findings, open
  questions for the Operator) and never edits the design itself. The step is in `PROCESS.md`, here
  and in the seed's template, and it is run by the `architecture-review` skill. A source a
  repository does not have (a consumer has no NFRs or matrix) is skipped.
- **A new non-functional requirement, NFR-13 `manages-the-environment-not-the-cli`.** The Features
  manage the environment of an agent (which agent, its state, its skills) and use each CLI's own
  features through that CLI's adapter and options; they do not re-implement or take over what a CLI
  already does. A feature of one CLI is an option of that CLI's Feature or adapter, not a key of the
  agents spec, unless NFR-12 is met.

This follows ADR-0011's rule that a requirement changes through an ADR, as ADR-0035 did for NFR-11
and ADR-0037 for NFR-12.

## Options considered

### Option 1: a review step before the ruling, plus NFR-13 (chosen)

The check happens where the decision is made, by a reader without the author's framing, and the
placement rule is written down once and is binding.

### Option 2: NFR-13 only, with no review step

The rule would exist but depend on the author remembering to apply it; the host's own first
placement had to be corrected by hand.

### Option 3: the review by the author, as a checklist

Cheaper, but the author's conclusions anchor the check, which is the failure the separate reader
avoids.

### Option 4: add NFR-13 without an ADR, following the subagent's mistaken precedent

Rejected: ADR-0011 requires an ADR, and NFR-11 and NFR-12 both have one.

## Consequences

- A proposal is checked against the requirements, records and matrix before the Operator rules, so
  a mis-placed feature is caught on paper.
- Every ruling on a design costs one Sonnet subagent run, and the proposal gains a section.
- CLI-specific features such as Remote Control stay options of that CLI's Feature or adapter and
  never become agents-spec keys.
- Consumers planted from the seed get the review step in `PROCESS.md`, worded for repositories
  without NFRs or a matrix.
- Backlog: none beyond the open pull requests that carry the skill, the step and NFR-13.

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First draft, accepted: the Operator decided the review step and NFR-13. |
