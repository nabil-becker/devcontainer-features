# ADR-0014: The seed is exported and imported by two skills, and the journalist is folded into the export

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0008 settled that an iteration hands the next one a cumulative package (the seed in the life
theme): every earlier white paper plus the newest foundation. ADR-0009 settled that the journalist
is a skill, not a back, and left it a skill of its own. What was still open was the workflow that
produces the seed at the end of a project and takes it up at the start of the next: the Operator
wants to copy the files into a blank directory, or somewhere an agent can read them, point the
agent at the README, and have the import interview and the setup start from there. The forces: the
seed must carry the means to be exported again, so the next project can hand on its own; rules
that can be written as a script should be (principle 5, right-size the work); and the journalist,
in practice, runs only inside the export.

## Decision

Two skills carry the cycle, and both travel inside the seed.

- `drop-a-seed` runs when a project ends. It runs the closing interview (what the project started
  with, what it learned, what the new seed should be), names the iteration, has a writing
  subagent write the white paper, settles the seed's contents with the Operator, and assembles the
  seed folder with the `devhost-package` script.
- `plant-a-seed` runs in the new place. The README sends the agent to it; it reads the papers and
  the foundation, runs the interview, sets up a new repository or adapts an existing one, and ends
  with the first ledger entry so the improvement loop starts on day one.

The seed is a plain folder: `README.md` (the one file an agent is pointed at), `papers/` (every
white paper so far, plus the new one), `foundation/` (the five principles, the ledger setup, a
starter lexicon and ontology), `starter/` (`devcontainer.json`, the context file template, the
setup one-pager, the dashboard) and `skills/` (`plant-a-seed`, `drop-a-seed`, `ledger-review`).

The journalist is no longer a skill of its own. Its instructions become `drop-a-seed/journalist.md`,
a reference file that `drop-a-seed` hands to a writing subagent, which keeps the long ledger read
out of the main session. The honest-account rules of ADR-0008 still bind the paper. This supersedes
ADR-0009 (the Operator, 2026-10-20): the journalist is a brief, not a skill, and still not a back.

## Options considered

### Option 1: two skills, journalist folded into the export (chosen)

Each skill owns a whole job, one exports and one imports, with no extra name to learn or keep in
sync. The writing subagent gives the context isolation that a separate skill was meant to give.

### Option 2: the journalist as its own skill, called by `drop-a-seed`

The case for it: reuse (for example the final white paper on the Agentic Delivery OS, which draws
on every iteration's paper), tuning it apart from the export flow, and keeping its context
separate. It lost because it only ever runs inside the export, the subagent already isolates the
context, and it adds a skill to maintain. The ledger review will show if the friction appears,
and the file can then be split out, as principle 2 intends.

### Option 3: no import skill, the README alone instructs the agent

Simpler to ship. It lost because the interview and the setup are repeatable procedure that should
be improved with use, and a skill can be reviewed and carried forward like any other.

## Consequences

- The seed's `README.md` is the entry point; the import interview is part of `plant-a-seed`, not a
  separate document.
- `drop-a-seed` is itself carried in `skills/`, so every project can export.
- The journalist skill of ADR-0009 becomes `drop-a-seed/journalist.md`; wherever the journalist is
  described as a separate skill, the description needs updating.
- Assembly is a script (`devhost-package`), so the seed's shape is checked and not remembered.
- If the final white paper needs the journalist on its own, split the file out again through the
  ledger review.

## Change log

| Date | Change |
|---|---|
| 2026-10-20 | First draft; accepted by the Operator in the session. |
| 2026-10-20 | Supersedes ADR 0009 instead of refining it (the Operator, closing interview 3, question 13). |
