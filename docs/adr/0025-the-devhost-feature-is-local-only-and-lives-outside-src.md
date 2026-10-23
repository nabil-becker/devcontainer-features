# ADR-0025: The devhost Feature is local-only and lives outside `src/`

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-23 |
| **Deciders** | the Operator; proposed by the host |

## Context

The product of this repository is the published Dev Container Features in `src/`. The devhost
Feature is different: it is this repository's own way-of-working tooling (briefing, backs, guards,
ledger), and it was released with the rest, which put it in the Features test matrix, the global
scenario, the generated docs and every release, although consumers do not need it and the
Operator does not want it presented as part of the collection. Seeds planted earlier pin a
published version of it and must keep working.

## Decision

The devhost Feature is a local-only Feature of this repository. It lives in
`local-features/devhost`, a top-level folder for Features this repository uses but does not
publish. `devcontainer features test -p .`, the generated docs and the release workflow act on
`src/` only, so devhost drops out of releases, the Features test matrix and the global scenario.
The registry keeps the last published version, frozen; seeds already planted keep working on it
and get no fixes.

`task features:stage` copies every `src/<id>` and every `local-features/<id>` into
`.devcontainer/features/<id>`, so the devcontainer's `./features/devhost` reference is unchanged
and nothing changes in how devhost runs here. Its Python unit tests stay in lint and CI; its
Docker tests stay in `test/devhost` and run locally through `task test:devhost:docker`.

## Options considered

### Option 1: a local-only Feature in `local-features/` (chosen)

Keeps the collection's product clean, leaves the devhost running exactly as before, and needs no
change to the devcontainer. The cost is a second folder to know about and the Docker tests no
longer running in CI.

### Option 2: keep devhost in `src/` and publish it

Status quo. Lost because it presents repository-internal tooling as part of the product and
makes every devhost change a release.

## Consequences

- Easier: releases, the test matrix and the generated docs cover only the published Features.
- Harder: the devhost Docker tests have no CI job; consumers on the frozen published version get
  no fixes; stage and lint globs must cover both folders.
- The backlog item to release a new devhost version is moot; the Operator closes or rewords it.
- The lint step that checks that Feature folders have tests only loops over `src/`, so
  `local-features/` is unchecked there.

## Change log

| Date | Change |
|---|---|
| 2026-10-23 | First draft. |
