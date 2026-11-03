# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.3.1 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.3.2] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.3.1] - 2026-10-30

### Changed

- **The post-start hook never fails and never holds the start.** A consumer's rebuild ended with
  `postStartCommand from Feature 'cloud-folder' failed with exit code 1` after 775 s, while another
  Feature's hook waited at a prompt and WSL reported a connection timeout. `cloud-folder-setup` with
  no argument (the hook, and `task cloud-folder:setup`) now always exits 0: a broken pipe or hang-up
  on the exec channel (SIGPIPE, SIGHUP) is ignored, and the whole run gets a budget of 60 s
  (`DCF_CLOUD_FOLDER_START_BUDGET`) after which it reports that it did not finish and returns; the
  mount and the sync timer are detached and go on in the background. A problem is a warning with
  the command to fix it (`task cloud-folder:status`, `:login`, `:start`). The explicit tasks
  (`start`, `sync`, `status`, `login`) keep their real exit codes.

## [1.3.0] - 2026-10-29

### Changed

- **One sign-in command, wherever it runs.** `task cloud-folder:login` now runs rclone's own browser
  sign-in (`rclone authorize "onedrive" --auth-no-open-browser`) in the container instead of
  asking for a token from another machine with the same rclone version. Sign in in any browser and
  paste back the address it fails to open (`http://localhost:53682/?code=...`), or, from the
  workstation with `devcontainer-cli` 1.16.0, let the launcher relay the browser into the container.
  A pasted token is still accepted at the same prompt, and `-- --token` asks for nothing else. See
  "Signing in". `login` takes `-- --relay` (the launcher's) and `-- --token`;
  `CLOUD_FOLDER_LOGIN_TIMEOUT` bounds the wait (default 600 s). The token is still written only into
  the volume's `rclone.conf`.

## [1.2.0] - 2026-10-29

### Added

- Mount and auto modes, FUSE per machine (cloud-folder 1.2.0, devcontainer-cli 1.15.0) ([#95](https://github.com/nabil-becker/devcontainer-features/pull/95))

## [1.1.2] - 2026-10-28

### Fixed

- Every build-time download retries through dcf_curl (13 Features) ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

## [1.1.1] - 2026-10-28

### Fixed

- The install reads rclone's whole version output, no SIGPIPE under pipefail (cloud-folder 1.1.1) ([#88](https://github.com/nabil-becker/devcontainer-features/pull/88))
- Installs retry every download error, no early-closing grep -q under pipefail (cloud-folder 1.1.1, claude-code 1.8.2, git 1.4.4) ([#89](https://github.com/nabil-becker/devcontainer-features/pull/89))

## [1.1.0] - 2026-10-27

### Added

- Sync mode with rclone (cloud-folder 1.1.0) ([#83](https://github.com/nabil-becker/devcontainer-features/pull/83))

## [1.0.0] - 2026-10-27

### Added

- A cloud folder in the container, host mode (cloud-folder 1.0.0, devcontainer-cli 1.12.0) ([#82](https://github.com/nabil-becker/devcontainer-features/pull/82))
