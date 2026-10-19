# ADR-0007: The life theme is a shared layer above each project's own theme

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

The way of working is tried in a series of projects: the office, DSNP, and this repository, each
an iteration. This repository will export the first iteration package, and the proposal
(`docs/proposals/iteration-package.md`) needed words for the series itself: what an iteration
hands on, what it produces, what changes the foundation and what proves a one-off. ADR-0004
made the Arthurian theme a layer for this repository's own roles and records, but it speaks
about one project's court, not about the series. The Operator liked a life theme (a seed grows
into a tree and bears fruit) and asked that it reach every project. Each project already has,
or may adopt, its own voice, and the ledgers are append-only, so a rename anywhere would split
old and new words.

## Decision

The series has one shared theme, life, with ten labels: iteration is a generation, project a
tree, project context the ground, iteration package a seed, white paper a fruit, a learning
that changed the foundation an adaptation, a change that proved a one-off a shed trait, the
series the lineage, iterations 1 and 2 first life before seeds, and this repository the first
seed-bearing tree. It follows the rule of ADR-0004: labels and story only. The plain word stays
in every id, path, command, field name, guard and ledger entry, and nothing committed is
renamed. The life layer sits above each project's own theme and does not replace it. It is
held in `LEXICON.md` and sent to the other projects as an information-only alignment note.

## Options considered

### Option 1: one shared life layer above each project's theme (chosen)

Every project can speak about the series in the same words, while each keeps its own voice for
its own roles. It costs a lexicon section and a note to the other projects, and changes nothing
the machinery reads.

### Option 2: a rename of the plain words

The labels would replace the plain names in committed text. It lost for the reason in
ADR-0004: append-only ledgers keep the old words, so every query would miss the past.

### Option 3: no shared theme, each project names the series itself

Each project would keep its own words. It lost because the white papers and seeds travel
between projects and need one vocabulary to be read as one lineage.

## Consequences

- One lexicon section gives the life label for each plain word; nothing anyone types or greps
  for changes.
- Two layers can be in use at once in a project (life for the series, its own for its roles);
  the plain word stays the authority wherever the machinery reads it.
- The other projects take the layer as a note in conversation and story, if they adopt it at
  all; no release is needed.
- The existing "Iteration package" lexicon line calls the seed label part of the "evolution
  theme"; a person updates that wording to the life theme.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft; accepted by the Operator in the session. |
