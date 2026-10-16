# ADR-0006: The docs site is built by a script, and hosting is a swappable skill

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

The Operator should not have to read the terminal or markdown files to see where the work
stands. They asked for a homepage-style dashboard over the repository's docs and records, with
function over form: a good experience matters more than good visuals. They also said Claude
artifacts is only an easy site host, and the architecture should keep that in mind. The
records to show are the backlog (`TODO.md`), the ledger, the ADRs, the lexicon, the proposals,
and the Features table.

## Decision

A tested script, `devhost-site`, reads the repository's docs and records and produces one
self-contained HTML page with its data inside. The name guard runs over all the text it
emits. The homepage leads with what needs the Operator (open decisions, items they own,
unreviewed night-shift reports, a due ledger review, draft proposals, open pull requests),
then a few numbers, the latest ledger entries and the Features table; further pages cover the
Features, the backlog, the ledger and the records, with search across all of it.

Publishing is a separate step, a skill (`/publish-site`), and it is the only part that knows
about Claude artifacts. The page itself carries no dependency on that host. Moving to another
host (GitHub Pages, a file share) changes only the skill.

## Options considered

### Option 1: a script builds the page, a skill publishes it

The page is deterministic, testable and costs nothing per run; the host coupling is one small
skill that can be replaced.

### Option 2: an agent writes the page each time

Costs tokens on every refresh, gives a different page each run, and nothing can show it failed.

### Option 3: build the page directly inside the Claude artifacts format

Quickest to a first version, but it ties the generator to one host, against the Operator's
instruction to treat the host as interchangeable.

## Consequences

- Reading the state of the court no longer needs the terminal or markdown files.
- The generator is tested like the other devhost tools and can run anywhere `task lint` runs.
- Switching host later is one skill, not a rewrite.
- The page must keep working on a phone, in light and dark.
- A published copy goes stale until the skill runs again; refreshing it is a manual step for now.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
