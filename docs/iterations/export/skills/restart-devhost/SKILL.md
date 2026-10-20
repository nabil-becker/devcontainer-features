---
name: restart-devhost
description: "Bring the devhost back after a shutdown, a rebuild or a night away, and pick up where it was left. Use it when the Operator says restart, bring it back, spin the container up, resume, or 'where were we' after a stop. The counterpart of shutdown-devhost."
---

# Restart the devhost

The other half of `shutdown-devhost`: the stop left a report of what was saved and what was open;
this brings the work back to where it was.

## Steps

1. **Start the container** (from the workstation; the engine is on the host): `task
   devcontainer:up`. Idempotent: a running container is left alone. After a rebuild
   (`task devcontainer:rebuild`) the Features are installed fresh; a login that lived only in the
   old container (gh, git credentials) may need doing again, and the briefing says so.
2. **Start or resume the host session**: `task devcontainer:claude`, which resumes the session
   named by `HOST_SESSION` or starts a new one. Inside a running container the session is
   already here; skip this step.
3. **Read the briefing** (it arrives at session start; `task devhost:briefing` otherwise): the
   ledger entries since the last review, what the backs left pending, the open items and
   decisions, a night-shift report not yet reviewed, and a warning when the installed devhost is
   older than the source.
4. **Check where the work stands:** `git status`, the current branch and whether it is the one
   the shutdown report named, then `devhost-shutdown-check` as a quick look at what is held or
   unpushed.
5. **Pick up what the shutdown report left open**: the findings, the stash, the untracked files,
   the item that was in progress. Say in two or three lines what is open and propose the next
   step; do not start work the Operator has not asked for.

## Why

A restart that starts from nothing makes the Operator re-explain. The records (ledger, backlog,
the shutdown report) carry the state; this reads them in a fixed order so the work resumes where
it stopped.
