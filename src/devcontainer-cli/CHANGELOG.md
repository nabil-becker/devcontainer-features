# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.18.1 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.18.2] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.18.1] - 2026-11-03

### Changed

- **The waiting line counts every other waiter** (`N waiting`, was `N ahead`): the build lock is
  not first-come, so a count of earlier arrivals promised an order that does not exist. The count
  is every live waiter but this one, whenever it arrived; the holder is not one, and there is no
  count when there is no other waiter: `waiting for alpha's up --build-no-cache (started 14:02, 2
  waiting)...`. Both launchers.

## [1.18.0] - 2026-11-03

### Changed

- **The build lock says who holds it** (#154). A waiting `up` printed only `waiting for another
  devcontainer build to finish...` and could sit there behind long rebuilds of other repositories
  with no way to tell. Now the holder writes a small file beside the lock (its repository's folder
  name, the subcommand with its flags, its start time) and each waiter registers too, so the line
  reads `waiting for alpha's up --remove-existing-container --build-no-cache (started 14:02, 2
  waiting)...` and is printed again when the holder or the count changes. A file whose process is
  gone is ignored. The count is every other waiter (not the holder, not this one), whenever it
  arrived: the lock is not first-come, so there is no place in a queue to show.
- **No build lock with BuildKit build contexts.** The lock is for one collision only: without
  BuildKit build contexts (wslc), `@devcontainers/cli` tags every repository's Feature content
  image `dev_container_feature_content_temp`. When `<engine> buildx version` reports 0.8.0 or later
  (the check the CLI itself makes; Docker Desktop and Docker Engine with buildx), the CLI uses
  build contexts and makes no such image, so the launcher now skips the lock with one line:
  `build lock skipped: docker builds with BuildKit build contexts (buildx 0.35.0), so builds of
  different repositories cannot collide (DEVCONTAINER_BUILD_LOCK=1 keeps it).` wslc always keeps
  it. `DEVCONTAINER_BUILD_LOCK=1` (new) keeps the lock on every engine; `=0` still turns it off.
  Both launchers (PowerShell and bash).

## [1.17.0] - 2026-11-02

### Changed

- **The launcher waits for the container engine** (new setting `DEVCONTAINER_ENGINE_WAIT`). Right
  after a rebuild an `up` failed inside with `Command failed: docker ps -q -a --filter label=...`
  and "An error occurred setting up the container", and a second run went through: the engine had
  not answered for a moment, and `@devcontainers/cli` hides its error. Now `up`, `build`, `exec`,
  `set-up` and `run-user-commands` first check that the engine answers (one check when it does);
  otherwise they print `waiting for the container engine to answer...` once and check every second
  for `DEVCONTAINER_ENGINE_WAIT` seconds (default 60; `0` = no wait), then fail naming the engine,
  its own error and how to start it. A failed `up` or `build` asks the engine once more and prints
  what it says. Both launchers (PowerShell and bash); see "Host-side counterpart".
- **`task devcontainer:agent` with no name** refuses on the host, before the container is started,
  when the agent list (`AGENTS_FILE`, else `.devcontainer/agents.yml`) marks no agent
  `default: true`; before, a whole `up` ran first and `agents start` inside then said so. A list
  that is missing or cannot be read is let through, as is any line that reads `default: true`.

## [1.16.3] - 2026-10-30

### Changed

- **FUSE is not granted on wslc.** `wslc run` (WSL Containers 3.0.3) has no `--device`, `--cap-add`
  or `--security-opt` option and refused the whole start ("Option name was not recognized for the
  current command: '--device=/dev/fuse'") when `DCF_HOST_FUSE=1` filled the `runArgs`. On the
  `windows-wslc` host type, or with `DEVCONTAINER_DOCKER_PATH` naming `wslc`, the launcher now
  withholds the grant: the three `DCF_HOST_FUSE_*` variables stay unset (the `runArgs` fall back to
  their labels), `DCF_HOST_FUSE` reaches the container empty, `up` warns once with the reason, and
  the container starts without FUSE, so the cloud-folder Feature's `auto` mode takes sync.
  `task devcontainer:host` prints `DCF_HOST_FUSE : 1 asked for, not granted on windows-wslc: ...`.
  Docker Desktop and the other engines are unchanged. Unset `DCF_HOST_FUSE` in `.devcontainer/.env`
  on a wslc machine to drop the warning.

## [1.16.2] - 2026-10-30

### Changed

- **`DCF_HOST_MACHINE`**: the launcher sets the workstation's machine name for `up` and `rebuild`,
  like the other `DCF_HOST_*` values, so agents' session names can say which machine they run on.
  PowerShell reads `$env:COMPUTERNAME` on Windows (else the host name before its first dot); bash
  reads `hostname -s` (else `uname -n` before its first dot). The name is cut to a safe set: letters,
  digits, dot, underscore and hyphen; any other character becomes a hyphen, runs collapse, no leading
  or trailing hyphen or dot, at most 63 characters. It is always the launcher's own value, never one
  inherited from the environment. The bootstrap's `devcontainer.json` passes it on with
  `"DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}"`. `up` and `host` warn once (never fail) when
  the repository's `devcontainer.json` lacks that line, as for the FUSE slots; add the line to the
  `containerEnv` of an existing repository. Empty means the container renders `container`.

## [1.16.1] - 2026-10-29

### Changed

- **`task devcontainer:lock` and `task devcontainer:outdated`** (aliases `dc:lock`, `dc:outdated`):
  update the lock file to the requested Feature versions, or list what is behind, instead of
  deleting the lock file by hand.

## [1.16.0] - 2026-10-29

### Changed

- **`task cloud-folder:login` from the workstation.** A new host command, `run cloud-folder-login`
  (bash) and `Invoke-CloudFolderLogin` (PowerShell), behind `task devcontainer:cloud-folder-login`
  and, when the root Taskfile includes the vendored `cloud-folder.yml` (the bootstrap's template
  does), `task cloud-folder:login`: the cloud-folder Feature's (1.3.0) sign-in through the running
  devcontainer. See "Cloud-folder sign-in" below. The bootstrap vendors `cloud-folder.yml` and prints
  the include lines for a Taskfile that lacks them. Nothing changes for the other tasks; the
  PowerShell module gains `Get-DevcontainerCliInvocation`, the argument list every CLI call already
  built, now shared with the login.

## [1.15.0] - 2026-10-29

### Added

- Mount and auto modes, FUSE per machine (cloud-folder 1.2.0, devcontainer-cli 1.15.0) ([#95](https://github.com/nabil-becker/devcontainer-features/pull/95))

## [1.14.1] - 2026-10-28

### Fixed

- Every build-time download retries through dcf_curl (13 Features) ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

## [1.14.0] - 2026-10-28

### Fixed

- Unreadable lists start nothing, retitled sessions are found, agents:reset; claude-code additionalDirectories (agents 1.0.1, claude-code 1.8.0, devcontainer-cli 1.14.0) ([#85](https://github.com/nabil-becker/devcontainer-features/pull/85))

## [1.13.0] - 2026-10-27

### Added

- One agent list, two kinds, one verb for every agent CLI (agents 1.0.0, claude-code 1.7.0, devcontainer-cli 1.13.0) ([#84](https://github.com/nabil-becker/devcontainer-features/pull/84))

## [1.12.0] - 2026-10-27

### Added

- A cloud folder in the container, host mode (cloud-folder 1.0.0, devcontainer-cli 1.12.0) ([#82](https://github.com/nabil-becker/devcontainer-features/pull/82))

## [1.11.0] - 2026-10-24

### Added

- The fleet waits for restored sessions, reports and stops duplicates (claude-code 1.6.0, devcontainer-cli 1.11.0) ([#76](https://github.com/nabil-becker/devcontainer-features/pull/76))

## [1.10.0] - 2026-10-24

### Added

- Dedicated keys and one-command rotation (ssh-agent 1.1.0, devcontainer-cli 1.10.0) ([#73](https://github.com/nabil-becker/devcontainer-features/pull/73))

## [1.9.0] - 2026-10-23

### Added

- Claude-host resumes the live session after /clear; claude-fleet (claude-code 1.5.0, devcontainer-cli 1.9.0) ([#70](https://github.com/nabil-becker/devcontainer-features/pull/70))

## [1.8.0] - 2026-10-23

### Added

- The ssh-agent Feature 1.0.0, the agent mount and key tasks (slice 4; devcontainer-cli 1.8.0, git 1.4.3) ([#68](https://github.com/nabil-becker/devcontainer-features/pull/68))

## [1.7.0] - 2026-10-23

### Added

- The launcher adds host mounts (slice 3, 1.7.0); git hint (1.4.2) ([#67](https://github.com/nabil-becker/devcontainer-features/pull/67))

## [1.6.0] - 2026-10-23

### Added

- The bootstrap vendors into .devcontainer/cli_bootstrap.ignore (slice 2, 1.6.0) ([#65](https://github.com/nabil-becker/devcontainer-features/pull/65))

## [1.5.0] - 2026-10-23

### Added

- HOST_TYPE and the DCF_HOST_* variables (slice 1, 1.5.0) ([#64](https://github.com/nabil-becker/devcontainer-features/pull/64))

## [1.4.4] - 2026-10-23

### Fixed

- Rebuild stops like stop (devcontainer-cli 1.4.4) ([#59](https://github.com/nabil-becker/devcontainer-features/pull/59))

## [1.4.3] - 2026-10-22

### Added

- The shutdown check is an optional contract (devcontainer-cli 1.4.3) ([#56](https://github.com/nabil-becker/devcontainer-features/pull/56))

## [1.4.2] - 2026-10-21

### Fixed

- Az installs the Azure CLI; Feature tasks run in the caller's folder ([#48](https://github.com/nabil-becker/devcontainer-features/pull/48))
- Serialise devcontainer up/build across repositories ([#49](https://github.com/nabil-becker/devcontainer-features/pull/49))

## [1.4.1] - 2026-10-21

### Changed

- Devcontainer-cli 1.4.1: stop finds the container on Windows; stop is one command; errors say what failed ([#41](https://github.com/nabil-becker/devcontainer-features/pull/41))

## [1.4.0] - 2026-10-21

### Changed

- Devcontainer-cli 1.4.0: dc:start and dc:down; up and stop idempotent and required by the other tasks ([#39](https://github.com/nabil-becker/devcontainer-features/pull/39))

## [1.3.0] - 2026-10-21

### Changed

- Stop runs a configurable check (STOP_CHECK); devcontainer-cli 1.3.0 ([#38](https://github.com/nabil-becker/devcontainer-features/pull/38))

## [1.2.0] - 2026-10-20

### Changed

- Devhost 1.6.0, devcontainer-cli 1.2.0: the shutdown check, the shutdown and restart skills, devcontainer:stop (ADR 0015) ([#24](https://github.com/nabil-becker/devcontainer-features/pull/24))

## [1.1.3] - 2026-10-20

### Changed

- Features docs to the NOTES standard; records of 2026-10-17 to 2026-10-19 ([#14](https://github.com/nabil-becker/devcontainer-features/pull/14))

## [1.1.1] - 2026-10-15

### Changed

- Features/true up features ([#11](https://github.com/nabil-becker/devcontainer-features/pull/11))

## [1.1.0] - 2026-10-09

### Changed

- Add seven Features, a Feature Taskfile registry, development conventions and a repo devcontainer ([#5](https://github.com/nabil-becker/devcontainer-features/pull/5))
- Move bootstrap material under bootstrap/ and share the bash devcontainer-CLI logic with the Feature ([#6](https://github.com/nabil-becker/devcontainer-features/pull/6))

## [1.0.0] - 2026-10-09

### Changed

- Add go-task, devcontainer-cli and claude-code Features, host-side Taskfile and bootstrap ([#2](https://github.com/nabil-becker/devcontainer-features/pull/2))
