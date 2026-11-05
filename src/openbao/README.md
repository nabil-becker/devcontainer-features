
# OpenBao CLI (openbao)

Installs the OpenBao CLI (https://openbao.org), the open-source Vault fork, as a release binary at /usr/local/bin/bao, verified against the release's checksums.txt. Owns the login state as a named volume at OPENBAO_STATE_DIR=/var/lib/devcontainer-features/openbao (bao's token helper, set through BAO_CONFIG_PATH, keeps the token in it) so `bao login` survives rebuilds, with the post-create hook openbao-setup, and installs dcf-secret, the one command the collection's Features use to read and write secrets (get, put, status, with fixed exit codes). Mode client (the default) is the CLI against a server of yours (set BAO_ADDR in containerEnv). Mode server also runs a server inside the container, started at post-start with raft storage on the same volume and sealed until the Operator unseals it: tasks openbao:init (unseal shares printed only to a terminal, a backup choice asked for), openbao:unseal, openbao:seal, userpass login for the Operator, loopback-bound AppRole roles (openbao:approle:issue) and openbao:server:status. Backup and restore (openbao:backup to a folder you name, on a timer if you set one, and openbao:restore from a snapshot). SSH key records in OpenBao (openbao:ssh:new, put, retire, age) and the import of keys kept elsewhere (openbao:ssh:import FROM=file, ssh-agent or agentic-register), which ssh-agent's key:load and key:rotate use. Onboarding: openbao:onboard:export and :onboard:claim (a starter instance restored, then rotate-keys and every access the sender held revoked) and openbao:wrap and :unwrap (one-use response-wrapping tokens for a few keys against a central server). Option unlock: keyfile opens a server-mode store with the OpenBao key file the Windows launcher keeps (no typed share or password; opt-in).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| mode | How the Feature is used. 'client' (default): the bao CLI and dcf-secret against a server outside the container (BAO_ADDR). 'server': also run a server in the container (raft storage on the Feature's volume, loopback only, started at post-start, sealed until `task openbao:unseal`; needs OpenBao 2.4.0 or newer). Override per container with OPENBAO_SETUP_MODE in containerEnv. | string | client |
| unlock | Server mode: how the store is opened. 'operator' (default): the Operator types two unseal shares after every server start (task openbao:unseal) and logs in with a password. 'keyfile': the OpenBao key file on the workstation (Windows launcher, task dc:openbao:keyfile:create once) unseals the server and logs the Operator in at every task dc:* with nothing typed: 5 unseal shares (3 custody shares kept by the Operator, 2 in the key file), an operator AppRole with a 1-hour periodic token renewed in the container, no password. Override per container with OPENBAO_SETUP_UNLOCK in containerEnv. | string | operator |
| backupDest | Server mode: the folder (an absolute path inside the container, e.g. a bind-mounted cloud folder or a USB disk) that `task openbao:backup` and the backup timer write to when no DEST is given. Empty (the default): no default destination, so nothing is backed up unless you run `task openbao:backup DEST=<folder>`; `task openbao:init` also records a destination. Override per container with OPENBAO_SETUP_BACKUP_DEST. | string | - |
| backupKeep | Server mode: how many backups of this machine to keep in the destination (the newest N); older ones named openbao-<machine>-<UTC time>.snap are removed after each backup, nothing else ever is. 0 keeps every backup. Every backup holds every secret (encrypted; the unseal shares open it), so they should not pile up. Override with OPENBAO_SETUP_BACKUP_KEEP. | string | 30 |
| backupInterval | Server mode: run a backup into the default destination every so often (5m, 6h, 1d; at least 5 minutes) from a timer the start hook starts inside the container. Empty (the default): off; backups are then yours to run, or to schedule from the host with its own scheduler (see the NOTES). A sealed server is skipped until the next tick. Override with OPENBAO_SETUP_BACKUP_INTERVAL. | string | - |
| backupWarnAfter | Server mode: `task openbao:server:status` warns when the last backup is older than this (30m, 12h, 7d). Override with OPENBAO_SETUP_BACKUP_WARN_AFTER. | string | 7d |
| version | OpenBao release to install (e.g. '2.7.1', with or without a leading 'v'), or 'latest'. Match your OpenBao server's version. | string | latest |

## How it fits

```text
  go-task registry --> openbao:* tasks
  bao CLI --BAO_ADDR (set in containerEnv)--> OpenBao server      dcf-secret --> bao
    |
    `--> token helper --> volume openbao-config-<id>/token  (or BAO_TOKEN from the environment)

  mode server: post-start --> bao server (127.0.0.1:8200, raft) --> volume openbao-config-<id>/
                              sealed until task openbao:unseal       raft/, audit.log, approle/
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Login token | `token` in the Feature's volume `openbao-config-${devcontainerId}`, kept by a token helper (`BAO_CONFIG_PATH`), so a rebuild keeps the login; or `BAO_TOKEN` in the environment | 4 working set |
| Server storage (mode server) | `raft/` in the same volume: every secret, policy and role of the local server | 4 working set, with ADR 0048's bounded-loss exception: not rebuildable, so a lost machine loses what came after the last backup (backups arrive in 1.3.0; until then a snapshot by hand) |
| Audit log (mode server) | `audit.log` in the same volume | 4 working set |
| AppRole secret ids (mode server) | `approle/<role>/` in the same volume, mode 600 | 4 working set (reissued with `task openbao:approle:issue ALL=1`) |
| Unseal shares | never in the container: printed once by `task openbao:init` | custody, outside the tiers (ADR 0049) |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [secrets-with-openbao](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/secrets-with-openbao.md)

## What it installs

The `bao` release binary from `github.com/openbao/openbao`, at
`/usr/local/bin/bao`. `install.sh` downloads
`openbao_<version>_linux_<arch>.tar.gz` and the release's `checksums.txt`,
checks the tarball with `sha256sum -c`, and installs the binary only if the
check passes. It runs `bao version` at the end, so the version is in the
build log. It installs no OpenBao server and no `vault` command.

Besides the binary, `install.sh` puts four scripts on PATH (nothing is downloaded for them):
`dcf-secret` (the interface callers use to read and write secrets, see below), `openbao-setup`
(the post-create hook, see State) and `dcf-persist` (a verbatim copy of `src/common/dcf-persist.sh`,
which makes the state directory usable and says what backs it). It writes the option defaults the
hook reads to `/usr/local/share/openbao-feature/options.env`.

- `version` takes a number with or without a leading `v` (`2.7.1`,
  `v2.7.1`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it to your server's
  version.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` fails the build.

## Options

- `version` (default `latest`): set it to the version of the OpenBao server
  you talk to, so the CLI and the server agree. A value that does not start
  with an `x.y.z` number fails the build.
- `mode` (`client`, the default, or `server`): `client` is the CLI and `dcf-secret` against a
  server outside the container, whose address is `BAO_ADDR`; a consumer that changes nothing keeps
  it. `server` also runs a server in the container (see "Server mode"); it needs OpenBao 2.4.0 or
  newer, and a build with an older pinned `version` fails with that said. Any other value fails the
  build. Override per container with `OPENBAO_SETUP_MODE` in `containerEnv` (the hooks read it, no
  rebuild; an unknown value is reported and the hooks run as `client`). A container built as `client`
  and switched to `server` this way works, because the binary is the same; only the build-time
  version check is skipped.
- `unlock` (`operator`, the default, or `keyfile`): how a server-mode store is opened. `operator`
  is the typed way (two unseal shares after every start, a password per sitting); `keyfile` is the
  OpenBao key file the Windows launcher keeps (see "The OpenBao key file"). Any other value fails
  the build. Override per container with `OPENBAO_SETUP_UNLOCK` in `containerEnv` (an unknown value
  reads as `operator`). Client mode ignores it.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/openbao.yml` in the image.

- `backupDest` (default empty), `backupKeep` (default `30`), `backupInterval` (default empty: off),
  `backupWarnAfter` (default `7d`): server mode's backups, see "Backup and restore". Each has the
  run-time twin `OPENBAO_SETUP_BACKUP_DEST`, `_KEEP`, `_INTERVAL`, `_WARN_AFTER` in `containerEnv`.
  A malformed value fails the build.

`version` and `installTaskfile` are fixed at build. `mode` has the run-time twin
`OPENBAO_SETUP_MODE`, `unlock` the twin `OPENBAO_SETUP_UNLOCK`. The server address is a run-time setting: see State. In server mode it
defaults to the local server.

## State

Owned by the Feature (NFR-1), like `gh` and `az`:

- `containerEnv` sets `OPENBAO_STATE_DIR=/var/lib/devcontainer-features/openbao`.
- `mounts` declares the named volume `openbao-config-${devcontainerId}` on that path. The name
  follows the repository's convention (`<id>-config-${devcontainerId}`, as `gh-config-` and
  `az-config-`) and supersedes `openbao-${devcontainerId}`, which the proposal
  `docs/proposals/secrets-master-split.md` (section 3) wrote before it checked the convention.
- `containerEnv` also sets `BAO_CONFIG_PATH=/usr/local/share/openbao-feature/bao-config.hcl`, a
  config whose one line, `token_helper = "/usr/local/bin/openbao-token-helper"`, makes `bao` keep
  its login token in the volume, at `$OPENBAO_STATE_DIR/token` (mode 600). Because it is
  `containerEnv`, it holds for every process, `devcontainer exec` and agents' shells included.
  **A rebuild keeps the login.**
- The post-create hook `openbao-setup` (also `task openbao:setup`) runs `dcf-persist`, so the
  folder belongs to the remote user and the log says what backs it, and says whether the token
  helper is in effect. A token already in `~/.vault-token` (a login from before this Feature) is
  moved into the volume once, when the volume has none. The post-create hook never contacts the server and
  never fails the rest of post-create.

How `bao` finds the helper, confirmed in OpenBao's source (`internal/command/config` and
`internal/command/token`, v2.1.1 and v2.7.1): the CLI reads an HCL config at `~/.bao`, or at the
path in `BAO_CONFIG_PATH`, and a `token_helper` in it names an absolute path to an executable
that `bao` runs as `<helper> get`, `store` (token on stdin) or `erase`. Without one, `bao` uses
its internal helper, which writes `~/.vault-token` through a temporary file and a rename: a link
to the volume at that path is replaced by the first `bao login`, which is why the Feature does
not use one. The helper is a few lines of `sh` (`openbao-token-helper`) and the token is written
atomically.

- **The server address** is `BAO_ADDR`, which the Feature does not set in `containerEnv`: its
  metadata is static, so an option cannot change it, and client mode keeps the CLI's own default.
  Put it in `containerEnv`. In server mode, when it is unset, `dcf-secret`, `openbao-setup` and
  every task of this Feature use `http://127.0.0.1:8200` (the local server); a bare `bao` does not,
  so give it `BAO_ADDR` (export it, or put it in `containerEnv`) or go through the tasks.
- **A repo that sets its own `BAO_CONFIG_PATH`** (or whose `containerEnv` leaves this one out)
  replaces the Feature's config; the hook says so. Add `token_helper =
  "/usr/local/bin/openbao-token-helper"` to that config to keep the login in the volume. A repo
  that wants the state on the host disk bind-mounts the volume's target (the README's "How the
  pieces fit"), or points `OPENBAO_STATE_DIR` elsewhere in its own `containerEnv`.
- **Log out with `task openbao:logout`**: it runs `bao token revoke -self` (ignored when the token
  is already dead) and then the helper's `erase`, so no token is left in the volume. `bao token
  revoke -self` alone only revokes the token on the server (OpenBao's `token_revoke` command calls
  the API and never the helper; there is no `bao logout`), so the dead token stays stored and
  `dcf-secret` answers exit 12 until you `task openbao:login` again.
- **`BAO_TOKEN`** in the environment takes precedence over the saved login (the hook says so). It
  is a way to give a container a token without a login, for a service that cannot run `bao login`:
  set it in `containerEnv` from a host variable (`"BAO_TOKEN": "${localEnv:BAO_TOKEN}"`) or an env
  file the repo keeps out of git. A stale value there makes `permission denied` appear even right
  after a fresh `bao login`; unset it or update it. Never commit it.
- OpenBao 2.6.0 and later also read `BAO_TOKEN_PATH` (the internal helper's file, still written by
  a rename); the Feature uses the token helper because it works for every version `version` can pin.

Upgrading from 1.0.x: the volume starts empty, so log in once after the rebuild; a login made
before it, in `~/.vault-token` of the old container, is gone with that container.

## Server mode

`mode: server` runs an OpenBao server inside the container: one node, **raft** storage on the
Feature's volume, one listener on `127.0.0.1:8200` with no TLS (it never leaves the container's
loopback; another container cannot reach it), started at post-start and **sealed until the Operator
unseals it**. Client mode stays the default and is unchanged. Why a local server and what a machine
loss costs: ADR 0048 and the "Backup" paragraph below.

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/openbao:1": { "mode": "server", "version": "2.7.1" },
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {}
}
```

**The start hook** (`postStartCommand`, `openbao-setup start`, also run by `task openbao:setup`)
writes the server's config into the volume, starts `bao server` in the background (its pid in
`server.pid`, its log in `server.log`; a live server is reused), waits only for the listener to
answer (at most 20 seconds), and prints one line: `not initialised; the Operator runs task
openbao:init`, `sealed; the Operator runs task openbao:unseal`, or `running and unsealed`. It never
waits for an unseal and never prompts (a start hook that waits holds every Feature's start), and it
never fails the start. The config is `server.hcl` in the volume; while its first line is the
Feature's marker it is rewritten on every start, so an upgrade reaches it; delete the marker line to
keep your own edits. It holds: `storage "raft"` at `raft/` with `node_id = "devhost"`, one `tcp`
listener on `127.0.0.1:8200` with `tls_disable`, `api_addr` and `cluster_addr` on loopback (raft
requires `cluster_addr`), no UI, and the file **audit device** `audit.log`, declared in the config
(OpenBao 2.4.0 and later: a server refuses an audit device made through the API unless
`unsafe_allow_api_audit_creation` is set, and the declarative stanza is the supported way). The log
of every request, with secrets hashed, names each identity that read a key.

**The gate.** Two steps, both the Operator's:

```text
 container start       task openbao:unseal            task openbao:login -- -method=userpass username=operator
      |                (2 of the 3 shares)             (per sitting)
      v                        |                                 |
  [ sealed ] ----------------> [ unsealed ] ------------> [ the Operator's token: 4 hours, at most 8 ]
   dcf-secret: exit 11         AppRoles can log in            dcf-secret reads and writes (exit 12 when it ends)
```

- **`task openbao:init`** (once). Interactive, in a plain terminal only. It asks for a **backup
  destination** (an absolute folder path that exists and is writable, or the words `no backup`; an
  empty answer is asked again: the choice is never defaulted) and for the **Operator's password**
  (twice, 12 characters at least); initialises with **3 unseal shares and a threshold of 2**; prints
  the shares to the terminal, once, and says to keep one in a password manager, one on paper
  offline and one with a second trusted person or on a hardware key, never in git, the container or
  where backups go; waits for Enter and then asks for two of them at `bao`'s own hidden prompt (so
  the unseal proves they were stored correctly); enables the `dcf` KV v2 mount, `userpass` and
  `approle`, writes the Operator's policy and the user `operator`; records the backup choice; and
  **revokes the root token**. The root token and the shares live in the task's memory only, never
  in a file or an argument. `-pgp-keys=...` after `--` encrypts the shares to your keys (you decrypt
  them yourself before the unseal step; not covered by a test). A failed configuration step revokes
  the root token as well and says how to start over: the store holds nothing yet, so stop the
  server, delete `raft/` in the volume and run the start hook and `init` again (new shares). Run
  twice it refuses: the server is initialised.
- **`task openbao:unseal`**: asks for shares at `bao`'s hidden prompt until the server is unsealed
  (needed after every server start, so after a container restart). `task openbao:seal` seals it
  with the saved login (`bao operator seal`; the Operator's policy has `update` and `sudo` on
  `sys/seal`).
- **`task openbao:password`**: a new password for the Operator, for one who forgot it (or wants
  another). It needs no current password and no login: two unseal shares are the authority. It
  asks for the new password twice (12 characters at least, as `init` does), then for two shares at
  a hidden prompt, makes a root token from them for this step alone, writes the password with
  `bao write auth/userpass/users/operator/password password=-` (on stdin, never an argument) and
  revokes the token, also when the step fails. It checks first, with that token, that the userpass
  login and the user `operator` exist (an onboarding claim not done yet has neither) and changes
  nothing when they do not. Tokens the Operator already holds stay valid until they expire (at most
  8 hours); log in again with the new password. Plain terminal only; refused inside an agent's job.
  It works with **no login saved at all** (the lock-out case: the shares unseal the server, but
  nothing can log in): the root token comes from the listener's unauthenticated root-token
  endpoints (below).
- **The root token from the shares, without a login.** OpenBao 2.6.0 made `bao operator
  generate-root` call the authenticated `sys/generate-root-token` endpoints and turned the old
  unauthenticated `sys/generate-root` ones off by default (the listener option
  `disable_unauthed_generate_root_endpoints`, true since 2.5.3). The config `openbao-setup start`
  writes sets it to **false on the one loopback listener**, so two shares alone make a root token.
  `bao`'s CLI cannot reach those endpoints, so the tasks call them with `curl`: the attempt is
  started and the server hands back its one-time password; each share is typed at a hidden prompt
  and sent on `curl`'s stdin with the attempt's nonce (a share never feeds an attempt someone else
  started, and an attempt already in progress is refused, not taken over); the encoded token is
  decoded in memory with the one-time password (an XOR: `bao`'s own `-decode` asks the
  authenticated status first). No share, one-time password or token is in an argument, a file or the
  output. **What an unauthenticated caller can do** on that listener (any process of the container):
  read an attempt's status (its nonce and progress, never the encoded token), start an attempt and
  cancel any attempt, a nuisance and not a breach: completing one takes two shares, and the token it
  makes is useless without the one-time password of whoever started it. The legacy rekey endpoints
  stay off. **A server picks the setting up when it starts**: a config that still carries the
  marker line is rewritten on every container start (a Feature upgrade is a rebuild, so it starts
  with the new config); a reload (SIGHUP) does not change it. A config without the marker line is
  the repo's own: add `disable_unauthed_generate_root_endpoints = false` to its listener block and
  restart the server, or the tasks fall back to the CLI's authenticated flow, which needs the
  Operator's login (the policy's two `sys/generate-root-token` paths, ADR 0051) and says so when there
  is none.
- **The login**: `userpass`, user `operator`, token `ttl` **4 hours**, `max_ttl` **8 hours**; a
  renewal past 8 hours is capped (`bao token renew` says so). `task openbao:logout` ends it early. A
  night shift that must sign overnight starts with a login made for it. These lifetimes are set on
  the server this Feature runs; against another server they are its owner's.
- **The Operator's policy**: read and write everything under the `dcf` mount, the snapshot read
  (`sys/storage/raft/snapshot`), `update` and `sudo` on
  `sys/seal`, and the **reissue of secret ids for roles that already exist** (list the roles, read a
  role's role id, list a role's secret-id accessors, destroy a secret id by accessor, make a new one).
  It may also start and cancel a root-token generation (`sys/generate-root-token/*`), which only the
  shares can complete. **Not** any policy (`sys/policies/acl/*`), not making, changing or deleting a
  role, not `snapshot-force`, audit devices, or any other `sys/` path: a token that could write a
  policy could write one with `snapshot-force` and log in through a role holding it, which would
  sidestep the rule that restore needs the shares. Making and deleting a role therefore take a root
  token made from the shares, for that step only (below).

**Agents.** `init`, `unseal`, `seal`, `restore`, `password` and the steps that ask for the shares (making a role, deleting a role, `backup:role`) **refuse inside an agent's job**: when `DEVHOST_JOB_CHILD`
(the devhost's backs and its test run) or `CLAUDECODE` (set by Claude Code on every process it
starts) is set, or a variable named in `OPENBAO_AGENT_JOB_VARS` (space separated, for another agent
CLI), each saying why and exiting 3: the shares and the token must never land in a transcript, which
the scribe reads. `init`, `unseal`, `password` and those two steps also refuse without a terminal on stdin and stdout (they ask
for secrets and print them only to a terminal), and all server-mode tasks refuse in client mode.
Run them yourself in a plain terminal in the devcontainer (a terminal opened from inside a Claude
Code session inherits `CLAUDECODE` and is refused too: open a fresh one). A refusal is no call to `bao`.

**AppRole** (`task openbao:approle:issue`, `:revoke`; server mode). One role per machine identity,
generic: the Feature never calls a task of another Feature. `ROLE=<name> POLICY_PATH=<mount/path>`
**asks for the unseal shares** (it writes a policy): it makes a root token with `bao operator
generate-root`'s unauthenticated endpoints (above: a one-time password held in a variable, two
shares typed at a hidden prompt, the token decoded in memory), runs that step with it, and revokes it
straight after, also when the step fails or is interrupted (an abandoned generation is cancelled). No
share, password or token is printed, logged, put in a file or passed as an argument (the CLI
fallback for a listener without those endpoints passes the one-time password, which is useless
without the encoded token, which goes over stdin). Issuing and revoking a role still need the
Operator's login for their other calls (the new role's secret id is made, and a role's existence
checked, with the login), so they check it before asking for a share. It makes the role (lower case name) with a policy `approle-<name>` that lets it read that one secret
and nothing else, **bound to loopback**: `secret_id_bound_cidrs` and `token_bound_cidrs` of
`127.0.0.1/32`, so a stolen secret id or token works only from inside this container, and only while
the server is unsealed; tokens last 5 minutes, at most 15; secret ids do not expire (an expiring one
would stop the backs on a date nobody is watching). `ROLE=<name>` alone reissues an existing role,
and `ALL=1` every role in the store (after a restore or on suspicion); both use the Operator's login
only and ask for no share. A reissue leaves **exactly one
valid secret id**: the others of the role are destroyed by their accessors first (issuing a new one
does not end the old). The secret id and the role id are written to `approle/<role>/secret_id` and
`role_id` in the volume (mode 600, folder 700), never printed. `approle:revoke ROLE=<name>` deletes
the role (OpenBao's role deletion destroys its secret ids) and its policy with a root token from the
shares, as above, and then its files; a token it
already made lives at most 15 minutes. There is no `DCF_SECRET_AS` yet: nothing logs in as a role in
this version except by hand (the devhost's backs log in through the key fetch of the devhost Feature).

**`task openbao:server:status`** (both modes; exit 0 unsealed, 10 unreachable, 11 sealed or not
initialised): the mode, the address, the server's state, and in server mode the process, the
storage, the audit log, the backup choice and whether the login is valid.

**Backup, and ADR 0045.** The live store stays in the volume (tier 4): raft's database is written in
place and under a lock, which no `cloud-folder` mode promises a database. So a lost machine loses
what was written since the last backup, a **bounded-loss exception to ADR 0045 for server mode**
(ADR 0048); it is a choice, never a silent default: `init` asks, records the answer in the volume
(`backup-choice`), and `server:status` shows the last backup, or a standing `WARNING`. Backups are
**optional and off by default**: nothing runs unless you run it or turn the timer on. See "Backup and
restore" below. The unseal shares, the other thing a machine loss must not take, are kept off the
machine by `init`'s instructions. A snapshot is ciphertext, useless without the shares and everything
with them.

## The OpenBao key file (`unlock: keyfile`)

`unlock: keyfile` (server mode, opt-in; `operator` stays the default) opens the store with **the
OpenBao key file**: a file the workstation's launcher (`devcontainer-cli`, Windows only for now)
keeps for this server and sends at every `task dc:*`, so the server is unsealed and the Operator
logged in with nothing typed. The design is `docs/proposals/openbao-key-file.md` (design B, with
its architecture review); the record is the ADR on the key file.

```text
 workstation (Windows, the Operator's account)             container (remote user, loopback only)
 --------------------------------------------              --------------------------------------
 task dc:up / dc:claude / dc:shell / rebuild               postStart: openbao-setup start
   | engine exec /usr/local/bin/openbao-setup -----------> bao server starts SEALED (never waits)
   |   unlock --status                         <---------- {"mode":"keyfile","ready":false,...}
   | the key file, DPAPI, opened in memory only
   | engine exec -i ... unlock --stdin  ------------------> PUT sys/unseal x2 (shares 4 and 5)
   |   stdin <- the key file's JSON                        AppRole login as operator
   |   (never an argument, env, temp file, log)            previous token revoked with itself
   |                                                       token -> the token helper's file
   |                                            <--------- renewer started (detached)
   v                                                       {"v":1,"ok":true,...}
```

**Five shares, two in the key file.** The store has 5 unseal shares and a threshold of 2. Shares 1
to 3 are the **custody shares**: printed once on the workstation by `keyfile:create` and `:rotate`,
kept by the Operator in the three places `openbao:init` names; any two of them open the store and
make a new key file when it is lost. Shares 4 and 5 are in the key file. A key-file server has **no
password**: its userpass user `operator` is deleted, and the Operator logs in with the **operator
AppRole**, whose role id and secret id are in the key file too.

**The Operator's login.** The operator AppRole gives a **periodic token, period 1 hour, no
maximum**, bound to `127.0.0.1/32` (as its secret ids), and the container's **renewer** renews it
every 20 minutes (a third of the period) while the container runs. A sitting is then the life of
the container's login, from the unlock to the container's stop or `task openbao:logout`. The
renewer stops on the first renewal the server refuses (the token expired or was revoked), when the
token is erased (`openbao:logout`), and with the container; the token then dies within the hour,
and the next `task dc:*` (or `task dc:openbao:unlock`, nothing typed) makes a new one. After a
long suspend (a laptop asleep with the container up) the token may have expired: the renewer
stops, `unlock --status` says `"token":"dead"`, and the next `task dc:*` logs in again. The
Operator's policy denies `auth/approle/role/operator` and everything under it: no Operator token can
mint a secret id of its own role (one that would outlive every rotation); only a root token made
from the shares does, at create and rotate. It also lists userpass users (names only), for
`keyfile status`.

**The renewer, and why not `bao agent`** (review finding 7, NFR-13). OpenBao Agent's AppRole
auto-auth was checked first, against bao 2.7.2: it reads the secret id from a file (removed after
reading), keeps it in memory for good, renews the token and, when the token is gone (it was
suspended past the period), **logs in again with the cached secret id**. That is a permanent
Operator credential held by a process of the container for its whole life, which design B rejects
(the secret id is kept only in the key file), and it needs the secret id written to a file first.
So the Feature runs its own renewer (`openbao-setup renew`, about 40 lines): it renews the one token
in the token helper's file and stops.

**The container side** is `/usr/local/bin/openbao-setup` (the launcher always calls this absolute
path; it hands over to `openbao-keyfile`). Secrets come only on stdin; stdout is one JSON object on
one line; human lines go to stderr. No share, secret id or token is put in an argument, the
environment, a file other than the token helper's, or a log: every request is made with `curl`, the
token in a curl config read from a pipe and the body on curl's stdin (the `bao` CLI takes a token
only from the environment, a flag or its helper). Only the loopback listener in `server.hcl` is
spoken to; `BAO_ADDR`, `VAULT_ADDR` and `BAO_TOKEN` in the environment are ignored (review finding
3), and `curl -q` keeps a `~/.curlrc` out.

| Command | stdin | stdout |
|---|---|---|
| `unlock --status` | nothing | `{"v":1,"mode":"off"\|"operator"\|"keyfile","initialized":bool,"sealed":bool,"token":"live"\|"missing"\|"dead","renewer":bool,"ready":bool,"server":"<cluster id>"}` |
| `unlock --stdin` | the key file | `{"v":1,"ok":true,"done":"unsealed, logged in"}` |
| `keyfile create --stdin` (step 1) | `{"v":1,"shares":["<custody>","<custody>"],"repo":"<name>"}`, or `{"v":1,"init":true,"repo":"<name>"}` on an empty server | `{"v":1,"ok":true,"pending":true,"server":"<id>","nonce":"<nonce>","custody":[three],"keyfile":{...},"warnings":[...]}` |
| `keyfile rotate --stdin` (step 1) | `{"v":1,"shares":["<any two of the five>"],"repo":"<name>"}` | as create |
| `keyfile confirm --stdin` (step 2) | `{"v":1,"server":"<id>","nonce":"<nonce>","shares":["<share 4>","<share 5>"]}` | `{"v":1,"ok":true,"server":"<id>","backup":"<file>"\|"none"\|"failed","warnings":[...]}` |
| `keyfile cancel --stdin` | `{"v":1,"server":"<id>"}`, optionally with `"nonce":"<nonce>"` | `{"v":1,"ok":true,"done":"cancelled: ...","warnings":[]}` |
| `keyfile status` | nothing | `{"v":1,"ok":true,"server":"<id>","shares":n,"threshold":t,"approle":bool,"userpass":bool,"pending":"<verification nonce>"\|"init"\|""}` (`approle` and `userpass` are `null` when no live token can tell) |

The key file: `{"v":1,"server":"<cluster id>","repo":"<name>","created":"<UTC>","shares":["<4>","<5>"],"role_id":"<id>","secret_id":"<id>"}`.
On a failure the JSON is `{"v":1,"ok":false,"error":"<the plain reason>","code":"<a short word>"}` (the launcher shows `error`). Exit codes: `0`
ok, `1` failed, `3` refused inside an agent's job (`DEVHOST_JOB_CHILD`, `CLAUDECODE`, a name in
`OPENBAO_AGENT_JOB_VARS`; `unlock --status` and `keyfile status` carry no secret and are not
refused), `4` not applicable (not server mode, or `unlock` is not `keyfile`), `2` a wrong call.

- **`unlock --status`**: `ready` is keyfile mode, unsealed, a live token **and the renewer running**
  (the Operator's ruling of 2026-11-05: a live token nobody renews dies within the hour, so the
  launcher sends the key file and the unlock restarts the renewer). `token` is `missing`
  (none saved) or `dead` (one the server does not take now: expired, revoked, or the server sealed
  or down). A sealed server cannot say its cluster id (it is in the store), so the last one seen is
  kept in `cluster-id` in the volume (not secret) and reported.
- **`unlock --stdin`**: unseals with `PUT sys/unseal` (progress reset first) if sealed, refusing
  before any share is sent when the key file names another server than the one remembered, and
  before the login when the running cluster differs; logs in; revokes the previous token with
  itself (`revoke-self`, in the default policy, review finding 6); saves the new one through the
  token helper; restarts the renewer, detached with its stdio closed so the launcher's exec returns.
- **Create and rotate are two steps** (the Operator's ruling of 2026-11-05, "confirm first"), so
  that the new shares take effect only after the launcher has saved the OpenBao key file. They use
  OpenBao's rekey **verification** (`require_verification`): until two of the new shares are given
  back, the shares in force stay in force (`seal-status` still says 3, the old shares still unseal),
  and a server start drops the waiting rekey altogether.
  - **Step 1, `keyfile create`**: from two custody shares of a store made the operator way (3
    shares, the migration) or on an empty server (`init`, 5 shares from the start). A root token is
    made from the two shares through the loopback listener's unauthenticated root-token endpoints
    (ADR 0055: **no login is needed**, so a lost key file with a dead token is recoverable, review
    finding 1) and revoked before the answer, also on a failure. It writes the operator AppRole and
    the Operator's policy, makes the key file's secret id (the earlier ones still hold), and runs
    **rotate-keys to 5 shares, threshold 2, with verification** (`sys/rotate/root/*`). The answer
    holds the new shares, the key file and a `nonce`. An init has no verification in OpenBao: its
    shares are in force at once, the nonce is `init`, and a cancel (or a new init) clears the store,
    which holds nothing yet.
  - **The nonce carries a narrow token.** Verification answers only to a token, and the root token
    is gone by then. Step 1 makes an orphan token whose policy (`keyfile-confirm`) may verify or
    cancel the waiting rekey and revoke itself, nothing else, for 15 minutes and a few uses, and
    puts it in the nonce (`<verification nonce>:<token>`). It is never written to a file: it goes
    to the launcher's memory with the shares and comes back on stdin. A launcher that compares
    `keyfile status`'s `pending` with its nonce compares the part before the colon.
  - **Step 2, `keyfile confirm`** with the saved key file's two shares: the verification (the new
    shares take effect), the token revoked, a root token from the new shares, then everything the
    rotation ends with: every other operator secret id destroyed (review finding 5), the userpass
    user `operator` deleted, every token an earlier password or AppRole login made revoked (the
    backs log in again at their next run; the Operator's ruling "keep it"), every other role's
    secret id reissued into its files, the Operator logged in (with a one-use secret id spent by
    that login, since the key file's own is not sent back), and **a backup** to the recorded
    destination before the answer (review finding 4; `"backup":"none"` and a warning when there is
    none). Run again (its answer was lost), it answers ok and does the end steps again.
  - **`keyfile cancel`** drops a step 1 that was not confirmed: the shares in force stay. With the
    nonce of step 1 it cancels only that step (another nonce is refused, `nonce-mismatch`) and,
    since the nonce carries the token, cancels the waiting rekey on the server at once; without
    it, the waiting rekey is dropped by the next step 1 (which also destroys the lost step's secret
    id and revokes its token) or by a server start.
  - **`keyfile status`**'s `pending` (Amendment 2) is the verification nonce while a rekey waits
    for its confirmation, `init` for an unconfirmed init, else empty: the shares read 5 before and
    after a rotation, `pending` tells them apart. It comes from the server when the saved login may
    read the rekey's status (the Operator's policy may read `sys/rotate/root/verify`), else from the
    record of step 1 in the volume (`keyfile-pending`: the kind, the server, the accessors and the
    verification nonce, no secret), which the start hook marks dropped when it starts a server.
  - **What a lost answer costs**: step 1's lost: nothing (the old shares hold; step 1 again). The
    confirmation's lost: `keyfile status` says `pending` empty and 5 shares, and confirm again is ok.
- **`keyfile rotate`**: the same two steps from any two of the five shares: the key file's own (no
  typing, after a suspected copy) or two custody shares (after a loss). Every share changes, so the
  three custody shares are stored again; **keep the previous ones until the backups made under them
  are pruned** (`backupKeep`): a backup opens only with the shares in force when it was taken.

**Lifecycle.**

- *Turning it on*: set `unlock: keyfile` and rebuild, then `task dc:openbao:keyfile:create` on the
  workstation once: two custody shares typed there (or none, on a new server), the key file saved
  there and confirmed, then the three new custody shares printed there once. From then on nothing
  is typed.
- *The key file lost, or the workstation*: the server stays sealed at the next start (the launcher
  says there is no key file for it); `task dc:openbao:keyfile:rotate` with two custody shares makes
  a new one, with no login (the token is dead by then). Two custody shares at `task openbao:unseal`
  in the container also unseal it, but log nobody in.
- *A machine loss*: a new container, `task openbao:restore FROM=<backup>` in its terminal (two
  shares of the store the backup came from; in keyfile mode no password is asked and nothing is
  reissued), which ends by naming `task dc:openbao:keyfile:rotate`: that makes the restored store's
  key file, reissues every AppRole and logs in. A restored store keeps its cluster id.
- *An onboarding claim* (`openbao:onboard:claim`) in a key-file server asks for no password and ends
  by naming `task dc:openbao:keyfile:rotate` with two of the new shares it printed.
- *Back to typing* is not a task yet: the userpass user `operator` is gone, and `task
  openbao:password` changes the password of a user that exists. Setting `unlock` back to `operator`
  leaves a store with five shares (any two still unseal it at `task openbao:unseal`) and no
  password login.

**What it does not change, and the threats.** No share is stored in the container, its volume or a
backup: the key file's two shares cross into the container's memory for two `sys/unseal` calls at
each start, and the custody shares only when typed to recover or rotate. But **a running key-file
container always holds an unsealed server and a live Operator token** (mode 600, the remote user's),
which every process of the remote user can use, and **any agent in the container could harvest the
quorum**: Claude Code and the backs run as the same Linux user as the Operator's shells, with
passwordless `sudo`, so an agent can put its own `openbao-setup` or listener in the way, or read the
key file's bytes on their way in, and two shares open every backup ever made under them, off the
machine too. That holds **until the backlog item `agent-linux-user` lands** (agents as their own
Linux user, without passwordless `sudo`); **then the Operator rotates** the key file and the shares
(`task dc:openbao:keyfile:rotate`). Until then this is accepted for this devhost (the Operator's
ruling of 2026-11-05); a consumer decides for itself by opting in. The key file is a quorum held by
one Windows account (DPAPI, the launcher's NOTES): whoever runs as that account, or holds a domain's
DPAPI backup key, opens it.

**Windows only for now.** The key file lives in the Windows launcher (DPAPI). The bash launcher
(Linux, macOS, a WSL distro) says the OpenBao key file is Windows-only and leaves the server as
`operator` mode has it: two custody shares at `task openbao:unseal`. A container started without the
launcher (VS Code's "Reopen in Container") stays sealed until `task dc:openbao:unlock` on the
workstation or two custody shares in the container.

**What was confirmed against OpenBao 2.7.2** (throwaway servers, other ports, a scratch folder):
`sys/rotate/root/init` and `update` with a root token take a 3-share store to 5 shares, threshold
2; two of the five (shares 4 and 5) unseal it through `sys/unseal`, and the old shares are refused
("failed to decrypt keys from storage"); a periodic AppRole token renews with `renew-self` and is
refused (403) once its period passed without a renewal; the unauthenticated root-token endpoints
work with two of the five shares; a raft snapshot restored into another server brings the source
store's cluster id with it. Rekey verification (`require_verification`): until two of the new
shares are verified, `seal-status` keeps the old count and the old shares unseal; a seal or a
restart drops the waiting rekey ("no rotation configuration found"); `sys/rotate/root/verify` needs a
token (403 without one), and an orphan token with only verify and cancel on it is enough; the root
token's `DELETE sys/rotate/root/init` cancels a rekey waiting for verification; a second verify
answers "no rotation in progress".

## Backup and restore

**`task openbao:backup [DEST=<folder>] [KEEP=<n>]`** (server mode; non-interactive, so a scheduler
can run it). `DEST` is any absolute folder (the cloud folder is one choice, a USB disk another); when
it is not given the `backupDest` option is used, then the folder recorded at `init`, and with none
of the three the task stops (exit 2). It logs in with the `backup` role that `init` made (a role
that may **read the snapshot path and nothing else**, loopback only, 5 minute tokens; its secret id
is in the volume under `approle/backup`, passed to `bao` as a file, never an argument), takes
`bao operator raft snapshot save` into a private folder on tmpfs (`/dev/shm`; `OPENBAO_BACKUP_TMP`
names another), copies it whole into `DEST` as `openbao-<machine>-<YYYYMMDDTHHMMSSZ>.snap`
(`<machine>` is `OPENBAO_MACHINE`, else the hostname) under a temporary name, checks the copy's
sha256 and moves it into place **without overwriting** (a name that exists waits for the next
second, and after five tries the task stops with exit 1). The temporary snapshot is removed on every
way out. It records the time, place and sha256 in the volume (`last-backup`), keeps only the newest
`KEEP` (else `backupKeep`, default 30, `0` keeps all) of **this machine's own files in `DEST`**
(a name that is exactly `openbao-<machine>-<time>.snap`: another machine's backups, notes and
anything else are never touched) and prints the path and the sha256. The unseal shares never travel
with a snapshot. A server made before 1.3.0 has no backup role: the task then uses your login and
says so, and `task openbao:backup:role` makes the role.

| Exit | Meaning |
|---|---|
| 0 | written |
| 10 | the server is unreachable |
| 11 | sealed or not initialised (what a scheduled run shows after a container start) |
| 12 | cannot log in (the role's secret id, or no login) |
| 13 | the token may not read the snapshot |
| 20 | `DEST` is missing or not writable |
| 2 / 1 | no destination or a wrong `KEEP` / a step failed (the snapshot, the copy, no free name) |

Client mode runs the same task with the token of the sitting (a role or token the server's owner
provides; granting read on `sys/storage/raft/snapshot` on a shared server lets the holder copy every
tenant's store, so it is the owner's call).

**After a write.** A task that writes a secret ends with `openbao-server after-write`: with no
default destination a one-line reminder (`not backed up since <time>; task openbao:backup DEST=...`),
with one it runs the backup, and **it always exits 0**: the write stands whatever the backup does,
and a failure prints its exit code and meaning. In client mode it does nothing (a central server's
owner takes its backups). It ends `openbao:ssh:new`, `:put`, `:import`, `:retire` and
`openbao:onboard:claim`, and **not `dcf-secret put`**: `dcf-secret` is the collection's one command for
every Feature and stays free of the server's own tasks, its callers here (`openbao-ssh`) write in
batches (one backup per key of an import would be wrong), and its exit codes are the contract the
consumers script against. A write made by hand with `dcf-secret put` is not followed by a reminder;
`task openbao:server:status` shows the age of the last backup and warns past `backupWarnAfter`.

**Scheduled backups, and the check that decided how.** Before building a timer the question was
whether OpenBao already has one. Checked on 2026-11-04 against the OpenBao tree and docs
(`website/content/docs/api/system/storage/raft.mdx`, `commands/operator/raft.mdx`, the file list of
`github.com/openbao/openbao`) and against `github.com/openbao/openbao-snapshot-agent`: **OpenBao has
no scheduled or automatic raft snapshots** (the API is `GET`/`POST sys/storage/raft/snapshot` and
`snapshot-force`; the Vault feature of that name is Enterprise and has no counterpart). The
snapshot agent (v0.4.5, MPL-2.0) is a recipe, not a daemon of its own: an OpenBao Agent for
authentication, a systemd timer or cron job running `bao operator raft snapshot save` to a name made
with `date`, and `find -mtime` for retention. It does not fit: it needs systemd or cron (a
devcontainer has neither by default), names files by date with no machine and never checks for an
overwrite, prunes everything in the folder by age rather than its own pattern, and has no sealed
case. So the Feature builds the optional pieces itself, on the same `backup` command:

- **`backupInterval`** (`5m`, `6h`, `1d`; at least 5 minutes; empty = off) makes the start hook start
  one background loop in the container (`backup-timer.pid` in the volume; a live one is reused; it
  never fails the start) that runs the backup into the default destination every interval. A sealed
  server, a missing folder or a failed login is skipped with one line in `backup.log` (with the
  exit code and its meaning) and tried again at the next tick, never in a retry loop. The timer needs
  a `backupDest` (or the folder recorded at `init`) and an unsealed server, which after a container
  restart means the Operator has unsealed it. It dies with the container and the next start brings it
  back.
- **The host's own scheduler** (the choice that survives the container being down, and tells you
  when it was): a Windows Task Scheduler entry that runs the task through the launcher, for example
  once a day at 02:00 from the repository's folder on the workstation:

  ```text
  schtasks /Create /SC DAILY /ST 02:00 /TN "openbao backup" /TR "cmd /c cd /d C:\path\to\repo && task devcontainer:exec CMD=\"task openbao:backup DEST=/backups\""
  ```

  (`/backups` is a folder inside the container, such as a bind-mounted cloud folder.) The launcher
  never registers it for you (ADR 0024 rules out a background process of ours on the host); a run
  against a stopped container or a sealed server fails with a clear line in the scheduler's history
  (exit 11 for sealed). Without the cloud folder or any other destination, a scheduled backup
  has nowhere to go, which is why both ways need a destination.

**`task openbao:restore FROM=<file>`** (interactive: the Operator, in a plain terminal; refuses
inside an agent's job and without a terminal). The restore installs the snapshot with
`bao operator raft snapshot restore -force`; the check that decided the `-force` is below.

- **On an empty server** (not initialised) it first initialises it with **one throwaway share**, in
  its own memory only (the key goes to `bao operator unseal` as an argument for an instant: it
  guards an empty store about to be replaced, and is never printed or written), installs the snapshot
  with the throwaway root token, and discards both. A marker `restore.pending` in the volume is
  written before the init and removed after the install: a restore that stopped in between leaves a
  store whose only share nobody has, so the next run clears `raft/`, starts the server again and
  begins from empty.
- **On a store in use** it says the snapshot **replaces** everything and asks you to type `restore`,
  unseals first if the server is sealed, and makes a **root token from two of the current shares**
  (`bao operator generate-root`), used once and revoked, the same way as making or deleting a role
  (a one-time password in a variable, the shares typed at a hidden prompt, the token only in the
  step's subshell, revoked on every way out, an attempt this task started cancelled if abandoned).
  It needs no login: the listener's unauthenticated root-token endpoints take the shares (above).
  On a listener without them (a config of the repo's own) the CLI's authenticated flow is used,
  which starts with the Operator's login, whose policy holds exactly two paths for it
  (`sys/generate-root-token/attempt` and `/update`); a login without those paths (a server
  initialised by an unreleased 1.2.0 build) is refused by the server, and the task stops before any
  share is typed. The root token is made in the store the snapshot replaces, so it goes with it:
  the task tries to revoke it and does not complain when the restored store no longer knows it.
- The restored store is **sealed under the shares of the store the snapshot came from** (a few
  seconds after the install the node seals itself; a snapshot of the very store it is restored onto
  holds the same unseal key and leaves the node unsealed, which the task says and waits out). The
  task asks for two of those shares when it is sealed, then
  for the Operator's password (the restored store's) at `bao login`'s hidden prompt, which leaves you
  logged in, and reissues every AppRole's secret id (the secret ids' files in the volume are not in
  the snapshot) so the backs and the `backup` role work again. If the login fails the task says to
  log in and run `task openbao:approle:issue ALL=1`.
- It is safe to run twice (the second run takes the "store in use" route). A snapshot whose file name
  says another machine wrote it is warned about, and you confirm: restoring your own backup restores
  your own access, and someone else's backup is not an onboarding hand-over.
- **An onboarding snapshot** (a file named `onboarding-<machine>-<UTC time>.snap`, from
  `task openbao:onboard:export`) is recognised by that name, since a restore has no token to read the
  marker inside. The task says it is an onboarding snapshot, gives no other-machine warning, unseals
  the server with the shares the sender handed over, and **stops there**: no login, no reissue of the
  roles, no password asked, because nothing of the sender's is trusted yet. The server is left running
  and unsealed under the sender's shares; `task openbao:onboard:claim` does the rest (it takes the
  claim token). A store in use still asks you to type `restore` first.

**`task openbao:backup:role`** makes the `backup` role on a server made before 1.3.0 (a root token
from two shares, used once and revoked, as for making a role).

**What was confirmed** (OpenBao docs and source, and a real 2.7.2 server, 2026-11-04):

- `bao operator raft snapshot save` needs only `read` on `sys/storage/raft/snapshot`: a role with that
  one capability saves a snapshot, `token capabilities` reports `read`, and the same role is denied
  `snapshot-force` (403). Restore is `POST sys/storage/raft/snapshot` (`update`) or
  `snapshot-force`; the CLI's `restore -force` calls `snapshot-force`.
- **A restore needs the snapshot's own shares afterwards, and `-force` on a different server.** A
  plain restore into a server with other shares is refused ("could not verify hash file, possibly the
  snapshot is using a different set of unseal keys; use the snapshot-force API to bypass this
  check"), so the throwaway init needs `-force`. After a forced restore the node seals itself and
  opens only with the shares of the store the snapshot came from; the throwaway share no longer opens
  it. So no share ever travels with a snapshot, and a restore needs the shares that went with it.
- `bao operator unseal` and `generate-root` need a terminal to read a share (a pipe is refused);
  `bao operator generate-root` prints its prompt on stdout, so the task prints its own prompt line.
- A root token generation through the CLI needs a token from 2.6.0 on (an unauthenticated one is a
  403); a token with create/read/update/delete on `sys/generate-root-token/attempt` and update on
  `sys/generate-root-token/update` runs it and the result is a `root` token.
- **The unauthenticated endpoints** (2.7.2, 2026-11-05): `disable_unauthed_generate_root_endpoints`
  is a listener option (`listener "tcp"` and `listener "unix"`), default true; with it true
  `sys/generate-root/*` answers 405, with it false a fresh server with no token anywhere completes
  a root token from 2 of 3 shares (`PUT sys/generate-root/attempt` with `{}` returns the nonce and a
  one-time password the server made, `PUT sys/generate-root/update` takes `{"key","nonce"}`), the
  token decodes to a `root` token (base64 without padding, XORed with the one-time password) and
  resets a userpass password; `bao operator generate-root -decode` asks the authenticated status
  first, so it cannot decode without a token. Without a token: the status (nonce, progress) is
  readable and never shows the encoded token, an attempt can be started and any attempt cancelled
  (also one started through the authenticated endpoints: they share one attempt), a share with the
  wrong nonce is refused, a second attempt while one runs is refused, a wrong share aborts at the
  threshold and leaves the attempt to be cancelled; the authenticated endpoints still answer 403
  and the legacy rekey endpoints 405. The option is read when the server starts: a SIGHUP does not
  change it. OpenBao calls these endpoints deprecated (2.6.0); no release has announced their
  removal yet.

**Not checked here:** the throwaway init and restore of the Feature's own tasks against a real
server, and restore run twice, run only in CI's Docker run (`test/openbao/backup_restore.sh`): the
tasks refuse inside an agent's job, and the pieces were run one by one against a real server instead
(save and retention, the role's capabilities, the forced restore across different shares, the
generate-root flow).

**What was confirmed in OpenBao's own documentation and source** (github.com/openbao/openbao,
checked on the tree of 2026-11-03): OpenBao has used **no `mlock` since 2.0.0** (the RFC
"mlock removal"; the migration guide says to remove `disable_mlock`, and it is an unknown field in
the config), so a container without `IPC_LOCK` needs nothing and the Feature writes no
`disable_mlock`; raft needs `cluster_addr` (and `api_addr` is set so the server does not guess); the
declarative `audit` stanza exists from 2.4.0, hence the version floor; self-initialisation
(`initialize` stanza) needs an auto-unseal seal and returns no shares, so it does not fit the Shamir
gate and `init` is the CLI's own `bao operator init`; AppRole's `secret_id_ttl` defaults to 0 (no
expiry), `secret_id_bound_cidrs` is checked at login and `token_bound_cidrs` on every use of the
token, deleting a role destroys its secret ids, and a secret id can be destroyed by its accessor;
`bao operator init` prints `Unseal Key N:` and `Initial Root Token:`, and `bao operator unseal`
reads a share at a hidden prompt that needs a terminal. The container test `server_mode` runs all
of it against a real server.

Files in the volume for server mode: `server.hcl`, `server.pid`, `server.log`, `raft/`,
`audit.log`, `backup-choice`, `last-backup`, `last-restore`, `restore.pending` (only while a restore is
half done), `backup.log` and `backup-timer.pid` (the timer), `approle/<role>/{secret_id,role_id}`, and
the login `token`.

## Onboarding: a new devhost starts from shared keys

Two routes, for two needs. **The receiver trusts the sender only for what was put in:** the sender
knows those values for good, and nothing here changes that. For anything stricter, use a fresh
instance and put new values in.

```
 (a) a starter instance, for many keys                  (b) response wrapping, for a few keys

 sender                         receiver                sender                       receiver
 openbao:onboard:export ------> openbao:restore         openbao:wrap NAMES=a,b       openbao:unwrap
   snapshot file                openbao:onboard:claim     one one-use token each ---> look up, check the
   3 shares + claim token         rotate-keys, revoke       (a file, TTL <= 1 hour)     creation path, unwrap
   (handed over separately)       everything the sender                                 once, dcf-secret put
                                  held, reissue, rotate    needs a central server
                                                           the receiver can reach
```

**Route (a).** `task openbao:onboard:export NAMES=ssh/key,register/x DEST=<folder>` (the sender, in
a plain terminal; refuses inside an agent's job) starts a second `bao` server of the same binary
under `OPENBAO_STATE_DIR/onboarding` (its own raft folder, a loopback listener on port 8210, or
`OPENBAO_ONBOARD_PORT`), initialises it with **fresh** shares (3, threshold 2: never the sender's
own), copies the named secrets in from the sender's store with the sender's login (every field),
writes the **onboarding marker** (`onboarding/marker`: the sender's machine name, from
`OPENBAO_MACHINE` or the hostname, and the time), takes a raft snapshot into `DEST` as
`onboarding-<machine>-<UTC time>.snap` (mode 600, never overwritten), then stops the instance and
deletes its folder. It prints the fresh shares and the **claim token** (the instance's root token)
once, to the terminal. The sender's own store is never snapshotted. The shares are not PGP
encrypted in this version (the instance has to be unsealed to be filled). The file name is the
marker a restore can read before it has a token (`onboarding-`); the record inside is the one
`claim` reads.

The receiver runs `openbao:restore FROM=<file>` (the backup and restore tasks), unseals with the
sender's fresh shares, then `task openbao:onboard:claim` (server mode, a plain terminal). It asks for
the claim token, the receiver's own Operator password and two of the sender's shares (all hidden),
and then:

1. `bao operator rotate-keys -verify`: three new unseal shares, printed once; bao commits them only
   when two are typed back, so a share that was never stored cannot lock the receiver out.
2. Revokes everything the sender held: every token (the accessor list, each revoked but the claim
   token's own, then the login paths by prefix), every `userpass` user, every auth method but
   `token`, `userpass` and `approle`, any audit device but the server's own file device; every
   AppRole role is deleted (which destroys its secret ids) and written again with the Feature's
   settings and the same policy. A policy that is not the Feature's own and not a role's is
   listed for the receiver to read; none is deleted blind.
3. Sets up the receiver's Operator (the mounts, the policy and the login, as `init` does) and runs
   the generic `openbao:approle:issue ALL=1`.
4. `bao operator rotate` (`ROTATE=0` skips it): new writes use a new data key.
5. Replaces the marker with `onboarding/claimed`, revokes the claim token, and lists the names that
   came with the snapshot as the sender's knowledge.

A claim that fails midway leaves the claim token valid and a resume file in the volume: run it again
(it skips the rotation, whose new shares are already in force).

**Why a claim token, and not a root token made from the shares.** OpenBao's `bao operator
generate-root` uses the authenticated `/sys/generate-root-token` endpoint since 2.6.0, and the
unauthenticated one is off by default (the listener option
`disable_unauthed_generate_root_endpoints`). A restored store holds only the sender's tokens, so
the receiver has no token that may start a generation. (Since openbao 1.4.0 the server's listener
has those unauthenticated endpoints on, so the shares alone could now start one; the claim is
unchanged so far.) The claim token is a root token that
was in the snapshot: the sender holds it already, so it adds no trust, and the claim revokes it.
`rotate-keys` itself needs a token too (`sys/rotate/root`), which is the same token.

**What was confirmed against OpenBao 2.7.2** (a real server, the container test `onboarding`, and
the source): `rotate-keys` changes the **unseal shares and the key that protects the keyring**: a
snapshot taken after it does not open with the old shares (the unseal is refused), a snapshot
taken before still does. It does **not** change the **data key** (the key term stays 1): that is
what `bao operator rotate` does, for writes after it. So the sender, holding the old snapshot and
the old shares, reads for good what was in it, cannot unseal a later backup of the receiver's store
with the old shares, and cannot read what the receiver writes after `rotate` (a new key, in a
keyring under the new shares). What was written under the old data key stays readable to anyone who
kept the old keyring: the data that came with the snapshot is the sender's for good. A
wrapping token is read with `-wrap-ttl` on a `kv get` (its creation path is `<mount>/data/<name>`),
`sys/wrapping/lookup` returns the creation path, time and TTL, the unwrap takes the wrapping token as
the call's own token, and a second unwrap or lookup fails (`wrapping token is not valid or does not
exist`). `-wrap-ttl` is not capped by the server: the cap is this task's.

**Route (b).** `task openbao:wrap NAMES=a,b [TTL=15m] [OUT=<file>] [SHOW=1]` makes one one-use
wrapping token per secret (not one for a bundle: a bundle would pass the plaintext through the task
and lose the creation-path check). `TTL` defaults to 15 minutes and is capped at 1 hour. The tokens
go to a file (mode 600, `/dev/shm` unless `OUT=`), and the task prints its path and the expiry;
`SHOW=1` also prints them, to a terminal only. `task openbao:unwrap FROM=<file> [ISSUER_ADDR=<the
issuing server>]` (or the name and the token at prompts, never an argument) looks **every** token
up first, unauthenticated, with the wrapping token as the call's token so no saved login reaches the
issuer, and refuses ("do not unwrap; ask the sender") unless each was made by a read of its own
secret's path and has not run out; only then does it unwrap each once and put the value into the
receiver's own store (`BAO_ADDR`) with `dcf-secret put`, field by field. A token that was read by
anyone else first is already spent, and the receiver learns it only then: a token that fails as
used or expired is an event to investigate. **The channel matters**: the token file is not the
channel. Route (b) works only against a central server the receiver reaches in client mode: in server
mode the issuer is a loopback listener in the sender's container.

**Two servers in one container** (the export): the second runs beside the main one on its own
ports (8210 and 8211, or `OPENBAO_ONBOARD_PORT` and the next) and was run against a real server in
the container test. If the ports are taken, the export says the instance did not answer and
points at its log; the fallback is the same export in a second devcontainer in server mode.

## `dcf-secret`

The interface every Feature and script of this collection uses to read and write a secret, so
where the server runs does not matter to the caller. `openbao:kv:get` stays as the raw `bao kv
get` for people; `dcf-secret` is for callers.

```text
dcf-secret get <name> [--field <field>]    the value on stdout, nothing else (field default: value)
dcf-secret put <name> --field <field> [--replace]
                                           the value on stdin, never an argument
dcf-secret status [<name>]                 one word on stdout, the fix on stderr
dcf-secret ttl                             the seconds the token has left (0: it does not expire)
```

- **Names are logical** (`ssh/<key>`, `register/<principal>`, `token/<name>`; letters, digits,
  `.`, `_`, `-`, with `/` between parts) and live at `<mount>/<name>` in a KV v2 mount. The mount is
  `dcf`; `DCF_SECRET_MOUNT` names another one (a client of a shared server uses its own).
- **Who asks**: the token `bao` uses (`BAO_TOKEN`, else the saved login). `DCF_SECRET_AS` (logging
  in as an AppRole) is not in this version: setting it exits 2 rather than asking as someone else.
- **`put` merges by default**: it writes only the given field and keeps the secret's other fields
  (`bao kv patch`); when the secret does not exist yet it creates it (`bao kv put -cas=0`, which
  fails if the secret appeared in the meantime, and then one more patch merges into it).
  `--replace` makes the secret exactly this one field (`bao kv put`) and drops the others. A token
  that may not patch is refused (exit 13, naming `--replace`), never silently turned into a
  replace. `put` refuses a terminal on stdin and holds the value in memory only (never a file,
  never an argument; a merge may offer it to `bao` twice). **`get` writes the value only to
  stdout**: it is never put in a file or a variable.
- **No fallback, ever.** On a non-zero exit nothing is read from a file, a volume or the
  environment instead. A second source would be a second master.

Exit codes, the same for every caller, each with one plain line on stderr naming the fix (the
sealed line names `task openbao:unseal`, not initialised names `task openbao:init`, unreachable
names `task openbao:server:status`, each adding what to do against a server that is not this
container's):

| Exit | Meaning | `status` prints |
| --- | --- | --- |
| 0 | done (`get`: the value is on stdout) | `ready` |
| 10 | the server is unreachable (`BAO_ADDR` wrong, server not running, no `bao`) | `unreachable` |
| 11 | the server is sealed, or not initialised | `sealed`, `not-initialised` |
| 12 | no token, or it expired | `logged-out` |
| 13 | the token may not use this name | `denied` (only with a name) |
| 14 | no such secret, or no such field | |
| 1 | `bao` failed and none of its signals say why (`put` only; its message follows) | |
| 2 | a wrong call (usage, a bad name, `DCF_SECRET_AS`) | |

The code is worked out from `bao`'s own signals, never from the words of a message: after a failed
call it asks `bao status -format=json` (exit 2 is sealed, the JSON says `initialized`; anything
else is unreachable), then `bao token capabilities` on `<mount>/data/<name>` (a refused call is no
valid token; no `read` or `root` for a get, no `create`, `update` or `root` for a put, is denied),
and a get that gets this far is a missing secret. A `put` that fails the same way checks for `patch`
(a merge needs it), then for `create` (a secret that does not exist yet needs it). A token
therefore needs the default policy (every token has it unless removed) besides `read` on
`<mount>/data/<name>` to get, `patch` (and `create` for a new secret) to put, and `create` and
`update` for `put --replace`. It speaks only `bao`, so it works the same against a Vault server.

A caller without this Feature finds no `dcf-secret` and says so; the Features stay independent at
build time.

`dcf-secret ttl` (from `bao token lookup`'s `ttl`) is how a caller lives no longer than the login:
ssh-agent's `key:load` gives a key that lifetime in the agent. It exits like `status` (10, 11, 12).

## SSH key records

OpenBao keeps the collection's SSH private keys; the `ssh-agent` Feature only loads them into an
agent for a sitting, and the `gh` Feature registers their public keys at GitHub (ADR 0048). This
Feature keeps the records and their lifecycle, and knows nothing of agents, git or GitHub.

A record is the KV v2 secret `dcf/ssh/<name>` with the fields `private_key`, `public_key` and
`purpose` (`git-signing` by default), and custom metadata `created` (the date), `source`
(`generated`, `import`, `ssh-agent`, `agentic-register`) and, once retired, `retired`. The
register's keys use `register/<principal>`.

- `task openbao:ssh:new [NAME=] [COMMENT=] [PURPOSE=]`: an ed25519 key (default name
  `<repo>-<container>-sign`), made by `ssh-keygen` in a private folder on tmpfs (`/dev/shm`) that is
  removed at once; with no writable tmpfs it refuses rather than write a key to disk. **No
  passphrase**: the gate is the unseal and the login, and a second passphrase per load would bring
  back the prompt ADR 0046 had. Prints the public key and the next steps.
- `task openbao:ssh:put NAME=`: a key you pipe in, from stdin only.
- `task openbao:ssh:retire NAME= [-- --plan]`: writes a version with only the public key, the
  purpose and the date, then destroys every version that held the private key (`bao kv destroy`,
  not recoverable). The metadata stays, so the record still lists and its public key can still
  verify old signatures.
- `task openbao:ssh:age`: each record's creation date, age (or retirement date) and fingerprint;
  a live key older than `SSH_KEY_MAX_AGE_DAYS` (default 365) is warned about.

A record is created only if absent (`bao kv put -cas=0`) and a name is never reused, also after a
retire. The private key is held in memory and handed to `bao` on stdin; it is never an argument
and never printed. Reads go through `dcf-secret`; list, metadata and destroy are `bao kv`'s own,
so the Operator's policy needs `create`, `read`, `update`, `patch` and `list` on `dcf/*` (which
covers `dcf/metadata/ssh/*` and `dcf/destroy/ssh/*`). The exit codes are `dcf-secret`'s; 3 is a
refusal (the name exists).

### Import

`task openbao:ssh:import FROM=...` brings keys kept elsewhere into OpenBao; run it again at any
time: a record that holds the same key is skipped, one that holds another key is refused.

- `FROM=ssh-agent [DIR=]`: every private key of the `ssh-agent` Feature's key volume becomes
  `ssh/<file name>`, dated from its `.meta` sidecar (else the file's date). A key with a
  passphrase is asked for **once, at ssh-keygen's own prompt**, on a tmpfs copy that is removed
  (without a terminal it is skipped and named). What OpenBao returns is compared, by fingerprint,
  with what was read. The volume's `allowed_signers.history` lines and a line per imported key go
  into the repository's `.devcontainer/allowed_signers` (`ALLOWED_SIGNERS=` names another file; a
  key the collection generated gets `valid-after` its creation date, an imported one none, since it
  may have signed earlier); **the host commits it**. Then one key (the one git signs with, if
  any) is loaded for 5 minutes through `ssh-agent-setup` and `git:verify` runs. Only then is
  deleting the volume's copy offered, per key, on a terminal, never by default, so a key is in two
  masters no longer than the import.
- `FROM=file FILE=<path> [NAME=]`, or the key on stdin with `NAME=`: one key, its line added to
  `.devcontainer/allowed_signers`; the source file is left alone. From the workstation, `task
  devcontainer:openbao-ssh-import FILE=<key>` (the `devcontainer-cli` launcher) streams a key into
  this through `devcontainer exec` on stdin.
- `FROM=agentic-register [DIR=]`: the register's `keys/<principal>` (in `AGENTIC_REGISTER_HOME`)
  become `register/<principal>` with purpose `register`; each back then reads its own through its
  AppRole.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {
    "version": "2.7.1"
  }
},
"containerEnv": {
  "BAO_ADDR": "https://bao.example.com"
}
```

Drop the `version` line to follow the newest release at each image build.
The login is kept in the Feature's volume: `bao login` once, and a rebuild keeps it.
For a server with a private CA, trust the certificate in the image
(`update-ca-certificates`) rather than setting `BAO_SKIP_VERIFY`.

## Verify it works

```bash
bao version          # prints the installed version
task openbao:version
openbao-setup        # the post-create report, any time
dcf-secret status    # needs BAO_ADDR; prints ready, or why not (exit codes above)
task openbao:server:status   # server mode: the state, the storage, the backup choice
```

The build log carries the first line (`openbao: downloading OpenBao
v<version> (openbao_<version>_linux_<arch>.tar.gz)...`, then the `bao
version` output). A failed checksum stops the build with `sha256sum`'s
`FAILED` line. The post-create log has the hook's lines: `openbao: /var/lib/devcontainer-features/openbao
(volume, writable)`, `openbao: mode client ...`, `openbao: token helper in effect`,
the version, `BAO_ADDR`, and whether a login is saved. `volume` in the first line is what keeps the
login across rebuilds; `image` means the mount is missing.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- It augments no official Feature and replaces none.
- Server mode is what the later slices of `docs/proposals/secrets-master-split.md` build on: backup
  and restore, onboarding, the `openbao:ssh:*` records and `ssh-agent`'s `key:load` from the store.
- `dcf-secret` is what later Features (`ssh-agent`, `gh`, `az`, `cloud-folder`) are to call for
  their secrets; none does yet, and none names this Feature in `installsAfter` (the Features stay
  independent at build time).
- Independent of `kube-state` and `git`: no kubeconfig is read and no git
  config is written. Its volume and hook are the shape of `gh` and `az`.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `openbao:`:

- `openbao:version`: show the installed version.
- `openbao:status`: run `bao status` against `BAO_ADDR` (seal state, HA,
  version); extra flags go after `--`.
- `openbao:logout`: revoke the current token on the server and erase the saved one.
- `openbao:login`: run `bao login` interactively; auth method and flags go
  after `--`, e.g. `task openbao:login -- -method=oidc`.
- `openbao:kv:get`: read the secret `KEY=<mount/path>` from a KV engine
  (`KEY`, not `PATH`, which Task would read as the shell variable); extra
  flags go after `--`, e.g.
  `task openbao:kv:get KEY=secret/app -- -format=json`.

- `openbao:server:status`: mode, address, the server's state, and in server mode the process, the
  storage, the audit log, the unlock mode (and with `keyfile` whether the renewer runs), the backup
  choice (a standing warning when there is none) and the login.
- `openbao:init`: server mode, once, in a plain terminal: the backup choice, the Operator's
  password, the unseal shares (printed once to the terminal), the first unseal and the setup;
  revokes the root token. Refuses inside an agent's job, and with `unlock: keyfile`
  (`task dc:openbao:keyfile:create` on the workstation initialises that server).
- `openbao:unseal`: server mode: shares at the hidden prompt until unsealed. Refuses inside an
  agent's job.
- `openbao:seal`: server mode: seal the server with the saved login. Refuses inside an agent's job.
- `openbao:password`: server mode: a new password for the Operator, asked twice, then two unseal
  shares (a root token for this step alone, revoked after); no current password needed. Refuses
  inside an agent's job, and with `unlock: keyfile` (no password there).
- `openbao:approle:issue`: server mode: `ROLE=<name> POLICY_PATH=<mount/path>` makes a loopback-bound
  role that reads one secret (asks for two unseal shares; refuses inside an agent's job);
  `ROLE=<name>` or `ALL=1` reissues with your login, no shares; one valid secret id each.
- `openbao:approle:revoke`: server mode: `ROLE=<name>` deletes the role, its secret ids, its policy
  and its files (asks for two unseal shares; refuses inside an agent's job).
- `openbao:backup`: server mode: `DEST=<folder>` `KEEP=<n>`: a snapshot into a new file
  `openbao-<machine>-<UTC time>.snap`, never overwriting, only its own files pruned; exit 0, 10, 11,
  12, 13, 20 (see "Backup and restore").
- `openbao:backup:role`: server mode: make the backup role on a server made before 1.3.0 (root token
  from shares). Refuses inside an agent's job.
- `openbao:restore`: server mode: `FROM=<file>`: install a snapshot (a throwaway init on an empty
  server, a root token from shares on a store in use), unseal with the snapshot's shares, reissue the
  roles (with `unlock: keyfile`: no password, no reissue, and the pointer to
  `task dc:openbao:keyfile:rotate`). Refuses inside an agent's job.
- `openbao:onboard:export`: `NAMES=<name>,... DEST=<folder>`: a starter instance with the named
  keys, snapshot into DEST, fresh shares and a claim token printed once. A plain terminal.
- `openbao:onboard:claim`: server mode, after `openbao:restore`: rotate-keys, revoke everything the
  sender held, reissue, rotate; `ROTATE=0` skips the data key rotation. A plain terminal.
- `openbao:wrap`: `NAMES=<name>,... [TTL=15m] [OUT=<file>] [SHOW=1]`: one one-use token per secret.
- `openbao:unwrap`: `FROM=<file> [ISSUER_ADDR=<server>]`: look up, check, unwrap once, `dcf-secret put`.
  The four refuse inside an agent's job.
- `openbao:ssh:new`, `openbao:ssh:put`, `openbao:ssh:import`, `openbao:ssh:retire`,
  `openbao:ssh:age`: the SSH key records and the import (above).
- `openbao:setup`: re-run the post-create hook (`openbao-setup`): make the state directory usable,
  move a token left in `~/.vault-token` into it, report the token helper, the address and the saved login; in
  server mode also the start hook.

The OpenBao key file's commands (`openbao-setup unlock`, `keyfile`, `renew`) are not tasks: the
workstation's launcher runs them (`task dc:openbao:unlock`, `task dc:openbao:keyfile:create`,
`:rotate`), and they can be run by hand by piping the JSON in (see "The OpenBao key file").

No task reads a variable besides `KEY` (and the `openbao:ssh:*`, approle and init tasks' own
`NAME`, `FROM`, `ROLE` and the like); the address and token come from
`BAO_ADDR` and `BAO_TOKEN` in the container's environment, as for `bao`
itself.

## Limits and troubleshooting

- Linux only, on the two architectures above; others fail with
  `unsupported architecture`.
- `could not resolve an OpenBao version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `checksums.txt` line fails the build (`curl
  -f`, or `sha256sum` finding no matching line). The binary is never
  installed unchecked.
- Logged out after a rebuild: the volume is gone (a container-engine storage reset, or another
  engine) or the hook's first line says `image` instead of `volume`. Log in again.
- `put` without `--replace` needs the `patch` capability on the secret's path; a policy that has
  only `create` and `update` must use `--replace`, which drops the secret's other fields.
- Not there yet: `DCF_SECRET_AS` (a secret read as another identity). No task changes a policy:
  it needs a root token made from the shares (the unauthenticated root-token endpoints, used once
  and revoked), as making or deleting an AppRole role and `openbao:password` do.
- Server mode: the shares are the keys to everything; losing two of three loses every secret. The
  loopback listener has no TLS: any process of the container can reach it and read the Operator's
  saved token (mode 600, the remote user's), as with any login kept in a volume; the token's 4 hour
  lifetime is the bound. Any process of the container can also start, read or cancel a root-token
  attempt on that listener without a token (the unauthenticated endpoints that let the shares work
  with no login): it can get in the way of an attempt, not complete one. `server.log` and
  `audit.log` grow without rotation. The server stops with
  the container and comes back sealed (the start hook says so); a server that does not answer is
  reported with the end of its log. Pinning `version` below 2.4.0 fails the build in server mode.
- `unlock: keyfile`: the launcher side is Windows only for now; the renewer's token dies within the
  hour after a suspend longer than that, until the next `task dc:*`; going back to `operator` needs
  the userpass user made again by hand. See "The OpenBao key file" for the threats.
- `dcf-secret` asks `bao` up to three questions after a failure, so a failure costs a few round
  trips; a success costs one. It assumes a KV v2 mount (the data lives under `<mount>/data/`).
- The login is kept by a token helper `bao` runs as a shell command on every call that needs the
  token; the container test `dev_server` checks login, use, revoke and `openbao:logout` against a real `bao`.
- `bao status` fails with a connection or certificate error: `BAO_ADDR` is
  unset or wrong, or the server's CA is not trusted in the image.
- A `BAO_TOKEN` in the environment takes precedence over the saved login (see State).

## Why this one exists

Checked 2026-11-03 (NFR-9): no published Dev Container Feature is a general OpenBao CLI Feature
with state, a setup hook and a tested interface, and none is in the containers.dev index (searched
by name and description for `openbao` and `vault`). Three repositories on GitHub hold a Feature
that installs `bao` for their own purpose: `openbao-agent` in `wyrd-company/devcontainers` (installs
OpenBao and runs OpenBao Agent as an s6-overlay service from the user's own config; the archive is
checked against `checksums.txt`), `openbao-secrets` in `dever-labs/devcontainers` (installs `bao` and
a helper that logs `gh` in with a token read from OpenBao through OIDC, a session volume at a fixed
home path; the archive is checked against `checksums.txt`) and `bao-env` in
`stevetfidalgo/mindmap-devcontainer-features` (a manifest tool for KV stores that installs `bao` 2.1.1
and `yq`; no checksum check in its install script, a read of the script, not a test). They install
the binary as a means to something else, and none gives the CLI a login that survives a rebuild
(besides `openbao-secrets`' own session) or a command other Features can call. Here the binary is
checked against the release's `checksums.txt` (OpenBao also signs releases with GPG and Sigstore,
which this Feature does not verify), the login is in a volume the Feature owns, and `dcf-secret`
is the one interface the collection's Features use. The
official `devcontainers/features` collection has no OpenBao or Vault Feature; the Vault ones
elsewhere (`devcontainers-extra`, `postfinance`, `roul`) install HashiCorp's `vault`, not `bao`.

## Version and upgrade

`version` pins the OpenBao release at build (`2.7.1`, with or without `v`) or follows `latest`; pin
it to your server's version. The Feature's own version is the tag you reference
(`openbao:1` follows 1.x; see Changes). **1.1.0** adds the volume, `openbao-setup`, `dcf-secret`
and `mode`, all additive: rebuild to get them, and log in once, because the volume starts empty.
Nothing is removed; `mode` stays `client`. **1.2.0** adds `mode: server` (the `server` value, the
start hook, `openbao:init`, `:unseal`, `:seal`, `:server:status`, `:approle:issue`, `:approle:revoke`,
`openbao-server`, `openbao-run`), all additive: rebuild to get them, and nothing changes for a
container that stays `client`, except that the tasks `status`, `login`, `logout` and `kv:get` now go
through `openbao-run` (the same `bao` call; in client mode nothing is added) and the
`dcf-secret` failure lines name the new tasks.

**1.3.0** adds backup and restore (`openbao:backup`, `:backup:role`, `:restore`, the `backup*` options
and the timer, `openbao-server after-write`), onboarding (`openbao:onboard:export`, `:onboard:claim`,
`openbao:wrap`, `:unwrap`, `openbao-onboard`), the SSH key records and the import (`openbao:ssh:*`,
`openbao-ssh`) and `dcf-secret ttl`, and installs `jq` at build (a dependency the onboarding scripts
read bao's JSON with): additive, rebuild to get them. It also narrows your login (it only reissues
secret ids; making or deleting a role asks for two shares). A server initialised by an unreleased
1.2.0 build runs `task openbao:backup:role` once.

**1.5.0** adds the `unlock` option (`operator`, the default and unchanged, or `keyfile`) and its
twin `OPENBAO_SETUP_UNLOCK`, the OpenBao key file's container side (`openbao-setup unlock`,
`keyfile`, `renew`, installed as `openbao-keyfile`), the unlock and renewer lines of
`server:status`, and the key-file endings of `restore` and `onboard:claim`: additive, rebuild to get
them; nothing changes for a container that leaves `unlock` alone. The Operator's policy gains a deny
on the operator AppRole and a list of userpass user names (written by `init` and by the key file's
create and rotate; an existing store keeps its policy until one of those runs).

## Changes

### [1.5.0] - 2026-11-05

#### Added

- **The OpenBao key file: option `unlock: keyfile`** (server mode, opt-in; the default `operator` is unchanged, override `OPENBAO_SETUP_UNLOCK`). The workstation's launcher (Windows, `devcontainer-cli` 1.20.0) keeps a key file for the server and sends it at every `task dc:*`, so the server is unsealed and you are logged in with nothing typed. The store gets five unseal shares, threshold two: three custody shares you keep, two in the key file. You log in as the operator AppRole (a 1-hour periodic token, loopback only, renewed in the container while it runs); a key-file server has no password. The container side is `/usr/local/bin/openbao-setup unlock --status|--stdin`, `keyfile create|rotate --stdin` and `keyfile status` (one JSON line on stdout; secrets only on stdin, never in an argument, the environment, a file or a log; `BAO_ADDR`, `VAULT_ADDR` and `BAO_TOKEN` ignored; refused inside an agent's job), installed as `openbao-keyfile`. `create` and `rotate` are two steps: step 1 makes a root token from two shares with no login (so a lost key file is recoverable from two custody shares) and rotates to the new shares with OpenBao's verification, so they take effect only when `keyfile confirm --stdin` gives two of them back after the launcher saved the key file; `confirm` then destroys every earlier operator secret id, deletes the userpass user, revokes earlier logins (the backs' included), reissues every role, logs you in and ends with a backup. `keyfile cancel --stdin` drops an unconfirmed step (with an optional nonce, only that one); `keyfile status` says which rekey is `pending`. `unlock --status` reports `ready` only while the token renewer runs. Action: none unless you opt in; to opt in, set `unlock: keyfile`, rebuild, then run `task dc:openbao:keyfile:create` once on the workstation. Until agents run as their own Linux user, any agent in the container could harvest the key file's shares; rotate (`task dc:openbao:keyfile:rotate`) once they do (see the NOTES).
- `task openbao:server:status` says the unlock mode and, with `keyfile`, whether the token renewer runs.

#### Changed

- With `unlock: keyfile`: `task openbao:password` and `task openbao:init` refuse (exit 3) and name the workstation's task; `task openbao:restore` and `task openbao:onboard:claim` ask for no password and end by naming `task dc:openbao:keyfile:rotate`; the login hints name `task dc:openbao:unlock`. No change with `unlock: operator`.
- The Operator's policy denies `auth/approle/role/operator` and everything under it (no Operator token can mint a secret id for the key file's login), may list userpass user names and may read whether a rekey waits for its verification. It is written by `task openbao:init` and by the key file's `create` and `rotate`; an existing store keeps its policy. No action needed.

### [1.4.0] - 2026-11-04

#### Added

- **`task openbao:password`** (server mode): sets a new password for the Operator, for when you forgot it or want another. It needs no current password and no login: it asks for the new password twice (12 characters at least), then for two unseal shares at a hidden prompt, which make a root token used for this step alone and revoked straight after. The password never appears in an argument, file or output. Tokens you already hold stay valid until they expire (at most 8 hours); log in again with `task openbao:login -- -method=userpass username=operator`. Plain terminal only; refused inside an agent's job. It works with no login saved at all (see Changed). No action needed.

#### Changed

- **Server mode: two unseal shares make a root token without a login.** The config `openbao-setup start` writes sets `disable_unauthed_generate_root_endpoints = false` on its one loopback listener, so OpenBao's unauthenticated `sys/generate-root` endpoints (off by default since 2.5.3) take the shares; the tasks call them with `curl`, since `bao operator generate-root` uses only the authenticated endpoints since OpenBao 2.6.0. `openbao:password`, `openbao:backup:role` and `openbao:restore` onto a store in use no longer need the Operator's login; `openbao:approle:issue` with `POLICY_PATH` and `openbao:approle:revoke` still do, for their other calls. Without a token, any process of the container can now start or cancel a root-token attempt (not complete one: that takes two shares). Action: none while your server's config still has its first line (the marker): it is rewritten at the next container start, which the rebuild for this version is. A config of your own (marker removed) needs `disable_unauthed_generate_root_endpoints = false` in its `listener "tcp"` block and a server restart; until then the tasks use the login as before.

### [1.3.1] - 2026-11-04

#### Fixed

- **The unseal-share prompts now say what they want.** A password typed at "Unseal share 1 of 2 (hidden):" made bao answer "'key' must be a valid hex or base64 string". Every share prompt (`init`'s follow-ups, `unseal`, `restore`, the root-token step of `approle:issue` and `approle:revoke`, `backup:role`, and `onboard:claim`) now says it wants one of the three shares `task openbao:init` printed, a long base64 string, not your Operator password; and when bao refuses a share the message names both likely causes (a password typed instead of a share, a mistyped share). No action needed. The share is still read by bao itself at its hidden prompt and never passes through the script (bao's `operator unseal` does not read a key from stdin), so the script cannot check its shape first or ask for the same share again; run the task again.
- Hardening: the tasks that ask for a share, token or password switch bracketed paste off on the terminal first (`ESC[?2004l`, only to a terminal; the shell sets it again at its next prompt), also `task openbao:login`, so a paste in a shell that leaves the mode on (pwsh) cannot carry `ESC[200~ ... ESC[201~` into bao's hidden prompt. A terminal that ignores the switch can still add the markers.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
