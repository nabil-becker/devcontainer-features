# Why the way of working is here: the iterations

This repository has two purposes, in this order.

1. **The product: the Dev Container Features** in `src/`, and the workstation tooling around them.
   They are what consumers adopt and what a release publishes.
2. **An iteration of the Agentic Delivery OS.** The devhost, its lexicon, process, backs, guards,
   ontology, principles and themes are the third implementation of a way of working that the
   Operator is distilling into a product.

## The Agentic Delivery OS

A set of tools that lets any individual, technical or not, bootstrap a devhost: an environment
where agents deliver work under a process, with records kept and checked. It is the foundation
of a pyramid; each project iteration defines that foundation further.

```
                    ┌──────────────────────────┐
                    │  final white paper:      │
                    │  building the Agentic    │
                    │  Delivery OS (open)      │
                    └────────────▲─────────────┘
          ┌──────────────────────┼──────────────────────┐
     white paper 1          white paper 2          white paper 3      … more
     client engagement      DSNP                   devcontainer-features
     (the office)                                  (this repo)
          └──────────── each iteration builds on the last ────────────┘
```

| Iteration | Project | White paper |
|---|---|---|
| 1 | Client engagement (the office consumer) | written: "From Seed to Tree", kept as it was used (`docs/iterations/papers/`) |
| 2 | DSNP | none: bootstrapped from paper 1; the third paper names what came from it (ADR 0008) |
| 3 | devcontainer-features (this repository) | when the Operator calls it; the first to export a package (`docs/proposals/iteration-package.md`) |

## Where this iteration's devhost comes from

Moved here from the devhost Feature's NOTES on 2026-10-19 (Feature principles, decision on "Where it comes from"): it is lineage, not something an adopter acts on.

The devhost was ported (commit `ff21f35`, 2026-10-15) from the housekeeping of two private repositories: the agentic workspace where the roles were first built ("the office": helpers, housekeepers, contractors, a name guard turning people's names into "the Operator") and a client project that made it a shared, pushed repository (one level, no rooms; a container gate so a workstation session is never touched; the forbidden-words guard shared by the backs and the commit check; `merge=union` on the monthly ledger files; the cost measured from the transcripts, never by the model; the tester). The original's ledger lists the mistakes already fixed and kept fixed here: stakes mid-paragraph are missed, so a stake stands on its own line; a reply is written once per content block and the first record can carry a partial count, so the cost script keeps the fullest record; the guards undo a run that rewords or reorders rather than trust the brief; a test fixture under a container-wide `GIT_DIR` committed onto the real branch, hence the git wrapper and `DEVHOST_JOB_CHILD` on the suite; the librarian woken at the scribe's rate had nothing to do a third of the time, hence its own thresholds; the state out of the checkout, so nothing is synced or committed by mistake. Vocabulary and prefix changed with the words: housekeeper to back, helper to inter, contractor to con, `Housekeeper <job>` to `Back <job>`.

## The white paper

At a point the Operator chooses, an iteration produces one white paper: the journey told as a
story, then the learnings. Function over form: a document to build on, not a blog. Its sources are
this repository's records: the ledger, the reviews, the night-shift reports, the ADRs, the lexicon,
the ontology, the principles and the cost reports. Every fact it states is traceable to one of
them. It is written in plain words (ADR 0004). The journalist back exists to write it
(`docs/proposals/journalist-back.md`).

The white papers are the notes for a final one, documenting the journey of building the Agentic
Delivery OS, which is to be released as open source.

## What this means for a session

- The Features come first: a session that only grows the devhost is drifting.
- The way of working is source material. Keep its records complete and true, because the white
  paper is only as good as they are.
