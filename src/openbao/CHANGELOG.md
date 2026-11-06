# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.0.3 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.6.0] - 2026-11-06

### Added

- **An SSH certificate authority in OpenBao**, for the two consumers that asked: AOF (the
  agentic-operating-framework's tooling agent; its packet-relay signs each stack instance's relay key
  with it, rulings D94 and D95) and the KGO Office (one CA for its register writer keys, so a register
  trusts the CA once instead of every machine's key one by one). The CA's private key lives in OpenBao
  and never leaves it: no task and no `dcf-secret` name returns it. Verification is stock OpenSSH:
  `ssh-keygen -Y verify` against `cert-authority` lines, with expiry.
  - **`task openbao:ssh:ca:init`** enables an `ssh` secrets engine at `ssh-ca` (`MOUNT=` or
    `DCF_SSH_CA_MOUNT` name another), has OpenBao generate the CA (ed25519), makes the default role
    and gives the Operator's policy the sign path. Idempotent: a second run reports the CA's
    fingerprint and changes nothing. In server mode it uses a root token made from two unseal shares
    for this step alone (like `openbao:approle:issue` with a policy path): a plain terminal, refused
    inside an agent's job. Against a server elsewhere it runs with the token you hold and prints the
    policy paths the server's owner adds.
  - **Roles.** The default role (`default`, `DCF_SSH_CA_ROLE` renames it) has the principal forms AOF
    uses, `relay@<guid>` and `fed-<guid>` (exactly a lowercase 8-4-4-4-12 GUID after the prefix; `<guid>` and `*` are the pattern syntax of every role; `ALLOWED=` overrides them), `TTL=` default 2160h (90 days), `MAX_TTL=`
    default the same as `TTL`. **`task openbao:ssh:ca:role NAME=<role> ALLOWED=<patterns> [TTL=]
    [MAX_TTL=]`** makes or changes another role on the same mount, with the same defaults and
    refusals, for the Office's `register` (`writer@*`): ed25519 keys only, user certificates only, host
    certificates off, no extensions, no critical options. A principal outside the named role is refused,
    so relay and register certificates never stand in for each other.
  - **`task openbao:ssh:ca:import < <key>`** (optional): an existing ed25519 CA key from stdin only,
    for one CA across several instances; refused when the mount already has a CA.
  - **`dcf-ssh-sign`**, the caller's command, in the style of `dcf-secret`: `sign --principals
    <p1,p2,...> --key-id <id> [--ttl <dur>] [--role <name>]` (the public key on stdin, the one-line
    certificate on stdout), `ca` (the public key), `ca --fingerprint` (as `ssh-keygen -lf` prints
    it, for the Operators to compare out of band), `roles` (one per line) and `status` (one word).
    `dcf-secret`'s exit codes (0, 10 unreachable, 11 sealed, not initialised or no CA, 12 no token,
    13 the token may not sign or a principal is outside the role, 2 usage, 1 other) with one plain
    line on stderr; 3 when `sign` is run inside an agent's job. Only the Operator's policy may sign: the
    backs' AppRoles and an agent's token are refused with 13. No private key is taken or printed.
    No role admits the principal `operator` (`ca:init` and `ca:role` refuse such an `ALLOWED`, and
    `sign` refuses the principal under any role). Every role sets a key id format of the role name and
    the key's hash, so a call with no key id puts no token name in a certificate (a key id the caller
    passes must not carry a person's name). `sign` is refused inside an agent's job (exit 3); `ca`,
    `ca --fingerprint`, `roles` and `status` are public reads and are not.
  - Action: none unless you want the CA. To use it, rebuild, then run `task openbao:ssh:ca:init`
    (in server mode on a store made before 1.6.0 this also adds the sign path to the Operator's
    policy, which an existing store otherwise keeps unchanged). Compare the CA's fingerprint with the
    other side's out of band, never from a shared folder (see the NOTES, "SSH certificate authority").

### Changed

- The Operator's policy (`operator_policy`, written by `openbao:init`, the key file's `create` and
  `rotate`, and now `openbao:ssh:ca:init`) gains the paths of the SSH CA mount: sign, read the CA's
  public key, list and read roles; never write a role or the CA. `openbao-lib.sh` gains
  `agent_job` (the variable that makes a job an agent's, which `guard` uses) and `dur_secs`.

## [1.5.0] - 2026-11-05

### Added

- **The OpenBao key file: option `unlock: keyfile`** (server mode, opt-in; the default `operator` is unchanged, override `OPENBAO_SETUP_UNLOCK`). The workstation's launcher (Windows, `devcontainer-cli` 1.20.0) keeps a key file for the server and sends it at every `task dc:*`, so the server is unsealed and you are logged in with nothing typed. The store gets five unseal shares, threshold two: three custody shares you keep, two in the key file. You log in as the operator AppRole (a 1-hour periodic token, loopback only, renewed in the container while it runs); a key-file server has no password. The container side is `/usr/local/bin/openbao-setup unlock --status|--stdin`, `keyfile create|rotate --stdin` and `keyfile status` (one JSON line on stdout; secrets only on stdin, never in an argument, the environment, a file or a log; `BAO_ADDR`, `VAULT_ADDR` and `BAO_TOKEN` ignored; refused inside an agent's job), installed as `openbao-keyfile`. `create` and `rotate` are two steps: step 1 makes a root token from two shares with no login (so a lost key file is recoverable from two custody shares) and rotates to the new shares with OpenBao's verification, so they take effect only when `keyfile confirm --stdin` gives two of them back after the launcher saved the key file; `confirm` then destroys every earlier operator secret id, deletes the userpass user, revokes earlier logins (the backs' included), reissues every role, logs you in and ends with a backup. `keyfile cancel --stdin` drops an unconfirmed step (with an optional nonce, only that one); `keyfile status` says which rekey is `pending`. `unlock --status` reports `ready` only while the token renewer runs. Action: none unless you opt in; to opt in, set `unlock: keyfile`, rebuild, then run `task dc:openbao:keyfile:create` once on the workstation. Until agents run as their own Linux user, any agent in the container could harvest the key file's shares; rotate (`task dc:openbao:keyfile:rotate`) once they do (see the NOTES).
- `task openbao:server:status` says the unlock mode and, with `keyfile`, whether the token renewer runs.

### Changed

- With `unlock: keyfile`: `task openbao:password` and `task openbao:init` refuse (exit 3) and name the workstation's task; `task openbao:restore` and `task openbao:onboard:claim` ask for no password and end by naming `task dc:openbao:keyfile:rotate`; the login hints name `task dc:openbao:unlock`. No change with `unlock: operator`.
- The Operator's policy denies `auth/approle/role/operator` and everything under it (no Operator token can mint a secret id for the key file's login), may list userpass user names and may read whether a rekey waits for its verification. It is written by `task openbao:init` and by the key file's `create` and `rotate`; an existing store keeps its policy. No action needed.

## [1.4.0] - 2026-11-04

### Added

- **`task openbao:password`** (server mode): sets a new password for the Operator, for when you forgot it or want another. It needs no current password and no login: it asks for the new password twice (12 characters at least), then for two unseal shares at a hidden prompt, which make a root token used for this step alone and revoked straight after. The password never appears in an argument, file or output. Tokens you already hold stay valid until they expire (at most 8 hours); log in again with `task openbao:login -- -method=userpass username=operator`. Plain terminal only; refused inside an agent's job. It works with no login saved at all (see Changed). No action needed.

### Changed

- **Server mode: two unseal shares make a root token without a login.** The config `openbao-setup start` writes sets `disable_unauthed_generate_root_endpoints = false` on its one loopback listener, so OpenBao's unauthenticated `sys/generate-root` endpoints (off by default since 2.5.3) take the shares; the tasks call them with `curl`, since `bao operator generate-root` uses only the authenticated endpoints since OpenBao 2.6.0. `openbao:password`, `openbao:backup:role` and `openbao:restore` onto a store in use no longer need the Operator's login; `openbao:approle:issue` with `POLICY_PATH` and `openbao:approle:revoke` still do, for their other calls. Without a token, any process of the container can now start or cancel a root-token attempt (not complete one: that takes two shares). Action: none while your server's config still has its first line (the marker): it is rewritten at the next container start, which the rebuild for this version is. A config of your own (marker removed) needs `disable_unauthed_generate_root_endpoints = false` in its `listener "tcp"` block and a server restart; until then the tasks use the login as before.

## [1.3.1] - 2026-11-04

### Fixed

- **The unseal-share prompts now say what they want.** A password typed at "Unseal share 1 of 2 (hidden):" made bao answer "'key' must be a valid hex or base64 string". Every share prompt (`init`'s follow-ups, `unseal`, `restore`, the root-token step of `approle:issue` and `approle:revoke`, `backup:role`, and `onboard:claim`) now says it wants one of the three shares `task openbao:init` printed, a long base64 string, not your Operator password; and when bao refuses a share the message names both likely causes (a password typed instead of a share, a mistyped share). No action needed. The share is still read by bao itself at its hidden prompt and never passes through the script (bao's `operator unseal` does not read a key from stdin), so the script cannot check its shape first or ask for the same share again; run the task again.
- Hardening: the tasks that ask for a share, token or password switch bracketed paste off on the terminal first (`ESC[?2004l`, only to a terminal; the shell sets it again at its next prompt), also `task openbao:login`, so a paste in a shell that leaves the mode on (pwsh) cannot carry `ESC[200~ ... ESC[201~` into bao's hidden prompt. A terminal that ignores the switch can still add the markers.

## [1.3.0] - 2026-11-04

### Added

- **`task openbao:backup`** (server mode): a raft snapshot into `DEST=<folder>` (else the new `backupDest` option, else the folder recorded at `init`) as `openbao-<machine>-<UTC time>.snap`, **never over a file that exists**, from a private tmpfs folder that is removed on every way out; it prints the path and sha256, records them for `server:status`, and keeps only the newest `KEEP` (the `backupKeep` option, default 30; 0 keeps all) of **this machine's own** files in `DEST`. It logs in with a new **`backup` AppRole** that `init` makes (read on the snapshot path only, loopback only). Exit codes: 0 written, 10 unreachable, 11 sealed or not initialised, 12 cannot log in, 13 snapshot read denied, 20 `DEST` missing or not writable. **Backups are optional and off by default.** The unseal shares never go with a snapshot. `task openbao:backup:role` makes the role on a server initialised before 1.3.0.
- **`task openbao:restore FROM=<file>`**: installs a snapshot. On an empty server it initialises with one throwaway share and installs the snapshot over it; on a store in use it asks you to type `restore` and uses a root token made from two of the current shares (used once, revoked). The restored store is sealed under the shares it came from: you enter two of them, then your password logs you in, and every AppRole gets a new secret id. Safe to run twice; a half-done restore starts again from empty. Warns when the file is from another machine; a file named `onboarding-...` (from `openbao:onboard:export`) is said to be an onboarding snapshot, is left unsealed under its shares and is finished by `openbao:onboard:claim`. Refuses inside an agent's job and without a terminal.
- Options `backupDest`, `backupKeep`, `backupInterval` (a timer in the container the start hook starts: `5m`, `6h`, `1d`; empty = off) and `backupWarnAfter` (default `7d`), each with an `OPENBAO_SETUP_BACKUP_*` twin. OpenBao has no scheduled snapshots of its own and its snapshot agent needs systemd or cron and names and prunes files differently, so the timer is the Feature's own; the NOTES give the Windows Task Scheduler line for a host-side schedule.
- `task openbao:server:status` shows the last backup's age, place and sha256, and warns past `backupWarnAfter`, with no backup taken yet, or with the explicit "no backup". `openbao-server after-write` is what a task that writes a secret ends with (the backup when a destination is set, else a "not backed up since" reminder); it always exits 0, so the write stands whatever the backup does. The `openbao:ssh:*` write tasks, `openbao:onboard:claim` and `dcf-secret put` (server mode) end with it.
- **Onboarding by a starter instance:** `task openbao:onboard:export NAMES=<name>,... DEST=<folder>` (the sender, in a plain terminal) starts a short-lived second server in the container (its own raft folder and port 8210), copies the named secrets into it from your own store (every field), writes the onboarding marker, takes a raft snapshot into `DEST` (`onboarding-<machine>-<time>.snap`, mode 600, never overwritten), stops the instance and deletes it, and prints its fresh unseal shares and a claim token once, to the terminal. Your own store is never snapshotted and your own shares are not involved. After `openbao:restore`, `task openbao:onboard:claim` (the receiver) rotates the unseal shares with `bao operator rotate-keys` (new shares, committed only when two are typed back), revokes everything the sender held (every token, user and extra auth method; every AppRole role rebuilt so every secret id is gone), sets up the receiver's own Operator, reissues the secret ids, rotates the data key (`ROTATE=0` skips it), revokes the claim token, replaces the marker and lists the names that came as the sender's knowledge. It resumes after a failure.
- **Response wrapping for a few keys:** `task openbao:wrap NAMES=<name>,... [TTL=15m]` makes one one-use wrapping token per secret (default TTL 15 minutes, capped at 1 hour) into a mode 600 file on tmpfs; `task openbao:unwrap FROM=<file> [ISSUER_ADDR=<server>]` looks every token up first and refuses, unwrapping nothing, unless each was made by a read of its own secret's path and has not run out, then unwraps each once into your own store. Works against a central server in client mode. The onboarding tasks refuse inside an agent's job; the claim token, the shares and the wrapping tokens are never an argument and are printed only to a terminal.
- **SSH key records in OpenBao**: `task openbao:ssh:new` makes an ed25519 key at `dcf/ssh/<name>` (the fields `private_key`, `public_key`, `purpose`, and its creation date in the metadata), generated on tmpfs and removed at once, with no passphrase: the unseal and your login are the gate. `task openbao:ssh:put NAME=` stores a key you pipe in, `task openbao:ssh:retire NAME=` destroys a record's private key and keeps its public key and dates (`-- --plan` shows the steps), `task openbao:ssh:age` lists each record with its age. A record is never overwritten and a name never reused. Nothing to do unless you want them; ssh-agent 1.4.0's `key:load NAME=ssh/<key>` reads them.
- **`task openbao:ssh:import`**: `FROM=ssh-agent` moves every key of the ssh-agent Feature's key volume into OpenBao (the creation dates from the volume, the fingerprints compared, a passphrase asked once at ssh-keygen's prompt), writes the volume's `allowed_signers.history` and a line per key (principal the key's name, no valid-after) into `.devcontainer/allowed_signers` for the host to commit, proves one key through ssh-agent, and only then asks, per key, whether to delete the volume's copy. `FROM=file FILE=<path>` (or the key on stdin with `NAME=`, which the workstation's `task devcontainer:openbao-ssh-import` streams in) and `FROM=agentic-register` (the register's `keys/<principal>` as `register/<principal>`) do the same for one key or the register's. It can run again: what is there is skipped. **If you use ssh-agent's key mode, run `task openbao:ssh:import FROM=ssh-agent` once** (server mode unsealed, logged in); the key volume goes with ssh-agent 2.0.
- `dcf-secret ttl` prints the seconds the token has left (0: it does not expire), so a caller lives no longer than the login.

### Changed

- **Your login can only reissue secret ids.** Its policy covers listing roles, reading a role-id, listing and destroying secret-id accessors, making a secret id, and starting or cancelling a root-token generation; it cannot write a policy or a role. **Making a role (`openbao:approle:issue ROLE= POLICY_PATH=`) and deleting one (`openbao:approle:revoke`) ask for two unseal shares** (a root token from `bao operator generate-root`, used for that step only and revoked on every way out, also on failure); both refuse inside an agent's job and without a terminal. Reissuing (`ROLE=<name>` alone, `ALL=1`) still asks for nothing.
- Restore on a store in use and the backup role make their root token the same way.
- `jq` is installed at build time (the onboarding scripts read `bao`'s JSON with it). Rebuild the devcontainer to get the new tasks.
- **Action if you initialised a server with an unreleased 1.2.0 build:** it lacks the `backup` role and the two paths that let your login start a root token generation. Run `task openbao:backup:role` once (it asks for two unseal shares); until then `openbao:backup` uses your login, with a line saying so, and `openbao:restore` on a store in use stops before any share is typed. Servers initialised by the released 1.2.0 or by this version need nothing.

## [1.2.0] - 2026-11-03

### Added

- **Server mode: a local OpenBao server in the container.** Set the `mode` option to `server` (or `OPENBAO_SETUP_MODE=server` in `containerEnv`, no rebuild; needs OpenBao 2.4.0 or newer, and an older pinned `version` fails the build with that said). The post-start hook starts one server with raft storage on the Feature's volume and a loopback-only listener (`127.0.0.1:8200`, no TLS), and it comes up **sealed**: nothing can read a secret until you unseal it. The hook never waits and never prompts; it prints whether the server is not initialised, sealed or unsealed. `mode: client` stays the default and behaves as before. **You must act once, in a plain terminal in the container:** `task openbao:init`, then after every container restart `task openbao:unseal`.
- `task openbao:init`: asks for a **backup destination or the words `no backup`** (never defaulted, and the answer is recorded in the volume), asks for the Operator's password, makes **3 unseal shares with a threshold of 2** and prints them once, only to the terminal (keep one in a password manager, one on paper offline, one with a second person or on a hardware key; losing two loses every secret), has you enter two of them to prove you stored them, sets up the `dcf` KV mount, `userpass` and `approle`, and revokes the root token. `-pgp-keys=...` after `--` encrypts the shares.
- `task openbao:unseal` and `task openbao:seal`. `task openbao:server:status` shows the state, the storage, the audit log, whether your login is valid and the backup choice, with a standing warning while there is none. Your login is `task openbao:login -- -method=userpass username=operator`: it lasts **4 hours, at most 8**, and a renewal past that is refused.
- `task openbao:approle:issue ROLE=<name> POLICY_PATH=<mount/path>` makes a role for a machine identity (for the devhost's backs, later) that may read that one secret, only from inside the container (loopback-bound secret ids and tokens), with 5 minute tokens; `ROLE=<name>` alone or `ALL=1` reissues, leaving exactly one valid secret id per role, written to the volume and never printed. `task openbao:approle:revoke ROLE=<name>` removes a role. **Making a role and deleting one ask for two unseal shares** (typed at a hidden prompt, they make a root token, `bao operator generate-root`, used for that step only and revoked straight after, also on failure); reissuing (`ROLE=<name>` alone, `ALL=1`) uses your login and asks for none. Your login's policy cannot write a policy or make, change or delete a role, so a token of yours can never give a role `snapshot-force`.
- A file audit device in the volume (`audit.log`), declared in the server's config.
- **Not included yet:** `openbao:backup` and restore. A backup destination is recorded but not used, so until a later version a lost machine loses what is in the server's volume (this is why `init` asks and `server:status` warns); take a snapshot by hand with `bao operator raft snapshot save`.

### Changed

- **`init`, `unseal`, `seal` and the two steps that ask for shares (making and deleting a role) refuse inside an agent's job** (when `DEVHOST_JOB_CHILD` or `CLAUDECODE` is set, or a variable you name in `OPENBAO_AGENT_JOB_VARS`), and `init`, `unseal` and those two steps refuse without a terminal: the shares and the token must never land in a transcript. Run them yourself in a plain terminal.
- `dcf-secret`'s failure lines now name the tasks: sealed points to `task openbao:unseal`, not initialised to `task openbao:init`, unreachable to `task openbao:server:status`, each adding what to do against a server elsewhere. The exit codes are unchanged.
- In server mode `BAO_ADDR` defaults to the local server for `dcf-secret` and every task when you have not set it (a bare `bao` still needs `BAO_ADDR`). The tasks `status`, `login`, `logout`, `kv:get` and `setup` run the same `bao` call through `openbao-run`, which adds only that default; client mode is unchanged. `task openbao:setup` now also runs the start hook.

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
