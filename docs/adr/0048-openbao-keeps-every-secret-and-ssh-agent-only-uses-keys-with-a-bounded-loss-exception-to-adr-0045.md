# ADR-0048: OpenBao keeps every secret and ssh-agent only uses keys, with a bounded-loss exception to ADR-0045

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-03 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0046 put the Operator's register key in the `ssh-agent` Feature's key mode: a
passphrase-protected key in a volume, loaded for a sitting with `key:unlock`. Key mode has since
grown a key store of its own (`key:new`, `key:rotate`, `key:retire`, `key:age`, `key:unlock`), and
secrets and their lifecycle belong in a secrets manager, which this collection already ships (the
`openbao` Feature, CLI only until now).

The proposal `docs/proposals/secrets-master-split.md` (pull request #160) set out the split, went
through two architecture reviews, and was ruled on by the Operator on 2026-11-03: the five
decisions of its section 1, the two rounds of rulings, and an approval of the con's three naming
and design choices (`openbao:onboard:claim`, `openbao:onboard:export`, one wrapping token per
secret). Its section 10.4 asks for this record before any build slice, because later slices change
what ADR-0046 decided.

One of the rulings collides with ADR-0045 ("losing a machine must lose nothing"). A server that
runs inside the container keeps its raft store in the Feature's volume (tier 4), and that store
holds keys that cannot be rebuilt. The live store cannot go in the shared folder: raft's database
is written in place and under a lock, and none of the `cloud-folder` modes promises that to a
database (proposal section 4). So the rule has to be met another way, or excepted by name.

## Decision

1. **OpenBao is the master of every secret and credential the collection creates or stores**: every
   private key (ssh, git signing, the register's operator and back keys), every token (gh, Azure,
   the cloud folder's login) and their lifecycle (create, rotate, retire, age). **`ssh-agent` only
   uses keys**: the agent socket, host-agent forwarding, git commit signing and verification
   through the agent, and `key:load` and `key:lock` of a key fetched from OpenBao into agent
   memory with a lifetime no longer than the login token's remaining time. Keys a workstation
   holds stay the workstation's.

2. **One recovery register key stays offline, outside OpenBao**: the register's second operator
   anchor. It is a named exception to decision 1; it is what reopens the rosters if the unseal
   shares are lost.

3. **The `openbao` Feature has two modes.** `client` is the default and today's Feature (the `bao`
   CLI, `BAO_ADDR` pointing at a server outside the container, plus the volume and `dcf-secret`).
   `server` adds a server run inside the container at post-start, with raft storage on the
   Feature's own volume, sealed until the Operator unseals it. The Feature never uses or depends on
   the shared folder. A central, owner-run server reached in client mode meets ADR-0045 as it
   stands.

4. **The gate.** The Operator unseals the server once per server start (3 Shamir shares, threshold
   2, kept in a password manager, on paper offline, and with a second person or on a hardware key;
   never in git, the container or the shared folder), and logs in once per sitting; the login
   token lasts 4 hours and at most 8 in a server this Feature runs. This replaces ADR-0046's
   passphrase unlock. The backs get their own AppRole identities, loopback only, that work once
   the server is unsealed. Every task that handles a share or a token refuses inside an agent's
   job.

5. **A bounded-loss exception to ADR-0045, for server mode only.** A machine loss loses at most
   what was written since the last backup, and the Operator accepts that window. The exception is
   a choice and never a silent default: `openbao:init` asks for a backup destination or an
   explicit "no backup", records the answer in the volume, and `openbao:server:status` shows the
   destination or a standing "no backup" warning. ADR-0045 itself is not changed; its tier 4 line
   (keys as rebuildable only) is read against this exception.

6. **Backup and restore.** `openbao:backup` writes a raft snapshot to any path the consumer names
   (the cloud folder, for example) under a name carrying the machine and the UTC time, never
   overwriting, and removes only the Feature's own files beyond `backupKeep`. A **restore needs a
   root token made from the unseal shares**, used once and revoked; `snapshot-force` is not in the
   Operator's policy. **Scheduled backups are optional and off by default**, built either way:
   OpenBao's own scheduled snapshots or the snapshot agent are checked first (NFR-13) and used if
   they fit; the Feature's own timer and `backupKeep` pruning only if nothing does. A backup is a
   snapshot the Feature copied into a destination under its own name.

7. **What this changes in earlier ADRs.**
   - **ADR-0046** is superseded: the register's operator key lives in OpenBao and is loaded for a
     sitting by `key:load`, gated by the unseal and the login. ADR-0046's flow carries on in
     practice until `ssh-agent` 1.4.0 ships.
   - **ADR-0029**: rotation's record steps move to `openbao:ssh:*`; the SSH steps stay in
     `ssh-agent:key:rotate`; the `allowed_signers` history moves from a local file to
     `.devcontainer/allowed_signers`, committed by the host.
   - **ADR-0026**: `task dc:ssh-key-import` is deprecated in favour of a one-shot host task that
     streams the key into `openbao:ssh:import FROM=file`; it stays one-shot and never leaves a
     process on the host. A consumer's workstation scheduler entry that runs `task dc:exec --
     task openbao:backup` is the same kind of one-shot command.
   - **ADR-0024 decision 7**: `DCF_HOST_SSH_AGENT=key` stays accepted for one major (`ssh-agent`
     2.0), then `keyMode` becomes `localAgent`. Decision 3 stands: the launcher registers no
     scheduler and runs no background process; the workstation scheduler is the consumer's own.

## Options considered

### Option 1: OpenBao keeps everything, server mode is a local instance, a named exception to 0045 (chosen)

One place for keys and tokens and one gate to open it, with no new infrastructure for a consumer
that has no server of its own. The cost is a window of possible loss, which is bounded by the
backup, chosen by the Operator at init, and shown in the status.

### Option 2: keep key mode's key store in `ssh-agent` (ADR-0046 as it stands)

Nothing to build. It lost because the key store keeps growing in a Feature whose purpose is SSH,
has no lifecycle for tokens, and gives the keys no gate beyond one passphrase.

### Option 3: the live store in the shared folder, so that ADR-0045 holds without exception

It lost because none of the `cloud-folder` modes gives a database a consistent single writer; a
second machine could open the same store.

### Option 4: server mode only with an external server, no local instance

It meets ADR-0045 outright. It lost because it makes a consumer with one machine stand up a server
first; it stays fully supported as client mode.

### Option 5: build scheduled backups only if OpenBao has something that fits

Suggested by the second review. It lost to the Operator's ruling: scheduled backups are built
either way, optional and off by default.

## Consequences

- One gate (unseal, then login) covers every secret; an agent never holds a share or a token in a
  transcript.
- A consumer in server mode accepts the loss window; one that wants none uses an external server.
- ADR-0045's rule gains one named, bounded exception; no other store may cite it.
- `ssh-agent` deprecates its key tasks in a minor version and removes them in 2.0; both consumers
  pin `:1` and are warned first.
- The slices follow the proposal's section 12: `openbao` 1.1.0 (the volume and `dcf-secret`), then
  1.2.0 (server mode), 1.3.0 (backup and restore) and 1.4.0 (onboarding), each its own pull
  request.
- Open until the build proves them: whether the sender's tokens and secret ids fail after an
  onboarding claim, whether two servers can run in one container, and whether OpenBao's own
  scheduled snapshots fit.

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | First draft, accepted by the Operator's approval of pull request #160 and its rulings the same day. |
