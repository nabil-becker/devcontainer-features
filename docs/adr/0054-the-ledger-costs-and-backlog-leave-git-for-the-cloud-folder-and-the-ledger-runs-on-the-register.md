# ADR-0054: The ledger, costs and backlog leave git for the cloud folder, and the ledger runs on the register

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-04 |
| **Deciders** | the Operator; proposed by the host session (the records-out-of-git work) |

## Context

ADR-0043 decided that the ledger moves onto the register with a mirror outside git, and that the
records follow it out of the tree in stories with checkpoints (A: the register works; B: the ledger
runs on it; C: out of git). ADR-0045 places data in four tiers, and ADR-0048 keeps every secret in
OpenBao. On 2026-11-04 the Operator ruled: "complete the migration of all the ledgers and registers
out of git and onto the cloud share using the register feature". Earlier rulings stand: the backlog
stays a file (the register importer cannot read its shape) and lives in the shared folder, and each
story states its blast radius before it runs.

State when the work started: the register `ledger` held 550 entries in its live store (a Docker
volume), the shared folder was mounted at `/mnt/cloud-folder`, and `docs/ledger/2026-11.md` held 119
entries not yet imported. The shared folder (rclone FUSE) refuses hard links but allows rename and
exclusive create. The cost files hold `{"reply":...}` and `{"run":...}` wrappers that the importer
would turn into thousands of unknown run entries that can never be removed.

## Decision

1. **Only the records move.** The ledger (`docs/ledger/YYYY-MM.md`), the cost files and the backlog
   (`TODO.md`) leave the tree. ADRs, the lexicon, the process and the docs stay in git as the
   reviewed record (tier 1).
2. **The ledger runs on the register.** The scribe signs each entry with its own OpenBao key into
   the register `ledger`; the live store stays in the volume and the shared folder holds the
   mirror, brought level after each write. The briefing, cost report, site, verify and the ledger
   review read the register through one renderer (`devhost-ledger`), which shows entries in the old
   shape; in register mode verify runs the register's own check in place of the Markdown
   append-only check.
3. **The places are settings.** `DEVHOST_RECORDS_DIR` names the folder holding the backlog, the
   costs and the reviews; `DEVHOST_LEDGER_REGISTER` turns on register mode. With both unset the
   devhost behaves as before.
4. **Reviews are files, not entries.** A review is written once to the records folder and is placed
   between the entries by its source line; it is never replaced.
5. **The cut-over is the Operator's.** It needs the host's register key loaded in a plain terminal,
   so the catch-up import, the mirror run and the rebuild are a runbook the Operator runs with no
   session open.

The live store location (volume with the share as mirror), keeping the cost history as files rather
than importing it, and deleting the superseded branch are the host's recommendations, implemented
on the branch and awaiting the Operator's confirmation.

## Options considered

### Option 1: live store in the volume, mirror on the share

A mount that is down only delays the mirror; nothing is written into a bare mount point. Writes and
the per-entry guard stay fast. This is what is implemented.

### Option 2: live store on the share itself

One copy, no mirror. It lost: a mount down at start breaks the scribe or writes into the empty mount
point, FUSE writes and guard runs are slow (the first mirror of 550 entries took 2.5 minutes), and
exclusive create is only checked locally.

### Option 3: keep the records in git

Nothing to migrate. It lost: the Operator ruled against it, and ADR-0043 already set the direction.

## Consequences

- The briefing, cost report, site and review read through one renderer, so a new reader has one place
  to go through.
- The backlog and costs are no longer reviewed in pull requests; the pre-push backlog-id check is
  skipped when the share is unmounted, and should warn.
- The two machines writing one mirror at once are not protected from each other; one writer is assumed.
- The merge driver for `TODO.md` and `.github/scripts/merge_todo.py` become unused and are to be removed.
- A purge of the records from git history stays separate and later (ADR-0043).
- Backlog items `records-out-of-git`, `devhost-ledger-register` and steps 5 and 6 of
  `aof-apply-plan` are ticked by the secretary after the cut-over.

## Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft, accepted on the Operator's ruling of the same day; the three recommendations named in the Decision await confirmation. |
