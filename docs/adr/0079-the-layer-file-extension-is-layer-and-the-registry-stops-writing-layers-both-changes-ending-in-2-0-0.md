# ADR-0079: The layer file extension is `.layer`, and the registry stops writing layers, both changes ending in 2.0.0

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-23 |
| **Deciders** | the Operator; proposed by the devhost host |

## Context

The component registry (ADR-0063) names its layer files `*.reg`, after the Windows Registry its
grammar is shaped on. On the Operator's Windows workstation a `.reg` file opens in the Registry
Editor on double-click, which is wrong for a consumer's maintainer who writes layer files. The
Operator ruled on 2026-11-20 that the extension changes and the grammar stays exactly as it is,
with `.reg` still accepted for one minor version with a deprecation note and removed in the next
major.

The registry also wrote to a layer: a layer marked `writable` received lines from
`dcf-registry remember` (and the `/registry-remember` skill), into `remembered.reg`. That second
way of changing a layer meant the rename had to handle a file the registry itself writes, and
two writers of one folder. The host proposed to deprecate it in the same stretch.

## Decision

A layer's files are `*.layer`; the grammar is unchanged. In 1.9.0 the resolver still reads `.reg`
files, together with `.layer` files in name order, and prints one deprecation line per layer
source naming the `.reg` files ("rename to .layer; .reg is removed in 2.0.0").

In 1.10.0 `writable`, `dcf-registry remember` and `/registry-remember` are deprecated and still
work; `remember` writes `remembered.layer`, or appends to an existing `remembered.reg`. In 2.0.0
the registry no longer reads `.reg`, ignores `writable` with a warning, and removes `remember` and
the skill. From then on the registry never writes a layer: a person edits their own layer.

The Operator confirmed 2.0.0 as the removal release, with all four removals, on 2026-11-23.

## Options considered

### Option 1: `.layer`, with a deprecation window and the writer removed in the same major

The extension says what the file is and Windows has no handler for it. One breaking release
carries both removals, so consumers migrate once. This is chosen.

### Option 2: keep `.reg`

No migration, but every consumer's maintainer keeps the double-click hazard. Lost.

### Option 3: rename with no window

Breaks every consumer's layers at once. Lost; the Operator asked for one minor of grace.

### Option 4: keep `remember` and move it to `.layer` for good

Keeps two writers on a layer folder and a skill whose value is a line a person can add themselves.
Lost.

## Consequences

- Consumers rename their `.reg` files before 2.0.0; the deprecation line says which.
- A `required` layer with only `.reg` files resolves empty with a warning in 2.0.0 (the fetch
  worked). The Operator kept it a warning on 2026-11-23: `.reg` layers were never given to anyone.
- ADR-0063 still says `.reg` and `remember`; this record amends it, the text there is not edited.
- The lexicon's ".layer file" and "Built-in base layer" entries and the ontology key `layer-file`
  are updated by the pull requests that carry the change (#225, #233).

## Change log

| Date | Change |
|---|---|
| 2026-11-23 | First draft; accepted the same day (2.0.0 and the removals confirmed, the empty required layer kept a warning). |
