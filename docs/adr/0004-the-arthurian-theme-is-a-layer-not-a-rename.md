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
Operator". No committed output speaks in the voice: the journalist back ("the bard" is only
its name in the layer) writes the story of the project's iterations, which is a record the
iterations are judged by, so it stays in plain words; the scribe's entries are machine-read and
stay as they are. The voice lives in the lexicon section and in conversation, and never enters
a machine-read part (entry field names, `Corrects:`, ids).

## Options considered

### Option 1: a layer (chosen)

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
- The journalist back writes in plain words; the first hand-run piece, written in voice, is
  rewritten plainly when the back is built. 
- Consumers take the layer in a release as new template text only, if they adopt it at all; that
  is still open.
- A full rename stays possible later, but only as a new decision, probably a new repository
  generation.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
| 2026-10-16 | The Operator: the journal is part of the project's iterations, so it stays in plain words; no back speaks in the voice. |
