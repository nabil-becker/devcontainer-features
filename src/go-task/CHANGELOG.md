# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.2.0 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.2.1] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.2.0] - 2026-10-29

### Added

- Opt-in `taskAliases` option: give your team's words their own short task names without wiring includes by hand in each repository. Off by default; with it off the generated `features.yml` is byte-identical, so nothing changes unless you set `"taskAliases": true`. Turned on, it installs a private, sha256-verified `yq` at `/usr/local/share/go-task/yq` (never on PATH). `task go-task:aliases` regenerates the aliases and exits non-zero on a bad one; an alias that shadows a task, task alias or include alias is refused. ([#98](https://github.com/nabil-becker/devcontainer-features/pull/98))

## [1.1.3] - 2026-10-28

### Fixed

- Every build-time download retries through dcf_curl (13 Features) ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

## [1.1.2] - 2026-10-22

### Changed

- Night shift 2026-10-22: merged-branch pruning, the guard's close message, NFR-2 lint; Pester in the devhost image ([#54](https://github.com/nabil-becker/devcontainer-features/pull/54))

## [1.1.1] - 2026-10-21

### Fixed

- Az installs the Azure CLI; Feature tasks run in the caller's folder ([#48](https://github.com/nabil-becker/devcontainer-features/pull/48))

## [1.1.0] - 2026-10-09

### Changed

- Add seven Features, a Feature Taskfile registry, development conventions and a repo devcontainer ([#5](https://github.com/nabil-becker/devcontainer-features/pull/5))
- Move bootstrap material under bootstrap/ and share the bash devcontainer-CLI logic with the Feature ([#6](https://github.com/nabil-becker/devcontainer-features/pull/6))

## [1.0.0] - 2026-10-09

### Changed

- Add go-task, devcontainer-cli and claude-code Features, host-side Taskfile and bootstrap ([#2](https://github.com/nabil-becker/devcontainer-features/pull/2))
