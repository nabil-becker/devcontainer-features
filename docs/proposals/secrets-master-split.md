# Proposal: OpenBao is the master of secrets, ssh-agent only does SSH

Status: Proposed 2026-11-03, reviewed and ruled the same day. The Operator's decisions (section 1)
and rulings (the section after it) are fixed, and the design sections carry them. This proposal
draws OpenBao's boundaries (phase 1); distribution and replication are a later phase, listed but
not designed. Build not started.

Who this serves: the engineers and the consumers' maintainers who use the `ssh-agent` and `openbao`
Features (they get one place where keys and tokens live, and one gate to open it), and the
Operator, who rules on the proposal and holds the gate.

How to read it: section 1 is the ask, the Rulings section is what was decided (and what is
deferred to phase 2), sections 2 to 15 are the phase 1 design as ruled, section 16 is what is
still open. The architecture review at the end is kept as written; it cites the first draft's
section numbers, which sections 1 to 13 keep (the first draft's section 14, its decisions, is now
the Rulings section and section 16).

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
   *Scoped by the rulings:* every private key the collection creates or stores; keys a workstation
   holds stay the workstation's (ruling 8), and one register recovery key stays offline (ruling 5).
2. **The openbao Feature gets two modes:** `client` (the default: the `bao` CLI only, `BAO_ADDR`
   pointing at a server outside the container) and `server` (the client plus a server run inside
   the container at post-start, sealed until the Operator unseals it). The server's storage obeys
   ADR 0045: losing a machine loses nothing.
   *Amended by rulings 1 and 2:* the server is a local instance whose data stays in its own volume;
   ADR 0045 is met by an external server (client mode) or by backups, so a machine loss loses at
   most what came after the last backup.
3. **The master gate:** the Operator unseals the server once per server start (Shamir shares,
   `bao operator unseal`); `bao login` per sitting gives a token that expires. This replaces ADR
   0046's passphrase unlock. Unattended backs (scribe, secretary, librarian, tester) get their own
   OpenBao identities that work once the server is unsealed.
4. **Migration:** import the keys of ssh-agent's volume into OpenBao, deprecate key mode's key
   tasks in a minor version, remove them in the next major, and supersede ADR 0046 with a new ADR
   (written when the proposal is accepted, not here).
5. **Git signing:** the signing key lives in OpenBao as a long-lived key, its public key stays
   registered at GitHub as a signing key, and ssh-agent loads it for the sitting.
   `allowed_signers` comes from the repository, at `.devcontainer/allowed_signers` (ruling 8).
   SSH certificates (OpenBao's SSH engine) are not relied on for GitHub (checked in section 8).

## Rulings (2026-11-03)

The Operator's rulings on the first draft and its architecture review, as given. The section
named after each says where the design carries it.

1. **Server mode is a local instance**, with its data in its own volume. The openbao Feature never
   uses or depends on the shared (cloud) folder. Persistence outside the container comes from an
   external server (client mode) or from backups. The snapshot-to-shared-folder design, the
   snapshot after every write and the shutdown-check snapshot are removed. (Sections 3, 4.)
2. **Backup and restore.** (Section 4.)
   - `openbao:backup DEST=<path>` writes a raft snapshot to any path (the cloud folder, for
     example) under a new name that is never overwritten, carrying the machine name and the UTC time.
   - `openbao:restore FROM=<file>`; after a restore the server needs unsealing.
   - `openbao:server:status` shows the last backup's age and place.
   - A scheduled backup uses its own `backup` AppRole, allowed only the snapshot path, loopback only.
   - When the server is sealed, the backup exits with its own code.
   - `backupKeep` defaults to 30 and removes only the Feature's own files.
   - After a write, a "not backed up since" reminder prints; the backup runs automatically only
     when a default destination is set.
   - Scheduling is the consumer's own host scheduler (Windows Task Scheduler running the task
     through `task dc:exec`); the launcher never registers it (ADR 0024). An optional
     `backupInterval` option is off by default.
   - Restore warns when the newest backup is from another machine.
3. **Onboarding: both routes.** (Section 15.)
   - (a) Restore, then rekey: a snapshot of an onboarding instance that holds only the shared keys
     (never the Operator's own store), the unseal shares handed over separately, then
     `openbao:rekey`: new unseal shares, a new root token, the sender's tokens and the backs'
     secret ids revoked and reissued for this devhost, and optionally `bao operator rotate` for new
     writes. The sender's old snapshot still opens with the old shares, which is why it holds only
     shared keys.
   - (b) Response wrapping: a one-use token for a few keys into an existing instance.
4. **Unseal shares:** 3 shares, threshold 2, kept in a password manager, on paper offline, and with
   a second person or on a hardware key. Never in git, the container or the shared folder.
   `openbao:init` is interactive only and refuses inside an agent's job. (Sections 3, 9.)
5. **One recovery register key stays offline, outside OpenBao**: an exception to "OpenBao keeps
   everything", stated as such. (Sections 7, 9.)
6. **The Operator's login** lasts 4 hours, at most 8, with no renewal past that. A key loaded for a
   sitting lives no longer than the token. (Sections 5, 8.)
7. **Topology: option 4 + 1 is the main shape.** One central server, optionally reached over a
   mesh network (Tailscale, WireGuard; the Feature needs only `BAO_ADDR`), plus a local read-only
   copy in each devcontainer. (Section 14; the copy is deferred to phase 2, below.)
   - The copy is refreshed by restoring the central server's latest backup. It unseals itself from
     the central server with transit auto-unseal, so it stays unsealed through an outage. If it
     restarts while the central server is down, it needs the shares by hand.
   - `dcf-secret get` uses the copy only when the central server is unreachable, says it is serving
     stale data and since when, logs in to the copy itself if its token is not there, and refuses
     once the copy is older than a maximum age (an option, default 24 hours).
   - `dcf-secret put` and every write go only to the central server. While it is down they exit
     10, and nothing is queued. When it is back, clients return to it and the next refresh updates
     the copy. Changes flow one way only, so there is nothing to merge.
   - Revocations reach a copy only at its next refresh; the maximum age bounds that.
   - This read-only fallback is its own slice after the first build.
   - Also supported: one master with read-only copies and no central server (a single machine),
     and an external 3-node raft cluster for a team (client mode; nothing in the Features changes).
   - Not supported, with reasons: peer-to-peer raft between devcontainers (laptops sleep, a
     majority is lost, every workstation would have to accept connections from other machines);
     OpenBao going read-only by itself when it loses its majority (it does not: with no active
     node it refuses reads too).
   - Considered, not chosen: a data mesh (signed, encrypted entries merged by union, like the
     agentic register). Its own proposal later, if offline sharing without a server is needed.
8. **The rest at the review's and the proposal's recommendations:**
   - the backs each have their own AppRole, loopback only, with a 5 to 15 minute token and secret
     ids that do not expire, reissued at init, restore and rekey (section 7);
   - `allowed_signers` lives at `.devcontainer/allowed_signers` (section 8);
   - ssh-agent's `keyMode` becomes `localAgent` in 2.0 (section 10);
   - the gh, az and cloud-folder tokens move in the last slice (sections 11, 12);
   - the interface is named `dcf-secret` (section 6);
   - openbao keeps the secret records, and the SSH, git and GitHub steps stay in ssh-agent's and
     gh's tasks (section 8);
   - in socket mode, `key:load` into the workstation's agent is allowed with a lifetime and says
     so (section 8);
   - the Feature's tasks live under `openbao:` (section 3);
   - one new ADR supersedes 0046 and names what it changes in 0029 and 0026, plus the backup
     route; stated here, written when the proposal is accepted (section 10).
**Phase 1, this proposal's slices** (the Operator's scoping, 2026-11-03): client and server modes;
local storage; the backup, restore and rekey tasks with the backup rulings; onboarding by restore
then rekey, and response wrapping (both use only native OpenBao features); `dcf-secret`;
`key:load` from OpenBao; the backs' AppRoles; the unseal shares, the recovery key and the login
lifetime; ssh-agent's `keyMode` deprecation; tokens last. One central server reached as a client
is already supported in phase 1, through `BAO_ADDR`.

### Deferred to a later phase (2026-11-03)

Distribution and replication. Each is named here and not designed; each gets its own amendment or
proposal. They share one open question: **who the writer is, and how conflicts resolve.**

- **The 4 + 1 topology's local read-only copy and its fallback** (ruling 7's copy): a copy in each
  devcontainer restored from the central server's latest backup, auto-unsealed by the central
  server's transit engine, serving stale reads while the central server is down, up to a maximum
  age, with writes only to the central server. Its design must also check whether a backup taken
  under the central server's Shamir seal restores into a server with a transit seal, and how a
  copy is unsealed by hand when it restarts during an outage.
- **Backups recorded in the register, and hydrate**: each backup written as a signed register
  entry with its sha256 and the file beside the register's mirror, so a machine with no external
  server is restored from the shared ledger, with the master named by a claim in the register.
- **The ledger as the source of secret values, applied periodically**: the register holds the
  secret values, encrypted, and OpenBao is rebuilt from it by a periodic apply, with the ledger
  doing the replicating.

**The review's findings.** All fifteen are accepted and carried in the design sections:

| Finding | Where |
|---|---|
| 1 backup coverage (privileges, sealed server, retention, window, two machines, fresh machine, host scheduler, operator key) | sections 4, 5, 7, 9; the two-machine case is settled by ruling 7 rather than left open |
| 2 task names under `openbao:` | sections 3, 4 |
| 3 `openbao:init` never in an agent's session; interactive tasks | section 3 |
| 4 `OPENBAO_SETUP_*` override names | section 3 |
| 5 decision 1 scoped; `key:load` in socket mode | sections 1, 8 |
| 6 the ADRs amended (0046, 0029, 0026, 0024 decision 7) and the backup route | section 10 |
| 7 raft chosen because the backup is a raft snapshot | section 4 |
| 8 `dcf-secret` beside `openbao:kv:get`, built on `bao`'s own signals | section 6 |
| 9 the backs' roles belong to the devhost; openbao ships only `backup` | sections 3, 7 |
| 10 a back's key fetch runs in the job runner, never as a tool call | section 7 |
| 11 the register's `key new` / `rekey` hand keys to `dcf-secret put` | section 7 |
| 12 openbao keeps the record; SSH, git and GitHub steps in their Features' tasks | section 8 |
| 13 how `gpg.ssh.allowedSignersFile` resolves | section 8 |
| 14 the host commits `allowed_signers` | sections 8, 10 |
| 15 lexicon terms (the librarian adds them on acceptance); the sitting defined | section 5 |

The review's six open questions are all answered by rulings 2, 7 and 8 (the two-machine one by the phase 2
writer question above).

## 2. The split in one picture

```
                         the Operator
                 unseal (once per server start)   login (per sitting, token 4 h, at most 8)
                               |                         |
                               v                         v
  +--------------------------- openbao Feature ------------------------------+
  |  mode=server: bao server, post-start, sealed at start, loopback only      |
  |    storage: raft on the openbao volume (tier 4)                           |
  |    openbao:backup DEST= ---> any path, new file each time                 |
  |  mode=client: no server, BAO_ADDR points at the central server            |
  |                                                                           |
  |  KV v2 mount "dcf":  ssh/<key>   register/<principal>   token/<name>      |
  |  auth: userpass (the Operator)    approle (backup; others the consumer's) |
  |  records: openbao:ssh:new | put | retire | age                           |
  |                                                                           |
  |  dcf-secret get|put|status   <- the one interface every caller uses       |
  +----------------------------------+----------------------------------------+
                                     | private key on stdin, never a file
                                     v
  +--------------------------- ssh-agent Feature ----------------------------+
  |  SSH_AUTH_SOCK (fixed path)  host socket mounted, or an in-container agent|
  |  key:load NAME= [MINUTES=]   dcf-secret get ... | ssh-add -t <life> -     |
  |  key:lock NAME=              ssh-add -d -                                 |
  |  key:rotate (the SSH steps)  git:signing, git:verify                      |
  |  no key volume, no key at rest                                            |
  +---------------------------------------------------------------------------+
         ^                       ^                           ^
     git commit -S         agentic-register             gh / az / cloud-folder
   (the Operator's         (operator acts: agent;       (tokens: section 11,
    sitting)                backs: section 7)            the last slice)
```

What goes where:

| Thing | Today | After |
|---|---|---|
| ssh and git signing private keys | ssh-agent key volume (`ssh-agent-key-*`) | OpenBao `dcf/ssh/<key>` |
| Key creation date, age | `<name>.meta` sidecar in the key volume | KV v2 metadata (`created_time`, custom metadata) |
| `allowed_signers.history` | the key volume | `.devcontainer/allowed_signers` in the repository (section 8) |
| Register operator key | ssh-agent key volume, passphrase (ADR 0046) | OpenBao `dcf/register/<principal>` |
| Register recovery key (second anchor) | none | offline, outside OpenBao (ruling 5) |
| Register back keys | agentic-register volume `keys/<principal>` | OpenBao `dcf/register/<principal>` |
| gh, Azure, cloud-folder logins | each Feature's volume | OpenBao `dcf/token/<name>` (section 11) |
| The unlock | the key's passphrase, per key | the unseal (per server start) and the login (per sitting) |
| Out-of-machine copy of the store | none | backups written by `openbao:backup` to a path the consumer picks, or an external server |

## 3. The openbao Feature's modes

One new option, `mode`, `client` (default) or `server`, overridable per container with
`OPENBAO_SETUP_MODE` in `containerEnv` (NFR-6, the collection's `<ID>_SETUP_<OPTION>` naming). A
consumer that changes nothing keeps today's Feature.

**Both modes** get what `openbao-state-build` already plans (NFR-1): a named volume
`openbao-${devcontainerId}` on `/var/lib/devcontainer-features/openbao`, a setup script
`openbao-setup` run by `dcf-persist`, and the login token kept there (`~/.vault-token` linked into
the volume), so a rebuild no longer logs out. That backlog item is the first slice of this work,
not a separate one. Both modes also install `dcf-secret` (section 6). `openbao:backup` works in
both: in client mode against any server whose token may read the snapshot path.

**Server mode** adds:

- **The start hook** (`postStartCommand`, `openbao-setup start`) writes the server's config into the
  volume if it is missing, starts `bao server` in the background (its PID in the volume; a live one
  is reused), and prints one line: `openbao: server started, sealed; the Operator runs task
  openbao:unseal`, or, on the first start, `not initialised; task openbao:init` (or `task
  openbao:restore` when a default backup destination holds backups). It never waits for an unseal
  and never prompts: the lesson of `ssh-passphrase-wait` (a start hook that waits holds every
  Feature's start). When `backupInterval` is set it starts the backup timer once (a live one is
  reused) and never fails the start because of it (NFR-5).
- **The config**: storage `raft` at `/var/lib/devcontainer-features/openbao/raft`, `node_id` fixed
  (`devhost`); one `tcp` listener on `127.0.0.1:8200` with TLS off (it never leaves the
  container's loopback; another container cannot reach it); `cluster_addr` on `127.0.0.1:8201`;
  `disable_mlock = true` (a container has no `IPC_LOCK` by default; the server slice checks this
  and raft's needs against OpenBao's own documentation, which the review could not confirm); no UI.
  `BAO_ADDR` defaults to `http://127.0.0.1:8200` in server mode.
- **Tasks**, all under `openbao:` (NFR-2), each with a `desc`:
  - `openbao:init` (once): `bao operator init` with 3 shares, threshold 2 (section 9); enables the
    `dcf` KV v2 mount, `userpass` for the Operator, `approle`, the `backup` role and its policy,
    the file audit device in the volume, the Operator's policy; prints the shares once and revokes
    the root token at the end. It is `interactive: true`, refuses without a terminal, and refuses
    when `DEVHOST_JOB_CHILD` or another agent's job environment is set: the shares must never land
    in a transcript (the review's finding 3). It also refuses when a backup is named or found in
    the default destination, and names `openbao:restore`. The NOTES tell the Operator to run it in
    a plain terminal (or with `-pgp-keys`).
  - `openbao:unseal` (asks for a share at `bao operator unseal`'s own prompt until the threshold is
    met), `openbao:seal`.
  - `openbao:backup`, `openbao:restore`, `openbao:rekey` (section 4 and section 15).
  - `openbao:wrap`, `openbao:unwrap` (section 15).
  - `openbao:approle:issue ROLE= [POLICY_PATH=]` and `openbao:approle:revoke ROLE=`: generic; the
    roles for the backs are the devhost's (section 7).
  - `openbao:server:status`: seal state, the last backup's age and place, and a warning past
    `backupWarnAfter` (section 4). `openbao:login`, `openbao:status` (the CLI's own `bao status`)
    and `openbao:kv:get` exist already and stay as they are.
  - `interactive: true` on `openbao:init`, `:unseal`, `:login`, `:restore`, `:rekey`, `:unwrap` and
    `openbao:ssh:import`. `openbao:backup` is non-interactive, so it can be scheduled (NFR-7).
- **No shutdown-check contribution.** The shutdown check (ADR 0022) takes no snapshot (ruling 1).
  `openbao:server:status` is where the Operator sees how old the last backup is.

**Client mode** is today's Feature plus the volume and `dcf-secret`. The server's address,
TLS and auth method are the server owner's; the Feature only needs the `dcf` mount layout of
section 6 (or `DCF_SECRET_MOUNT` naming another mount).

**Options this proposal adds** (each with its `OPENBAO_SETUP_*` twin):

| Option | Default | Twin | Section |
|---|---|---|---|
| `mode` | `client` | `OPENBAO_SETUP_MODE` | 3 |
| `backupDest` | empty (no automatic backup) | `OPENBAO_SETUP_BACKUP_DEST` | 4 |
| `backupKeep` | `30` | `OPENBAO_SETUP_BACKUP_KEEP` | 4 |
| `backupInterval` | empty (off) | `OPENBAO_SETUP_BACKUP_INTERVAL` | 4 |
| `backupWarnAfter` | `7d` | `OPENBAO_SETUP_BACKUP_WARN_AFTER` | 4 |

`DEST`, `FROM`, `KEEP` are task variables; `DCF_SECRET_MOUNT` and `DCF_SECRET_AS` are plain
runtime variables.

## 4. Where the server's storage goes, and the backup (ADR 0045)

The rule: if losing a machine would lose something, it is in the wrong tier. The server's data
cannot be rebuilt (it is the keys). Tier 1 (git) is out: a public repository. And the live store
never goes into the shared folder.

**Why the live store stays in the volume.** Raft's bbolt database is one file written in place
with random writes, memory-mapped, `fsync`ed and held under an exclusive lock; raft also writes a
log and renames snapshot files. None of the `cloud-folder` Feature's three modes promises a
consistent single-writer database, and each lets a second machine open the same store:

| Mode | What the live raft store would meet |
|---|---|
| `host` (the sync client's folder bind-mounted) | the engine's file share from Windows; the sync client uploads a database that is being written, and a second machine would open the same file |
| `sync` (rclone bisync) | a copy made between writes, never a consistent one; a file changed on two machines is kept twice as `.conflict1` / `.conflict2` and nothing picks a winner |
| `mount` (rclone FUSE, `--vfs-cache-mode writes`) | no hard links (`register-store-no-hardlink`), and no guarantee for in-place random writes, the lock or `fsync` reaching the remote |

**Raft, not file or pebble.** The `file` backend was deprecated in v2.6.0 and removed in v2.7.0,
and the Feature's default `version` is `latest`. v2.7.0 also adds a PebbleDB backend ("non-HA,
durable"). Raft is chosen because `bao operator raft snapshot` is the backup; pebble is not used.
The NOTES say so.

**The design: a local volume, and backups to a path the consumer picks.** The openbao Feature
does not know or depend on the shared folder (ruling 1); a destination is just a path.

```
 tier 4: openbao volume (per container)            DEST (any path the consumer names,
   raft/            live store                       e.g. the cloud folder, a USB disk)
   audit.log        audit device                       openbao-<machine>-<UTC time>.snap
   approle/backup   the backup role's secret id        written once, never overwritten,
   last-backup      time, place, sha256                the last backupKeep (30) kept
   .vault-token     the Operator's login
```

ADR 0045 is met two ways: by an external server (client mode, the server owner's storage), or by
backups, so a machine loss loses at most what came after the last backup.

**`openbao:backup [DEST=<path>]`** (`DEST` defaults to `backupDest`; neither set refuses):

1. Logs in with the `backup` AppRole (section 7), runs `bao operator raft snapshot save` to a file
   in the volume, and copies it whole into `DEST` as `openbao-<machine>-<YYYYMMDDTHHMMSSZ>.snap`
   (`<machine>` is `OPENBAO_MACHINE` when set, else the hostname). A name that exists is never
   overwritten. A new file is never a conflict in `sync` and needs no hard link in `mount`.
2. Records the time, the path and the sha256 in the volume's `last-backup`.
3. With `backupKeep` (or `KEEP=`), removes the oldest files in `DEST` that match the Feature's own
   name pattern for this machine beyond the last N. Nothing else is ever removed.
4. Prints the snapshot's path and sha256.

Exit codes, each with one line naming the fix, the same numbers as `dcf-secret` where they mean
the same thing (section 6): 0 written; 10 unreachable; **11 sealed** (the code a host scheduler's
history shows after an unattended container start, ruling 2); 12 the backup role cannot log in;
20 `DEST` missing or not writable.

**After a write.** Every task that writes a secret (`openbao:ssh:new`, `:import`, `:retire`,
`dcf-secret put`, `openbao:approle:issue`, `openbao:rekey`) ends with `not backed up since <time>;
task openbao:backup DEST=…`. It runs the backup itself only when `backupDest` is set (ruling 2).

**Scheduled backups.**

- The consumer's own host scheduler: a Windows Task Scheduler entry running `task dc:exec --
  task openbao:backup` is a one-shot command on the host (ADR 0026). The NOTES give the line as the
  consumer's own setup; no launcher task registers it, since ADR 0024 decision 3 rules out a
  background process of ours on the host.
- Or `backupInterval` (off by default): a timer started by the start hook, running the backup
  while the server is up and unsealed, into `backupDest`. A sealed server is skipped with one
  line in the volume's log, not retried in a loop.
- Either way, `openbao:server:status` shows the last backup's age and place and warns past
  `backupWarnAfter`; the devhost briefing's sealed line says how old the last backup is.

**`openbao:restore FROM=<file>`.** Restore needs a token, so on a fresh server the task first
initialises it with throwaway shares and logs in with that root token, then runs `bao operator
raft snapshot restore -force`, discards the throwaway shares and token, and leaves the server
sealed for the backup's own shares (the review's "Facts checked"). It warns when the newest
Feature backup beside `FROM` is from another machine than the store's last backup. After the
unseal, the Operator runs `openbao:approle:issue` for each role (the backs' secret ids are
reissued at restore, ruling 8; the devhost does its roles in one task).

**A snapshot is ciphertext**: the store is encrypted by OpenBao's barrier, and the barrier key is
protected by the unseal shares. A snapshot without the shares is useless; with them it is
everything. So the shares never go where the backups go (section 9). Old snapshots keep keys
retired since; `backupKeep` bounds how long.

## 5. The gate: unseal, login, and what each step opens

```
 container start          the Operator                      the Operator
      |                    task openbao:unseal               task openbao:login
      v                    (2 of 3 shares)                   (userpass, per sitting)
  [ sealed ] ----------------------> [ unsealed ] ----------------> [ Operator token ]
   nothing works            backs and backup log in           ssh keys, register operator
   dcf-secret: exit 11      with AppRole (own paths only)     key, tokens, record tasks
   backup: exit 11                                             4 h, at most 8 -> exit 12
```

- **Unseal** once per server start. It opens the store; by itself it lets nobody read anything.
- **A sitting** is the span between the Operator's login and the end of that token. In server mode
  the login is `userpass` (one user, a password the Operator keeps); in client mode it is whatever
  the server offers (`task openbao:login -- -method=oidc`). The token has `ttl` 4 hours and
  `max_ttl` 8 hours, with no renewal past that (ruling 6); `task openbao:logout` (or `bao token
  revoke -self`) ends a sitting early. A night shift that must sign overnight starts with a login
  made for it.
- **What the Operator's policy allows**: read and write everything under `dcf/`, the snapshot
  read and the restore (`sys/storage/raft/snapshot`, `sys/storage/raft/snapshot-force`), AppRole
  secret ids; not `sys/` beyond that. The root token is revoked after `init` and made again only
  from the shares (`bao operator generate-root`) when a policy must change, and at a rekey
  (section 15).

## 6. How a Feature asks for a secret: `dcf-secret`

One small executable, installed by the openbao Feature in both modes, named like the collection's
other shared helpers (`dcf-persist`, `dcf-curl`). Every caller (ssh-agent, agentic-register, gh,
az, cloud-folder, the devhost) uses it and nothing else, so where the server runs does not matter to
the caller. `openbao:kv:get` stays as the raw CLI pass-through for people; `dcf-secret` is the
callers' interface, documented as such (the review's finding 8).

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
  `DCF_SECRET_AS=<role>` it logs in first with that role's AppRole (section 7).
- **Exit codes**, the same for every caller, each with one plain line on stderr naming the fix:

| Exit | Meaning | The line names |
|---|---|---|
| 0 | the value is on stdout | |
| 10 | the server is unreachable (`BAO_ADDR` wrong, server not running, no openbao Feature) | `task openbao:server:status` or `BAO_ADDR` |
| 11 | the server is sealed | `task openbao:unseal` (the Operator) |
| 12 | no token, or it expired | `task openbao:login` |
| 13 | the token may not read this name | the policy |
| 14 | no such secret | `task openbao:ssh:import` or `:new` |

- **It is a thin wrapper**: `bao kv get -field=...` and `bao kv put ... field=-`. The mapping is
  built on `bao`'s own signals (`bao status` exit 2 when sealed, the HTTP status in
  `-format=json`), never on parsed English. It does not re-implement the CLI (NFR-13), and it works
  the same against a Vault server, whose API the `bao` CLI speaks.
- **No fallback, ever.** A caller that gets a non-zero exit fails with that line. Nothing reads a
  key from a volume, a file or an environment variable instead. This is the rule that makes
  OpenBao the master: a second source would be a second master. (A read-only copy is phase 2.)
- **A caller without the openbao Feature** finds no `dcf-secret` and says so (`install the openbao
  Feature`); the Features stay independent at build time (no new `installsAfter` is needed, and an
  unpublished Feature could not be named in one anyway).

## 7. The backs' identities, and the backup role

**Choice: AppRole**, one role per machine identity, each with a policy on its own path only.

Why AppRole:

- It is OpenBao's method for machines that log in without a person: a `role_id` (not secret) and a
  `secret_id` (the credential), each login giving a short token.
- Each role is its own identity in the audit log, and one can be cut off
  (`openbao:approle:revoke ROLE=`) without touching the others.
- `secret_id_bound_cidrs` and `token_bound_cidrs` of `127.0.0.1/32`: a stolen `secret_id` works
  only from inside this container, and only while the server is unsealed.
- `token_ttl` 5 minutes, `token_max_ttl` 15; secret ids do not expire (an expiring one would stop
  the backs on a date nobody is watching), and are reissued at `init`, `restore` and `rekey`, and on
  suspicion (ruling 8).

Rejected: a long-lived periodic token per back in a file (simpler, but a bearer token with nothing
to rotate it and no login step to bind); the `cert` method (a client certificate per back is a
second PKI to keep); TLS or a Kubernetes-style platform identity (the container has none to offer).

**Who owns which role** (the review's finding 9):

- The openbao Feature ships one role, `backup`, whose policy allows only `read` on
  `sys/storage/raft/snapshot`, loopback only. It is what a scheduled backup logs in with, since the
  Operator's token ends after at most 8 hours.
- The devhost (local Feature) creates one role per back (`scribe`, `secretary`, `librarian`,
  `tester`) through `openbao:approle:issue ROLE= POLICY_PATH=dcf/register/<principal>`. The names
  are this way of working's and mean nothing to another consumer of a published Feature.

**How a back signs a register entry** (the review's finding 10). The devhost's job runner
(`run-job.sh`), around the CLI and never as a tool call, runs `DCF_SECRET_AS=scribe dcf-secret get
register/scribe --field private_key` into a file on tmpfs (`/dev/shm`, mode 0600, its own folder),
and the signing and the removal (on exit, success or failure) happen there too. The key never
reaches a model's tool output or transcript, and the route is the same for every agent CLI. It does
**not** load the key into the SSH agent: in socket mode the agent is the workstation's own.

**The register's own key creation** (the review's finding 11): the agentic-register slice gives
`key new` and `rekey` a way to hand the new private key to `dcf-secret put` on stdin (or to print
it to stdout only), and stops writing `keys/` when the openbao Feature is present.

**The bootstrap secret.** Each role's `secret_id` lives in the openbao volume
(`approle/<role>/secret_id`, mode 0600). It is the one credential at rest in the container, and it
is worth only what the server allows: nothing while sealed, one path while unsealed, from
loopback. Tier 4, because it can be reissued.

**When the server is sealed**, a back exits non-zero with the `dcf-secret` line and records it in
its metrics line; it must not mark its stretch as read, so its next run after the unseal does the
work. The briefing shows one line while the server is sealed (`OpenBao sealed: the backs cannot
sign; last backup <age>; task openbao:unseal`). The slice that wires the backs checks this against
the backs' code.

**The Operator's register key** is used in the Operator's sitting, through the agent:
`task ssh-agent:key:load NAME=register/operator-1 MINUTES=15`, then the register's `--key
<public key>` signs through the agent, as the register already supports, and `key:lock` or the
lifetime ends it. That is ADR 0046's flow with the passphrase replaced by the login.

**The recovery register key** (ruling 5): the register's second operator anchor has its private
key offline, outside OpenBao. It is an exception to "OpenBao keeps everything", stated as such: if
the shares are lost, or a key made after the last backup is lost with a machine, it is what reopens
the rosters.

## 8. Git signing

- **The record** (openbao): one long-lived ed25519 signing key per purpose, created by
  `openbao:ssh:new` (named `<repo>-<container>-sign` as today), kept at `dcf/ssh/<name>` with
  fields `private_key`, `public_key`, `purpose` (`git-signing`) and the creation date in the KV
  metadata. `openbao:ssh:new`, `:put`, `:retire` (destroys the private key's versions, keeps the
  metadata, dated) and `:age` are the record's lifecycle.
- **The SSH, git and GitHub steps stay in their Features' tasks** (ruling 8, the review's finding
  12). openbao does not know SSH, git or GitHub:
  - ssh-agent: `key:load`, `key:lock`, `git:signing`, `git:verify`, and `key:rotate`, which keeps
    ADR 0029's four steps and their order (make the new record with `openbao:ssh:new`, load it,
    register it, point git at it and verify, then `openbao:ssh:retire` the old).
  - gh: a new task (`gh:ssh-key:add`, the gh slice) registers a public key as a **signing** key,
    as `key:rotate` does through `gh` today. A step whose Feature is absent refuses plainly.
- **The sitting**: `task ssh-agent:key:load NAME=ssh/<name> [MINUTES=]` fetches it with
  `dcf-secret`, pipes it to `ssh-add -t <seconds> -` (the key is read from stdin, never written to a
  file; confirmed with OpenSSH 10.0, and `ssh-add -d -` removes it the same way, so `key:lock` needs
  no file either), and says the clock time it drops out. The lifetime is at most what is left of
  the Operator's token (ruling 6); `MINUTES` may shorten it.
- **In socket mode** the agent is the workstation's. `key:load` loads into it with the lifetime and
  says so (`loaded into the workstation's agent until <time>`) (ruling 8). Keys the workstation
  already holds stay the workstation's and are not imported: decision 1 covers every private key
  the collection creates or stores (the review's finding 5).
- **Generation without a file at rest**: `openbao:ssh:new` runs `ssh-keygen` in a private folder on
  tmpfs, `put`s the key, and removes the folder. No passphrase is set: the gate is the login now
  (decision 3), and a second passphrase per load would bring back ADR 0046's prompt.

**`allowed_signers`: `.devcontainer/allowed_signers` in the repository** (ruling 8), one line per
key with `namespaces="git"` and `valid-after` / `valid-before`. Why the repository and not OpenBao:

- Public keys are not secrets, and verifying must work where there is no server: CI, another
  engineer's container, the Operator's workstation, a sealed devhost.
- Who may sign this repository's history is a reviewed decision, and git is the reviewed record
  (tier 1). A key added or retired is a line in a pull request.
- It replaces `allowed_signers.history`, which sits in a volume today and goes with it.

`ssh-agent:key:rotate` and `openbao:ssh:new` / `:retire` (through ssh-agent's task) write the line
into the working tree; **the host commits it** (ADR 0040).

**How git finds it** (the review's finding 13). `git:signing` writes global config (the git
Feature's volume here) or repo config, which is shared with Windows through `.git-dirs` (ADR 0020).
A repo-relative path in global config points at the wrong file in every other repository, and an
absolute container path in repo config means nothing to git on the Windows host. The slice checks
how git resolves a relative `gpg.ssh.allowedSignersFile` and picks by that test: repo scope with
the work-tree-relative `.devcontainer/allowed_signers` if git resolves it against the work tree
on both sides, otherwise written per repository by `git-setup`. `git:signing` takes another path
with `ALLOWED_SIGNERS=`. A test covers it.

**SSH certificates and GitHub (checked 2026-11-03).** GitHub's "About commit signature verification"
says an SSH signature is checked as "cryptographically verifiable against a public key you have added
to your account", requires Git 2.34 or later, and nowhere mentions SSH certificates or certificate
authorities (the only certificate authority on that page is for S/MIME). A search found no GitHub
statement of support and one community question about it left unanswered. So **GitHub is not
documented to verify a commit signed with an SSH certificate**, and this design does not rely on
it. (Locally, `ssh-keygen` accepts a `cert-authority` line in `allowed_signers`, so certificates
could serve local verification; not needed here.)

One more finding from the same page: "once a commit signature is verified, it remains verified within
its repository's network", even if the key is later revoked. That changes the trade-off `REVOKE=1`
describes today (section 13).

## 9. Security trade-offs

| | ADR 0046 today | This proposal |
|---|---|---|
| Key at rest | a passphrase-protected file in the key volume | encrypted by OpenBao's barrier in the raft volume and in each backup |
| What opens it | the passphrase, per key, per load | the unseal shares, per server start; the Operator's login, per sitting |
| A back's key | a plain file in the register's volume | readable only through the back's AppRole, while unsealed, in the job runner |
| Lost machine | the volume is gone; the key must be on the host too | with a central server, nothing; otherwise restore the newest backup, unseal with the shares; what came after it is lost, and the offline recovery key covers the register |
| Audit | none | the file audit device names every identity that read a key |
| Revoking one back | rekey that back | revoke its secret id; the others carry on |

The costs, plainly:

- **The unseal shares are now the keys to everything** (ruling 4): three shares, threshold two:
  one in the Operator's password manager, one on paper kept offline, one with a second trusted
  person or on a hardware key. Never in git, never in the container, never in the shared folder or
  wherever backups go. Losing two of three loses every secret; that is why one register recovery key
  stays offline, outside OpenBao (ruling 5). `openbao:init` runs only in a plain terminal, never in
  an agent's job, so the shares never reach a transcript.
- **A backup is everything to whoever holds the shares.** Backups are written once, kept to
  `backupKeep`, and old ones still hold keys retired since. A snapshot handed to someone else still
  opens with the shares it was made under, even after they rekey their copy (section 15).
- **The Operator's token sits in the volume for the sitting**, readable by any process of the remote
  user, as an unlocked key sits in the agent today. Its TTL bounds it (4 hours, at most 8, no
  renewal past it; ruling 6).
- **The secret ids are at rest** in the volume (section 7). Any process of the same user can read
  them and act as that role while the server is unsealed: the same exposure as the register's
  `keys/<principal>` today, now logged, narrowed to one path each, loopback-only and revocable.
  Separating the backs by user is not proposed.
- **A server runs in the container**: one more process and a loopback listener without TLS. Only
  processes in the container reach it, and they can already read the token file; TLS would add a
  certificate to keep and protect nothing more.
- **`disable_mlock`**: the server's memory may be swapped. Containers do not grant `IPC_LOCK` by
  default; granting it is a launcher change not proposed here.
- **A sealed server stops signing.** That is the intended price: an agent that cannot reach the
  master must not find a key elsewhere.

## 10. Migration (decision 4)

```
 ssh-agent 1.3.0                  ssh-agent 1.4.0 (minor)               ssh-agent 2.0.0 (major)
 key volume + key tasks   --->    key:load/lock from OpenBao       ---> no key volume, no key tasks
                                  old key tasks warn "deprecated:       keyMode renamed localAgent
                                  task openbao:ssh:<verb>"              (in-container agent, memory
                                  openbao:ssh:import FROM=ssh-agent      only)
```

1. **Import**: `task openbao:ssh:import FROM=ssh-agent` (interactive) reads each private key of the
   key volume, asks once for the passphrase of a protected one (at `ssh-keygen -p`'s own prompt, on
   a tmpfs copy), puts it under `dcf/ssh/<name>` with its creation date from the `.meta` sidecar,
   appends `allowed_signers.history` to `.devcontainer/allowed_signers`, compares fingerprints, and
   calls `task ssh-agent:key:load` and `task ssh-agent:git:verify` for one key. Only then does it
   offer to delete the volume's copy (asks, never by default), so a key is never in two masters for
   longer than the import. `FROM=agentic-register` does the same for the register's
   `keys/<principal>`, then the devhost issues each back its role. `FROM=file FILE=` (and the
   launcher's streaming twin of `devcontainer:ssh-key-import`) takes a key from the workstation.
2. **Deprecate** (ssh-agent 1.4.0): `key:new`, `key:add`, `key:retire`, `key:age`, `key:unlock` and
   `key:remove DELETE=1` keep working on the volume and print one line naming the task that
   replaces them. `key:rotate` moves onto OpenBao records (section 8). `key:load NAME=` and
   `key:lock NAME=` take an OpenBao name (`ssh/<key>`, `register/<principal>`); `key:load` with no
   `NAME` keeps loading the volume's keys until 2.0, with the same warning. The start hook never
   fetches from OpenBao (it never waits and never asks).
3. **Remove** (ssh-agent 2.0.0): the key volume's mount, the deprecated tasks and the volume code go.
   The in-container agent stays (Windows engines still need an agent to load into); `keyMode` is
   renamed `localAgent` (start an agent in the container when no host socket is mounted; keys only
   in its memory), with `SSH_AGENT_MODE=key` still accepted by the launcher for one major (ruling
   8). Removing a mount does not delete the volume: the 2.0 notes say to run the import first and
   remove the old volume with the engine's own command.
4. **One new ADR**, written when this proposal is accepted (ruling 8, the review's finding 6):
   - supersedes ADR 0046: the register's operator key lives in OpenBao and is loaded for a sitting
     by `key:load`, gated by the unseal and the login;
   - names what it changes in ADR 0029 (rotation's record steps move to `openbao:ssh:*`, the SSH
     steps stay in `ssh-agent:key:rotate`, and the `allowed_signers` history moves to a committed
     file) and in ADR 0026 (`dc:ssh-key-import` becomes a stream into `openbao:ssh:import
     FROM=file`); ADR 0024 decision 7's `DCF_HOST_SSH_AGENT=key` value stays accepted for one major;
   - records the backup route: how server mode meets ADR 0045 (an external server, or backups to a
     path the consumer picks), without changing 0045 itself.

**What changes for a consumer using key mode today** (this devhost, and the consumer whose request
led to ADR 0046):

| Step | Who | What |
|---|---|---|
| 1 | maintainer | `openbao` with `"mode": "server"` (and, if wanted, `backupDest`) in `devcontainer.json`; ssh-agent to 1.4.0 (`:1` picks it up); rebuild |
| 2 | the Operator, once, in a plain terminal | `task openbao:init`, store the three shares (section 9); `task openbao:unseal`; `task openbao:login` |
| 3 | the Operator, once | `task openbao:ssh:import FROM=ssh-agent`, then `FROM=agentic-register`; the host commits `.devcontainer/allowed_signers` |
| 4 | the Operator | `task openbao:backup DEST=…` once, then the host scheduler entry or `backupInterval` if wanted |
| 5 | everyone | `key:unlock NAME=<file>` becomes `key:load NAME=ssh/<file> MINUTES=`; each sitting starts with `openbao:login` (and, after a container start, the Operator's `openbao:unseal`) |
| 6 | maintainer, at 2.0 | move to `ssh-agent:2` and rename `keyMode` to `localAgent`; remove the old volume |

`SSH_AGENT_MODE=key` stays meaningful (it still starts the in-container agent). A consumer in socket
mode that never used key mode changes nothing, and a consumer that does not install openbao keeps
ssh-agent 1.x working as it is until it moves to `:2`.

## 11. Tokens (gh, Azure, the cloud folder)

Decision 1 puts them in OpenBao too, in the last slice (ruling 8). They differ from keys in one way
that matters: `az` and rclone refresh their tokens themselves and write the new one back into their
own files. So OpenBao holds the **long-lived credential** (a gh token, a service principal or
refresh token, rclone's config), the Feature's setup fetches it with `dcf-secret` into its volume at
the sitting's start, and the tool's own refreshed copy in the volume is tier 4 (rebuildable from
OpenBao). A Feature that writes back a refreshed long-lived credential puts it back with
`dcf-secret put`. The write-back is a design of its own per Feature, made in that slice.

## 12. Blast radius and slices

| Part | Change | Version |
|---|---|---|
| `openbao` | volume and `openbao-setup` (`openbao-state-build`), `dcf-secret`, `mode` | 1.1.0 |
| `openbao` | server mode, init, unseal, seal, userpass, AppRole tasks and the `backup` role, `openbao:backup` / `:restore` / `:rekey`, `backupKeep`, `backupInterval`, `openbao:wrap` / `:unwrap`, `openbao:server:status` | 1.2.0 |
| `openbao` | `openbao:ssh:*` records and the import | 1.3.0 |
| `ssh-agent` | `key:load`/`key:lock` from OpenBao, `key:rotate` on OpenBao records, deprecations | 1.4.0 |
| `ssh-agent` | the key volume and key tasks removed, `keyMode` renamed `localAgent` | 2.0.0 (breaking) |
| `gh` | `gh:ssh-key:add` (signing key registration) | minor |
| `devcontainer-cli` | `devcontainer:ssh-key-import` deprecated in favour of a host task that streams into `openbao:ssh:import FROM=file` | minor |
| `agentic-register` (local) | `key new` / `rekey` to `dcf-secret put`; `keys/<principal>` deprecated | minor |
| `devhost` (local) | the backs' AppRoles, the fetch in the job runner, the sealed line with the backup's age in the briefing | minor |
| `gh`, `az`, `cloud-folder` | fetch their credential with `dcf-secret` (section 11) | minor each, last |
| `git`, `go-task` | none | |

Every openbao change is additive with `client` as the default. Consumers: **both**, the office and
software project 1, pin `ssh-agent:1` and get the deprecation lines with 1.4.0; the one that uses
key mode for its operator key migrates (section 10); nothing breaks for either until they choose
`ssh-agent:2`. Because the ssh-agent major and the server mode reach every consumer, those slices
are sized for the strongest model; the others are Sonnet work.

Slices, each one pull request with its version bump and `task docs`:

1. **openbao 1.1.0**: the volume and setup hook (`openbao-state-build`), `dcf-secret` (on `bao`'s
   own signals), the `mode` option with `client` only, the `OPENBAO_SETUP_*` names.
2. **openbao 1.2.0, the server with backup, restore and rekey**: server mode, raft on the volume,
   init (interactive, refusing in an agent's job), unseal, seal, userpass, generic AppRole tasks and
   the `backup` role, `openbao:backup` with `backupKeep`, `backupInterval`,
   `openbao:restore` (with the throwaway init), `openbao:rekey`, `openbao:wrap` / `:unwrap`,
   `openbao:server:status` with the last backup. The NOTES carry the Task Scheduler line.
3. **openbao 1.3.0, ssh-agent 1.4.0, gh minor, devcontainer-cli minor**: `openbao:ssh:*` records,
   the import, `key:load`/`key:lock` and `key:rotate` on OpenBao, `gh:ssh-key:add`, the
   deprecations, `.devcontainer/allowed_signers` and its resolution test.
4. **agentic-register and devhost**: the backs' roles, the fetch in the job runner, the register's
   key creation into `dcf-secret put`, the briefing line; the ADR superseding 0046.
   That ends the first build.
5. **ssh-agent 2.0.0**: the removal, after at least one release of 1.4.0 has been adopted by both
   consumers.
6. **gh, az, cloud-folder**: credentials from `dcf-secret` (section 11). The last slice.

Tests are Docker-free where they can be: `dcf-secret` against a fake `bao` (each exit code, no
fallback when sealed),
the import against a key volume made in a temp folder, the key piped to `ssh-add -` never touching
a file (checked by the folder staying empty), the backup naming (never overwritten), `backupKeep`
touching only its own pattern, the sealed exit 11, the
`openbao:init` refusal under `DEVHOST_JOB_CHILD`, the status line, and the start hook returning at
once on a sealed server. The server itself (`bao server -dev` is not enough for raft and seal),
restore and rekey are Feature tests that need a Docker daemon, with a
`mode=server` and a `backupInterval` scenario.

## 13. For the repository (found while writing)

- `src/ssh-agent/NOTES.md` says that after `REVOKE=1` "old commits show unverified at GitHub". GitHub's
  documentation now says a commit verified once stays verified in its repository's network even if
  the key is revoked. The note should say that, and `REVOKE=1` loses less than it says (only commits
  GitHub had not yet verified).
- The openbao Feature's default `version: latest` installs a release without the `file` backend
  (removed in v2.7.0); nothing uses it today. The NOTES could say raft is the storage the Feature
  uses, why (the snapshot is the backup), and that pebble is not.
- The lexicon terms of the review's finding 15 (sitting, seal and unseal, unseal share, the gate,
  master of secrets, server and client mode, backup and restore, secret name, back
  identity, the register's operator key, anchor and principal, key mode and `localAgent`) are the
  librarian's when the proposal is accepted.

## 14. Topology (ruling 7)

Phase 1 draws the boundary: the openbao Feature talks to one server at `BAO_ADDR`, its own
(server mode) or another (client mode), and replicates nothing.

**Supported in phase 1:**

- **One central server, reached as a client**: any OpenBao server at `BAO_ADDR`, optionally over a
  mesh network (Tailscale, WireGuard); the Feature needs only the address. Its TLS, storage and
  backups are its owner's; `openbao:backup` in client mode can take them with a `backup` role
  there. This is ruling 7's main shape without the local copy, which is phase 2.
- **A single machine, no central server**: one devcontainer in server mode, backed up as section
  4 says. Read-only copies in other devcontainers are phase 2.
- **A team: an external 3-node raft cluster**, in client mode. Nothing in the Features changes.

**Not supported, and why:**

- Peer-to-peer raft between devcontainers: laptops sleep, a majority is lost, and every
  workstation would have to accept connections from other machines.
- OpenBao going read-only by itself when it loses its majority: it does not; with no active node it
  refuses reads too.

**Considered, not chosen:** a data mesh (signed, encrypted entries merged by union, like the
agentic register). Its own proposal later, if offline sharing without a server is needed.

## 15. Onboarding (ruling 3)

Two routes, for two needs.

**(a) Restore, then rekey: a new devhost starts from a set of shared keys.**

```
 sender: onboarding instance (only the shared keys, never the sender's own store)
    openbao:backup  ---- snapshot file ---->  receiver: openbao:restore FROM=
    unseal shares   ---- separately ------->  receiver: openbao:unseal (sender's shares)
                                              receiver: openbao:rekey
```

`openbao:rekey` (interactive, the Operator in a plain terminal, like `init`):

1. `bao operator rekey` with 3 new shares, threshold 2, given the sender's shares; the new shares
   are printed once, for the custody of section 9.
2. A new root token from the new shares (`bao operator generate-root`), used for the next steps and
   revoked at the end, as after `init`.
3. Revokes the sender's tokens (every token issued before the rekey), sets the receiver's own
   `userpass` password, and reissues every role's secret id for this devhost (the `backup` role
   here, the backs' through the devhost's task).
4. With `ROTATE=1`, `bao operator rotate`: new writes use a new encryption key.

Said plainly: **the sender's old snapshot still opens with the old shares.** A rekey changes how
this store is unsealed, not what was already handed over, and a rotate protects only new writes.
That is why the onboarding instance holds only the shared keys and never the Operator's own store.

**(b) Response wrapping: a few keys into an existing instance.** `openbao:wrap NAMES=<name>,...
[TTL=]` reads the named secrets into one wrapped response and prints a one-use wrapping token
(`bao`'s `-wrap-ttl`), which the sender hands over separately. `openbao:unwrap` (interactive; the
token at a prompt, never an argument) unwraps it once and `dcf-secret put`s each value. A token
already used, or expired, fails for the receiver, which shows that someone else opened it.

## 16. Decisions needed

None for phase 1. The phase 2 question (who the writer is, and how conflicts resolve) is the
Operator's when that phase starts.

## Architecture review (2026-11-03)

**Verdict:** fit with changes

Reviewed against two rulings the Operator gave during the review.

1. **Local only.** OpenBao does not use the shared folder itself. Server mode is a local
   instance whose data lives in its own volume. Persistence outside the container is what client
   mode against an external server is for, and the Feature takes no dependency on the cloud folder.
2. **Ad-hoc backup and restore.** A backup task takes a raft snapshot and writes it to any path
   (`DEST=`, for example the cloud folder) under a new timestamped name that is never overwritten.
   A restore task restores one (`FROM=`), after which the server needs unsealing.
   - Scheduling is optional. The host recommends a host scheduler (Windows Task Scheduler running
     the task through `task dc:exec`), and a Feature option `backupInterval`, off by default, runs
     backups while the server is up and unsealed.
   - The status task shows when the last backup was taken and where.
   - This is how server mode meets ADR 0045: a machine loss loses at most what came after the last
     backup.

Findings that concerned only the earlier design are dropped: section 4's automatic copy into
`snapshotDir`, the snapshot after every write, and the snapshot in the shutdown check. What the
rulings leave uncovered is finding 1.

**Requirements (NFR-1 to NFR-13):**

- NFR-1 owns-its-state: met (section 3: the `openbao-${devcontainerId}` volume, `openbao-setup`
  through `dcf-persist`, the token in the volume). The live store is tier 4 and is carried out of
  the machine only by the backups (finding 1).
- NFR-2 registered-taskfile: needs a change. The Feature's namespace is `openbao:`, so the ruled
  `bao:backup` / `bao:restore` / `bao:status` are `openbao:backup`, `openbao:restore` and
  `openbao:status` (finding 2). Each new task needs a `desc`.
- NFR-3 verified-and-pinned: met. The server is the same `bao` binary the Feature already
  installs and verifies; no new download.
- NFR-4 augments-not-replaces: does not apply (no official OpenBao Feature is in play).
- NFR-5 idempotent-and-user-neutral: met for the start hook (section 3: a live PID is reused, it
  never waits or prompts). The `backupInterval` timer must also start once and never fail the start
  (finding 1).
- NFR-6 one-way-to-configure: not met as written. `OPENBAO_MODE` breaks the collection's
  `<ID>_SETUP_*` override naming; `backupInterval` needs its twin too (finding 4).
- NFR-7 agent-ready: not met as written. No task is marked `interactive`, and `openbao:init` prints
  the shares (finding 3). `openbao:backup` must be non-interactive to be schedulable.
- NFR-8 documented-to-the-standard: needs work at build. Item 3 (state) gets the volume and the
  backup. Item 8 (limits) gets the window since the last backup, the sealed-server case and
  retention. Item 2 gets `backupInterval`. Item 6 says the Feature only writes to the backup
  destination and takes no dependency on the cloud folder.
- NFR-9 says-why-it-exists: unchanged by this proposal.
- NFR-10 tested-on-base-images: met in plan (section 12). Add a `mode=server` scenario,
  a `backupInterval` scenario, and Docker-free tests of the backup naming (never overwritten), the
  status line and a sealed server.
- NFR-11 linter-cli-contract: does not apply (`dcf-secret` is not a check or transform tool).
- NFR-12 vendor-neutral-contracts: does not apply. No contract for agent CLIs is defined; the
  backs' identities sit below the CLI (finding 10).
- NFR-13 manages-the-environment-not-the-cli: met. The backup is `bao operator raft snapshot save`
  plus naming, a destination and a status record, which is environment management. One overlap is
  finding 8.

**Facts checked:**

- OpenBao `file` storage removed in v2.7.0: confirmed. The v2.7.0 release notes (2026-09-23) say
  "command/server: Remove `file` storage backend support" (GH-3879); the deprecation page says
  deprecated in v2.6.0. The latest release is v2.7.2.
  - Section 4's "two embedded backends" is no longer complete: v2.7.0 adds a PebbleDB backend
    ("non-HA, durable").
  - The ruled backup is a raft snapshot, which settles raft over pebble. The NOTES should say why.
- `ssh-add -t <life> -` from stdin: confirmed here with OpenSSH 10.0p2.
  - The key loads from stdin ("Identity added: (stdin)", "Lifetime set to 60 seconds").
  - `ssh-keygen -Y sign` then signs through the agent with only the `.pub` present.
  - `ssh-add -d -` removes the key with its public key on stdin, so `key:lock` needs no file either.
- GitHub SSH-certificate verification: confirmed as far as the documentation goes.
  - "About commit signature verification" describes SSH verification only against public keys
    added to the account, requires Git 2.34 or later, and mentions no SSH certificates.
  - It also says a verified signature "remains verified within its repository's network" after the
    key is revoked, so section 13 is right.
- Raft needs (bbolt, `fsync`, lock, `disable_mlock` recommended with raft): not confirmed. The
  OpenBao configuration page fetched does not mention `disable_mlock`, and no `bao` binary was
  available to run a raft server. The claims match Vault's documentation; check them in the server
  slice.
- Restore onto a fresh server: not confirmed. `bao operator raft snapshot restore` needs a token,
  so a new machine's server must first be initialised with throwaway shares and logged in. Only
  then does `-force` restore the snapshot, which is unsealed with the original shares (Vault's
  documented flow). The ruled restore task must do or explain that step (finding 1).

### Findings

1. **ADR 0045 and the ruled backup: what it does not cover yet.** The backup makes server mode meet
   ADR 0045 to the extent the ruling states: a machine loss loses what came after the last backup.
   The rest of what the backup needs is not specified.
   - **Snapshot privileges.** A raft snapshot needs a token allowed `read` on
     `sys/storage/raft/snapshot`, and a restore `update` on `sys/storage/raft/snapshot-force`.
     Section 5 gives the Operator's policy "not `sys/` beyond that". `backupInterval` and a host
     scheduler run when no Operator is there, and the Operator's token lives 4 to 8 hours
     (decision 4), so an overnight scheduled backup has no valid token.
     Recommended change: a dedicated AppRole `backup` whose policy allows only the snapshot read,
     bound to loopback like the backs' (section 7). The Operator's policy gets the restore path.
     The root token stays revoked.
   - **A sealed server.** No backup can be taken while sealed, and after a container start the
     server stays sealed until the Operator unseals it. A host scheduler firing then fails every
     time, unnoticed.
     Recommended change: the backup task exits with its own code and one line when sealed or not
     logged in (the `dcf-secret` codes 11 and 12). The status task shows the last backup's age and
     warns past a limit. The briefing's sealed line also says how old the last backup is.
   - **Retention.** "Never overwritten" means the destination only grows, and a snapshot carries
     every secret (ciphertext under the barrier, useless without the shares). Old snapshots also
     keep keys that were retired since.
     Recommended change: an option `backupKeep` (the last N, default for example 30) that removes
     only files matching the Feature's own name pattern in `DEST`. Never remove anything else.
   - **The window.** The rare writes (`openbao:ssh:new`, `:rotate`, `:import`, `approle:issue`) are
     the ones a loss would cost.
     Recommended change: after a write, the task prints "not backed up since <time>; task
     openbao:backup DEST=…". It runs the backup itself only when a default destination is
     configured (`OPENBAO_SETUP_BACKUP_DEST`).
   - **Two machines, one destination.** If two machines back up into one cloud folder, the
     section-4 fork comes back.
     Recommended change: the file name carries the container or machine name. The restore task
     warns when the newest file in the folder is from another machine than its store's last
     backup. This keeps decision 3 open (open question 4).
   - **A fresh machine.** `openbao:init` should refuse when a backup is named or found and point
     at `openbao:restore`. The restore task does the throwaway init described under "Facts checked".
   - **The host scheduler.** ADR 0026 allows a one-shot command on the host, and a Task Scheduler
     entry running `task dc:exec` is one. ADR 0024 decision 3 rules out a background process of
     ours on the host, so the launcher must not install or own the schedule.
     Recommended change: the NOTES give the Task Scheduler line as the consumer's own setup on the
     workstation, and no launcher task registers it.
   - **The operator key.** A key that cannot be made again (the register's operator key) is still
     lost for whatever window a backup leaves. Recommended change: keep decision 2's offline second
     anchor, now as the backstop to the backup window rather than the only protection.

2. **NFR-2: the ruled task names are outside the Feature's namespace.** A Feature's tasks appear
   under `<id>:`, and the id is `openbao`.
   - `bao:backup`, `bao:restore` and `bao:status` would be `openbao:backup`, `openbao:restore` and
     `openbao:status`.
   - `openbao:status` already exists as a pass-through of `bao status`. Adding the last-backup line
     there changes a pass-through.
   Recommended change: `openbao:backup DEST=`, `openbao:restore FROM=`, and the last backup shown
   by `openbao:server:status` (new in section 3). `openbao:status` stays the CLI's own.

3. **NFR-7: `openbao:init` must never run in an agent's session.** It prints the unseal shares
   once. Run by an agent, or by the Operator in a session a back condenses, the shares land in a
   transcript and then in the stretch the scribe reads. Section 9 says "never in the container",
   and a transcript is in the container.
   Recommended change: mark `openbao:init`, `openbao:unseal`, `openbao:login`, `openbao:restore`
   and `openbao:ssh:import` `interactive: true`. Make `init` refuse without a terminal, and when
   `DEVHOST_JOB_CHILD` or an agent's environment is set. The NOTES tell the Operator to run it in a
   plain terminal (or with `-pgp-keys`). `openbao:backup` stays non-interactive.

4. **NFR-6: the override variables are misnamed.** The collection's per-container override of an
   option is `<ID>_SETUP_<OPTION>`, as in `SSH_AGENT_SETUP_KEY_MODE` and `GIT_SETUP_HOOKS_PATH`.
   Recommended change: rename `OPENBAO_MODE` to `OPENBAO_SETUP_MODE`. `backupInterval` gets
   `OPENBAO_SETUP_BACKUP_INTERVAL`. `DEST` and `FROM` are task variables. `DCF_SECRET_MOUNT` and
   `DCF_SECRET_AS` are plain runtime variables and stay.

5. **Decision 1 ("every private key") contradicts socket mode, which section 10 keeps unchanged.**
   ssh-agent's default rule is that a host-held key never enters the container. Section 10 says
   a socket-mode consumer changes nothing, so its keys stay on the workstation. That is a second
   master by the definition in section 6. And `key:load` in socket mode puts an OpenBao key into
   the workstation's agent. Section 7 refuses this for the backs but allows it for the Operator's
   register key.
   Recommended change: scope decision 1 as "every private key the collection creates or stores".
   Keys the workstation holds stay the workstation's. Say what `key:load` does in socket mode:
   load into the host agent with the lifetime, or refuse.

6. **ADRs this amends, beyond 0046, are not named.** Section 10.4 names only ADR 0046. The design
   also changes:
   - ADR 0029: rotation moves from `ssh-agent:key:rotate` to `openbao:ssh:rotate`, and retiring no
     longer keeps a local `allowed_signers` history in the key volume (it moves to a committed file).
   - ADR 0026: `dc:ssh-key-import` streams into the key volume today; it becomes a stream into
     `openbao:ssh:import FROM=file`.
   - ADR 0024 decision 7: the opt-in `DCF_HOST_SSH_AGENT=key` and its "key never enters the
     container" trade-off are renamed (decision 6).

   The backup ruling also needs its ADR: how server mode meets ADR 0045, which does not change
   0045 itself. Recommended change: section 10.4 names a new ADR that supersedes 0046 and the parts
   of 0029 and 0026 it changes, and records the backup route. One ADR may do all of it. ADR 0024
   decision 7's value stays accepted for one major.

7. **The storage choice should be stated as settled by the backup.** Section 4 weighs only raft
   against `file`, and v2.7.0 also offers PebbleDB. The ruled backup is a raft snapshot, which
   decides it.
   Recommended change: section 4 says raft is chosen because `bao operator raft snapshot` is the
   backup, and pebble is not used.

8. **NFR-13: `dcf-secret get` overlaps the existing `openbao:kv:get` task.** Both are
   `bao kv get`. The exit-code mapping in `dcf-secret` is environment management (callers learn one
   contract), so it belongs. But two read paths for one action goes against "Tasks are the API".
   Mapping sealed, denied and missing also needs `bao`'s own signals (`bao status` exit 2 when
   sealed, the HTTP status in `-format=json`), not parsed English.
   Recommended change: keep `openbao:kv:get` as the raw CLI pass-through and document
   `dcf-secret` as the callers' interface. Build the mapping on `bao status` and JSON output.

9. **Placement: the AppRole roles for the backs belong to the devhost, not the openbao Feature.**
   Section 3 has `openbao:init` create "approle for the backs". The names scribe, secretary,
   librarian and tester are this way of working's and mean nothing to another consumer of a
   published Feature.
   Recommended change: the openbao Feature offers generic `openbao:approle:issue ROLE=
   POLICY_PATH=` and `:revoke`, and ships one role of its own, `backup` (finding 1). The devhost
   local Feature creates one role per back and its policy on `dcf/register/<principal>`.

10. **Placement: a back's key fetch belongs in the back's shell runner, not the model's session.**
    Backs run as `claude -p` from `run-job.sh`. If the model itself ran
    `DCF_SECRET_AS=scribe dcf-secret get ...`, the private key would pass through its tool output
    and transcript. The route would also depend on Claude Code's environment handling (matrix row
    "Env or settings into the session": Claude Code takes the settings file only).
    Recommended change: section 7 says the fetch to tmpfs, the signing and the removal run in the
    devhost's job runner around the CLI, never as a tool call. The key then never reaches a model,
    and the route is the same for every CLI.

11. **The register's own key creation is a second writer.** `agentic-register key new` and `rekey`
    generate keys into the volume's `keys/<principal>` (`cli.py`). Section 10 deprecates that path,
    but the register would still write new keys there, and section 6 rules out a second master.
    Recommended change: the agentic-register slice gives `key new` and `rekey` a way to hand the
    new private key to `dcf-secret put` on stdin (or to print it to stdout only), and stops writing
    `keys/` when the openbao Feature is present.

12. **Placement: the SSH lifecycle tasks reach back into ssh-agent.** `openbao:ssh:rotate` keeps
    ADR 0029's four steps. Two of them belong to ssh-agent (`key:load`, `git:signing`/`git:verify`)
    and one to gh. The openbao Feature would then know SSH, git and GitHub, and depend on
    ssh-agent at run time, the reverse of the split in section 2.
    Recommended change: the openbao Feature keeps the secret record (create, put, retire versions,
    age from KV metadata). The SSH steps call `task ssh-agent:*` and `gh`, refusing plainly when
    absent.

13. **`allowed_signers` in the repository needs a path git resolves the same everywhere.**
    `git:signing` writes either global config (the git Feature's volume, in this devhost) or repo
    config, which is shared with Windows through `.git-dirs` (ADR 0020).
    - A repo-relative `.devcontainer/allowed_signers` in global config points at the wrong file in
      every other repository.
    - An absolute container path in repo config means nothing to git on the Windows host.
    Recommended change: section 8 states how `gpg.ssh.allowedSignersFile` is set (repo scope with a
    work-tree-relative path checked against git's resolution, or written per repository by
    `git-setup`), and adds a test for it.

14. **ADR 0040: the Operator does not commit.** Section 10's table, step 3, has the Operator
    "commit the `allowed_signers` file".
    Recommended change: "the host commits the `allowed_signers` file", as section 8 already says.

15. **Lexicon: new concepts need terms.** `LEXICON.md` has none of these:
    - sitting (used in ADR 0046 and throughout; proposed: the span between the Operator's login and
      the token's end)
    - seal and unseal, and unseal share
    - the gate
    - master of secrets
    - server mode and client mode
    - backup (a raft snapshot written once to a destination) and restore
    - secret name (the logical `ssh/`, `register/`, `token/` names)
    - back identity (an AppRole role per back)
    - the register's operator key, anchor and principal (used here and in the register's README, not
      in the lexicon)
    - key mode, and its 2.0 successor

    Terms used and already defined are used as defined: back, stretch, storage tier, shared
    folder, shutdown check, host.
    Recommended change: the librarian adds these terms when the proposal is accepted, and section 9
    or 14 defines the sitting, since decision 4 rests on it.

### Open questions for the Operator

- **The backup's identity** (finding 1): an unattended backup needs a token outliving the
  Operator's sitting. Recommendation: a `backup` AppRole limited to the snapshot read, loopback
  only.
- **Retention in the destination** (finding 1): keep every backup forever, or let the Feature
  remove its own oldest files. Recommendation: `backupKeep`, default 30, touching only the Feature's
  own file pattern.
- **Back up after each write** (finding 1): only print the reminder, or also back up automatically
  when a default destination is configured. Recommendation: both. The reminder always prints, and
  the automatic backup runs only with `OPENBAO_SETUP_BACKUP_DEST` set.
- **Two machines, one destination** (finding 1, decision 3): recommendation: one machine is the
  master. File names carry the machine, and the restore task warns about a newer backup from
  another machine.
- **Who owns the SSH key lifecycle** (finding 12): the openbao Feature calling ssh-agent and gh,
  or ssh-agent's tasks with OpenBao as their store. Recommendation: the record in openbao, the SSH
  steps in ssh-agent's tasks, which the openbao tasks call.
- **Decision 1's reach in socket mode** (finding 5): do keys held by a workstation stay out of
  OpenBao, and may `key:load` put an OpenBao key into the workstation's agent? Recommendation:
  workstation keys stay the workstation's, and `key:load` into a host agent is allowed with the
  lifetime, said in the output.
