# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.0.3 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.1.1] - 2026-11-03

### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Documentation only: the Feature itself is unchanged. Nothing to do.

## [1.1.0] - 2026-11-03

### Added

- **Your `bao login` now survives a rebuild.** The Feature owns a named volume (`openbao-config-<devcontainerId>`, at `/var/lib/devcontainer-features/openbao`, named by `OPENBAO_STATE_DIR`) and points `bao` at a token helper (`BAO_CONFIG_PATH`, set in `containerEnv`, so it holds for `devcontainer exec` too) that keeps the token there, as `gh` and `az` keep their logins. The post-create hook, `openbao-setup` (also `task openbao:setup`), makes the folder usable and moves a token left in `~/.vault-token` into it once. **You must act once:** rebuild the container and run `bao login` again, because the volume starts empty. A repo that sets its own `BAO_CONFIG_PATH` replaces the Feature's config (the hook says so); add `token_helper = "/usr/local/bin/openbao-token-helper"` to it. A repo that wants the state on the host disk bind-mounts the same target. A `BAO_TOKEN` in the environment still takes precedence over the saved login.
- **`dcf-secret`**, a command for scripts and other Features to read and write a secret without knowing where the server runs: `dcf-secret get <name>`, `dcf-secret put <name> --field <field>` (the value on stdin) and `dcf-secret status`. `put` writes only that field and keeps the secret's other fields (it creates the secret when it does not exist); `--replace` makes the secret exactly that one field. A token whose policy lacks the `patch` capability is refused with exit 13 rather than silently replacing the secret. It fails with fixed exit codes (10 unreachable, 11 sealed, 12 not logged in, 13 denied, 14 no such secret), each with one line saying what to do, and never falls back to a key on disk. Secrets live in a KV v2 mount named `dcf` (`DCF_SECRET_MOUNT` changes it). Nothing to do unless you want it; `task openbao:kv:get` is unchanged.
- **The `mode` option**, with the one value `client` (the default, what the Feature always did: the CLI against a server outside the container). A later version adds `server`. `OPENBAO_SETUP_MODE` in `containerEnv` overrides it per container. Nothing to do.
- `task openbao:logout`: revokes your token on the server and erases the saved one, so no login is left behind (`bao token revoke -self` alone leaves the dead token stored, and `dcf-secret` then says to log in). Nothing to do unless you log out.
- `task openbao:setup`: re-runs the post-create hook.

## [1.0.4] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.0.3] - 2026-10-28

### Fixed

- Build-time downloads retry on transient network errors, so a flaky connection no longer fails the container build outright. Rebuild the container to pick it up. No change to options or tasks; nothing to do. ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

## [1.0.2] - 2026-10-21

### Fixed

- Az installs the Azure CLI; Feature tasks run in the caller's folder ([#48](https://github.com/nabil-becker/devcontainer-features/pull/48))

## [1.0.1] - 2026-10-20

### Changed

- Features docs to the NOTES standard; records of 2026-10-17 to 2026-10-19 ([#14](https://github.com/nabil-becker/devcontainer-features/pull/14))

## [1.0.0] - 2026-10-09

### Changed

- Add seven Features, a Feature Taskfile registry, development conventions and a repo devcontainer ([#5](https://github.com/nabil-becker/devcontainer-features/pull/5))
