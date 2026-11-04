# Proposal: OpenBao is the master of secrets, ssh-agent only does SSH

Status: Proposed 2026-11-03, reviewed and ruled the same day, then reviewed a second time and ruled
again (the Rulings section has both). The Operator's decisions (section 1) and rulings are fixed, and
the design sections carry them. This proposal draws OpenBao's boundaries (phase 1); distribution and
replication are a later phase, listed but not designed. Build not started.

Who this serves: the engineers and the consumers' maintainers who use the `ssh-agent` and `openbao`
Features (they get one place where keys and tokens live, and one gate to open it), and the
Operator, who rules on the proposal and holds the gate.

How to read it: section 1 is the ask, the Rulings section is what was decided (the first rulings,
what is deferred to phase 2, and the rulings on the second review with a table of where each of its
findings is answered), sections 2 to 15 are the phase 1 design as ruled, section 16 is what is
decided and what is still unconfirmed. The two architecture reviews at the end are kept as
written; they cite the section numbers of the drafts they reviewed, which sections 1 to 13 keep (the
first draft's section 14, its decisions, is now the Rulings section and section 16), and the second
review cites sections as they were before its rulings, whose changes the table names.

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
   most what came after the last backup; the new ADR names that as a bounded-loss exception to ADR
   0045 for server mode (second-review ruling 1).
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
   - A scheduled backup uses its own `backup` AppRole, allowed only the snapshot path, loopback only
     (in server mode; in client mode the role is the server owner's, section 4).
   - When the server is sealed, the backup exits with its own code.
   - `backupKeep` defaults to 30 and removes only the Feature's own files.
   - After a write, a "not backed up since" reminder prints; the backup runs automatically only
     when a default destination is set.
   - Scheduling is the consumer's own workstation scheduler (Windows Task Scheduler running the task
     through `task dc:exec`); the launcher never registers it (ADR 0024). An optional
     `backupInterval` option is off by default (built as the second-review ruling 4 says, section 4).
   - Restore warns when the newest backup is from another machine.
3. **Onboarding: both routes.** (Section 15.)
   - (a) Restore, then rekey: a snapshot of an onboarding instance that holds only the shared keys
     (never the Operator's own store), the unseal shares handed over separately, then
     `openbao:rekey`: new unseal shares, a new root token, the sender's tokens and the backs'
     secret ids revoked and reissued for this devhost, and optionally `bao operator rotate` for new
     writes. The sender's old snapshot still opens with the old shares, which is why it holds only
     shared keys. *(Amended by the second review's rulings 2 and 5: `rotate` is the default, the
     deprecated `rekey` becomes `rotate-keys`, and the task is `openbao:onboard:claim`; section 15.)*
   - (b) Response wrapping: a one-use token for a few keys into an existing instance. *(Works only
     against a central server in client mode; section 15.)*
4. **Unseal shares:** 3 shares, threshold 2, kept in a password manager, on paper offline, and with
   a second person or on a hardware key. Never in git, the container or the shared folder.
   `openbao:init` is interactive only and refuses inside an agent's job. (Sections 3, 9.)
5. **One recovery register key stays offline, outside OpenBao**: an exception to "OpenBao keeps
   everything", stated as such. (Sections 7, 9.)
6. **The Operator's login** lasts 4 hours, at most 8, with no renewal past that. A key loaded for a
   sitting lives no longer than the token. These lifetimes apply only to a server this Feature runs
   (server mode); against an owner-run server they are the owner's, and `key:load` caps itself by
   the token's remaining time. (Sections 5, 8.)
7. **Topology: option 4 + 1 is the main shape.** One central server, optionally reached over a
   mesh network (Tailscale, WireGuard; the Feature needs only `BAO_ADDR`), plus a local read-only
   copy in each devcontainer. (Section 14; the copy is deferred to phase 2, below.)
   - **Phase 2 intent, not a phase 1 requirement: the next five bullets (the copy) may be changed by
     the amendment, and no phase 1 slice builds from them.** Their design is
     `docs/proposals/secrets-distribution.md` (on main once pull request #159 merges). In phase 1 a
     down server is exit 10 for reads and writes alike (section 6).
   - Phase 2 intent: the copy is refreshed by restoring the central server's latest backup. It unseals itself from
     the central server with transit auto-unseal, so it stays unsealed through an outage. If it
     restarts while the central server is down, it needs the shares by hand.
   - Phase 2 intent: `dcf-secret get` uses the copy only when the central server is unreachable, says it is serving
     stale data and since when, logs in to the copy itself if its token is not there, and refuses
     once the copy is older than a maximum age (an option, default 24 hours).
   - Phase 2 intent: `dcf-secret put` and every write go only to the central server. While it is
     down they exit 10, and nothing is queued. When it is back, clients return to it and the next
     refresh updates the copy. Changes flow one way only, so there is nothing to merge (the
     deferred list's open question, who the writer is and how conflicts resolve, is still open).
   - Phase 2 intent: revocations reach a copy only at its next refresh; the maximum age bounds that.
   - Phase 2 intent: this read-only fallback is its own slice after the first build.
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
     ids that do not expire, reissued at init, restore and claim (section 7);
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
local storage; the backup and restore tasks with the backup rulings; onboarding by restore then
claim (rotate-keys), and response wrapping against a central server (both use only native OpenBao
features); `dcf-secret`;
`key:load` from OpenBao; the backs' AppRoles; the unseal shares, the recovery key and the login
lifetime; ssh-agent's `keyMode` deprecation; tokens last. One central server reached as a client
is already supported in phase 1, through `BAO_ADDR`. The server work is built in three pull
requests (second-review ruling 5, section 12).

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
| 1 backup coverage (privileges, sealed server, retention, window, two machines, fresh machine, workstation scheduler, operator key) | sections 4, 5, 7, 9; the two-machine case is settled by ruling 7 rather than left open |
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

### Rulings on the second review (2026-11-03)

The Operator's rulings on the second architecture review (the section at the end of this file), all
"yes", as given. The table after them says where each of the review's findings is answered.

1. **ADR 0045: a named, bounded-loss exception.** The new ADR (section 10.4) names a bounded-loss
   exception to ADR 0045 for server mode: a machine loss loses at most what was written since the
   last backup. `openbao:init` asks for a backup destination or an explicit "no backup", and records
   the answer in the server's state. (Sections 3, 4, 10.)
2. **Onboarding trusts the sender only for what was in the snapshot.** Key rotation (`bao operator
   rotate`) is on by default after a restore. For anything stricter, use a one-use token against a
   central server, or a fresh instance. The deprecated `rekey` is replaced by `rotate-keys`. The task
   was `openbao:rekey`; it is now `openbao:onboard:claim`, because the old name is the deprecated
   command's, says only that new shares are made, and invites confusion with `bao operator rotate`,
   while the task also rotates the data key, revokes everything the sender held and reissues the
   secret ids ("claim" says what the receiver does with a store that was someone else's). The
   mechanism that revokes the sender's tokens, users, roles and secret ids after a restore is named
   in section 15 (accessor listing, revocation by prefix, role deletion, user deletion); whether
   each call does what is claimed is **unconfirmed**, and the build checks it with a test that a
   token and a secret id taken from the snapshot fail afterwards (section 16).
3. **Restore authority.** `snapshot-force` is dropped from the Operator's policy. A restore needs a
   root token generated from the unseal shares, used once and revoked. (Sections 4, 5.)
4. **Check OpenBao's own scheduled snapshots, and the `openbao/openbao-snapshot-agent`, first**, and
   use them if they fit (NFR-13), before building `backupInterval` and `backupKeep`. Scheduled
   backups stay optional and OFF by default, whichever way they are built. (Section 4.)
5. **Slice 2 is three pull requests**: server mode; backup and restore; onboarding (rotate, wrap and
   unwrap). (Section 12.)

**Where the second review's findings are answered.** The numbers are the review's own.

| Finding | Where it is answered |
|---|---|
| 1 ADR 0045 and the default | ruling 1 above; sections 3 (`init` asks), 4 (the exception, `backup-choice`, the standing warning), 10.4 (the ADR names it) |
| 2 rekey alone does not protect later backups | ruling 2; section 15a (the guarantee stated exactly, rotate on by default, `rotate-keys`, the names the receiver replaces); task renamed, reason in ruling 2 |
| 3 the sender's access is not dead | ruling 2; section 15a step 3 (the mechanisms, the test), section 7 (`approle:issue ALL=1`), sections 12 and 16 |
| 4 `snapshot-force` in the Operator's policy | ruling 3; sections 4 (restore), 5 (the policy) |
| 5 response wrapping | section 15b: central server in client mode only (also sections 14, 16), one token per secret, TTL default 15 minutes and cap 1 hour, lookup and creation-path check before unwrapping, no printing of the token, two addresses |
| 6 the agent-job refusal | section 3 (one rule for every task that handles a share or a token), section 12 (a test per task) |
| 7 check before building the schedule | ruling 4; section 4 (scheduled backups); not applied: the review's "`backupInterval` can wait for a later minor" if nothing fits, because ruling 4 keeps it optional and off by default, built either way |
| 8 client mode and the `backup` role | sections 3 and 4 (a role or token the owner provides, exit 13), 5 (lifetimes only in server mode, `key:load` caps itself), 14 (the central server is always owner-run) |
| 9 the onboarding instance | section 15a (`openbao:onboard:export`, the onboarding marker, the restore warning), section 16 (two servers in one container unconfirmed) |
| 10 restore and the devhost's roles | sections 3 and 7 (`openbao:approle:issue ALL=1`, generic), 4 (restore ends by calling it) and 15 (claim calls it) |
| 11 exit codes and small gaps | section 4 (the two exit-code tables side by side, the snapshot file removed, a write exits 0 when its backup fails), section 6 (the numbers), section 16 (no longer "none") |
| 12 lexicon | section 13 (the terms the librarian adds, and the review's list); "host scheduler" is now "workstation scheduler" throughout |
| 13 ADR order and slice 2 | ruling 5; section 12 (the ADR is slice 0, before slice 1; slice 2 is 2a, 2b and 2c) |
| 14 phase boundary | ruling 7's copy bullets above are marked "phase 2 intent" and point to `docs/proposals/secrets-distribution.md`; exit 10 for a down server stays (section 6) |

The review's requirement notes are applied too: `OPENBAO_MACHINE` is a runtime variable and the
wrapping TTL a task variable, neither an option (section 3); the throwaway init is safe to run twice
(section 4); the tests the review lists are in section 12; NFR-9 (is there a published OpenBao
Feature) is checked in slice 1 (sections 12, 16).


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
both: in client mode it needs a role or token the server's owner provides (section 4).

**Server mode** adds:

- **The start hook** (`postStartCommand`, `openbao-setup start`) writes the server's config into the
  volume if it is missing, starts `bao server` in the background (its PID in the volume; a live one
  is reused), and prints one line: `openbao: server started, sealed; the Operator runs task
  openbao:unseal`, or, on the first start, `not initialised; task openbao:init` (or `task
  openbao:restore` when a default backup destination holds backups). It never waits for an unseal
  and never prompts: the lesson of `ssh-passphrase-wait` (a start hook that waits holds every
  Feature's start). When `backupInterval` is set and the Feature runs its own timer (section 4,
  scheduled backups) it starts it once (a live one is reused) and never fails the start because of
  it (NFR-5).
- **The config**: storage `raft` at `/var/lib/devcontainer-features/openbao/raft`, `node_id` fixed
  (`devhost`); one `tcp` listener on `127.0.0.1:8200` with TLS off (it never leaves the
  container's loopback; another container cannot reach it); `cluster_addr` on `127.0.0.1:8201`;
  `disable_mlock = true` (a container has no `IPC_LOCK` by default; the server slice checks this
  and raft's needs against OpenBao's own documentation, which the review could not confirm); no UI.
  `BAO_ADDR` defaults to `http://127.0.0.1:8200` in server mode.
- **Tasks**, all under `openbao:` (NFR-2), each with a `desc` (section 12 says which pull request
  adds each):
  - `openbao:init` (once): `bao operator init` with 3 shares, threshold 2 (section 9); enables the
    `dcf` KV v2 mount, `userpass` for the Operator, `approle`, the `backup` role and its policy, the
    file audit device in the volume, the Operator's policy; **asks for a backup destination or an
    explicit "no backup"** and records the answer in the volume (`backup-choice`: a path, or `none`
    with the date; section 4, second-review ruling 1); prints the shares once and revokes the root
    token at the end. It follows the rule below, and also refuses when a backup is named or found
    in the default destination, naming `openbao:restore`. The NOTES tell the Operator to run it in a
    plain terminal (or with `-pgp-keys`).
  - `openbao:unseal` (asks for a share at `bao operator unseal`'s own prompt until the threshold is
    met), `openbao:seal`.
  - `openbao:backup`, `openbao:restore` (section 4); `openbao:onboard:claim` and
    `openbao:onboard:export` (section 15a); `openbao:wrap`, `openbao:unwrap` (section 15b).
  - `openbao:approle:issue ROLE= [POLICY_PATH=]` makes a role or adds a secret id, and
    `openbao:approle:issue ALL=1` reissues every role in the store (section 7); `openbao:approle:revoke
    ROLE=`: generic, so the Feature never calls a devhost task; the roles for the backs are the
    devhost's (section 7).
  - `openbao:server:status`: seal state, the last backup's age and place (or the standing "no
    backup" warning), and a warning past `backupWarnAfter` (section 4). `openbao:login`,
    `openbao:status` (the CLI's own `bao status`) and `openbao:kv:get` exist already and stay as they
    are.
  - **One rule for every task that handles a share or a token** (the second review's finding 6):
    `init`, `unseal`, `restore`, `onboard:claim`, `onboard:export`, `wrap` and `unwrap` are
    `interactive: true` and refuse without a terminal and when `DEVHOST_JOB_CHILD` or another
    agent's job environment is set, each naming why (the shares or the token must never land in a
    transcript, which the scribe reads). `-pgp-keys` is offered where new shares are printed
    (`init`, `onboard:claim`, `onboard:export`). `openbao:login` and `openbao:ssh:import` are
    `interactive: true` as well. `openbao:backup` is non-interactive, so it can be scheduled (NFR-7).
- **No shutdown-check contribution.** The shutdown check (ADR 0022) takes no snapshot (ruling 1).
  `openbao:server:status` is where the Operator sees how old the last backup is.

**Client mode** is today's Feature plus the volume and `dcf-secret`. The server's address,
TLS, auth method, token lifetimes and policies are the server owner's; the Feature only needs the
`dcf` mount layout of section 6 (or `DCF_SECRET_MOUNT` naming another mount). The `backup` role
and the Operator's policy are made by `openbao:init`, which is server mode only, so in client mode
`openbao:backup` runs with a role or token the owner provides (section 4), and the 4 and 8 hour
login of section 5 is the owner's to set.

**Options this proposal adds** (each with its `OPENBAO_SETUP_*` twin):

| Option | Default | Twin | Section |
|---|---|---|---|
| `mode` | `client` | `OPENBAO_SETUP_MODE` | 3 |
| `backupDest` | empty (no automatic backup) | `OPENBAO_SETUP_BACKUP_DEST` | 4 |
| `backupKeep` | `30` | `OPENBAO_SETUP_BACKUP_KEEP` | 4 |
| `backupInterval` | empty (off) | `OPENBAO_SETUP_BACKUP_INTERVAL` | 4 |
| `backupWarnAfter` | `7d` | `OPENBAO_SETUP_BACKUP_WARN_AFTER` | 4 |

`backupInterval` and `backupKeep` configure OpenBao's own scheduled snapshots or its snapshot agent
when the check in section 4 finds one that fits, and the Feature's own timer and pruning when not;
either way scheduled backups are optional and off by default.

`DEST`, `FROM`, `KEEP`, `NAMES`, `TTL` (the wrapping TTL, default 15 minutes, cap 1 hour, section
15) and `ROTATE` are task variables; `OPENBAO_MACHINE` (the machine name in backup files, default
the hostname), `DCF_SECRET_MOUNT` and `DCF_SECRET_AS` are plain runtime variables. None of these
is an option, so none needs a `OPENBAO_SETUP_*` twin (NFR-6).

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
   backup-choice    a path, or "none" and the date
   .vault-token     the Operator's login
```

ADR 0045 says losing a machine must lose nothing. Server mode meets it two ways: by an external
server (client mode, the server owner's storage), or by backups. **The second is a named,
bounded-loss exception to ADR 0045, written into the new ADR (section 10.4)**: a machine loss
loses at most what was written since the last backup, and the Operator accepts that window
(second-review ruling 1). It is a choice and never a silent default: `openbao:init` asks for a
backup destination or an explicit "no backup" and records the answer in the volume
(`backup-choice`), and `openbao:server:status` shows the destination, or a standing "no backup"
warning until one is set. The unseal shares, the other thing a machine loss must not take, are
kept off the machine by section 9.

**`openbao:backup [DEST=<path>]`** (`DEST`, else `backupDest`, else the destination recorded at init;
none of the three refuses). Non-interactive, so it can be scheduled (NFR-7):

1. Logs in and runs `bao operator raft snapshot save` to a file in a private folder on tmpfs (mode
   0600). In server mode it logs in with the `backup` AppRole (section 7). **In client mode there is
   no Feature-made role** (`openbao:init` makes it, in server mode only, and it is bound to
   loopback): it uses the role or token the server's owner provides, named by `DCF_SECRET_AS` or
   the sitting's token. A token that may read `sys/storage/raft/snapshot` on a shared server can copy
   every tenant's store out, so granting it is the owner's call, and the Feature never asks for it.
2. Copies the file whole into `DEST` as `openbao-<machine>-<YYYYMMDDTHHMMSSZ>.snap` (`<machine>` is
   `OPENBAO_MACHINE` when set, else the hostname). A name that exists is never overwritten. A new
   file is never a conflict in `sync` and needs no hard link in `mount`.
3. **Removes the temporary snapshot** after the copy and after a failed copy (a trap on exit,
   success or failure): the file is ciphertext but it is the whole store, and none stays at rest.
4. Records the time, the path and the sha256 in the volume's `last-backup`.
5. With `backupKeep` (or `KEEP=`), removes the oldest files in `DEST` that match the Feature's own
   name pattern for this machine beyond the last N. Nothing else is ever removed.
6. Prints the snapshot's path and sha256.

Exit codes, each with one line naming the fix. **The numbers are `dcf-secret`'s (section 6) where
they mean the same thing, and the two tables are kept side by side:**

| Exit | `openbao:backup` | `dcf-secret` (section 6) |
|---|---|---|
| 0 | written | the value is on stdout |
| 10 | the server is unreachable | the same |
| 11 | sealed (what a workstation scheduler's history shows after an unattended container start, ruling 2) | the same |
| 12 | cannot authenticate: no token, it expired, or the role cannot log in | no token, or it expired |
| 13 | the snapshot read is denied (the policy; in client mode the owner's) | the token may not read this name |
| 14 | does not apply: there is no secret name | no such secret |
| 20 | `DEST` missing or not writable | does not apply |

**After a write.** Every task that writes a secret (`openbao:ssh:new`, `:import`, `:retire`,
`dcf-secret put`, `openbao:approle:issue`, `openbao:onboard:claim`) ends with `not backed up since
<time>; task openbao:backup DEST=...`. It runs the backup itself only when a default destination is
set (`backupDest`, or the one recorded at init; ruling 2). **The write stands whatever the backup
does:** if the backup fails (the folder is missing, the server is sealed) the task still exits 0 and
prints the backup's own line and the meaning of its code.

**Scheduled backups** are optional and off by default, whichever way they are built (second-review
ruling 4).

- **Check first (NFR-13).** Before building a timer or pruning, the backup and restore pull request
  (section 12, 2b) checks OpenBao's own documentation for scheduled (automatic) raft snapshots and
  the `openbao/openbao-snapshot-agent` repository. Neither is confirmed (section 16). One fits if
  it writes a never-overwritten file named by machine and time to a path, prunes only its own files,
  skips a sealed server without a loop, and needs no standing token that we would have to keep. If
  one fits, `backupInterval` and `backupKeep` configure it, a downloaded agent is verified and
  pinned (NFR-3), the status reads what it wrote, and the NOTES name it. If neither fits, the NOTES
  say why the Feature does it itself, and it is built as the next bullet says.
- **The Feature's own, only if nothing fits:** `backupInterval`, a timer started by the start hook,
  running the backup while the server is up and unsealed, into the default destination; a sealed
  server is skipped with one line in the volume's log, not retried in a loop. `backupKeep` is the
  pruning of step 5.
- **The consumer's own workstation scheduler**: a Windows Task Scheduler entry running `task dc:exec --
  task openbao:backup` is a one-shot command on the host (ADR 0026). The NOTES give the line as the
  consumer's own setup; no launcher task registers it, since ADR 0024 decision 3 rules out a
  background process of ours on the host.
- Either way, `openbao:server:status` shows the last backup's age and place and warns past
  `backupWarnAfter`; the devhost briefing's sealed line says how old the last backup is.

**`openbao:restore FROM=<file>`** (interactive; refuses in an agent's job, section 3). A restore needs
a token allowed to restore, and the Operator's policy does not hold `sys/storage/raft/snapshot-force`
(section 5, second-review ruling 3), so **the root token comes from the unseal shares and is used
once**:

- On a **fresh server** (not yet initialised) the task first initialises it with throwaway shares,
  logs in with that root token, runs `bao operator raft snapshot restore -force`, and discards the
  throwaway shares and token (the review's "Facts checked"). It is safe to run twice: a half-done
  restore leaves a marker, and the next run starts again from an empty raft folder (NFR-5).
- On a **store already in use** it asks for a quorum of the current shares, makes a root token with
  `bao operator generate-root`, restores, and revokes the token.
- Either way the restored store is sealed under the snapshot's own shares. The task then asks for
  those (the prompt of `openbao:unseal`), makes a root token from them, runs
  `openbao:approle:issue ALL=1` (the secret ids' files in the volume are not in the snapshot, and
  the ids in the store are the old ones; section 7), and revokes the root token, so the backs and the
  `backup` role work again with no step per role (the second review's finding 10). If the Operator
  stops before that, `openbao:unseal` then `openbao:approle:issue ALL=1` finish it.
- It warns when the newest Feature backup beside `FROM` is from another machine than the store's
  last backup, unless the snapshot carries the onboarding marker (section 15a), when it says
  "onboarding" and names `openbao:onboard:claim` instead. Restoring one's own backup restores one's
  own access; restoring someone else's snapshot is onboarding, and the next task is `claim`.

**A snapshot is ciphertext**: the store is encrypted by OpenBao's barrier, and the barrier key is
protected by the unseal shares. A snapshot without the shares is useless; with them it is
everything. So the shares never go where the backups go (section 9). Old snapshots keep keys
retired since; `backupKeep` bounds how long.

### Slice 2b findings (2026-11-04): the check of scheduled snapshots, and what restore needs

Recorded by the backup and restore build (openbao 1.3.0), from OpenBao's tree and documentation and
from a real 2.7.2 server.

- **Scheduled snapshots (second-review ruling 4): nothing fits, so the Feature builds `backupInterval`
  and `backupKeep` itself.** OpenBao has no scheduled or automatic raft snapshots (the API page lists
  only the snapshot read, the restore and `snapshot-force`; the Vault feature of that name is
  Enterprise). `openbao/openbao-snapshot-agent` (v0.4.5, MPL-2.0) is a recipe: an OpenBao Agent for
  authentication plus a systemd timer or cron job running `bao operator raft snapshot save` to a
  date-named file and `find -mtime` for retention. It needs systemd or cron (a devcontainer has
  neither), names files by date with no machine and no overwrite check, prunes by age over everything
  in the folder, and has no sealed case. The Feature's own timer (started by the start hook, off by
  default) and pruning (only its own name pattern) are built, and the NOTES give the Task Scheduler
  line.
- **Capabilities:** `read` on `sys/storage/raft/snapshot` is all a snapshot save needs (a role with
  only that saves one and is denied `snapshot-force`); a restore is `update` on `snapshot` or
  `snapshot-force`.
- **A restore needs the snapshot's own shares, and `-force` across different shares.** A plain restore
  into a server with other shares is refused ("could not verify hash file ... use the snapshot-force
  API"), so the throwaway init uses `restore -force`; the node then seals itself and opens only with
  the shares of the store the snapshot came from.
- **Finding that changes section 5's "root token from the shares": from OpenBao 2.6.0 `bao operator
  generate-root` is authenticated** (`sys/generate-root-token`; the unauthenticated `sys/generate-root`
  is deprecated and off by default: an unauthenticated call is a 403). A root token cannot be made from
  the shares alone: it needs a login that may call the endpoint. The Feature gives the Operator's login
  a small policy `rootgen` (start an attempt, give a share; only two shares complete it) written by
  `init`, and the policy that narrows the Operator (ruling 3) must not remove it; the throwaway-init
  path needs no root-from-shares step at all (the throwaway root token is the token), and the restore
  ends with the Operator's own login (a password prompt) to reissue the secret ids instead of a second
  root token, which saves two share entries. A store initialised before 1.3.0 has no `rootgen`.

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
- **What the Operator's policy allows**: read and write everything under `dcf/`, the snapshot read
  (`sys/storage/raft/snapshot`), AppRole secret ids; not `sys/` beyond that. **Not
  `sys/storage/raft/snapshot-force`** (second-review ruling 3): a 4-hour token must not be able to
  replace the whole store with an old snapshot that revives revoked secret ids and retired keys. The
  root token is revoked after `init` and made again only from a quorum of the shares (`bao operator
  generate-root`), used once and revoked, when a policy must change, at a restore (section 4) and at
  a claim (section 15).
- **Where the lifetimes apply.** The 4 and 8 hours are set on a server this Feature runs (server
  mode). In client mode the login is whatever the owner's server offers and its lifetimes are the
  owner's (ruling 6). `key:load`'s lifetime, at most what is left of the token (section 8), still
  holds in both, because it reads the remaining time from `bao token lookup`.

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

- **`openbao:backup` uses the same numbers** (the table in section 4): 12 is "cannot authenticate" in
  both, 13 "denied" (the snapshot read, for the backup), and 14 does not apply to it.
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
  the backs on a date nobody is watching), and are reissued at `init`, `restore` and `onboard:claim`
  by `openbao:approle:issue ALL=1`, and on suspicion (ruling 8). The reissue is generic: for every
  role in the store it reads the role's settings, deletes the role and writes it again (issuing a new
  secret id does not end the others of the role, so the delete does), then writes one new secret id
  into `approle/<role>/secret_id`. The openbao Feature never calls a devhost task: the roles and
  their policies come back inside a snapshot, so the devhost needs nothing extra. Whether deleting a
  role ends its secret ids, and whether `token_bound_cidrs` is honoured, are checked by tests
  (section 16).

Rejected: a long-lived periodic token per back in a file (simpler, but a bearer token with nothing
to rotate it and no login step to bind); the `cert` method (a client certificate per back is a
second PKI to keep); TLS or a Kubernetes-style platform identity (the container has none to offer).

**Who owns which role** (the review's finding 9):

- The openbao Feature ships one role, `backup`, made by `openbao:init` in server mode only, whose
  policy allows only `read` on `sys/storage/raft/snapshot`, loopback only. It is what a scheduled
  backup logs in with, since the Operator's token ends after at most 8 hours. Against a server
  someone else runs (client mode) there is no such role from us, and a loopback-bound role could not
  log in from the container anyway: the owner provides one (section 4).
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
| Lost machine | the volume is gone; the key must be on the host too | with a central server, nothing; otherwise restore the newest backup, unseal with the shares; what came after it is lost (the bounded-loss exception to ADR 0045, chosen at `openbao:init`), and the offline recovery key covers the register |
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
  opens with the shares it was made under, even after they claim their copy (section 15).
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
4. **One new ADR**, written when this proposal is accepted, **before slice 1** (ruling 8, the first
   review's finding 6, the second review's finding 13; section 12, slice 0):
   - supersedes ADR 0046: the register's operator key lives in OpenBao and is loaded for a sitting
     by `key:load`, gated by the unseal and the login. ADR 0046's flow carries on in practice until
     ssh-agent 1.4.0 ships; the ADR says so;
   - names what it changes in ADR 0029 (rotation's record steps move to `openbao:ssh:*`, the SSH
     steps stay in `ssh-agent:key:rotate`, and the `allowed_signers` history moves to a committed
     file) and in ADR 0026 (`dc:ssh-key-import` becomes a stream into `openbao:ssh:import
     FROM=file`); ADR 0024 decision 7's `DCF_HOST_SSH_AGENT=key` value stays accepted for one major;
   - **names a bounded-loss exception to ADR 0045 for server mode** (second-review ruling 1): a
     machine loss loses at most what was written since the last backup; the Operator accepts that
     window; `openbao:init` asks for a backup destination or an explicit "no backup" and records it;
     an external server (client mode) meets 0045 as it stands. The ADR records the backup route
     without changing 0045 itself, and its tier 4 line (keys as rebuildable only) is read against the
     exception.

**What changes for a consumer using key mode today** (this devhost, and the consumer whose request
led to ADR 0046):

| Step | Who | What |
|---|---|---|
| 1 | maintainer | `openbao` with `"mode": "server"` (and, if wanted, `backupDest`) in `devcontainer.json`; ssh-agent to 1.4.0 (`:1` picks it up); rebuild |
| 2 | the Operator, once, in a plain terminal | `task openbao:init`, store the three shares (section 9); `task openbao:unseal`; `task openbao:login` |
| 3 | the Operator, once | `task openbao:ssh:import FROM=ssh-agent`, then `FROM=agentic-register`; the host commits `.devcontainer/allowed_signers` |
| 4 | the Operator | `task openbao:backup DEST=…` once, then the workstation scheduler entry or `backupInterval` if wanted |
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
| `openbao` | 2a, server mode: raft on the volume, init (with the backup choice), unseal, seal, userpass, the generic AppRole tasks (`ALL=1`), `openbao:server:status` | 1.2.0 |
| `openbao` | 2b, backup and restore: the `backup` role, `openbao:backup`, `openbao:restore`, `backupKeep`, `backupInterval` (built per section 4's check) | 1.3.0 |
| `openbao` | 2c, onboarding: `openbao:onboard:export` / `:claim`, `openbao:wrap` / `:unwrap` | 1.4.0 |
| `openbao` | `openbao:ssh:*` records and the import | 1.5.0 |
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

Slices, each one pull request with its version bump and `task docs` (the ADR is a records change):

0. **The ADR**, with the acceptance of this proposal and before slice 1: supersedes 0046, names the
   bounded-loss exception to 0045 for server mode and the backup route, and what it changes in 0029,
   0026 and 0024 decision 7 (section 10.4). It comes first because later slices change what 0046
   decided.
1. **openbao 1.1.0**: the volume and setup hook (`openbao-state-build`), `dcf-secret` (on `bao`'s
   own signals), the `mode` option with `client` only, the `OPENBAO_SETUP_*` names. It also checks
   whether a published OpenBao Feature exists and writes NFR-9's paragraph, or "none".
2. **Slice 2 is three pull requests** (second-review ruling 5), each with its own version bump and
   tests:
   - **2a, openbao 1.2.0, server mode**: server mode, raft on the volume, init (interactive,
     refusing in an agent's job, asking for the backup destination or "no backup"), unseal, seal,
     userpass, the generic AppRole tasks including `openbao:approle:issue ALL=1`,
     `openbao:server:status`, and section 3's one rule for tasks that handle a share or a token.
   - **2b, openbao 1.3.0, backup and restore**: first the check of section 4 (OpenBao's scheduled
     snapshots, the snapshot agent); then the `backup` role, `openbao:backup` with its exit codes
     and `backupKeep`, `backupInterval` (as that check decides), `openbao:restore` (with the
     throwaway init and the root token from shares), the last backup in the status. The NOTES carry
     the Task Scheduler line.
   - **2c, openbao 1.4.0, onboarding**: `openbao:onboard:export`, `openbao:onboard:claim` (with
     `rotate-keys`, the revocations and the rotate), `openbao:wrap` and `openbao:unwrap`.
3. **openbao 1.5.0, ssh-agent 1.4.0, gh minor, devcontainer-cli minor**: `openbao:ssh:*` records,
   the import, `key:load`/`key:lock` and `key:rotate` on OpenBao, `gh:ssh-key:add`, the
   deprecations, `.devcontainer/allowed_signers` and its resolution test.
4. **agentic-register and devhost**: the backs' roles, the fetch in the job runner, the register's
   key creation into `dcf-secret put`, the briefing line. That ends the first build.
5. **ssh-agent 2.0.0**: the removal, after at least one release of 1.4.0 has been adopted by both
   consumers.
6. **gh, az, cloud-folder**: credentials from `dcf-secret` (section 11). The last slice.

**Packaging (the Operator, 2026-11-04):** after 2a (openbao 1.2.0, its own pull request), slices
2b, 2c, 3 and 4 are built in parallel and ship as **one** pull request and one release, each
Feature bumped once: openbao 1.3.0 (2b, 2c and slice 3's records and import), ssh-agent 1.4.0,
gh, devcontainer-cli, agentic-register and devhost a minor each. The table's 1.4.0 and 1.5.0 rows
for openbao fold into 1.3.0. Slices 5 and 6 are unchanged.

Tests are Docker-free where they can be: `dcf-secret` against a fake `bao` (each exit code, no
fallback when sealed), the import against a key volume made in a temp folder, the key piped to
`ssh-add -` never touching a file (checked by the folder staying empty), the backup naming (never
overwritten), `backupKeep` touching only its own pattern, the backup's exits 11, 12, 13 and 20
beside `dcf-secret`'s, the temporary snapshot folder empty after a success and after a failure, a
write task exiting 0 when its backup fails, the refusal under `DEVHOST_JOB_CHILD` **for every task
in section 3's rule** (`init`, `unseal`, `restore`, `onboard:claim`, `onboard:export`, `wrap`,
`unwrap`), init's backup choice and the status's standing warning, the status line, the start hook
returning at once on a sealed server, `wrap`'s TTL default and cap, `unwrap`'s lookup and
creation-path refusal, and a token used once failing the second time. The server itself (`bao
server -dev` is not enough for raft and seal), restore (run twice), `claim`'s revocations (a token
and a secret id taken from the snapshot fail afterwards; users, roles and audit devices are
rebuilt), the onboarding marker, and `unwrap` against a real central server are Feature tests that
need a Docker daemon, with a `mode=server` and a `backupInterval` scenario.

## 13. For the repository (found while writing)

- `src/ssh-agent/NOTES.md` says that after `REVOKE=1` "old commits show unverified at GitHub". GitHub's
  documentation now says a commit verified once stays verified in its repository's network even if
  the key is revoked. The note should say that, and `REVOKE=1` loses less than it says (only commits
  GitHub had not yet verified).
- The openbao Feature's default `version: latest` installs a release without the `file` backend
  (removed in v2.7.0); nothing uses it today. The NOTES could say raft is the storage the Feature
  uses, why (the snapshot is the backup), and that pebble is not.
- The lexicon terms of the first review's finding 15 (sitting, seal and unseal, unseal share, the
  gate, master of secrets, server and client mode, backup and restore, secret name, back
  identity, the register's operator key, anchor and principal, key mode and `localAgent`) and of the
  second review's finding 12 (onboarding instance, claim and `rotate-keys` (the OpenBao name for
  what was `rekey`), response wrapping and wrapping token, recovery key, central server, throwaway
  init, and snapshot against backup: a snapshot is the raft file, a backup is the Feature's named
  copy of it in a destination) are the librarian's when the proposal is accepted. "Workstation
  scheduler" is used in this proposal because "host scheduler" collides with Host (the main
  session) in the lexicon.

## 14. Topology (ruling 7)

Phase 1 draws the boundary: the openbao Feature talks to one server at `BAO_ADDR`, its own
(server mode) or another (client mode), and replicates nothing.

**Supported in phase 1:**

- **One central server, reached as a client**: any OpenBao server at `BAO_ADDR`, optionally over a
  mesh network (Tailscale, WireGuard); the Feature needs only the address. **It is always
  owner-run in phase 1**: the server this Feature runs is a loopback, TLS-off listener inside one
  container, and nothing in the Feature exposes it. Its TLS, storage, login lifetimes and backups
  are its owner's; `openbao:backup` in client mode uses a role or token the owner provides (section
  4). It is also the only shape in which route (b) of section 15 (a one-use wrapping token) works.
  This is ruling 7's main shape without the local copy, which is phase 2.
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

## 15. Onboarding (ruling 3, and the second review's rulings 2 and 5)

Two routes, for two needs. **The receiver trusts the sender only for what was in the snapshot**
(second-review ruling 2): the sender knows those values for good, and nothing here changes that.
For anything stricter, use route (b) (a one-use token against a central server) or a fresh instance
with the values put in again.

**(a) Restore, then claim: a new devhost starts from a set of shared keys.**

```
 sender: onboarding instance (only the shared keys, never the sender's own store)
    openbao:onboard:export ... ---- snapshot file ---->  receiver: openbao:restore FROM=
    its own fresh unseal shares ---- separately ------->  (restore asks for them, unseals)
                                                          receiver: openbao:onboard:claim
```

**The onboarding instance** (the second review's finding 9). The sender's devhost has one server
and one volume, so the shared keys are put in a second, short-lived instance, never snapshotted
from the sender's own store. `openbao:onboard:export NAMES=<name>,... DEST=<path>` (the rule of
section 3; interactive) starts a second server of the same binary with its own config and raft
folder under the volume and its own loopback port, initialises it with fresh shares (3, threshold
2; printed once, or `-pgp-keys`; these are the shares handed over, never the sender's own), copies
the named secrets in with `dcf-secret get` and `put`, writes the **onboarding marker** (a record in
it with the sender's machine name and the time), takes the snapshot into `DEST` as `openbao:backup`
does, then stops the instance and deletes its folder. The marker is what lets `openbao:restore`
say "onboarding" instead of its other-machine warning (section 4). Whether two servers can run in
one container is not confirmed (section 16); if not, the same is done in a second devcontainer in
server mode with its own volume, and the NOTES carry that procedure.

**`openbao:onboard:claim`** (the rule of section 3; interactive; run after `restore`, which ends with
the server unsealed under the sender's shares). Its old name was `openbao:rekey`; `rekey` is the
deprecated name of the command, so the task uses `bao operator rotate-keys` and a name for what
the receiver does with a store that was someone else's.

1. **`bao operator rotate-keys`**, given a quorum of the sender's shares: 3 new shares, threshold 2,
   printed once (or `-pgp-keys`), for the custody of section 9.
2. A new root token from the new shares (`bao operator generate-root`), used for the next steps and
   revoked at the end.
3. **Revokes everything the sender held** (the second review's finding 3: a restored store carries
   the sender's tokens, users, roles, secret ids, policies and audit settings). The mechanism, by
   kind; every call is **unconfirmed** in the pages read, so the build checks each with a test
   that a token and a secret id taken from the snapshot fail after the task (sections 12, 16):
   - **tokens**: list the token accessors (`auth/token/accessors`) and revoke each one but the
     task's own (`bao token revoke -accessor`), which reaches a root token that no prefix does; then
     revoke by prefix on `auth/token/create` and on each auth mount's login path. If no call reaches
     every token, the fallback is to disable and re-enable each auth mount (which revokes what it
     issued) and to rebuild what was on it from step 4's reissue;
   - **AppRole secret ids**: every role is deleted and written again (the reissue of
     `openbao:approle:issue ALL=1`, section 7), because a new secret id does not end the old ones;
   - **users**: every `userpass` user but the receiver's is deleted, and the receiver's password set;
   - **audit devices**: any not the receiver's own file device in the volume is disabled;
   - **policies**: any not in the Feature's own set or referenced by a role are listed in the
     output, for the receiver to read; none is deleted blind.
4. `openbao:approle:issue ALL=1` (generic; the roles and their policies came back in the snapshot,
   so the devhost needs nothing extra).
5. **`bao operator rotate` by default** (`ROTATE=0` skips it): new writes use a new data key.
6. Prints the names that came with the snapshot, as **the sender's knowledge**, with the line "put
   new values for these where you want them to be yours alone", and the "not backed up since" line.

**What this guarantees, exactly.** The sender holds the old shares and the old snapshot, so the
sender can read for good every value that was in it. Later backups of the receiver's store stay
unreadable to the sender only if they never reach the sender (a shared folder the sender sees
defeats it for anything still under the old key), because `rotate` protects only new writes and an
old entry stays under the old key. The review's reading that a rekey may leave the data key
unchanged (Vault's documented behaviour) is not confirmed for OpenBao and the design assumes the
worse case (section 16). That is why the onboarding instance holds only the shared keys and never
the Operator's own store.

**(b) Response wrapping: a few keys into an existing instance, against a central server in client
mode only.** A wrapping token is a call to the server that holds the wrapped response's cubbyhole.
In server mode that server is a loopback-only listener inside the sender's container, which the
receiver cannot reach, so **route (b) works in phase 1 only when the issuing server is a central,
owner-run server that the receiver's client mode reaches** (section 14). Against a server this
Feature runs, use route (a).

- `openbao:wrap NAMES=<name>,... [TTL=]` (the rule of section 3) makes **one wrapping token per
  secret** (`bao`'s `-wrap-ttl` on the read of that secret's path), not one for a bundle: a bundle
  would pass the plaintext through the task (`sys/wrapping/wrap`) and lose the creation-path check
  below. `TTL` defaults to 15 minutes and is capped at 1 hour, which the task enforces and the
  server's owner may also enforce by policy (a minimum and maximum wrapping TTL). The tokens are
  not printed by default: they are written to a file (mode 0600, on tmpfs; `OUT=`), and the task
  prints its path and the expiry; `SHOW=1` prints them, and only to a terminal.
- `openbao:unwrap FROM=<file>` (the rule of section 3; interactive; or the token at a prompt that
  does not echo, never an argument) takes two addresses: `ISSUER_ADDR=` (the central server that
  holds the cubbyhole, default `BAO_ADDR`) for the lookup and the unwrap, and the receiver's own
  `BAO_ADDR` for the `dcf-secret put`. For each token it first calls `sys/wrapping/lookup`
  (unauthenticated), checks that the creation path is the expected secret's path and that the TTL
  has not run out, and refuses with "do not unwrap; ask the sender" if not; only then unwraps once
  and puts the value.
- **The channel matters**, and the NOTES say so: a token read by anyone else before the receiver is
  already spent, and the receiver learns it only afterwards, when the unwrap fails. A token that
  fails as already used or expired is an event to investigate. The file is not the channel.

## 16. Decisions needed, and what is still unconfirmed

**Decisions needed:** none new for phase 1; the second review's five open questions are ruled
(the Rulings section). The one phase 2 question (who the writer is, and how conflicts resolve) is
the Operator's when that phase starts.

**Still unconfirmed.** None blocks the design; each names the pull request (section 12) that
checks it and what the design does if the answer is no.

| Unconfirmed | Checked by | If it is no |
|---|---|---|
| Whether `rotate-keys` or `rotate` changes the key that encrypts the data, or only the key that protects it (the pages read do not say; Vault's documentation, from memory, says `rotate` is what changes it) | 2c: documentation, then a test of what the sender's old shares open in a later snapshot | the design already assumes the worse case (section 15a); the NOTES say so |
| That an accessor listing and revoke, revocation by prefix, and deleting a role reach every token and every secret id the sender held (no single call that revokes everything is confirmed) | 2c: a test that a token and a secret id from the snapshot fail after `claim` | disable and re-enable each auth mount and rebuild from the reissue (section 15a) |
| The capabilities needed for `sys/storage/raft/snapshot` and `snapshot-force` (the fetched pages do not list them) | 2a and 2b: Feature tests (answered 2026-11-04: `read` saves, `snapshot-force` is a separate path; see "Slice 2b findings") | the `backup` role's policy and exit 13 are adjusted |
| That a restore needs a token on a fresh server (the throwaway init) and the snapshot's own shares (taken from Vault's flow) | 2b: a Feature test of restore on a fresh server, run twice (answered against a real 2.7.2 for the shares and `-force`; the task run is the CI scenario `backup_restore`) | the throwaway init is changed; nothing else depends on it |
| AppRole: that `token_bound_cidrs` is honoured, the default of `secret_id_ttl`, destroying a secret id by accessor, and that deleting a role ends its secret ids | 2a: tests | the reissue and the revocation use the call that does |
| OpenBao's own scheduled snapshots and the `openbao/openbao-snapshot-agent` (the API page returned 404; a search found Vault's, which is Enterprise, and the agent repository) | 2b, first step (section 4): answered 2026-11-04, nothing fits | the Feature's own timer and pruning, with the NOTES saying why |
| `disable_mlock` with raft, and raft's needs (bbolt, `fsync`, the lock) in a container (the configuration page does not mention `disable_mlock`) | 2a | the config or the NOTES change |
| Wrapping: `-wrap-ttl` per secret, the policy's minimum and maximum wrapping TTL, and what `sys/wrapping/lookup` returns (creation path, TTL) | 2c: a Feature test against a server | the check or the token per secret is redesigned; route (a) is unaffected |
| Two servers (the sender's and the onboarding instance) running in one container | 2c | a second devcontainer does it (section 15a) |
| Whether a published OpenBao Feature exists (NFR-9) | slice 1 writes the paragraph, or "none" | |

Phase 2's own unknowns (restoring a Shamir-sealed backup into a transit-sealed copy, unsealing a
copy by hand) are in the deferred list and not repeated here.

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

## Architecture review (2026-11-03, second: the rulings and phase 1)

**Verdict:** fit with changes

Scope: what is new since the first review (the Rulings section, the phase 1 scope, sections 4, 14
and 15, the slices) and the deferred paragraphs only as far as phase 1 depending on them. Sources read
first-hand: `docs/principles/non-functional-requirements.md`, ADRs 0024, 0026, 0029, 0045 and 0046,
`LEXICON.md`, `src/openbao/` (today's Feature: version 1.0.3, tasks `version`, `status`, `login`,
`kv:get`). The first review's findings are not repeated.

**Requirements (NFR-1 to NFR-13), the new parts only:**

- NFR-1 owns-its-state: met (section 3, the volume with `raft/`, `approle/`, `last-backup`, the
  token). The store is tier 4 and unrebuildable: see finding 1.
- NFR-2 registered-taskfile: met as drawn (all under `openbao:`, each needs a `desc`; `version` stays
  first). `openbao:status` stays the CLI's own.
- NFR-3 verified-and-pinned: met. No new download. It stops being met if finding 7 adopts a separate
  snapshot agent binary: that needs a verified download.
- NFR-4 augments-not-replaces: does not apply.
- NFR-5 idempotent-and-user-neutral: met for the start hook and the `backupInterval` timer (section 3:
  a live one is reused, never fails the start). The throwaway init in `openbao:restore` must be safe to
  run twice (a half-done restore); say so in the slice.
- NFR-6 one-way-to-configure: partly met. Four of five options have their `OPENBAO_SETUP_*` twin in
  the table, `mode` included. Not covered: `OPENBAO_MACHINE` (a new runtime variable in section 4,
  not in the table), and the wrapping TTL default (finding 5). Also
  `backupInterval` plus the workstation scheduler are two ways to schedule one action (finding 7).
- NFR-7 agent-ready: not met as written for the new tasks: finding 6 (`rekey`, `wrap`, `unseal` and
  `restore` print or take secrets and only `init` refuses in an agent's job).
- NFR-8 documented-to-the-standard: needs work at build. Item 8 (limits) must carry the finding 2 and
  finding 5 limits in plain words (what the sender can still open; wrapping needs the issuing server
  reachable). Item 3 (state) the backup and the volume. Item 6 the Task Scheduler line.
- NFR-9 says-why-it-exists: not assessed by the proposal. Whether a published OpenBao Feature exists
  was not checked here; the slice must check and write the paragraph or "none".
- NFR-10 tested-on-base-images: partly met. Section 12 lists the backup naming, `backupKeep`, exit 11,
  the init refusal and the start hook. Missing: wrap and unwrap (single use, expiry, TTL cap), rekey's
  revocations (finding 3), backup exits 12 and 20, restore run twice, and the refusal in an agent's
  job for every task finding 6 names.
- NFR-11 linter-cli-contract: does not apply.
- NFR-12 vendor-neutral-contracts: does not apply (no contract for agent CLIs).
- NFR-13 manages-the-environment-not-the-cli: mostly met; two questions (finding 7). Restore (throwaway
  init plus `snapshot restore -force`), wrap and unwrap wrap `bao` thinly, except that one wrapped
  token for several secrets is not what `-wrap-ttl` does (finding 5).

**ADRs:**

- 0045: not met by the default (finding 1). The ADR's tier 4 line even lists "keys" as rebuildable
  only, which the openbao volume is not.
- 0024: no conflict. A workstation scheduler entry is the consumer's own and decision 3 is respected;
  the in-container `backupInterval` timer is inside the container, which decision 3 allows. Decision 7's
  value stays accepted for one major, as the proposal says.
- 0026: no conflict. `dc:exec` as a Task Scheduler one-shot is the ADR's exception. Nothing new runs
  on the host.
- 0029: no new conflict from the new parts; section 8 already keeps its four steps.
- 0046: it is still in force. Slice 3 (ssh-agent 1.4.0, `key:load` from OpenBao) ships before slice 4's
  ADR that supersedes it (finding 13).

**Facts checked** (OpenBao's own documentation, fetched 2026-11-03):

- Confirmed: `bao operator raft snapshot save <file>` and `restore <file>` exist (CLI page); snapshots are
  not supported when raft is used only as `ha_storage`; with a Shamir seal a joining node needs the
  unseal keys.
- Confirmed, and it changes the design: the `bao operator rekey` page says it "is deprecated, please
  use rotate-keys instead". Both generate new unseal key shares, need the server unsealed and a quorum
  of existing shares, and are zero downtime. `bao operator rotate` is a different thing: it installs a
  new key in the key ring for new data, and older keys stay to decrypt older data.
- Confirmed: response wrapping. The original response is stored in the cubbyhole of a new single-use
  token; the client sets the TTL per request (the page gives no default); policies can enforce a minimum
  and a maximum wrapping TTL; `sys/wrapping/lookup` is unauthenticated and shows creation time, creation
  path and TTL; unwrapping needs only the token; a token already used or expired is an event to
  investigate. The page's own recommendation is: look up, check the creation path, unwrap, alert on a
  failure.
- Confirmed in part: AppRole's `secret_id_bound_cidrs` limits logins to configured CIDRs; the page
  recommends response-wrapping the secret id for delivery. `token_bound_cidrs`, the default of
  `secret_id_ttl` and destroying a secret id by accessor are not on the page.
- Not confirmed: whether a rekey or `rotate-keys` changes the key that encrypts the data or only the
  key that protects it (the pages do not say; Vault's documentation, from memory, says the data key is
  unchanged and `rotate` is what changes it); the capabilities needed for `snapshot` and `snapshot-force`
  (the fetched pages do not list them); that restore needs the snapshot's own unseal shares and needs a
  token on a fresh server (the first review took this from Vault's flow); whether any call revokes every
  token at once; whether OpenBao has built-in automated snapshots (the API page returned 404 and a search
  found only Vault's, which is Enterprise, and an `openbao/openbao-snapshot-agent` repository that takes
  snapshots with `bao operator raft snapshot save`); `disable_mlock` with raft (the raft configuration
  page does not mention it).

### Findings
1. **ADR 0045: phase 1 server mode does not meet "a machine loss must lose nothing" by default.** The
   ruled design loses everything after the last backup (section 4 says so), and out of the box there is
   no backup: `backupDest` is empty, `backupInterval` is off, and after a write only a reminder prints
   (ruling 2, section 3 options). The store cannot be rebuilt, so by the ADR's own rule it is in the
   wrong tier ("anything in tier 4 that cannot be rebuilt is a defect to move up"), and tier 4 in the ADR
   names "keys" as rebuildable only. The shares are the second thing a machine loss must not take; their
   custody is rightly off the machine (section 9). Recommended change: the new ADR (section 10.4) states
   this as a named, bounded exception to 0045 (the loss window is the time since the last backup, and
   the Operator accepts it), and `openbao:init` makes it a choice: it asks for a `backupDest` or an
   explicit "no backup" that `openbao:server:status` then shows as a standing warning.
2. **Rekey alone does not protect later backups from the sender (NFR-8 item 8, section 15a).** Section
   15 says the old snapshot "still opens with the old shares" and treats that as the whole residue. The
   fetched pages do not say that a rekey changes the data key, and `rotate` is optional (`ROTATE=1`) and,
   per its page, protects only new data: data written before stays under the old key. If the data key is
   unchanged by a rekey (Vault's documented behaviour; not confirmed for OpenBao), then a sender holding
   threshold shares can derive the key from the old snapshot and read the pre-rekey entries of any later
   snapshot of the receiver's store that reaches them, such as backups in a folder the sender can see.
   Recommended change: section 15a states the guarantee exactly: the shared keys are known to the sender
   for good; later backups stay safe from the sender only if they never reach the sender, and `rotate`
   is not a remedy for old entries. Make `rotate` default on in the task (as `ROTATE=0` to skip), name the
   keys in the snapshot as the sender's knowledge to be replaced where the receiver wants them to be his
   own, and use `bao operator rotate-keys`, since `rekey` is deprecated (the task stays named
   `openbao:rekey`).
3. **Rekey does not make the sender's access dead, and the revocation step names no mechanism
   (section 15a step 3, section 7).** A restored store carries the sender's tokens (a root token among
   them, if one was left), `userpass` users, AppRole roles with live secret ids, policies and audit
   settings; the secret ids' files in the volume are not in the snapshot, the ids in the store are.
   Section 15 says "revokes and reissues", but issuing a new secret id does not invalidate the others of
   the role. The sender cannot reach a loopback-only server, so the exposure is to a central or shared
   one (finding 8), but the design claims the property. Recommended change: name the calls and test them:
   revoke by prefix on every auth mount and the token store (an exact call is not confirmed in the pages
   read), delete and recreate each AppRole role so old secret ids die, remove every `userpass` user but the
   receiver's, and check by a test that a token and a secret id taken from the snapshot fail after the
   task.
4. **The Operator's policy holds `snapshot-force` (section 5).** A 4-hour token may then replace the
   whole store with any snapshot, including an old one that revives revoked secret ids and retired keys;
   the root token is otherwise only made from the shares. Recommended change: remove
   `sys/storage/raft/snapshot-force` from the Operator's policy; `openbao:restore` on a store that is
   already in use makes a root token from a quorum of shares (`generate-root`) and revokes it at the end,
   as `rekey` does; the fresh-server throwaway init path stays as drawn. Keep the snapshot read.
5. **Response wrapping (section 15b) needs the issuing server reachable, and a bundle is not what
   `-wrap-ttl` does.**
   - Unwrapping is a call to the server that holds the cubbyhole, so the receiver must reach the
     sender's server. In server mode that is a loopback-only, TLS-off listener in the sender's container
     (section 3): unreachable. Route (b) works in phase 1 only against a central server in client mode
     (section 14). Recommended change: section 15b says so, and `openbao:unwrap` takes the issuing
     address (`BAO_ADDR` for the unwrap, the receiver's own for the `put`; two addresses, designed in the
     task).
   - `bao ... -wrap-ttl` wraps one response. "One wrapped response for several named secrets" would need
     a composed payload (`sys/wrapping/wrap`, not confirmed in the pages read), which passes the
     plaintext through the task and removes the creation-path check. Recommended change: one token per
     secret, printed as a list, or one bundle path in KV the task writes and wraps; pick one in the slice.
   - TTL and travel. `[TTL=]` has no default, and the token alone opens it. Recommended change: a
     default of 15 minutes and a cap of 1 hour (the page says policies can enforce both), the token
     printed only to a terminal (finding 6), the receiver runs `sys/wrapping/lookup` first and checks the
     creation path and TTL before unwrapping (the page's own advice), and the sender is told the channel
     matters: a token read by anyone else before the receiver is already spent, and the receiver learns
     it only afterwards.
6. **NFR-7: the agent-job refusal covers only `openbao:init`.** Section 3 and slice 2 say `init`
   refuses under `DEVHOST_JOB_CHILD`. `openbao:rekey` prints new shares, `openbao:wrap` prints a token
   that opens secrets with no authentication, `openbao:unseal` and `:restore` take shares at a prompt, and
   `:unwrap` takes a token: each lands in a transcript if an agent runs it, and the scribe reads
   transcripts. Recommended change: one rule in section 3: every task marked `interactive: true` that
   handles a share or a wrapping token refuses without a terminal and under an agent's job environment,
   with `-pgp-keys` offered for `init` and `rekey`; a test per task (section 12 lists one).
7. **NFR-13 and NFR-6: check what OpenBao already does before building the schedule and retention.**
   `backupInterval` (a timer) and `backupKeep` (removing the oldest files) are scheduling and retention,
   the part of a backup `bao` does not claim; but Vault has automated snapshots, an
   `openbao/openbao-snapshot-agent` repository exists, and neither was confirmed or ruled out here. The
   timer is also a second way to schedule next to the workstation entry. Recommended change: the slice
   begins by checking OpenBao's own documentation for automated snapshots and the agent; if either serves,
   `backupInterval` and `backupKeep` become options that configure it (NFR-13), and a downloaded agent is
   verified and pinned (NFR-3); if not, the NOTES say why the Feature does it, and `backupInterval` can wait
   for a later minor.
8. **Client mode and the `backup` role do not fit together (sections 3, 4, 7, 14, ruling 6).**
   - Section 3 says `openbao:backup` works in client mode with "any server whose token may read the
     snapshot path"; the `backup` role is created by `openbao:init` (server mode only) and is bound to
     loopback, so against a remote server it cannot exist or log in from the container.
   - A token that may read `sys/storage/raft/snapshot` on a shared server can copy the whole store of
     every tenant out. That is the server owner's call.
   - Ruling 6's 4 and 8 hours are set on a server this Feature runs; in client mode they are the server's
     (section 5 says the login is whatever the server offers). `key:load`'s lifetime ("at most what is
     left of the token", section 8) still holds if it reads the token's remaining time from `bao`.
   - ruling 7's "one central server" has no Feature-provided way to run it in phase 1 (loopback, no TLS);
     it is an owner-run server by definition.
   Recommended change: section 3 says `backup` in client mode uses a role or token the server owner
   provides, with `DCF_SECRET_AS` or the sitting token, and `openbao:backup` exits 13 when the snapshot
   read is denied; section 14 says the central server is always owner-run in phase 1; section 5 says the
   lifetimes are enforced only in server mode and `key:load` caps itself by the token's remaining time.
9. **The onboarding instance (section 15a) is not designed.** Both a restore receiver and a sender
   need a second OpenBao instance holding "only the shared keys". The Feature gives one server per container
   (the volume is `openbao-${devcontainerId}`, one `node_id`), and no task or note says how the sender
   makes the second one. Recommended change: section 15 says how: a second devcontainer in server mode
   with its own volume and `dcf-secret put` of the shared keys, or a task `openbao:onboard:export` that
   does the copy into a fresh instance; the NOTES carry the procedure. Also, `openbao:restore`'s "newest
   backup is from another machine" warning will fire on every onboarding; it should say onboarding when
   the snapshot carries an onboarding marker, or be skippable with a flag.
10. **Placement: rekey calls the devhost, and restore leaves a manual step (sections 4, 7, 15).** Section
    15 says the backs' secret ids are reissued "through the devhost's task", and section 4 says the
    Operator runs `openbao:approle:issue` for each role after a restore. The openbao Feature must not
    know the devhost's roles. Recommended change: `openbao:approle:issue ALL=1` (generic: every role in
    the store, new secret id into `approle/<role>/secret_id`, old ones destroyed per finding 3), which
    `rekey` and `restore` call at the end; the devhost needs nothing extra because the roles and policies
    come back inside the snapshot.
11. **Internal consistency: exit codes and small gaps.**
    - `openbao:backup` exit 12 means "the backup role cannot log in", while in `dcf-secret` 12 means
      "no token, or it expired" and 13 "may not read this name". Recommended change: keep 12 for "cannot
      authenticate" in both and add 13 for "snapshot read denied", and list the codes for `backup`
      beside the `dcf-secret` table so the numbers visibly match; 14 (no such secret) does not apply to
      `backup`, and the table says so.
    - The backup writes the snapshot to a file in the volume before the copy (section 4 step 1) and
      never says it is removed; a full snapshot (ciphertext) would stay at rest. Recommended change:
      remove it after the copy and after a failed copy.
    - "After a write ... runs the backup itself only when `backupDest` is set" does not say what the write
      task exits when that backup fails (a missing folder, sealed). Recommended change: the write stands,
      the task exits 0, and the failure prints the backup's own line.
    - Section 16 says "None for phase 1", while this review's open questions are phase 1 decisions.
      Recommended change: update section 16 with the Operator's rulings on them.
12. **Lexicon.** Terms used in the new parts and not defined in `LEXICON.md`: onboarding instance,
    rekey (and the OpenBao name `rotate-keys`), wrapping token and response wrapping, recovery key (the
    register's offline anchor), central server, throwaway init, snapshot against backup (a snapshot is the
    raft file; a backup is the Feature's named copy in a destination), and "register", "principal" and
    "anchor" which the register's README defines but the lexicon does not (the first review's list). The
    wording "host scheduler" (sections 3, 4) collides with Host (the main session) in the lexicon; the
    lexicon has Host type. Recommended change: the librarian adds the terms on acceptance as the first
    review says, and the proposal says "the workstation's scheduler" instead of "host scheduler".
13. **ADR order and size of slice 2.** Slice 4 writes the ADR that supersedes 0046 and records the 0045
    route; slice 3 has already changed what 0046 decided. Recommended change: the ADR lands with the
    acceptance of the proposal, before slice 1 (the proposal's section 10.4 already says "written when
    this proposal is accepted"; the slice list contradicts it). Slice 2 carries the server, init, unseal,
    seal, userpass, AppRole, backup, restore, rekey, wrap, unwrap and the status in one 1.2.0 pull request
    and is the largest risk. Recommended change: split it (2a: server, init, unseal, seal, userpass,
    AppRole and the `backup` role, backup, status; 2b: restore and rekey; 2c: wrap and unwrap), each with
    its own version bump and tests.
14. **Phase boundary (deferred paragraphs).** Nothing in phase 1 needs a deferred item: `dcf-secret` has
    no fallback, the start hook knows no copy, and section 14's phase 1 shapes name no copy. Two soft
    leaks: ruling 7's bullets state phase 2 details as rulings (max age default 24 hours, transit
    auto-unseal, writes exit 10 and nothing queued) while the deferred paragraph says "named and not
    designed"; and ruling 7 says "changes flow one way only, so there is nothing to merge" while the
    deferred list's shared open question is who the writer is and how conflicts resolve. Recommended
    change: mark ruling 7's copy bullets "phase 2 intent, not a phase 1 requirement; the amendment may
    change them" so no slice builds from them, and keep exit 10 for a down server in phase 1 (it already
    is in the `dcf-secret` table).

### Open questions for the Operator
- **ADR 0045** (finding 1): accept a named, bounded-loss exception, and require `openbao:init` to ask for
  a backup destination or an explicit "no backup"? Recommendation: yes, both.
- **How far to trust the sender in onboarding** (findings 2, 3): is the sender inside the receiver's trust
  circle (so a rekey plus `rotate` is enough and later backups may sit in a shared folder), or must the
  receiver's later data stay unreadable to the sender? Recommendation: treat the sender as trusted for
  what was in the snapshot only, make `rotate` the default, and for anything stricter use route (b) or a
  fresh instance with the values put in again.
- **Restore authority** (finding 4): drop `snapshot-force` from the Operator's policy and restore only with
  a root token made from shares? Recommendation: yes.
- **`backupInterval` in phase 1** (finding 7): keep, or wait until OpenBao's own snapshot support is
  checked? Recommendation: check first; defer it to a later minor if the Feature would only be rebuilding
  scheduling.
- **Splitting slice 2** (finding 13): three pull requests instead of one? Recommendation: yes.
