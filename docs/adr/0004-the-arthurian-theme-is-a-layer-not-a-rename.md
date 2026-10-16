# ADR-0004: The Arthurian theme is a layer over the plain words, not a rename

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

The devhost generation of the way of working has its own words (`LEXICON.md`). The next
generation is to be themed on King Arthur's court. `docs/proposals/king-arthur-theme.md` mapped
the roles and records to the court and costed two ways of adopting it. A full rename would touch
about 130 files, the job directories and entrypoints under `src/devhost/share/`, both consumers'
templates, and the skill and command names. The ledger is append-only, so its entries would keep
the old words and every query for them would miss the past that the briefing, the review and the
guards read. A rename would also make "host" ambiguous again, and break the con and back pairing
with the inter that the lexicon was built around. A layer touches a handful of prose files and
changes nothing the machinery reads.

## Decision

The theme is a layer. `LEXICON.md` holds a separate section, "The Arthurian layer", with ten
names as synonyms; no existing definition changes. The plain word stays in every id, path,
command, field name, guard, ledger entry and skill name. Committed text still says "the
Operator". The voice is trialled with one back first: the bard (the journalist back), whose
output is read by people rather than by the machinery, so it speaks first. The scribe's entries
are machine-read and stay as they are. Other prose adopts the voice only after the trial, and
the voice never enters a machine-read part (entry field names, `Corrects:`, ids).

## Options considered

### Option 1: a layer, with the bard first (chosen)

It gives the theme where a person reads it, costs a few prose files, leaves both consumers and
the ledger's history valid, and is reversible by deleting the voice.

### Option 2: a full rename

Every word in the table would replace the old one everywhere. It lost on cost and risk for no
change in what the system does: about 130 files, a migration for each consumer, a split between
old and new words in an append-only ledger, and high muscle-memory cost for `devhost-verify`,
`devhost-briefing` and `/ledger-review`.

### Option 3: start the trial with the scribe

The proposal's first plan put the voice in the scribe's entries. It lost because those entries
are machine-read by the guards and cost parsers, so a voice there risks breaking them.

## Consequences

- Readers can find the Arthurian name for any role in one lexicon section; nothing they type
  or grep for changes.
- Two vocabularies live side by side; the plain one is the authority wherever the machinery
  reads it.
- The bard's first journal piece is the trial; building the bard back depends on the Operator's
  reading of it.
- Consumers take the layer in a release as new template text only, if they adopt it at all; that
  is still open.
- A full rename stays possible later, but only as a new decision, probably a new repository
  generation.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
