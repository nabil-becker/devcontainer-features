# Architecture decision records

An ADR is for the decision whose reasoning does not fit in a line: options were weighed, the
consequences need spelling out, or someone will ask "why" in a year and the answer should not
depend on who remembers.

## When to write one

Write an ADR when at least one of these is true:

- two or more real options were considered and the losing ones deserve a record;
- the decision constrains how people work (branching, tooling, review) or how the system is
  shaped (a boundary, a protocol, a storage choice);
- the consequences include something to undo later, or a cost someone else pays.

Do not write one for a choice a backlog item or a ledger entry states completely.

## Format

`devhost-adr <title words>` (or `task devhost:adr -- <title words>`) creates the next record
from [0000-template.md](0000-template.md) and adds its row below. The sections are fixed:

| Section | What goes there |
|---|---|
| header table | status, date, deciders |
| Context | the situation and the forces at work, with their sources |
| Decision | what was decided, in full sentences, present tense |
| Options considered | each option with the reason it lost; the chosen one too |
| Consequences | what becomes easier, what becomes harder, what must be done as a result |
| Change log | one row per revision of the ADR |

Nothing in an ADR names a person other than as "the Operator", holds credentials, identifiers
or real data; nothing is silently deleted.

## Numbering and lifecycle

- Files are `NNNN-short-title.md`, numbered in creation order from 0001; `0000` is the template.
  Numbers are never reused.
- Status moves `proposed` to `accepted` (the Operator confirms) or `rejected`. A later ADR that
  replaces an earlier one sets the earlier one to `superseded by ADR-NNNN`; the text of the
  earlier one is not edited beyond that status line. The librarian back may add new records and
  change a status line, nothing else; its guard undoes anything more.
- An accepted ADR changes only through a new ADR.

`devhost-verify` checks that every ADR has the required sections, a known status, consecutive
numbering and a row below.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [0001](0001-agent-git-identity-through-containerenv.md) | Agent git identity is set through containerEnv | superseded by 0012 | 2026-10-16 |
| [0002](0002-agent-co-author-trailers-use-unclaimable-addresses.md) | Agent co-author trailers use unclaimable per-model addresses | accepted | 2026-10-16 |
| [0003](0003-backs-only-add-so-change-stakes-become-amend-items.md) | Backs only add, so a stake that asks for a change becomes an amend item | accepted | 2026-10-16 |
| [0004](0004-the-arthurian-theme-is-a-layer-not-a-rename.md) | The Arthurian theme is a layer over the plain words, not a rename | accepted | 2026-10-16 |
| [0005](0005-the-ontology-is-the-canonical-model-and-a-guard-keeps-the-rest-in-line.md) | The ontology is the canonical model, and a guard keeps the rest in line | accepted | 2026-10-16 |
| [0006](0006-the-docs-site-is-built-by-a-script-and-hosting-is-a-swappable-skill.md) | The docs site is built by a script, and hosting is a swappable skill | accepted | 2026-10-16 |
| [0007](0007-the-life-theme-is-a-shared-layer-above-each-projects-own.md) | The life theme is a shared layer above each project's own theme | accepted | 2026-10-16 |
| [0008](0008-the-iteration-package-carries-papers-forward-and-merges-the-foundation.md) | The iteration package carries papers forward, merges the foundation, and its papers are honest accounts | accepted | 2026-10-16 |
| [0009](0009-the-journalist-is-a-skill-in-the-iteration-package-not-a-back.md) | The journalist is a skill in the iteration package, not a back | accepted | 2026-10-17 |
| [0010](0010-a-paper-carrying-names-is-committed-under-an-approved-exception.md) | A paper that carries names is committed unchanged under an approved exception | accepted | 2026-10-19 |
| [0011](0011-the-feature-and-agent-principles-are-binding.md) | The agent principles and the Feature requirements are binding | accepted | 2026-10-19 |
| [0012](0012-agent-git-identity-through-the-git-feature-wrapper.md) | Agent git identity is set by the git Feature's wrapper | accepted | 2026-10-19 |
| [0013](0013-the-agent-principles-are-trimmed-to-five-generic-ones.md) | The agent principles are trimmed to five generic ones | accepted | 2026-10-20 |
| [0014](0014-the-seed-is-exported-and-imported-by-two-skills-and-the-journalist-is-folded-into-the-export.md) | The seed is exported and imported by two skills, and the journalist is folded into the export | accepted | 2026-10-20 |
