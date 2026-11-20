# ADR-0065: The copilot Feature pins the Copilot CLI inside its own dependsOn and stops the CLI's self-update

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host session |

## Context

The `copilot` Feature installs the Copilot CLI by depending on the official
`ghcr.io/devcontainers/features/copilot-cli:1` Feature. That Feature takes a `version` option
(`latest`, `prerelease` or an exact version, with or without a leading `v`), and runs
`copilot update` only on `latest` and `prerelease`. Its download is not checksum-verified, which
is its gap, not ours. With `latest`, two machines built on different days hold different CLI
versions, and Copilot also updates itself when a session starts unless `COPILOT_AUTO_UPDATE` is
`false`. Every engineer who uses the Feature expects the same CLI version on every machine, and
nothing should drift between a test and a consumer's build.

## Decision

The `copilot` Feature pins the CLI inside its own `dependsOn`:
`{"ghcr.io/devcontainers/features/copilot-cli:1": {"version": "1.0.114"}}`, the stable release
whose `SHA256SUMS.txt` was checked by hand. Its `containerEnv` sets `COPILOT_AUTO_UPDATE` to
`false`, so the CLI does not move the pin when a session starts. A person who wants updates sets
`COPILOT_AUTO_UPDATE=true` in their own `.env` or `containerEnv`. Listing the official Feature
yourself with another version conflicts with ours and is not supported; listing it at the same
version is one install. Each `copilot` release bumps the pin after a test: bump the pin, check
the release's `SHA256SUMS.txt`, run the scenarios, release. The Feature's tests assert that
`copilot --version` reports the pinned version and that `COPILOT_AUTO_UPDATE` is `false`.

## Options considered

### Option 1: pin inside the Feature's own dependsOn, and stop self-update (chosen)

One version for everyone, set where the Feature is defined, and a release is the only thing that
moves it. The cost is a bump per release, which the test gate makes deliberate.

### Option 2: leave the official Feature on `latest` and tell people to list it themselves to pin

Each repo would choose its own version. It lost: the versions drift between machines and builds,
and the pin depends on every consumer remembering to do it.

### Option 3: pin the version but leave Copilot's self-update on

It lost: the CLI would update itself at the next session start, so the pin would hold only until
the first run.

## Consequences

- Every machine gets the same Copilot CLI version, and a build tomorrow matches a build today.
- Moving to a newer CLI is a Feature release, with its scenarios run first, not something that
  happens by itself.
- Nothing resolves a conflicting second entry of the official Feature; the NOTES call it
  unsupported, and the `official_listed` scenario covers only the identical entry.
- The official Feature's lack of checksum verification remains; the hand check of the pin's
  `SHA256SUMS.txt` at each bump is the mitigation.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's ruling. |
