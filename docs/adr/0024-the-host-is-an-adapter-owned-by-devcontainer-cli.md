# ADR-0024: The host is an adapter owned by devcontainer-cli

| | |
|---|---|
| **Status** | accepted |
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
--help`), while `--remote-env` only reaches user commands, not the container's environment, which is why the
variables travel through the repository's `containerEnv`.
Anything a repo has to script around is a gap to close here.

## Decision

Decided by the Operator on 2026-10-23, written up in
[the proposal](../proposals/host-profile.md):

1. The host is a pluggable side, like a backend, source or sink. Only the devcontainer-cli Feature
   and its bootstrap (the launcher, run on the host) know about the host; every other Feature is
   host-blind and adapts inside the container.
2. `HOST_TYPE` is the one host choice: `windows-docker`, `windows-wsl-docker`, `windows-wslc`,
   `linux`, `macos`. It defaults to `auto`; `HOST_TYPE_PRIORITY`, an ordered comma-separated list
   with a default per OS, says which detection wins; an explicit `HOST_TYPE=<id>` skips detection.
3. No process of ours runs in the background on the host. Processes inside the devcontainer are fine.
4. There is no profile file. The launcher sets `DCF_HOST_*` variables (`DCF_HOST_TYPE`,
   `DCF_HOST_HOME`, `DCF_HOST_SSH_AGENT`) in its own environment; the repository maps them into the
   container with `containerEnv` and `${localEnv}` (the bootstrap template does). Features read
   them and behave sensibly when they are unset. Host-specific mounts come from
   `devcontainer up --mount`, so repositories declare none.
5. The vendored bootstrap lives in `.devcontainer/cli_bootstrap.ignore/` (repo-relative only),
   `BOOTSTRAP_DIR` overrides it, and it is git-ignored through `.devcontainer/.gitignore`
   (`BOOTSTRAP_GITIGNORE=false` skips that).
6. Existing consumers migrate when they decide; the old form keeps working and a migration note ships.
7. An opt-in signing-only SSH key (`DCF_HOST_SSH_AGENT=key`) is offered, temporary, and documented
   as breaking "the key never enters the container" for those who opt in.

## Options considered

### Option 1: the host is an adapter in the launcher, exposed as DCF_HOST_* variables (chosen)

One place knows the host; Features read variables and stay host-blind; repositories declare no
host-specific mounts. The repository's `containerEnv` is the only bridge, and `${localEnv}` works
there.

### Option 2: a mounted host profile file

Considered first. Dropped by the Operator: variables need no file, no mount and no path to keep
in step.

### Option 3: each Feature probes the host itself

Impossible from inside the container for most facts, and it spreads host knowledge over every Feature.

### Option 4: repos keep writing the host-specific mounts

The status quo, and the gap: every repo carries `${localEnv:...}` lines that differ by OS.

### Option 5: a host daemon or relay (for example for the SSH agent)

Rejected by decision 3.

## Consequences

- A repository opened directly in VS Code has `DCF_HOST_*` unset and no launcher mounts; Features
  say so in one line and use defaults.
- Consuming repos shrink: no `.git-dirs` mount line, no `./bootstrap` in version control; a fresh
  clone lacks the bootstrap, so the root Taskfile include becomes `optional: true` and the first
  step on a new machine is the bootstrap one-liner.
- Existing consumers migrate when they decide: the old form keeps working; the note says to re-run
  the bootstrap, remove the old `./bootstrap` and repoint the include.
- Windows named-pipe SSH agents cannot be forwarded without a host relay, so `windows-docker`
  and `windows-wslc` have no agent in the container unless the opt-in key is used.
- ADR 0020's mount line moves from the repo into the launcher; its wrapper is unchanged.
- The devcontainer-cli Feature and the bootstrap change together, with a version bump.

## Change log

| Date | Change |
|---|---|
| 2026-10-23 | Proposed; the five decisions taken by the Operator, the rest open. |
| 2026-10-23 | Accepted: the Operator answered the open questions; HOST_TYPE_PRIORITY, DCF_HOST_* instead of a profile file, windows-docker, key option, BOOTSTRAP_* settings. |
| 2026-10-29 | Amendment 2026-10-29: the host is called a host type; "adapter" is reserved for the CLI adapter (LEXICON.md); the "backend, source or sink" wording is retired. The decision is unchanged. |
