# The model

One canonical data model of this repository's base names, and what is derived from it. The
product comes first: the Dev Container **Features** (`type = "product"`: feature, consuming-repo,
devcontainer, feature-registry, release, feature-taskfile, feature-state). The devhost and the
way of working (roles, records, mechanisms) are where the Features are built.

| File | What it is |
|---|---|
| `ontology.toml` | The canonical model: the closed `types` and `predicates`, one `[id]` table per base name (`type`, `term`, `summary`), and the `[[relation]]` triples (subject, predicate, object). |
| `../../LEXICON.md` | The same names explained in prose for people. |
| `themes/*.toml` | Label files, `id = "label"`, one per theme (`arthurian.toml`). They change no process; no committed output speaks in them (ADR 0004). |
| `c4-context.md`, `c4-container.md` | C4 views as Mermaid flowcharts of the ids. |

## Rules

- An id is kebab-case and unique; its `type` is in `types`; `term` is exactly the bold term
  LEXICON.md writes (`- **Term**`), and every bold term of LEXICON.md has an id.
- A relation's subject and object are ids, its predicate is in `predicates`.
- Every key of a theme file is an id.
- Every Mermaid node id in `docs/model/*.md` is an id, or starts `external-` for something
  outside the model (`external-github`). Write nodes as `id["Label"]`, edges as `a -->|verb| b`.
- The librarian back only adds (ids, relations, labels, nodes); changing or removing is the host's.
- `devhost-verify` (guard `model`) enforces all of this and names file, line and fix. It does
  nothing in a repository without `docs/model/ontology.toml`.

## Adding a term

1. Add the bold term to LEXICON.md in its section.
2. Add a `[kebab-id]` table to `ontology.toml` with `type`, the same `term` and a one-line `summary`.
3. Add relations if it relates to others; add a theme label or a diagram node if it should appear there.
4. Run `task devhost:verify`.
