# ADR-0072: The devhost keeps no Docker cache, and test runs clean up after themselves and refuse to start on a nearly full disk

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

On 2026-11-20 the workstation drive filled and ended a session mid-command. The docker-in-docker
volume of a devhost held almost 200 GB, most likely from local CI-style runs (`task test`,
`task test:global`), which build fresh images for every Feature test. Nothing reused that cache:
every Feature test builds its images anew. The Operator's words were that the stack needs to do
better, and "or turn off the caches. Clearly weren't using it."

The docker-in-docker Feature starts `dockerd` before any script of this repository runs, so the
daemon's own configuration cannot be set from here without a restart that would fight the
Feature.

## Decision

The devhost keeps no Docker cache:

- every devhost start runs `.devcontainer/dind-clean.sh --wait` from `postStartCommand`, which
  prunes images, volumes and the builder cache and prints one line with the sizes before and
  after; with no daemon (`wslc`) it prints one line and exits 0;
- `task test`, `task test:global` and `task test:devhost:docker` clean the whole docker-in-docker
  after each run, pass or fail, through a go-task `defer:`;
- the same three tasks refuse to start (exit 1, with a message) when less than 20 GB is free
  where `/var/lib/docker` lives, through `.devcontainer/dind-guard.sh`; `FORCE=1` overrides and
  `MIN_FREE_GB` changes the threshold;
- a test run happens once, one at a time, and CONTRIBUTING.md carries the section "The Docker
  cache in this devhost".

## Options considered

### Option 1: prune at start and after every run, with a free-space guard

The cache is never reused, so keeping none costs nothing, and the guard stops a run before it
can fill the disk. It needs no change to the docker-in-docker Feature.

### Option 2: cap the BuildKit cache with a garbage-collection limit

Lost: the daemon starts before the repository's scripts run, so a `daemon.json` written later
needs a daemon restart. Pruning after each run covers the need. Peak use inside a single run is
bounded only by the guard, not by a cap.

### Option 3: keep the cache and prune by hand

Lost: this is what produced the 200 GB volume.

## Consequences

- The disk no longer grows between runs, and a full drive is refused early instead of ending a
  session.
- Every run rebuilds its images; since nothing reused the cache, no measurable time is lost.
- A running devhost that predates the change still holds the old cache until it is restarted or
  `bash .devcontainer/dind-clean.sh` is run once.
- Peak disk use within one run is still bounded only by the 20 GB guard; a BuildKit cap stays
  open if that proves too loose.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted by the Operator. |
