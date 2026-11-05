# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.3.0 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.5.0] - 2026-11-05

### Added

- **A `mode` option** (`auto`, `socket`, `key`, `none`; default `auto`) is the one setting for which agent the container uses. `auto` behaves exactly as before: it follows what the launcher found for the host. `key` starts the agent inside the container and loads the keys of the key volume (what `keyMode: true` meant; a host socket the launcher really mounted still wins, and the start hook says so). `socket` and `none` pin those two outcomes whatever the launcher found. To choose per machine, write `"mode": "${localEnv:SSH_AGENT_MODE:auto}"` in `devcontainer.json` and `SSH_AGENT_MODE=key` in `.devcontainer/.env` on the workstation, then rebuild. An empty or unknown value counts as `auto` with one warning. `SSH_AGENT_SETUP_MODE` in `containerEnv` overrides it without a rebuild.

### Changed

- The messages that told you how to turn key mode on now name this way (the `mode` line plus `SSH_AGENT_MODE=key` in `.devcontainer/.env`, then rebuild).

### Deprecated

- **`keyMode` and the `SSH_AGENT_SETUP_KEY_MODE` override** (removed in 2.0): they still work, `keyMode: true` meaning `mode: key` while `mode` is `auto`, and the start hook prints one deprecation line while either is on. **You do not have to act now**; move to `mode` when convenient.

## [1.4.0] - 2026-11-04

### Added

- **`task ssh-agent:key:load NAME=ssh/<key> [MINUTES=]` loads a key from OpenBao** (the openbao Feature 1.3.0, unsealed, after `task openbao:login`): the key is piped into `ssh-add -t <life> -`, so it is in agent memory only and never in a file, for as long as your OpenBao login has left (at most 8 hours; `MINUTES` shortens it), and it says when it drops out. In socket mode it loads into the workstation's agent and says so. `task ssh-agent:key:lock NAME=ssh/<key>` takes it out, also while OpenBao is sealed. OpenBao's own exit codes come through (11 sealed, 12 log in, 14 no such key).
- **`task ssh-agent:key:rotate NAME=ssh/<key>` rotates on OpenBao records**: the same four steps and order (a new record, registered at GitHub as a signing key through the gh Feature's `gh:ssh-key:add`, git pointed at it and verified, only then the old record retired), and `.devcontainer/allowed_signers` keeps both keys with valid-after and valid-before stamps, so old commits still verify. The host commits the file.
- `task ssh-agent:git:signing` adds the key to `.devcontainer/allowed_signers` and sets `gpg.ssh.allowedSignersFile` in the repository's config to that relative path, but only where the repository has the file (or `ALLOWED_SIGNERS=<file>` names one). git reads it from the top of the work tree, from any folder.

### Deprecated

- **The key volume and its tasks**: `key:new`, `key:add`, `key:unlock`, `key:retire`, `key:age`, `key:remove DELETE=1`, `key:load` with no `NAME`, `key:lock` and `key:rotate` of a volume key, and the old workstation import (`devcontainer:ssh-key-import`) still work as before and print one line naming what replaces them; the start hook says so once in key mode when the volume holds keys. They are removed in ssh-agent 2.0, where `keyMode` becomes `localAgent`. **Nothing breaks now**; to move, add the openbao Feature and run `task openbao:ssh:import FROM=ssh-agent` once, then `key:unlock NAME=<file>` becomes `key:load NAME=ssh/<file>`. A setup in socket mode that never used key mode changes nothing.

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
