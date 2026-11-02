# ADR-0043: The AOF planting keeps four local rules and moves the ledger onto the register with a mirror outside git

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-02 |
| **Deciders** | the Operator; proposed by the host session (the AOF apply plan) |

## Context

This repository is now a project planted from AOF (the Agentic Operating Framework seed). The
planting interview and its two rounds settled the gaps between the seed's defaults and what is
done here. Four were settled outright: the review runs every 75 entries (ADR-0021), the backs stay
approved to run unattended, `TODO.md` stays a file in the OneDrive folder for now, and the
vendor co-author trailer is removed at its source (the harness setting), leaving our
`@noreply.invalid` trailer (ADR-0002).

Five places remained where an existing rule here differs from an AOF default. The seed says to keep
the existing rule and ask the Operator. The Operator agreed to the recommendation on all five.

## Decision

1. **Merging and releases stay the Operator's** (ADR-0040); agents do not merge once checks pass.
2. **The ledger keeps one entry per turn or job**, finer than a pull request.
3. **The repository stays public**, with DCO sign-off and a protected `main`.
4. **One commit check and one redact list**: `devhost-verify` gains AOF's checks (ADR-0042).
5. **The ledger moves onto the register.** The 510 entries are imported after a dry run that
   reports what does not map; the scribe then writes through the register. The monthly Markdown
   files are frozen, mirrored in git at first, and the mirror then moves to the OneDrive folder
   (`/mnt/cloud-folder`), not git. The records follow it out of the tree (`TODO.md`, journal,
   night-shift reports, costs), and a purge of history comes later as the Operator's runbook.

The work is applied in stories with checkpoints (A: the register works; B: the ledger runs on the
register, still visible in git; C: out of git), so each step can be stopped.

## Options considered

### Option 1: keep the existing rules and move only the ledger store

Four rules stay as they protect review, history granularity and the public posture; the store
changes to the register. This wins.

### Option 2: adopt every AOF default

Agents would merge, entries would be one per pull request, and the repository would be private.
It lost: it weakens the Operator's review (ADR-0040) and does not fit a public Feature collection.

### Option 3: keep the ledger as monthly files in git

Nothing to migrate, but the records stay in the tree and none of the register's signing and
guard is gained. It lost.

## Consequences

- The register's guard is our redact check wrapped as a command, so no listed name can be signed
  into the ledger.
- The briefing, report, costs, site and review must read the register once the scribe writes to it.
- The secretary and the branch and pre-push checks read `TODO.md` from the mount and warn when it
  is absent.
- Until checkpoint C the records stay visible in git; the history purge is separate and later.

## Change log

| Date | Change |
|---|---|
| 2026-11-02 | First draft, accepted by the Operator's "Agree to all" of the same day. |
