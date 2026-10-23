# ADR-0023: The theme is a bar

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-23 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0004 made the Arthurian theme a layer of labels over the plain words: a label file keyed by
ontology ids, used in conversation only, with no committed output speaking in it. On 2026-10-23
the Operator said they did not like the King Arthur theme and asked for a restaurant or a bar.
Because the theme is only a layer, changing it touches the label file, the lexicon's section and
the places that name the theme; no id, path, command, field name or guard changes.

## Decision

The theme is a bar (`docs/model/themes/bar.toml`): the Operator is the landlord, the host the
bartender, a con a runner on one order, the backs the barbacks, the ledger the tab book, the
backlog the chalkboard, the ledger review the cash-up, the night shift the lock-in, the guards
the bouncers, the journalist the regular who tells the stories. Everything else in ADR-0004
stands: a layer, not a rename, and no committed output speaks in it. The dashboard, which was
called "the court" (the Operator's word, not a theme label), is the plain "Dashboard" in what it
shows. The Operator's own "court" framing of claims and evidence (CONTEXT.md, the agent
principles) is not the theme and stays.

## Options considered

- **A bar** (chosen): the landlord, the bartender, runners, barbacks, the bouncers. Two labels fit
  their roles closely: barbacks for the backs, bouncers for the guards.
- **A restaurant**: the owner, the head chef at the pass, line cooks, porters, the health
  inspector. The kitchen brigade fits the chain of command, but its words are less memorable.
- **Keep the Arthurian theme**: the Operator did not like it.

## Consequences

- `docs/model/themes/arthurian.toml` is replaced by `bar.toml`; ADR-0004 is superseded by this
  record; `docs/proposals/king-arthur-theme.md` is kept as history.
- Records already written (the ledger, journals, papers, night-shift reports) keep their words.
- The site's title and brand read "Dashboard"; the devhost Feature is bumped for that.

## Change log

| Date | Change |
|---|---|
| 2026-10-23 | First draft; chosen by the Operator in the session ("I like the bar. Lets do it"). |
