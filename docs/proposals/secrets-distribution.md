# Secrets distribution and replication (phase 2): research notes

**Status:** research notes, 2026-11-03; not designed, not reviewed, nothing decided. Phase 2 of
[secrets-master-split](secrets-master-split.md), which draws OpenBao's boundaries (phase 1) and
lists these items as deferred. Kept so the research is not done twice. Before any of it is built,
it becomes a proposal with an architecture review and the Operator's ruling.

Who it serves: the Operator and the engineers who need the same secrets on more than one machine,
or a machine's secrets back after it is lost, without running an external server.

## 1. The question the three ideas share

Who is the writer, and how do conflicts resolve? Each idea below answers it differently: one
master (a claim in the register), one owner per secret path, or nobody writes while the central
server is down. Phase 2 starts by choosing that answer once for all three.

## 2. Topologies weighed (2026-11-03)

| Option | How | Good for | Cost |
|---|---|---|---|
| 1. One master, read-only copies | one machine's server is the master; others restore its backups | one Operator, a second machine at times | copies are as fresh as the last backup |
| 2. External raft cluster (client mode) | 3 OpenBao nodes on always-on hosts; every devcontainer a client | a team, current secrets everywhere | hosts to run, patch, back up |
| 3. Independent instances | each machine its own server; shared keys arrive by onboarding | engineers who each own their secrets | no sync: a rotated shared key is handed out again |
| 4. One server over a private network | one always-on server, clients over a mesh network (Tailscale, WireGuard) | two or three machines | single point of failure; needs backups |

Phase 1 supports 2 and 4 (client mode, `BAO_ADDR`) and a single machine in server mode. Chosen as
phase 2's main shape: **4 + 1** (one central server plus a local read-only copy).

**Comparison with SQL Server Availability Groups**: an AG has one primary, readable secondaries,
synchronous or asynchronous replication, and failover (automatic with quorum, forced with data
loss). A raft cluster is closest to an AG with synchronous commit and automatic failover. Option 1
is closest to log shipping to read-only secondaries. Option 4 alone is a single instance.

**Raft on losing its majority**: OpenBao does not drop to read-only; with no active node it refuses
reads as well as writes (consistency over availability). The protocol could allow stale follower
reads, and some systems built on it do; as far as was checked, OpenBao does not. So "raft, and
read-only when it cannot write" means raft plus a separate read-only copy.

**Not supported** (stays out): peer-to-peer raft between devcontainers. Laptops sleep, so a
majority is lost often (two nodes: either one down stops both), and every workstation would have
to accept connections from other machines.

## 3. Idea A: the 4 + 1 local read-only copy

- Normally every client uses the central server. Each devcontainer also keeps a read-only copy,
  refreshed by restoring the central server's latest backup.
- `dcf-secret get` falls back to the copy only when the central server is unreachable, says it is
  stale and since when, and refuses once the copy is older than a maximum age (an option, default
  24 h suggested). `dcf-secret put` goes only to the central server; while it is down, writes exit
  10 and nothing is queued.
- When the central server is back, clients return to it and the next refresh updates the copy.
  Changes flow one way only, so there is nothing to merge.
- Revocations and rotations reach a copy only at its next refresh; the maximum age bounds that.
- Logins on the copy are those of its last snapshot; a token issued later must log in again
  against the copy (`dcf-secret` would do that itself and say so).
- Unseal: a restored snapshot opens with the central server's unseal key. Suggested: the copy
  unseals itself from the central server (transit auto-unseal), so it stays unsealed through an
  outage; a restart during the outage needs the shares by hand.
- **Unconfirmed, may break the design** (the amendment's author): restoring a snapshot taken under a
  Shamir seal into a server with a transit seal may be refused or need a seal migration, and with
  a transit seal the shares become recovery keys, which cannot unseal by hand (as in Vault). Check
  against OpenBao before designing.

## 4. Idea B: backups recorded in the register, and hydrate

- `openbao:backup` ends by printing the snapshot's path and sha256 and runs an optional
  `BACKUP_HOOK`. openbao itself knows nothing of the register or the cloud folder.
- The hook (devhost or AOF's register Feature) writes a signed entry: backup, machine, UTC time,
  who, size, sha256, where the file is; the file sits beside the register's mirror in the shared
  folder. `backupKeep` removals add a "removed" entry, so history stays complete under append-only.
- Gains: tamper evidence (restore refuses a snapshot whose hash matches no signed entry),
  provenance, discovery (the newest backup and its machine come from the register, not a folder
  listing).
- **Hydrate**: a new or rebuilt machine with no external server finds the master's newest entry,
  fetches the file, checks the hash, restores, and asks for the unseal shares. Also disaster
  recovery for the same machine.
- **Single writer**: the master is named in the register (a claim, like the agents lease); the hook
  refuses backups from a machine without the claim; promoting another machine is an explicit task
  that ends the old claim, so two lineages never diverge.
- Rejected inside this idea: a per-write log of changes taken from OpenBao. Its audit log HMACs the
  values and cannot be replayed; building replay is replication (NFR-13).

## 5. Idea C: the ledger as the source of secret values

The Operator's latest direction before tabling (2026-11-03): rebuild the store instead of
backup and restore; the ledger holds the values and is applied periodically; the ledger replicates.

```
dcf-secret put ─► encrypt to the readers' keys ─► signed entry in the ledger ─► mirror (shared folder)
every machine:  openbao:apply (periodic, and at post-start) ─► bao kv put / delete ─► local OpenBao
```

- It reverses part of phase 1's ruling 1: the ledger is the master of values, OpenBao the gate
  (logins, policies, the backs' identities, sitting tokens, unseal).
- Apply drives the `bao` CLI with ordinary writes, so it manages the environment (NFR-13), unlike
  idea B's rejected per-write log.
- To settle:
  1. **Readers**: values encrypted to the readers' public keys (age, or the ssh key), not to an
     OpenBao key, which is lost exactly when a rebuild is needed. The offline recovery key always
     a reader.
  2. **All writes through the ledger**: a change made straight in OpenBao is overwritten at the
     next apply, so apply reports drift loudly.
  3. **Two writers**: the ledger merges by union; a fixed rule is needed. Suggested: one owner per
     secret path (alternative: the later entry wins, by timestamp then hash).
  4. **History is forever**: an old value stays, encrypted. A leaked reader key exposes all it
     could ever read, so it means rotating every such secret; removing a reader likewise needs
     rotation.
  5. **Not rebuildable from the ledger**: leases, tokens, the backs' secret ids, unseal and root keys
     (new per instance, reissued at apply). Policies and auth configuration can live in the ledger
     or git as configuration.
  6. **Staleness**: a machine is as current as its last apply.
- Comparison with idea B:

| | B: backups in the register | C: ledger as the source |
|---|---|---|
| Unit | a whole snapshot | one secret per entry |
| Writers | one master (claim) | many, an owner per path |
| Rebuild | restore + the unseal shares | new instance + apply |
| History | snapshots, pruned | every value, forever |
| Key-leak blast radius | one snapshot, with the shares | all a leaked reader key could read |
| Depends on | the register mirror | the register mirror + a reader-key model |

## 6. Considered, not chosen

A data mesh of OpenBao itself (each node writes locally, copies merge when they meet): OpenBao
needs one source of truth, so it would mean building replication (NFR-13). Idea C is the form of
this that stays outside OpenBao.

## 7. Dependencies and open checks

- The register writing to the shared folder: AOF's fix for `register-store-no-hardlink`.
- Phase 1's backup, restore and `dcf-secret` slices.
- Check against OpenBao: the seal question in section 3; whether standbys serve stale reads;
  whether OpenBao has added replication between separate servers (in Vault an Enterprise feature).
