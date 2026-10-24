# ADR-0027: CI runs `task lint` inside the devcontainer, and the tool versions are pinned

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

The point of the devcontainer is that a local run and CI give the same answer. They did not: the
`lint` job ran on `ubuntu-latest` with whatever shellcheck, yamllint, PowerShell, Pester and Python
the runner carried, while the devcontainer took its shellcheck from the `devcontainers-extra`
Feature at its latest version. On 2026-10-24 CI's older shellcheck flagged SC2015 that the local one
did not, so a change passed locally and failed in CI.

Two things were open: who defines the toolchain, and whether the versions may float. This
repository's own devcontainer cannot simply be built in CI: it references `./features/*` staged by
`task features:stage`, binds the `.git-dirs` folder from the Windows profile, sets the `DEVHOST_*`
environment and adds the claude-code and docker-in-docker Features, none of which CI can or should
provide.

## Decision

1. CI runs `task lint` inside a devcontainer built with the official `devcontainers/ci` action, so
   the devcontainer is the one definition of the toolchain. The action is pinned by commit SHA with
   its version in a comment, like the other actions in the workflows. The job keeps the name `lint`
   (branch protection requires it), and its checks stay at least as strict as before; the steps that
   need GitHub itself stay in the job.
2. The tool Features (shellcheck, yamllint, PowerShell, and Pester through its modules option) are
   pinned to exact versions in `.devcontainer/devcontainer.json`, so a new upstream release changes
   nothing until someone bumps the pin.
3. CI builds its own config, `.devcontainer/ci/devcontainer.json`, which leaves out the host-only
   bits (the Windows mount, the git-dirs layout, the `DEVHOST_*` environment, claude-code,
   docker-in-docker). Staging the local Features is a script, `.devcontainer/stage-features.sh`,
   shared by the initialize command and CI.
4. The two configs cannot drift: `task lint:toolchain` compares the tool Feature entries and options
   of both and fails on any difference, and it runs as part of `task lint`.

## Options considered

### Option 1: a CI config plus a drift check, with pinned versions (chosen)

CI and the devhost share one toolchain definition in effect, the pins make the result reproducible,
and the check turns drift into a failing lint instead of a surprise.

### Option 2: make the main config tolerate CI

Rejected: the main config would carry conditions for a Windows mount, the git-dirs layout and the
agent Features, and every future host-side addition would need a CI escape hatch. It is the same
single source on paper but a fragile one in practice.

### Option 3: pin the versions on the runner only

Rejected: it fixes the symptom with a second definition of the toolchain. The devcontainer and CI
would be pinned separately and could be pinned differently, which is the problem again.

### Option 4: leave CI on `ubuntu-latest`

Rejected: this is the situation that failed. The runner image changes under the repository.

## Consequences

- A local `task lint` and the CI `lint` job run the same tools at the same versions.
- A tool version is bumped on purpose, in both configs, in one change; the drift check fails the
  change if only one was edited.
- The CI job builds an image, which costs time on a cold cache; the image caching of the action
  keeps a warm run reasonable.
- The CI config is a second file to keep; only the toolchain part is guarded, so the rest of it
  must be reviewed by hand.

## Change log

| Date | Change |
|---|---|
| 2026-10-24 | Accepted: the Operator decided both remedies after the SC2015 mismatch. |
