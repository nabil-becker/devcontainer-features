# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.18.1 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.22.1] - 2026-11-09

### Fixed

- **The OpenBao key file works with a variable remote user (Windows launcher)**: with `"remoteUser": "${localEnv:NAME:default}"` in devcontainer.json, `task dc:openbao:unlock` and `task dc:openbao:keyfile:create` said "this devcontainer has no openbao-setup that knows the OpenBao key file" (create exited 4) and the unlock after `up` did nothing, because the launcher ran `docker exec -u '${localEnv:NAME:default}'` with the text as written. The launcher now resolves `${localEnv:NAME}` and `${localEnv:NAME:default}` as the devcontainers CLI does at `up` (the launcher's environment, which under `task` includes the `.env` files, else the default); any other `${...}` falls back to the container's own user, never reaching `-u`.
- When asking the container for OpenBao's unlock status fails for another reason than a missing or older `openbao-setup`, the launcher now says so in one line, with the exit code and the error's first line (for example `docker exec as user 'X' failed (exit 1): unable to find user X: no matching entries in passwd file`), on `task dc:openbao:unlock`, on `keyfile:create`/`rotate` (exit 1) and after `up`, instead of the misleading "no openbao-setup" or silence.

### Changed

- **Act:** none beyond the next bootstrap refresh (re-run the bootstrap to vendor the new launcher); no rebuild.

## [1.22.0] - 2026-11-06

### Added

- **The microphone is gated on the workstation (both launchers)**: with `DCF_HOST_AUDIO=wslg`, `up` no longer binds WSLg's own `/mnt/wslg` and mounts it in the container (1.21.0, always on) but makes an empty relay directory `/mnt/wsl/devhost-audio` in the default WSL distro and mounts that at `/mnt/wslg`. The real socket is never mounted and the microphone is OFF until you turn it on: `task audio:on` (the new `audio.yml`, vendored by the bootstrap; include it in the root Taskfile as the bootstrap's `Taskfile.yml` shows) starts a socat relay in the default distro for `TTL=<duration>` (`90s`, `15m`, `2h`; default `DCF_HOST_AUDIO_TTL` or 15 minutes; at most `DCF_HOST_AUDIO_TTL_MAX`, default 2 hours, longer is cut to it), `task audio:off` ends it at once, `task audio:status` says whether it is on and the time left. When the relay ends, the socket file is gone and the container sees none. The switch lives outside the container, so no process in it can undo it, and turning it on or off needs no rebuild. New launcher subcommand `audio on|off|status`. It needs socat in the default distro.
- `task devcontainer:host` describes the relay directory.
- `task audio:setup` (optional, once per machine) installs socat in the default WSL distro with apt-get, or says it is already there; `audio on` names it when socat is missing.

### Changed

- **Act:** if you use `DCF_HOST_AUDIO=wslg`, re-run the bootstrap (it vendors `audio.yml`), add the `audio` include to the root Taskfile (the `Taskfile.yml` of a new bootstrap has it), install socat in the default WSL distro, run `task devcontainer:up` and `task devcontainer:rebuild` once (the mount source changed), then `task audio:on` whenever you dictate. Unset or `none` still changes nothing. The audio Feature 1.1.0 is the container side.

## [1.21.0] - 2026-11-06

### Added

- **Audio on request (both launchers)**: `DCF_HOST_AUDIO=wslg` in a Windows WSL2 workstation's `.devcontainer/.env` gives the container its microphone through WSLg's PulseAudio socket, for the new `audio` Feature (Claude Code's `/voice`). Before `up`, on the `windows-docker` and `windows-wsl-docker` host types, the launcher binds the default WSL distro's `/mnt/wslg` to `/mnt/wsl/wslg` as root (skipped when already there; a WSL restart drops it and the next `up` redoes it), mounts it at `/mnt/wslg`, and sets `DCF_HOST_AUDIO=wslg` for `containerEnv`; anywhere else, or when that distro has no WSLg socket, it warns once and starts the container without audio (`DCF_HOST_AUDIO=none`). `task devcontainer:host` says what it would do. Unset or `none` (the default) runs nothing and adds nothing: nothing changes unless you opt in. It gives every process in the container the microphone; whether dictated audio may go to a model provider is your repository's ruling. To use it: re-vendor the bootstrap, add `"DCF_HOST_AUDIO": "${localEnv:DCF_HOST_AUDIO}"` to `containerEnv` (the bootstrap's template has it), add the `audio` Feature once it is released, set the variable and run `task devcontainer:rebuild`.

## [1.20.0] - 2026-11-05

### Added

- **The OpenBao key file (Windows launcher)**: with the openbao Feature 1.5.0 or later set to `unlock: keyfile`, every `task dc:up` (so `start`, `shell`, `exec`, `agent`, `claude`, `rebuild`) unseals OpenBao and logs you in with nothing typed, from a DPAPI-protected key file in `%LOCALAPPDATA%\devcontainer-features-keys\openbao\` (it also opens with a domain's DPAPI backup key). It is streamed into the container on stdin through the engine's `exec`, never as an argument, an environment variable or a file. New tasks: `dc:openbao:unlock`, `dc:openbao:keyfile:create`, `:rotate`, `:export`, `:import`, `:forget`; `create` and `rotate` take two steps (OpenBao's rekey verification): the key file is saved first, then confirmed with its own shares 4 and 5, and only then are the three custody shares printed; a failed save or confirm cancels the rotation (with its own nonce; another rotation is never cancelled) and keeps the old shares and key file; a lost confirm answer is settled by `keyfile status`'s pending verification nonce; the nonce carries a confirm token, so it is never printed or logged; the container's warnings are shown. The four that handle shares or the file refuse inside an agent's job (`CLAUDECODE`, `DEVHOST_JOB_CHILD`, `OPENBAO_AGENT_JOB_VARS`). Nothing changes for a repository whose openbao Feature is not in keyfile mode (one silent status call after `up`). To use it: re-vendor the bootstrap, set `unlock: keyfile`, rebuild, then run `task dc:openbao:keyfile:create` once in a plain terminal and store the three custody shares it prints.
- The bash launcher (Linux, macOS, a WSL distro) refuses those tasks in one line: the OpenBao key file is Windows-only for now.

## [1.19.0] - 2026-11-04

### Added

- **`task devcontainer:openbao-ssh-import FILE=<key> [NAME=]`** (both launchers): streams a private key of the workstation into OpenBao in the running container (the openbao Feature 1.3.0, unsealed, logged in there), through `devcontainer exec` on stdin, never as an argument; it is stored as `ssh/<name>` and its public key goes into the repository's `.devcontainer/allowed_signers`. A one-shot, as before: nothing is left running on the workstation. A key with a passphrase is imported inside the container instead (`task openbao:ssh:import FROM=file FILE=<path>`), where ssh-keygen can ask for it. Re-vendor the bootstrap to get the task.

### Deprecated

- `task devcontainer:ssh-key-import` (the key into ssh-agent's key volume) still works and says it is deprecated; it goes with ssh-agent 2.0. Use `devcontainer:openbao-ssh-import`.

## [1.18.3] - 2026-11-03

### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Documentation only: the Feature itself is unchanged. Nothing to do.

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
