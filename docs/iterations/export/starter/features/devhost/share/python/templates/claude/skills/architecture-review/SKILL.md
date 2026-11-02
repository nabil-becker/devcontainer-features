---
name: architecture-review
description: Review a proposal's design before the Operator rules on it, by briefing a subagent that checks it against the non-functional requirements, the ADRs, the CLI capability matrix, the lexicon, the line "manage the environment, not the CLI" (NFR-13) and where each element is placed, and writes an "Architecture review (YYYY-MM-DD)" section into the proposal. Use it on every proposal in docs/proposals/ after it is written and before the Operator rules, and when the Operator asks for an architecture review, a design check or "the architect". Never changes the design sections.
---

# Architecture review

A proposal that goes straight to the Operator's ruling is checked only by whoever wrote it. The
architecture review is a second reader that holds the standing rules the author may have missed,
and that leaves its findings in the proposal so the Operator rules with them in front of them.
The Operator's ruling is still theirs; the review advises.

## Steps

1. **Pick the proposal** (`docs/proposals/<name>.md`) and note who it serves (the Operator, an
   engineer, a consumer's maintainer, per `CONTEXT.md`). If the proposal already has an
   "Architecture review" section, the new review is a new dated section below it, never an edit.

2. **Brief a subagent** (a con, Sonnet by default; larger only when the proposal reshapes a
   boundary others build on). The brief carries the "who you serve" note, the proposal's path and
   the reply shape (the hand-off: Outcome, Outputs, Friction, For the repository, Decisions
   needed). Give it the proposal and the sources below, not the author's conclusions, the
   conversation or the host's opinion: a reviewer told the answer confirms it.

3. **The reviewer checks, in this order**, reading the sources itself:
   - **The requirements** (`docs/principles/non-functional-requirements.md`): each NFR that
     applies is met, not met, or needs a written exception; one line each, with the proposal's
     section that shows it.
   - **The decisions** (`docs/adr/`): conflicts with an accepted ADR, and what the proposal
     amends or supersedes (an ADR is amended or superseded by a new ADR, never edited).
   - **Agent CLIs**, for anything that touches them: the capability matrix
     (`docs/proposals/agents-v2.md`, section 14) and NFR-12 (two vendors or a named fallback).
   - **The line** (NFR-13, `manages-the-environment-not-the-cli`): does the design manage the
     agent's environment (which agent, its state, skills, records, how it starts and is found
     again), or re-implement something a CLI already does? A capability one CLI has is that
     adapter's or Feature's option, not a new concept in the agents spec, unless NFR-12's
     two-vendor test is met.
   - **The lexicon** (`LEXICON.md`): each term used as defined; each new concept that needs a
     term, named.
   - **Placement**: for each element, the layer it belongs in (a Feature option, a CLI adapter,
     the agents list spec, the launcher, a consumer's own config) and why. A misplaced element is
     the commonest finding.
   Where a source does not exist in this repository (a consumer has no capability matrix), the
   reviewer says so and skips it; it never invents the rule.

4. **Write the section.** The reviewer, or the host from its reply, appends to the proposal:

   ```markdown
   ## Architecture review (YYYY-MM-DD)

   **Verdict:** fit | fit with changes | does not fit

   ### Findings
   1. <what, citing the NFR, ADR, matrix row or term> Recommended change: <one change>.

   ### Open questions for the Operator
   - <a choice only the Operator can make, with the review's recommendation>
   ```

   It never touches the design sections. The author or the host applies the changes the Operator
   accepts, in a later edit.

5. **Hand it to the Operator**: the verdict and the findings that need a ruling, in a few lines. The
   ruling follows ([PROCESS.md](../../../PROCESS.md)).

## Why

The standing rules (the NFRs, the ADRs, the capability matrix, the line between the environment
and the CLI) only protect a design when someone checks it against them, and the author is the
person least likely to. A reviewer that sees only the proposal reads it as the Operator will:
cold. Writing the review into the proposal keeps the reasoning where the ruling is made, and
keeping it out of the design sections keeps the author's text and the reviewer's apart.
