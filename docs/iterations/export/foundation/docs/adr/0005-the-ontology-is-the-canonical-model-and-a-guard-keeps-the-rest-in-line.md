---
iteration: 3
date: 2026-10-20
sources:
  - docs/adr/0005-the-ontology-is-the-canonical-model-and-a-guard-keeps-the-rest-in-line.md
---
# ADR-0005: The ontology is the canonical model, and a guard keeps the rest in line

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

The way of working has several descriptions of the same things: the lexicon (what a word means),
the Arthurian layer (another name for the same thing, ADR-0004), and prose in `PROCESS.md` and
the README. Nothing checks that they agree, and no diagram shows the system's shape. The Operator
asked for a canonical data model and a set of C4 diagrams in Mermaid, kept by the librarian, with
the themes as plain labels so that a theme never changes process. The host separated the pieces:
an ontology says what exists and how it relates, a lexicon says what a word means, C4 views show
one zoom level, a theme names things in a voice. A knowledge graph (the ontology filled with
instances) was named and set aside: the ledger and the cost report already hold the instances.

## Decision

The ontology is the canonical model: one plain base id per term, with a type, a one-line summary
and relations drawn from a fixed list. The themes become label tables keyed by those ids; the C4
views (Context and Container, Mermaid) name their nodes by those ids. A guard in `devhost-verify`
checks that the lexicon, the themes and the views agree with the ontology, and is skipped in a
repository that has no model. The librarian keeps the model, add-only like its other files. It
starts small and grows from friction, not from a design made up front.

## Options considered

### Option 1: an ontology checked by a guard (chosen)

One source of truth that machines can check; the themes cost nothing in process; friction shapes
it as it grows.

### Option 2: prose and diagrams kept by hand

The lexicon and the diagrams would drift apart, as nothing would compare them. It lost because
that drift is what the Operator wants to remove.

### Option 3: a knowledge graph with instances

It would duplicate the ledger and the cost report, which already hold the instances. It lost on
cost for no new answer; it can come later as a new decision.

## Consequences

- A rename or a new term touches one place first, and the guard names what is left behind.
- The Arthurian table moves out of `LEXICON.md` into a theme file; ADR-0004's decision (a layer,
  not a rename) is unchanged.
- The librarian gains the model as a file it keeps; its prompt and guard must be told.
- A first version is built by a con on a branch stacked on the records PR; friction will change
  its shape, and later changes are backlog items.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft; accepted by the Operator ("kick it into a guard, let friction form it"). |
