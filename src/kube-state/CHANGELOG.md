# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.0.2 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.0.4] - 2026-11-03

### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Documentation only: the Feature itself is unchanged. Nothing to do.

## [1.0.3] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.0.2] - 2026-10-21

### Fixed

- `task kube-state:...` now runs in the folder you call it from, not in the Taskfile include folder, so it finds your repository. Rebuild to pick it up; nothing to change. ([#48](https://github.com/nabil-becker/devcontainer-features/pull/48))

## [1.0.1] - 2026-10-20

### Changed

- Features docs to the NOTES standard; records of 2026-10-17 to 2026-10-19 ([#14](https://github.com/nabil-becker/devcontainer-features/pull/14))

## [1.0.0] - 2026-10-15

### Changed

- Features/true up features ([#11](https://github.com/nabil-becker/devcontainer-features/pull/11))
