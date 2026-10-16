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
| 1 | Client engagement (the office consumer) | written |
| 2 | DSNP | when the Operator calls it |
| 3 | devcontainer-features (this repository) | when the Operator calls it |

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
