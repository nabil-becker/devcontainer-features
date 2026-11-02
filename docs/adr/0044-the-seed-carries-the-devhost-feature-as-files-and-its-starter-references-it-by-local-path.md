# ADR-0044: The seed carries the devhost Feature as files, and its starter references it by local path

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-02 |
| **Deciders** | the Operator; proposed by the host |

## Context

Since ADR-0025 the devhost Feature lives in `local-features/devhost` and is no longer released;
the registry holds its last published version, frozen. The seed's starter
(`docs/iterations/starter/devcontainer.json`, and its exported copy) still pinned
`ghcr.io/nabil-becker/devcontainer-features/devhost:1`, so a project that planted the seed got
the frozen copy and none of the fixes. ADR-0025 accepted this for seeds planted earlier, but not
for new plantings: the engineer who plants a seed needs the current devhost.

## Decision

The seed carries the devhost Feature as files. `devhost-package` (`task devhost:package`) copies
`local-features/devhost` whole into the package at `starter/features/devhost/`, byte for byte,
and refuses to run when the folder is missing. A planted repository gets it at
`.devcontainer/features/devhost`, and the starter `devcontainer.json` references it by local path
(`./features/devhost`), the form this repository's own devcontainer uses. The starter's other
Features stay on the registry. The Feature is updated in a planted repository by re-copying the
folder from a newer seed. The plant-a-seed skill and the starter's SETUP.md say so. The old
devhost package on the registry is deleted by the Operator afterwards; nothing assumes that has
happened.

## Options considered

### Option 1: the seed carries the files (chosen)

The planted repository gets the current devhost, works offline from the seed, and needs no
registry package for it. The Feature is self-contained (`dcf-persist.sh` is vendored, `install.sh`
installs python3 if missing), and its `installsAfter` ids that are absent from the starter are
ignored, as before.

### Option 2: publish devhost again

Lost because it reverses ADR-0025: repository-internal tooling would be part of every release
again.

### Option 3: leave the starter on the frozen registry version

Lost because a new project would start on a devhost that gets no fixes.

## Consequences

- Easier: a planted project starts on the current devhost, and the registry package can be
  deleted.
- Harder: a planted repository commits about 100 KB of tooling, and nothing guards it against
  drift from `local-features/devhost` except re-exporting or re-copying from a newer seed.
- Reverses the part of ADR-0025's consequences that left new seeds pointing at the registry;
  extends ADR-0008 (the package gains the devhost folder).
- The Operator deletes the old registry package after the merge; the export is refreshed in a
  targeted way, a full re-export (drop-a-seed) stays the Operator's call.

## Change log

| Date | Change |
|---|---|
| 2026-11-02 | First draft. |
