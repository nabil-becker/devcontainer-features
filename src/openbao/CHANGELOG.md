# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.0.3 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.3.0] - 2026-11-04

### Added

- **SSH key records in OpenBao**: `task openbao:ssh:new` makes an ed25519 key at `dcf/ssh/<name>` (the fields `private_key`, `public_key`, `purpose`, and its creation date in the metadata), generated on tmpfs and removed at once, with no passphrase: the unseal and your login are the gate. `task openbao:ssh:put NAME=` stores a key you pipe in, `task openbao:ssh:retire NAME=` destroys a record's private key and keeps its public key and dates (`-- --plan` shows the steps), `task openbao:ssh:age` lists each record with its age. A record is never overwritten and a name never reused. Nothing to do unless you want them; ssh-agent 1.4.0's `key:load NAME=ssh/<key>` reads them.
- **`task openbao:ssh:import`**: `FROM=ssh-agent` moves every key of the ssh-agent Feature's key volume into OpenBao (the creation dates from the volume, the fingerprints compared, a passphrase asked once at ssh-keygen's prompt), writes the volume's `allowed_signers.history` and a line per key into `.devcontainer/allowed_signers` for the host to commit, proves one key through ssh-agent, and only then asks, per key, whether to delete the volume's copy. `FROM=file FILE=<path>` (or the key on stdin with `NAME=`, which the workstation's `task devcontainer:openbao-ssh-import` streams in) and `FROM=agentic-register` (the register's `keys/<principal>` as `register/<principal>`) do the same for one key or the register's. It can run again: what is there is skipped. **If you use ssh-agent's key mode, run `task openbao:ssh:import FROM=ssh-agent` once** (server mode unsealed, logged in); the key volume goes with ssh-agent 2.0.
- `dcf-secret ttl` prints the seconds the token has left (0: it does not expire), so a caller lives no longer than the login.

## [1.2.0] - 2026-11-03

### Added

- **Server mode: a local OpenBao server in the container.** Set the `mode` option to `server` (or `OPENBAO_SETUP_MODE=server` in `containerEnv`, no rebuild; needs OpenBao 2.4.0 or newer, and an older pinned `version` fails the build with that said). The post-start hook starts one server with raft storage on the Feature's volume and a loopback-only listener (`127.0.0.1:8200`, no TLS), and it comes up **sealed**: nothing can read a secret until you unseal it. The hook never waits and never prompts; it prints whether the server is not initialised, sealed or unsealed. `mode: client` stays the default and behaves as before. **You must act once, in a plain terminal in the container:** `task openbao:init`, then after every container restart `task openbao:unseal`.
- `task openbao:init`: asks for a **backup destination or the words `no backup`** (never defaulted, and the answer is recorded in the volume), asks for the Operator's password, makes **3 unseal shares with a threshold of 2** and prints them once, only to the terminal (keep one in a password manager, one on paper offline, one with a second person or on a hardware key; losing two loses every secret), has you enter two of them to prove you stored them, sets up the `dcf` KV mount, `userpass` and `approle`, and revokes the root token. `-pgp-keys=...` after `--` encrypts the shares.
- `task openbao:unseal` and `task openbao:seal`. `task openbao:server:status` shows the state, the storage, the audit log, whether your login is valid and the backup choice, with a standing warning while there is none. Your login is `task openbao:login -- -method=userpass username=operator`: it lasts **4 hours, at most 8**, and a renewal past that is refused.
- `task openbao:approle:issue ROLE=<name> POLICY_PATH=<mount/path>` makes a role for a machine identity (for the devhost's backs, later) that may read that one secret, only from inside the container (loopback-bound secret ids and tokens), with 5 minute tokens; `ROLE=<name>` alone or `ALL=1` reissues, leaving exactly one valid secret id per role, written to the volume and never printed. `task openbao:approle:revoke ROLE=<name>` removes a role.
- A file audit device in the volume (`audit.log`), declared in the server's config.
- **Not included yet:** `openbao:backup` and restore. A backup destination is recorded but not used, so until a later version a lost machine loses what is in the server's volume (this is why `init` asks and `server:status` warns); take a snapshot by hand with `bao operator raft snapshot save`.

### Changed

- **`init`, `unseal` and `seal` refuse inside an agent's job** (when `DEVHOST_JOB_CHILD` or `CLAUDECODE` is set, or a variable you name in `OPENBAO_AGENT_JOB_VARS`), and `init` and `unseal` refuse without a terminal: the shares and the token must never land in a transcript. Run them yourself in a plain terminal.
- `dcf-secret`'s failure lines now name the tasks: sealed points to `task openbao:unseal`, not initialised to `task openbao:init`, unreachable to `task openbao:server:status`, each adding what to do against a server elsewhere. The exit codes are unchanged.
- In server mode `BAO_ADDR` defaults to the local server for `dcf-secret` and every task when you have not set it (a bare `bao` still needs `BAO_ADDR`). The tasks `status`, `login`, `logout`, `kv:get` and `setup` run the same `bao` call through `openbao-run`, which adds only that default; client mode is unchanged. `task openbao:setup` now also runs the start hook.

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
