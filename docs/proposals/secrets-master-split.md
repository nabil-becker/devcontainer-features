# Proposal: OpenBao is the master of secrets, ssh-agent only does SSH

Status: Proposed 2026-11-03. The Operator's decisions (section 1) are fixed; the design around them
and the open points (section 14) await the architecture review and the Operator. Build not started.

Who this serves: the engineers and the consumers' maintainers who use the `ssh-agent` and `openbao`
Features (they get one place where keys and tokens live, and one gate to open it), and the
Operator, who rules on the proposal and holds the gate.

## 1. The ask, and what the Operator decided

The ask: `ssh-agent`'s key mode has grown a key store (a volume, `key:new`, `key:rotate`,
`key:retire`, `key:age`, `key:unlock`), and the register's operator key now lives there (ADR 0046).
Secrets and their lifecycle belong in a secrets manager, and this collection already ships one
(the `openbao` Feature, CLI only today). The Operator's decisions, as given:

1. **OpenBao is the master of secrets and credentials.** It keeps every private key (ssh, git
   signing, the register's operator and back keys), every token (gh, Azure, the cloud folder's
   login) and their lifecycle (create, rotate, retire, age). **ssh-agent provides SSH only**, in
   the container: the agent socket, host-agent forwarding, git commit signing and verification
   through the agent, and `key:load` / `key:lock` of a key fetched from OpenBao into agent memory
   with a lifetime. The key storage of `keyMode` (its volume and the `key:new`, `rotate`,
   `retire`, `age`, `unlock` tasks) moves to OpenBao.
2. **The openbao Feature gets two modes:** `client` (the default: the `bao` CLI only, `BAO_ADDR`
   pointing at a server outside the container) and `server` (the client plus a server run inside
   the container at post-start, sealed until the Operator unseals it). The server's storage obeys
   ADR 0045: losing a machine loses nothing.
3. **The master gate:** the Operator unseals the server once per server start (Shamir shares,
   `bao operator unseal`); `bao login` per sitting gives a token that expires. This replaces ADR
   0046's passphrase unlock. Unattended backs (scribe, secretary, librarian, tester) get their own
   OpenBao identities that work once the server is unsealed.
4. **Migration:** import the keys of ssh-agent's volume into OpenBao, deprecate key mode's key
   tasks in a minor version, remove them in the next major, and supersede ADR 0046 with a new ADR
   (written when the proposal is accepted, not here).
5. **Git signing:** the signing key lives in OpenBao as a long-lived key, its public key stays
   registered at GitHub as a signing key, and ssh-agent loads it for the sitting.
   `allowed_signers` comes from OpenBao or the repository (chosen in section 8). SSH certificates
   (OpenBao's SSH engine) are not relied on for GitHub (checked in section 8).

## 2. The split in one picture

```
                         the Operator
                 unseal (once per server start)   login (per sitting, token with a TTL)
                               |                         |
                               v                         v
  +--------------------------- openbao Feature ------------------------------+
  |  mode=server: bao server, post-start, sealed at start                     |
  |    storage: raft on the openbao volume (tier 4)                           |
  |    snapshots ----------------------------> shared folder (tier 2)         |
  |  mode=client: no server, BAO_ADDR points elsewhere                        |
  |                                                                           |
  |  KV v2 mount "dcf":  ssh/<key>   register/<principal>   token/<name>      |
  |  auth: userpass (the Operator)    approle (one role per back)             |
  |  lifecycle tasks: openbao:ssh:new | import | rotate | retire | age        |
  |                                                                           |
  |  dcf-secret get|put|status   <- the one interface every caller uses       |
  +----------------------------------+----------------------------------------+
                                     | private key on stdin, never a file
                                     v
  +--------------------------- ssh-agent Feature ----------------------------+
  |  SSH_AUTH_SOCK (fixed path)  host socket mounted, or an in-container agent|
  |  key:load NAME= [MINUTES=]   dcf-secret get ... | ssh-add -t <life> -     |
  |  key:lock NAME=              ssh-add -d                                    |
  |  git:signing, git:verify     public key from ssh-add -L, allowed_signers  |
  |  no key volume, no key at rest                                            |
  +---------------------------------------------------------------------------+
         ^                       ^                           ^
     git commit -S         agentic-register             gh / az / cloud-folder
   (the Operator's         (operator acts: agent;       (tokens: section 11)
    sitting)                backs: section 7)
```

What goes where:

| Thing | Today | After |
|---|---|---|
| ssh and git signing private keys | ssh-agent key volume (`ssh-agent-key-*`) | OpenBao `dcf/ssh/<key>` |
| Key creation date, age | `<name>.meta` sidecar in the key volume | KV v2 metadata (`created_time`, custom metadata) |
| `allowed_signers.history` | the key volume | the repository (section 8) |
| Register operator key | ssh-agent key volume, passphrase (ADR 0046) | OpenBao `dcf/register/<principal>` |
| Register back keys | agentic-register volume `keys/<principal>` | OpenBao `dcf/register/<principal>` |
| gh, Azure, cloud-folder logins | each Feature's volume | OpenBao `dcf/token/<name>` (section 11) |
| The unlock | the key's passphrase, per key | the unseal (per server start) and the login (per sitting) |

## 3. The openbao Feature's two modes

One new option, `mode`, `client` (default) or `server`, overridable per container with
`OPENBAO_MODE` in `containerEnv` (NFR-6). A consumer that changes nothing keeps today's Feature.

**Both modes** get what `openbao-state-build` already plans (NFR-1): a named volume
`openbao-${devcontainerId}` on `/var/lib/devcontainer-features/openbao`, a setup script
`openbao-setup` run by `dcf-persist`, and the login token kept there (`~/.vault-token` linked into
the volume), so a rebuild no longer logs out. That backlog item is the first slice of this work,
not a separate one. Both modes also install `dcf-secret` (section 6).

**Server mode** adds:

- **The start hook** (`postStartCommand`, `openbao-setup start`) writes the server's config into the
  volume if it is missing, starts `bao server` in the background (its PID in the volume; a live one
  is reused), and prints one line: `openbao: server started, sealed; the Operator runs task
  openbao:unseal`, or, on the first start, `not initialised; task openbao:init`. It never waits
  for an unseal and never prompts: the lesson of `ssh-passphrase-wait` (a start hook that waits
  holds every Feature's start).
- **The config**: storage `raft` at `/var/lib/devcontainer-features/openbao/raft`, `node_id` fixed
  (`devhost`); one `tcp` listener on `127.0.0.1:8200` with TLS off (it never leaves the
  container's loopback; another container cannot reach it); `cluster_addr` on `127.0.0.1:8201`;
  `disable_mlock = true` (a container has no `IPC_LOCK` by default; raft storage is recommended
  with it); no UI. `BAO_ADDR` defaults to `http://127.0.0.1:8200` in server mode.
- **Tasks**: `openbao:init` (once: `bao operator init` with the shares of section 9, enables the
  `dcf` KV v2 mount, `userpass` for the Operator, `approle` for the backs, the file audit device in
  the volume, the policies; prints the shares once and revokes the root token at the end),
  `openbao:unseal` (asks for a share at `bao operator unseal`'s own prompt until the threshold is
  met), `openbao:seal`, `openbao:snapshot`, `openbao:restore FILE=<snapshot>`,
  `openbao:server:status`. `openbao:login` and `openbao:status` exist already.
- **The shutdown check** (ADR 0022): `openbao:snapshot` contributes to `shutdown:check` when the
  server is unsealed and the Operator's token is valid; otherwise it says why it did not snapshot
  and does not refuse the stop (every write was snapshotted when it was made, section 4).

**Client mode** is today's Feature plus the volume and `dcf-secret`. The server's address,
TLS and auth method are the server owner's; the Feature only needs the `dcf` mount layout of
section 6 (or `DCF_SECRET_MOUNT` naming another mount).

## 4. Where the server's storage goes (ADR 0045)

The rule: if losing a machine would lose something, it is in the wrong tier. The server's data
cannot be rebuilt (it is the keys), so it must reach tier 1 or 2. Tier 1 (git) is out: a public
repository. So tier 2, the shared folder. The question is whether the live store can sit there.

**What OpenBao's storage needs.** OpenBao keeps two embedded backends: `raft` (integrated storage,
whose database is bbolt) and `file`. The `file` backend is "a development-only, non-production
backend", deprecated in v2.6.0 and **removed in v2.7.0** (OpenBao's deprecation page), and the
Feature's default `version` is `latest`, so `file` is not an option. Raft's bbolt database is one
file written in place with random writes, memory-mapped, `fsync`ed and held under an exclusive
lock; raft also writes a log and renames snapshot files.

**What the shared folder gives** (the `cloud-folder` Feature's three modes):

| Mode | What the live raft store would meet |
|---|---|
| `host` (the sync client's folder bind-mounted) | the engine's file share from Windows; the sync client uploads a database that is being written, and a second machine would open the same file |
| `sync` (rclone bisync) | a copy made between writes, never a consistent one; a file changed on two machines is kept twice as `.conflict1` / `.conflict2` and nothing picks a winner |
| `mount` (rclone FUSE, `--vfs-cache-mode writes`) | no hard links (`register-store-no-hardlink`), and no guarantee for in-place random writes, the lock or `fsync` reaching the remote |

Raft needs no hard links, so the limit the register store met does not apply. But none of the
three modes promises a consistent single-writer database, and each lets a second machine open the
same store. **The live store never goes into tier 2.**

**The design: a volume, backed up to the shared folder.**

```
 tier 4: openbao volume (per container)          tier 2: shared folder
   raft/            live store, rebuildable  -->   <snapshotDir>/openbao-<UTC time>.snap
   audit.log        audit device                     write-once, never overwritten,
   approle/<back>   the backs' secret ids            the last N kept (option, default 30)
   .vault-token     the Operator's login
```

- `openbao:snapshot` runs `bao operator raft snapshot save` to a file in the volume, then copies it
  whole into `snapshotDir` under a new name. A snapshot is written once and never changed, so it
  suits all three modes (a new file is never a conflict in `sync`, and a plain create needs no
  hard link in `mount`).
- **Every task that writes a secret snapshots right after it** (`openbao:ssh:*`, `dcf-secret put`,
  `openbao:approle:*`), and the shutdown check takes one more. What a machine loss can lose is then
  only what can be rebuilt: tokens and leases issued since (the next login makes new ones) and the
  backs' secret ids (reissued at restore, section 7). That is the ADR 0045 test passed.
- **A snapshot is ciphertext**: the store is encrypted by OpenBao's barrier, and the barrier key is
  protected by the unseal shares. A snapshot without the shares is useless; with them it is
  everything. So the shares never go to the shared folder (section 9).
- **A new option `snapshotDir`**: default `/mnt/cloud-folder/openbao` when the `cloud-folder`
  Feature is installed, empty otherwise. In server mode with no usable `snapshotDir`, the start hook
  and `openbao:server:status` warn on every start (`no snapshot folder: a machine loss loses every
  secret`), and `openbao:snapshot` refuses. It does not block the start.
- **A new machine** (or a reset volume): `task openbao:init` refuses when `snapshotDir` holds
  snapshots and names `task openbao:restore`, which starts a fresh server, restores the newest
  snapshot (`snapshot restore -force`), and leaves it sealed for the original shares.
- **Two machines**: each runs its own server from its own volume. Two live servers both
  snapshotting into one folder would fork the secrets. The snapshot carries the writing machine's
  name; `openbao:restore` and the start hook warn when the newest snapshot in the folder is from
  another machine than the store's last one. Which machine is the master is section 14, decision 3.

## 5. The gate: unseal, login, and what each step opens

```
 container start          the Operator                      the Operator
      |                    task openbao:unseal               task openbao:login
      v                    (threshold of shares)             (userpass, per sitting)
  [ sealed ] ----------------------> [ unsealed ] ----------------> [ Operator token ]
   nothing works            backs log in with AppRole         ssh keys, register operator
   dcf-secret: exit 11      (their own paths only)            key, tokens, lifecycle tasks
                                                               TTL ends -> exit 12
```

- **Unseal** once per server start. It opens the store; by itself it lets nobody read anything.
- **The Operator's login** is `userpass` (one user, a password the Operator keeps) in server mode;
  in client mode it is whatever the server offers (`task openbao:login -- -method=oidc`). The token's
  TTL is section 9.
- **What the Operator's policy allows**: read and write everything under `dcf/`, snapshots,
  AppRole secret ids; not `sys/` beyond that. The root token is revoked after `init` and made again
  only from the shares (`bao operator generate-root`) when a policy must change.

## 6. How a Feature asks for a secret: `dcf-secret`

One small executable, installed by the openbao Feature in both modes, named like the collection's
other shared helpers (`dcf-persist`, `dcf-curl`). Every caller (ssh-agent, agentic-register, gh,
az, cloud-folder, the devhost) uses it and nothing else, so where the server runs does not matter to
the caller.

```
dcf-secret get <name> [--field <field>]      the value on stdout, nothing else
dcf-secret put <name> --field <field>        the value on stdin (never an argument)
dcf-secret status                            one line: ready | sealed | unreachable |
                                             logged-out | denied | not-initialised
```

- **Names are logical**: `ssh/<key>`, `register/<principal>`, `token/<name>`. They map onto
  `<DCF_SECRET_MOUNT>/<name>` (default mount `dcf`), so a client-mode consumer on a shared server
  points `DCF_SECRET_MOUNT` at its own mount and nothing else changes.
- **Who asks**: the token in the environment (`BAO_TOKEN`, or the volume's login) by default; with
  `DCF_SECRET_AS=<principal>` it logs in first with that back's AppRole (section 7).
- **Exit codes**, the same for every caller, each with one plain line on stderr naming the fix:

| Exit | Meaning | The line names |
|---|---|---|
| 0 | the value is on stdout | |
| 10 | the server is unreachable (`BAO_ADDR` wrong, server not running, no openbao Feature) | `task openbao:server:status` or `BAO_ADDR` |
| 11 | the server is sealed | `task openbao:unseal` (the Operator) |
| 12 | no token, or it expired | `task openbao:login` |
| 13 | the token may not read this name | the policy |
| 14 | no such secret | `task openbao:ssh:import` or `:new` |

- **It is a thin wrapper**: `bao kv get -field=...` and `bao kv put ... field=-` with the exit
  codes mapped. It does not re-implement the CLI (NFR-13), and it works the same against a Vault
  server, whose API the `bao` CLI speaks.
- **No fallback, ever.** A caller that gets a non-zero exit fails with that line. Nothing reads a
  key from a volume, a file or an environment variable instead. This is the rule that makes
  OpenBao the master: a second source would be a second master.
- **A caller without the openbao Feature** finds no `dcf-secret` and says so (`install the openbao
  Feature`); the Features stay independent at build time (no new `installsAfter` is needed, and an
  unpublished Feature could not be named in one anyway).

## 7. The backs' identities

**Choice: AppRole**, one role per back (`scribe`, `secretary`, `librarian`, `tester`), each with a
policy that reads only `dcf/register/<its principal>`.

Why AppRole:

- It is OpenBao's method for machines that log in without a person: a `role_id` (not secret) and a
  `secret_id` (the credential), each login giving a short token.
- Each back is its own identity in the audit log, and one back can be cut off
  (`openbao:approle:revoke BACK=`) without touching the others.
- `secret_id_bound_cidrs` and `token_bound_cidrs` of `127.0.0.1/32`: a stolen `secret_id` works
  only from inside this container, and only while the server is unsealed.

Rejected: a long-lived periodic token per back in a file (simpler, but a bearer token with nothing
to rotate it and no login step to bind); the `cert` method (a client certificate per back is a
second PKI to keep); TLS or a Kubernetes-style platform identity (the container has none to offer).

**How a back signs a register entry.** A back runs `DCF_SECRET_AS=scribe dcf-secret get
register/scribe --field private_key` into a file on tmpfs (`/dev/shm`, mode 0600, its own
folder), signs with `agentic-register ... --key <that file>`, and removes it on exit, success or
failure. It does **not** load its key into the SSH agent: in socket mode the agent is the
workstation's own, and a back's key would then sit in the host's agent. The token lives for that
one act (`token_ttl` 5 minutes, `token_max_ttl` 15).

**The bootstrap secret.** Each back's `secret_id` lives in the openbao volume
(`approle/<back>/secret_id`, mode 0600). It is the one credential at rest in the container, and it
is worth only what the server allows: nothing while sealed, one back's key while unsealed, from
loopback. `openbao:approle:issue` makes the secret ids (at `init`, at `restore`, and on suspicion);
they are tier 4 because they can be reissued.

**When the server is sealed**, a back exits non-zero with the `dcf-secret` line and records it in
its metrics line; it must not mark its stretch as read, so its next run after the unseal does the
work. The briefing shows one line while the server is sealed (`OpenBao sealed: the backs cannot sign;
task openbao:unseal`). The slice that wires the backs checks this against the backs' code.

**The Operator's register key** is used in the Operator's sitting, through the agent:
`task ssh-agent:key:load NAME=register/operator-1 MINUTES=15`, then the register's `--key
<public key>` signs through the agent, as the register already supports, and `key:lock` or the
lifetime ends it. That is ADR 0046's flow with the passphrase replaced by the login.

## 8. Git signing

- **The key**: one long-lived ed25519 signing key per purpose, created by `openbao:ssh:new` (named
  `<repo>-<container>-sign` as today), kept at `dcf/ssh/<name>` with fields `private_key`,
  `public_key`, `purpose` (`git-signing`) and the creation date in the KV metadata. Its public key
  is registered at GitHub as a **signing** key (through `gh` when logged in, as `key:rotate` does
  today).
- **The sitting**: `task ssh-agent:key:load NAME=ssh/<name> [MINUTES=]` fetches it with
  `dcf-secret`, pipes it to `ssh-add -t <seconds> -` (the key is read from stdin, never written to a
  file; checked with OpenSSH 10.0: `ssh-add -t 60 -` loads a key from stdin, and `ssh-keygen -Y sign`
  then signs through the agent with only the `.pub` present), and says the clock time it drops out.
  The default lifetime is what is left of the Operator's token; `MINUTES` may shorten it.
  `git:signing` and `git:verify` are unchanged.
- **Generation without a file at rest**: `openbao:ssh:new` and `:rotate` run `ssh-keygen` in a
  private folder on tmpfs, `put` the key, and remove the folder. No passphrase is set: the gate is
  the login now (decision 3), and a second passphrase per load would bring back ADR 0046's prompt.
- **Rotation** keeps today's four steps and their order (make and load the new key, register it,
  point git at it and verify, then retire the old), moved to `openbao:ssh:rotate`; retiring destroys
  the old private key's versions in KV and keeps its metadata, dated.

**`allowed_signers`: from the repository.** The file is committed (path in section 14, decision 5),
one line per key with `namespaces="git"` and `valid-after` / `valid-before`, and `git:signing`
points `gpg.ssh.allowedSignersFile` at it. Why the repository and not OpenBao:

- Public keys are not secrets, and verifying must work where there is no server: CI, another
  engineer's container, the Operator's workstation, a sealed devhost.
- Who may sign this repository's history is a reviewed decision, and git is the reviewed record
  (tier 1). A key added or retired is a line in a pull request.
- It replaces `allowed_signers.history`, which sits in a volume today and goes with it.

`openbao:ssh:new`, `:rotate` and `:retire` write the line into the working tree; the commit is the
host's (ADR 0040).

**SSH certificates and GitHub (checked 2026-11-03).** GitHub's "About commit signature verification"
says an SSH signature is checked as "cryptographically verifiable against a public key you have added
to your account", requires Git 2.34 or later, and nowhere mentions SSH certificates or certificate
authorities (the only certificate authority on that page is for S/MIME). A search found no GitHub
statement of support and one community question about it left unanswered. So the host's belief
holds as far as the documentation goes: **GitHub is not documented to verify a commit signed with an
SSH certificate**, and this design does not rely on it. (Locally, `ssh-keygen` accepts a
`cert-authority` line in `allowed_signers`, so certificates could serve local verification; not
needed here.)

One more finding from the same page: "once a commit signature is verified, it remains verified within
its repository's network", even if the key is later revoked. That changes the trade-off `REVOKE=1`
describes today (section 13).

## 9. Security trade-offs

| | ADR 0046 today | This proposal |
|---|---|---|
| Key at rest | a passphrase-protected file in the key volume | encrypted by OpenBao's barrier in the raft volume and in each snapshot |
| What opens it | the passphrase, per key, per load | the unseal shares, per server start; the Operator's login, per sitting |
| A back's key | a plain file in the register's volume | readable only through the back's AppRole, while unsealed |
| Lost machine | the volume is gone; the key must be on the host too | restore the newest snapshot, unseal with the shares |
| Audit | none | the file audit device names every identity that read a key |
| Revoking one back | rekey that back | revoke its secret id; the others carry on |

The costs, plainly:

- **The unseal shares are now the keys to everything.** Recommendation (section 14, decision 1):
  three shares, threshold two: one in the Operator's password manager, one on paper kept offline,
  one with a second trusted person or a hardware key. Never in git, never in the container, never in
  the shared folder beside the snapshots. Losing two of three loses every secret; that is why
  section 14 decision 2 keeps one register anchor outside OpenBao.
- **The Operator's token sits in the volume for the sitting**, readable by any process of the remote
  user, as an unlocked key sits in the agent today. Its TTL bounds it. Recommendation (decision 4):
  `ttl` 4 hours, `max_ttl` 8 hours (480 minutes, the limit `key:unlock` has today), no renewal past
  it; `task openbao:logout` (or `bao token revoke -self`) ends a sitting early.
- **The backs' secret ids are at rest** in the volume (section 7). Any process of the same user can
  read them and act as a back while the server is unsealed: the same exposure as the register's
  `keys/<principal>` today, now logged, narrowed to one path each, loopback-only and revocable.
  Separating the backs by user is not proposed.
- **A server runs in the container**: one more process and a loopback listener without TLS. Only
  processes in the container reach it, and they can already read the token file; TLS would add a
  certificate to keep and protect nothing more.
- **`disable_mlock`**: the server's memory may be swapped. Containers do not grant `IPC_LOCK` by
  default; granting it is a launcher change not proposed here.
- **No fallback** (section 6) means a sealed server stops signing. That is the intended price:
  an agent that cannot reach the master must not find a key elsewhere.

## 10. Migration (decision 4)

```
 ssh-agent 1.3.0                  ssh-agent 1.4.0 (minor)               ssh-agent 2.0.0 (major)
 key volume + key tasks   --->    key:load/lock from OpenBao       ---> no key volume, no key tasks
                                  old key tasks warn "deprecated:       in-container agent kept
                                  task openbao:ssh:<verb>"              (memory only)
                                  openbao:ssh:import FROM=ssh-agent
```

1. **Import**: `task openbao:ssh:import FROM=ssh-agent` reads each private key of the key volume,
   asks once for the passphrase of a protected one (at `ssh-keygen -p`'s own prompt, on a tmpfs
   copy), puts it under `dcf/ssh/<name>` with its creation date from the `.meta` sidecar, appends
   `allowed_signers.history` to the repository's file, compares fingerprints, loads one key and runs
   `git:verify`. Only then does it offer to delete the volume's copy (asks, never by default), so a
   key is never in two masters for longer than the import. `FROM=agentic-register` does the same for
   the register's `keys/<principal>`, then `openbao:approle:issue` gives each back its identity.
   `FROM=file FILE=` (and the launcher's streaming twin of `devcontainer:ssh-key-import`) takes a
   key from the workstation.
2. **Deprecate** (ssh-agent 1.4.0): `key:new`, `key:add`, `key:rotate`, `key:retire`, `key:age`,
   `key:unlock` and `key:remove DELETE=1` keep working on the volume and print one line naming the
   `openbao:ssh:*` task that replaces them. `key:load NAME=` and `key:lock NAME=` take an OpenBao
   name (`ssh/<key>`, `register/<principal>`); `key:load` with no `NAME` keeps loading the volume's
   keys until 2.0, with the same warning. The start hook never fetches from OpenBao (it never waits
   and never asks).
3. **Remove** (ssh-agent 2.0.0): the key volume's mount, the deprecated tasks and the volume code go.
   The in-container agent stays (Windows engines still need an agent to load into); the option is
   renamed (decision 6). Removing a mount does not delete the volume: the 2.0 notes say to run the
   import first and remove the old volume with the engine's own command.
4. **ADR 0046 is superseded** by a new ADR when this is accepted: the register's operator key lives
   in OpenBao and is loaded for a sitting by `key:load`, gated by the unseal and the login.

**What changes for a consumer using key mode today** (this devhost, and the consumer whose request
led to ADR 0046):

| Step | Who | What |
|---|---|---|
| 1 | maintainer | `openbao` with `"mode": "server"` (and `cloud-folder` for `snapshotDir`) in `devcontainer.json`; ssh-agent to 1.4.0 (`:1` picks it up); rebuild |
| 2 | the Operator, once | `task openbao:init`, store the shares; `task openbao:unseal`; `task openbao:login` |
| 3 | the Operator, once | `task openbao:ssh:import FROM=ssh-agent`, then `FROM=agentic-register`; commit the `allowed_signers` file |
| 4 | everyone | `key:unlock NAME=<file>` becomes `key:load NAME=ssh/<file> MINUTES=`; each sitting starts with `openbao:login` (and, after a container start, the Operator's `openbao:unseal`) |
| 5 | maintainer, at 2.0 | move to `ssh-agent:2` and rename the option; remove the old volume |

`SSH_AGENT_MODE=key` stays meaningful (it still starts the in-container agent). A consumer in socket
mode that never used key mode changes nothing, and a consumer that does not install openbao keeps
ssh-agent 1.x working as it is until it moves to `:2`.

## 11. Tokens (gh, Azure, the cloud folder)

Decision 1 puts them in OpenBao too. They differ from keys in one way that matters: `az` and
rclone refresh their tokens themselves and write the new one back into their own files. So the
proposal is that OpenBao holds the **long-lived credential** (a gh token, a service principal or
refresh token, rclone's config), the Feature's setup fetches it with `dcf-secret` into its volume at
the sitting's start, and the tool's own refreshed copy in the volume is tier 4 (rebuildable from
OpenBao). A Feature that writes back a refreshed long-lived credential puts it back with
`dcf-secret put`. This is the last slice and section 14, decision 7, asks whether to take it now.

## 12. Blast radius

| Part | Change | Version |
|---|---|---|
| `openbao` | volume and `openbao-setup` (`openbao-state-build`), `dcf-secret`, `mode`, server, `snapshotDir`, `openbao:init/unseal/seal/snapshot/restore/server:status`, `openbao:ssh:*`, `openbao:approle:*` | 1.1.0, 1.2.0, 1.3.0 (all additive, default `client`) |
| `ssh-agent` | `key:load`/`key:lock` from OpenBao, deprecations | 1.4.0 |
| `ssh-agent` | the key volume and key tasks removed, option renamed | 2.0.0 (breaking) |
| `devcontainer-cli` | `devcontainer:ssh-key-import` deprecated in favour of a host task that streams into `openbao:ssh:import FROM=file` | minor |
| `agentic-register` (local) | backs sign from `dcf-secret` on tmpfs; `keys/<principal>` deprecated | minor |
| `devhost` (local) | backs' AppRole, the sealed line in the briefing, the snapshot in the shutdown check | minor |
| `gh`, `az`, `cloud-folder` | fetch their credential with `dcf-secret` (section 11) | minor each, last |
| `git`, `go-task` | none | |

Consumers: **both**, the office and software project 1, pin `ssh-agent:1` and get the
deprecation lines with 1.4.0; the one that uses key mode for its operator key migrates (section
10); nothing breaks for either until they choose `ssh-agent:2`. Because the ssh-agent major and the
server mode reach every consumer, those slices are sized for the strongest model; the others are
Sonnet work.

Slices, each one pull request with its version bump and `task docs`:

1. openbao 1.1.0: the volume and setup hook (`openbao-state-build`), `dcf-secret`, the `mode` option
   with `client` only.
2. openbao 1.2.0: server mode, raft on the volume, snapshots, init, unseal, restore, userpass,
   AppRole, the shutdown-check contribution.
3. openbao 1.3.0, ssh-agent 1.4.0, devcontainer-cli minor: `openbao:ssh:*`, the import,
   `key:load`/`key:lock` from OpenBao, the deprecations, `allowed_signers` from the repository.
4. agentic-register and devhost: backs on AppRole, the briefing line; the ADR superseding 0046.
5. gh, az, cloud-folder: credentials from `dcf-secret` (if decision 7 says now).
6. ssh-agent 2.0.0: the removal, after at least one release of 1.4.0 has been adopted by both consumers.

Tests are Docker-free where they can be: `dcf-secret` against a fake `bao` (each exit code, no
fallback when sealed), the import against a key volume made in a temp folder, the key piped to
`ssh-add -` never touching a file (checked by the folder staying empty), the snapshot naming and
retention, and the start hook returning at once on a sealed server. The server itself (`bao server
-dev` is not enough for raft and seal) is a Feature test that needs a Docker daemon.

## 13. For the repository (found while writing)

- `src/ssh-agent/NOTES.md` says that after `REVOKE=1` "old commits show unverified at GitHub". GitHub's
  documentation now says a commit verified once stays verified in its repository's network even if
  the key is revoked. The note should say that, and `REVOKE=1` loses less than it says (only commits
  GitHub had not yet verified).
- The openbao Feature's default `version: latest` will install a release without the `file`
  backend (removed in v2.7.0); nothing uses it today, but the NOTES could say raft is the only
  embedded storage.

## 14. Decisions needed

1. **Unseal shares and custody.** Recommendation: three shares, threshold two (password manager,
   paper offline, a second person or a hardware key); never in git, the container or the shared
   folder. Alternative: one share, threshold one (simplest; one loss or one leak is total).
2. **One register anchor outside OpenBao.** The register's README advises two operator anchors so
   losing one never closes the rosters. Recommendation: the second anchor's private key stays offline,
   outside OpenBao, as the recovery key if the shares are lost. This is an exception to "every
   private key in OpenBao" (decision 1), so it is the Operator's.
3. **Which machine is the master when two run a server.** Recommendation: one machine's server
   is the master; another machine restores from its snapshots and is used read-only for secrets
   (its lifecycle tasks refuse while its store is older than the folder's newest snapshot from
   another machine). Alternative: a single server outside every container, which is client mode.
4. **The Operator's token TTL.** Recommendation: `ttl` 4 hours, `max_ttl` 8 hours, no renewal past
   it; a key loaded by `key:load` lives at most until the token ends. A night shift that must sign
   overnight is started with a login made for it (the 8-hour limit covers a night).
5. **Where `allowed_signers` lives in the repository.** Recommendation:
   `.devcontainer/allowed_signers`, beside the rest of the container's definition, which every
   consumer already has; `git:signing` takes another path with `ALLOWED_SIGNERS=`.
6. **The name of ssh-agent's option in 2.0.0.** "Key mode" no longer holds keys. Recommendation:
   rename `keyMode` to `localAgent` (start an agent in the container when no host socket is mounted;
   keys only in its memory), with `SSH_AGENT_MODE=key` still accepted by the launcher for one major.
7. **Tokens now or later.** Recommendation: later (slice 5), after the keys have run through a
   release; the refresh write-back of `az` and rclone (section 11) is a design of its own per Feature.
8. **The secret id's lifetime.** Recommendation: no expiry, bound to loopback, reissued at `init`,
   at `restore` and on suspicion; an expiring secret id would stop the backs on a date nobody is
   watching. Alternative: 90 days with the briefing warning two weeks before.
9. **The interface's name.** Recommendation: `dcf-secret`, in the collection's helper naming, since
   any server that speaks the API works behind it; the alternative `openbao-secret` ties callers to
   the product name.
