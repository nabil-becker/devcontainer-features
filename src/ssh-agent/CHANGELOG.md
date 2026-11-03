# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.3.0 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.3.2] - 2026-11-03

### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Where the Feature has them, its best practices and anti-patterns are in the README too. Documentation only: the Feature itself is unchanged. Nothing to do.

## [1.3.1] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.3.0] - 2026-11-03

### Added

- `task ssh-agent:key:unlock NAME=<key> [MINUTES=15]` loads one key from the key volume into the agent for a sitting (at most 480 minutes), asking for its passphrase on the terminal, and says when it drops out; `task ssh-agent:key:lock NAME=<key>` drops it sooner. Key mode only. Nothing to do for existing setups. ([#152](https://github.com/nabil-becker/devcontainer-features/pull/152))

## [1.2.0] - 2026-10-30

### Fixed

- The start hook never asks for a passphrase (ssh-agent 1.2.0) ([#135](https://github.com/nabil-becker/devcontainer-features/pull/135))

## [1.1.1] - 2026-10-26

### Fixed

- Git:verify cleans up without an unbound-variable error; Windows hosts default to SCOPE=global (ssh-agent 1.1.1) ([#81](https://github.com/nabil-becker/devcontainer-features/pull/81))

## [1.1.0] - 2026-10-24

### Added

- Dedicated keys and one-command rotation (ssh-agent 1.1.0, devcontainer-cli 1.10.0) ([#73](https://github.com/nabil-becker/devcontainer-features/pull/73))

## [1.0.0] - 2026-10-23

### Added

- The ssh-agent Feature 1.0.0, the agent mount and key tasks (slice 4; devcontainer-cli 1.8.0, git 1.4.3) ([#68](https://github.com/nabil-becker/devcontainer-features/pull/68))
