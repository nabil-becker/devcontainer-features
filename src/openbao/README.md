
# OpenBao CLI (openbao)

Installs the OpenBao CLI (https://openbao.org), the open-source Vault fork, as a release binary at /usr/local/bin/bao, verified against the release's checksums.txt. Owns the login state as a named volume at OPENBAO_STATE_DIR=/var/lib/devcontainer-features/openbao (bao's token helper, set through BAO_CONFIG_PATH, keeps the token in it) so `bao login` survives rebuilds, with the post-create hook openbao-setup, and installs dcf-secret, the one command the collection's Features use to read and write secrets (get, put, status, with fixed exit codes). Mode client (the default) is the CLI against a server of yours (set BAO_ADDR in containerEnv). Mode server also runs a server inside the container, started at post-start with raft storage on the same volume and sealed until the Operator unseals it: tasks openbao:init (unseal shares printed only to a terminal, a backup choice asked for), openbao:unseal, openbao:seal, userpass login for the Operator, loopback-bound AppRole roles (openbao:approle:issue) and openbao:server:status.

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
| version | OpenBao release to install (e.g. '2.7.1', with or without a leading 'v'), or 'latest'. Match your OpenBao server's version. | string | latest |

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
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/openbao.yml` in the image.

`version` and `installTaskfile` are fixed at build. `mode` has the run-time twin
`OPENBAO_SETUP_MODE`. The server address is a run-time setting: see State. In server mode it
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
- **The login**: `userpass`, user `operator`, token `ttl` **4 hours**, `max_ttl` **8 hours**; a
  renewal past 8 hours is capped (`bao token renew` says so). `task openbao:logout` ends it early. A
  night shift that must sign overnight starts with a login made for it. These lifetimes are set on
  the server this Feature runs; against another server they are its owner's.
- **The Operator's policy**: read and write everything under the `dcf` mount, the snapshot read
  (`sys/storage/raft/snapshot`, for the backup of a later version), `update` and `sudo` on
  `sys/seal`, and the **reissue of secret ids for roles that already exist** (list the roles, read a
  role's role id, list a role's secret-id accessors, destroy a secret id by accessor, make a new one).
  It may also start and cancel a root-token generation (`sys/generate-root-token/*`), which only the
  shares can complete. **Not** any policy (`sys/policies/acl/*`), not making, changing or deleting a
  role, not `snapshot-force`, audit devices, or any other `sys/` path: a token that could write a
  policy could write one with `snapshot-force` and log in through a role holding it, which would
  sidestep the rule that restore needs the shares. Making and deleting a role therefore take a root
  token made from the shares, for that step only (below).

**Agents.** `init`, `unseal`, `seal`, and the two steps that ask for the shares (making a role,
deleting a role) **refuse inside an agent's job**: when `DEVHOST_JOB_CHILD`
(the devhost's backs and its test run) or `CLAUDECODE` (set by Claude Code on every process it
starts) is set, or a variable named in `OPENBAO_AGENT_JOB_VARS` (space separated, for another agent
CLI), each saying why and exiting 3: the shares and the token must never land in a transcript, which
the scribe reads. `init`, `unseal` and those two steps also refuse without a terminal on stdin and stdout (they ask
for secrets and print them only to a terminal), and all server-mode tasks refuse in client mode.
Run them yourself in a plain terminal in the devcontainer (a terminal opened from inside a Claude
Code session inherits `CLAUDECODE` and is refused too: open a fresh one). A refusal is no call to `bao`.

**AppRole** (`task openbao:approle:issue`, `:revoke`; server mode). One role per machine identity,
generic: the Feature never calls a task of another Feature. `ROLE=<name> POLICY_PATH=<mount/path>`
**asks for the unseal shares** (it writes a policy): it makes a root token with `bao operator
generate-root` (a one-time password held in a variable, two shares typed at a hidden prompt, the
token decoded in memory), runs that step with it, and revokes it straight after, also when the step
fails or is interrupted (an abandoned generation is cancelled). No share, password or token is
printed, logged, put in a file or passed as an argument but the one-time password, which is useless
without the encoded token (that goes over stdin). It makes the role (lower case name) with a policy `approle-<name>` that lets it read that one secret
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
this version except by hand, the backs are wired in a later slice.

**`task openbao:server:status`** (both modes; exit 0 unsealed, 10 unreachable, 11 sealed or not
initialised): the mode, the address, the server's state, and in server mode the process, the
storage, the audit log, the backup choice and whether the login is valid.

**Backup, and ADR 0045.** The live store stays in the volume (tier 4): raft's database is written in
place and under a lock, which no `cloud-folder` mode promises a database. So a lost machine loses
what was written since the last backup, a **bounded-loss exception to ADR 0045 for server mode**
(ADR 0048); it is a choice, never a silent default: `init` asks, records the answer in the volume
(`backup-choice`), and `server:status` shows the destination, or a standing `WARNING no backup`.
**This version has no `openbao:backup` yet** (the next minor adds it, with restore): until then a
destination is only recorded, and a backup is `bao operator raft snapshot save` by hand. The unseal
shares, the other thing a machine loss must not take, are kept off the machine by `init`'s
instructions. A snapshot is ciphertext, useless without the shares and everything with them.

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
`audit.log`, `backup-choice`, `approle/<role>/{secret_id,role_id}`, and the login `token`.

## `dcf-secret`

The interface every Feature and script of this collection uses to read and write a secret, so
where the server runs does not matter to the caller. `openbao:kv:get` stays as the raw `bao kv
get` for people; `dcf-secret` is for callers.

```text
dcf-secret get <name> [--field <field>]    the value on stdout, nothing else (field default: value)
dcf-secret put <name> --field <field> [--replace]
                                           the value on stdin, never an argument
dcf-secret status [<name>]                 one word on stdout, the fix on stderr
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
  storage, the audit log, the backup choice (a standing warning when there is none) and the login.
- `openbao:init`: server mode, once, in a plain terminal: the backup choice, the Operator's
  password, the unseal shares (printed once to the terminal), the first unseal and the setup;
  revokes the root token. Refuses inside an agent's job.
- `openbao:unseal`: server mode: shares at the hidden prompt until unsealed. Refuses inside an
  agent's job.
- `openbao:seal`: server mode: seal the server with the saved login. Refuses inside an agent's job.
- `openbao:approle:issue`: server mode: `ROLE=<name> POLICY_PATH=<mount/path>` makes a loopback-bound
  role that reads one secret (asks for two unseal shares; refuses inside an agent's job);
  `ROLE=<name>` or `ALL=1` reissues with your login, no shares; one valid secret id each.
- `openbao:approle:revoke`: server mode: `ROLE=<name>` deletes the role, its secret ids, its policy
  and its files (asks for two unseal shares; refuses inside an agent's job).
- `openbao:setup`: re-run the post-create hook (`openbao-setup`): make the state directory usable,
  move a token left in `~/.vault-token` into it, report the token helper, the address and the saved login; in
  server mode also the start hook.

No task reads a variable besides `KEY`; the address and token come from
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
- No `openbao:backup`, restore, onboarding or `DCF_SECRET_AS` yet (later versions); in server mode a
  destination is recorded, not used. No task changes the Operator's password or a policy: both need a
  root token made from the shares (`bao operator generate-root`, used once and revoked); then `bao
  write auth/userpass/users/operator/password password=-` changes the password.
- Server mode: the shares are the keys to everything; losing two of three loses every secret. The
  loopback listener has no TLS: any process of the container can reach it and read the Operator's
  saved token (mode 600, the remote user's), as with any login kept in a volume; the token's 4 hour
  lifetime is the bound. `server.log` and `audit.log` grow without rotation. The server stops with
  the container and comes back sealed (the start hook says so); a server that does not answer is
  reported with the end of its log. Pinning `version` below 2.4.0 fails the build in server mode.
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

## Changes

### [1.2.0] - 2026-11-03

#### Added

- **Server mode: a local OpenBao server in the container.** Set the `mode` option to `server` (or `OPENBAO_SETUP_MODE=server` in `containerEnv`, no rebuild; needs OpenBao 2.4.0 or newer, and an older pinned `version` fails the build with that said). The post-start hook starts one server with raft storage on the Feature's volume and a loopback-only listener (`127.0.0.1:8200`, no TLS), and it comes up **sealed**: nothing can read a secret until you unseal it. The hook never waits and never prompts; it prints whether the server is not initialised, sealed or unsealed. `mode: client` stays the default and behaves as before. **You must act once, in a plain terminal in the container:** `task openbao:init`, then after every container restart `task openbao:unseal`.
- `task openbao:init`: asks for a **backup destination or the words `no backup`** (never defaulted, and the answer is recorded in the volume), asks for the Operator's password, makes **3 unseal shares with a threshold of 2** and prints them once, only to the terminal (keep one in a password manager, one on paper offline, one with a second person or on a hardware key; losing two loses every secret), has you enter two of them to prove you stored them, sets up the `dcf` KV mount, `userpass` and `approle`, and revokes the root token. `-pgp-keys=...` after `--` encrypts the shares.
- `task openbao:unseal` and `task openbao:seal`. `task openbao:server:status` shows the state, the storage, the audit log, whether your login is valid and the backup choice, with a standing warning while there is none. Your login is `task openbao:login -- -method=userpass username=operator`: it lasts **4 hours, at most 8**, and a renewal past that is refused.
- `task openbao:approle:issue ROLE=<name> POLICY_PATH=<mount/path>` makes a role for a machine identity (for the devhost's backs, later) that may read that one secret, only from inside the container (loopback-bound secret ids and tokens), with 5 minute tokens; `ROLE=<name>` alone or `ALL=1` reissues, leaving exactly one valid secret id per role, written to the volume and never printed. `task openbao:approle:revoke ROLE=<name>` removes a role. **Making a role and deleting one ask for two unseal shares** (typed at a hidden prompt, they make a root token, `bao operator generate-root`, used for that step only and revoked straight after, also on failure); reissuing (`ROLE=<name>` alone, `ALL=1`) uses your login and asks for none. Your login's policy cannot write a policy or make, change or delete a role, so a token of yours can never give a role `snapshot-force`.
- A file audit device in the volume (`audit.log`), declared in the server's config.
- **Not included yet:** `openbao:backup` and restore. A backup destination is recorded but not used, so until a later version a lost machine loses what is in the server's volume (this is why `init` asks and `server:status` warns); take a snapshot by hand with `bao operator raft snapshot save`.

#### Changed

- **`init`, `unseal`, `seal` and the two steps that ask for shares (making and deleting a role) refuse inside an agent's job** (when `DEVHOST_JOB_CHILD` or `CLAUDECODE` is set, or a variable you name in `OPENBAO_AGENT_JOB_VARS`), and `init`, `unseal` and those two steps refuse without a terminal: the shares and the token must never land in a transcript. Run them yourself in a plain terminal.
- `dcf-secret`'s failure lines now name the tasks: sealed points to `task openbao:unseal`, not initialised to `task openbao:init`, unreachable to `task openbao:server:status`, each adding what to do against a server elsewhere. The exit codes are unchanged.
- In server mode `BAO_ADDR` defaults to the local server for `dcf-secret` and every task when you have not set it (a bare `bao` still needs `BAO_ADDR`). The tasks `status`, `login`, `logout`, `kv:get` and `setup` run the same `bao` call through `openbao-run`, which adds only that default; client mode is unchanged. `task openbao:setup` now also runs the start hook.

### [1.1.0] - 2026-11-03

#### Added

- **Your `bao login` now survives a rebuild.** The Feature owns a named volume (`openbao-config-<devcontainerId>`, at `/var/lib/devcontainer-features/openbao`, named by `OPENBAO_STATE_DIR`) and points `bao` at a token helper (`BAO_CONFIG_PATH`, set in `containerEnv`, so it holds for `devcontainer exec` too) that keeps the token there, as `gh` and `az` keep their logins. The post-create hook, `openbao-setup` (also `task openbao:setup`), makes the folder usable and moves a token left in `~/.vault-token` into it once. **You must act once:** rebuild the container and run `bao login` again, because the volume starts empty. A repo that sets its own `BAO_CONFIG_PATH` replaces the Feature's config (the hook says so); add `token_helper = "/usr/local/bin/openbao-token-helper"` to it. A repo that wants the state on the host disk bind-mounts the same target. A `BAO_TOKEN` in the environment still takes precedence over the saved login.
- **`dcf-secret`**, a command for scripts and other Features to read and write a secret without knowing where the server runs: `dcf-secret get <name>`, `dcf-secret put <name> --field <field>` (the value on stdin) and `dcf-secret status`. `put` writes only that field and keeps the secret's other fields (it creates the secret when it does not exist); `--replace` makes the secret exactly that one field. A token whose policy lacks the `patch` capability is refused with exit 13 rather than silently replacing the secret. It fails with fixed exit codes (10 unreachable, 11 sealed, 12 not logged in, 13 denied, 14 no such secret), each with one line saying what to do, and never falls back to a key on disk. Secrets live in a KV v2 mount named `dcf` (`DCF_SECRET_MOUNT` changes it). Nothing to do unless you want it; `task openbao:kv:get` is unchanged.
- **The `mode` option**, with the one value `client` (the default, what the Feature always did: the CLI against a server outside the container). A later version adds `server`. `OPENBAO_SETUP_MODE` in `containerEnv` overrides it per container. Nothing to do.
- `task openbao:logout`: revokes your token on the server and erases the saved one, so no login is left behind (`bao token revoke -self` alone leaves the dead token stored, and `dcf-secret` then says to log in). Nothing to do unless you log out.
- `task openbao:setup`: re-runs the post-create hook.

### [1.0.4] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
