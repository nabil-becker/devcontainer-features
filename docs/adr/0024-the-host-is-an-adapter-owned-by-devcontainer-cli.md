# ADR-0024: The host is an adapter owned by devcontainer-cli

| | |
|---|---|
| **Status** | proposed |
| **Date** | 2026-10-23 |
| **Deciders** | the Operator; proposed by the host |

## Context

The Operator runs devcontainers from a Windows workstation, and consuming repositories should work
the same on any host. Today the host leaks into every repository: the git-dirs mount line names
`${localEnv:USERPROFILE}` (wrong on Linux and macOS, backlog item `git-dirs-posix-line`), the
engine is a path (`DEVCONTAINER_DOCKER_PATH`) rather than a kind of host, and a vendored
`./bootstrap/` sits in the repo root and in version control. The dev container CLI cannot substitute
`${localEnv}` in a Feature's own mounts (ADR 0020), so a Feature cannot mount a host folder itself;
`devcontainer up --mount` can (`type=bind,source=..,target=..`, checked with `devcontainer up
--help`), while `--remote-env` only reaches user commands, not the container's environment.
Anything a repo has to script around is a gap to close here.

## Decision

Decided by the Operator on 2026-10-23, written up in
[the proposal](../proposals/host-profile.md):

1. The host is a pluggable side, like a backend, source or sink. Only the devcontainer-cli Feature
   and its bootstrap (the launcher, run on the host) know about the host; every other Feature is
   host-blind and adapts inside the container.
2. `HOST_TYPE` is the one host choice: `windows-docker-desktop`, `windows-wsl-docker`,
   `windows-wslc`, `linux`, `macos`. The launcher detects it; it can be overridden.
3. No process of ours runs in the background on the host. Processes inside the devcontainer are fine.
4. The launcher passes host-specific mounts with `devcontainer up --mount`, so consuming repos
   declare none, and mounts a small host profile file at a fixed path
   (`/var/lib/devcontainer-features/host/profile.env`) that Features read.
5. The vendored bootstrap lives in `.devcontainer/cli_bootstrap.ignore/` by default, overridable
   (`BOOTSTRAP_DIR`), and git-ignored through `.devcontainer/.gitignore`.

This ADR stays proposed until the Operator accepts the proposal's open questions; the build is
four slices in the proposal.

## Options considered

### Option 1: the host is an adapter in the launcher, with a profile file (chosen)

One place knows the host; Features read a file and stay host-blind; repos declare nothing
host-specific.

### Option 2: each Feature probes the host itself

Impossible from inside the container for most facts, and it spreads host knowledge over every
Feature.

### Option 3: repos keep writing the host-specific mounts

The status quo. It is the gap: every repo carries `${localEnv:...}` lines that differ by OS.

### Option 4: a host daemon or relay (for example for the SSH agent)

Rejected by decision 3: nothing of ours outlives a task on the host.

## Consequences

- Consuming repos shrink: no `.git-dirs` mount line, no `./bootstrap` in version control; a fresh
  clone lacks the bootstrap, so the root Taskfile include becomes `optional: true` and the first
  step on a new machine is the bootstrap one-liner.
- Existing consumers migrate: re-run the bootstrap, remove the old `./bootstrap`, repoint the
  include (the bootstrap could repoint it when it finds the old one).
- A repo opened directly in VS Code bypasses the launcher and misses the mounts and the profile;
  the proposal recommends a loud check, not a workaround.
- Windows named-pipe SSH agents cannot be forwarded without a host relay, so `windows-docker-desktop`
  and `windows-wslc` have no agent in the container.
- ADR 0020's mount line moves from the repo into the launcher; its wrapper is unchanged.
- The devcontainer-cli Feature and the bootstrap change together, with a version bump.

## Change log

| Date | Change |
|---|---|
| 2026-10-23 | Proposed; the five decisions taken by the Operator, the rest open. |
