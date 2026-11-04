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
  `sys/seal`, AppRole roles and secret ids (`auth/approle/role/*`), and policies named `approle-*`
  (what `openbao:approle:issue` writes). **Not** `snapshot-force`, audit devices, or any other policy
  or `sys/` path. Whoever can write a role and its policy can act as that role, so the Operator's
  token is the strongest thing short of the shares; it lasts 4 hours.

**Agents.** `init`, `unseal` and `seal` **refuse inside an agent's job**: when `DEVHOST_JOB_CHILD`
(the devhost's backs and its test run) or `CLAUDECODE` (set by Claude Code on every process it
starts) is set, or a variable named in `OPENBAO_AGENT_JOB_VARS` (space separated, for another agent
CLI), each saying why and exiting 3: the shares and the token must never land in a transcript, which
the scribe reads. `init` and `unseal` also refuse without a terminal on stdin and stdout (they ask
for secrets and print them only to a terminal), and all server-mode tasks refuse in client mode.
Run them yourself in a plain terminal in the devcontainer (a terminal opened from inside a Claude
Code session inherits `CLAUDECODE` and is refused too: open a fresh one). A refusal is no call to `bao`.

**AppRole** (`task openbao:approle:issue`, `:revoke`; server mode). One role per machine identity,
generic: the Feature never calls a task of another Feature. `ROLE=<name> POLICY_PATH=<mount/path>`
makes the role (lower case name) with a policy `approle-<name>` that lets it read that one secret
and nothing else, **bound to loopback**: `secret_id_bound_cidrs` and `token_bound_cidrs` of
`127.0.0.1/32`, so a stolen secret id or token works only from inside this container, and only while
the server is unsealed; tokens last 5 minutes, at most 15; secret ids do not expire (an expiring one
would stop the backs on a date nobody is watching). `ROLE=<name>` alone reissues an existing role,
and `ALL=1` every role in the store (after a restore or on suspicion). A reissue leaves **exactly one
valid secret id**: the others of the role are destroyed by their accessors first (issuing a new one
does not end the old). The secret id and the role id are written to `approle/<role>/secret_id` and
`role_id` in the volume (mode 600, folder 700), never printed. `approle:revoke ROLE=<name>` deletes
the role (OpenBao's role deletion destroys its secret ids), its policy and its files; a token it
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
the receiver has no token that may start a generation. The claim token is a root token that
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
  role that reads one secret; `ROLE=<name>` or `ALL=1` reissues; one valid secret id each.
- `openbao:approle:revoke`: server mode: `ROLE=<name>` deletes the role, its secret ids, its policy
  and its files.
- `openbao:onboard:export`: `NAMES=<name>,... DEST=<folder>`: a starter instance with the named
  keys, snapshot into DEST, fresh shares and a claim token printed once. A plain terminal.
- `openbao:onboard:claim`: server mode, after `openbao:restore`: rotate-keys, revoke everything the
  sender held, reissue, rotate; `ROTATE=0` skips the data key rotation. A plain terminal.
- `openbao:wrap`: `NAMES=<name>,... [TTL=15m] [OUT=<file>] [SHOW=1]`: one one-use token per secret.
- `openbao:unwrap`: `FROM=<file> [ISSUER_ADDR=<server>]`: look up, check, unwrap once, `dcf-secret put`.
  The four refuse inside an agent's job.
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

**1.3.0** adds onboarding (`openbao:onboard:export`, `:onboard:claim`, `openbao:wrap`, `:unwrap`,
`openbao-onboard`) and installs `jq` at build (a dependency the onboarding scripts read bao's JSON
with): additive, rebuild to get them.
