# ADR-0031: The launcher grants FUSE on request, and the cloud-folder mode is chosen in the container

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-27 |
| **Deciders** | the Operator; proposed by the host |

## Context

The `cloud-folder` Feature ([the proposal](../proposals/cloud-folder.md)) gives a container one
fixed path filled from a SharePoint or OneDrive folder, by one of three modes: `host` (a bind
mount of a folder the host syncs), `mount` (`rclone mount`, needs FUSE) and `sync` (`rclone
bisync` on a timer, needs nothing privileged). A Feature's `capAdd`, `securityOpt` and `devices`
are static JSON and would apply to every consumer whatever the `mode` option says, so a Feature
cannot ask for FUSE only when it is wanted. [ADR 0024](0024-the-host-is-an-adapter-owned-by-devcontainer-cli.md)
made the launcher the one place that knows the host and had it pass `DCF_HOST_*` variables and
`--mount` arguments, but so far it has only added a mount and an environment variable; it has
never granted a container a privilege. The proposal also needs a process that runs inside the
container (the sync timer), of which no Feature has an example yet, and a default for the
rclone backend. The Operator accepted all six recommendations of the proposal on 2026-10-27.

## Decision

1. **The launcher grants FUSE per machine, only on request.** When the project sets a launcher
   variable (for example `DCF_HOST_FUSE=1`), the devcontainer-cli launcher adds the runtime
   arguments `mount` mode needs. It never grants them by default. This extends ADR 0024: the
   launcher may now grant a privilege as well as pass a path or a variable, and a Feature never
   declares one for this purpose.
2. **`host` mode is a launcher bind mount** of `DCF_HOST_CLOUD_FOLDER`, carried into the container
   through the repository's `containerEnv` like the other `DCF_HOST_*` variables. No rclone is
   involved. The launcher always mounts it at one fixed path, `/mnt/cloud-folder-host`, because it cannot
   read the Feature's options; the Feature links its `mountPoint` to that path at build time, so a
   consumer sets the path once (decided by the Operator 2026-10-27, after the first build).
3. **`auto` tries `host`, then `mount`, then `sync`**, inside the container, and says which it
   chose. `mount` is chosen only if `/dev/fuse` is usable, which is all the Feature detects.
4. **`remoteType` defaults to `sharepoint`**, not `onedrive`, because the client-credentials flow
   the cluster will need works only with a SharePoint document library. (`sharepoint` is a
   choice inside rclone's `onedrive` backend, not a backend of its own; corrected 2026-10-27.)
5. **The sync timer is one supervised loop started from the Feature's `postStartCommand`**, with a
   PID file in the Feature's volume, following the ssh-agent Feature's key mode. No `entrypoint`
   is declared. The repository's shutdown check refuses a stop while a sync runs or uploads are
   pending.
6. **Slices:** `host` mode and `status` first (the office adopts then), `sync` and the timer
   second, `mount`, `auto` and the FUSE grant third. In `sync` mode bisync's defaults stand
   (no winner is picked: both versions of a conflicting file are kept, renamed `.conflict1` and
   `.conflict2`; the 50% delete guard stays; corrected 2026-10-27, rclone 1.75.2).

## Options considered

### Option 1: the launcher grants FUSE on request; the Feature detects what it was given (chosen)

Keeps the privilege out of every consumer that does not ask, keeps the Feature host-blind, and
follows the pattern of ADR 0024. `auto` needs only to detect that FUSE is present.

### Option 2: the Feature declares `capAdd: SYS_ADMIN` and `/dev/fuse` in its JSON

Static: every consumer would get the privilege whether or not it uses `mount`, including those
that choose `sync` or `host`. Rejected.

### Option 3: grant FUSE always in the launcher

Widens every container started through the launcher for the sake of one Feature. Rejected in
favour of asking.

### Option 4: supervise the timer as a container `entrypoint`

It would run as PID 1 for every consumer and collide with a repository's own entrypoint; no
Feature declares one today. Rejected; the `postStartCommand` loop is the established precedent.

### Option 5: `onedrive` as the default `remoteType`

What the original request asked for, but client credentials do not work with it, so the cluster
case would need a different remote type. Rejected.

## Consequences

- The launcher and devcontainer-cli change together for slice 3, with a version bump, and ADR
  0024's host contract now includes granting a privilege on request; the notes for the launcher
  must say so and that the grant is opt-in per machine.
- A project that does not ask for FUSE gets `sync` (or `host`), so `auto` degrades instead of
  failing; whether the grant works on Docker Desktop and wslc, and whether a cluster can grant it
  at all, is still unverified (proposal section 11).
- The first in-container background process of the collection is introduced; a hard kill or a
  stop that skips the shutdown check can leave a stale bisync lock and a listing that needs
  `--resync`, and the next start says so.
- The proposal's open questions (client credentials with the `sharepoint` remote, bisync with
  SharePoint hashes, the meaning of the pending-upload counters) remain to be answered during
  slices 2 and 3.

## Change log

| Date | Change |
|---|---|
| 2026-10-27 | Accepted: the Operator accepted all six recommendations of the cloud-folder proposal. |
| 2026-10-27 | Corrected while building step 2 against rclone 1.75.2: bisync's default keeps both versions of a conflict (it was described as "newer wins"), and `sharepoint` is a choice inside the `onedrive` backend. The decisions stand; the Operator also accepted step 2's six build decisions (both versions kept on conflict, `--resilient --recover` on every sync, the local copy in the container's filesystem, the shutdown check refusing unsynced local changes, no rclone in `host` mode, client-credentials sign-in only through `cloud-folder:login`). |
