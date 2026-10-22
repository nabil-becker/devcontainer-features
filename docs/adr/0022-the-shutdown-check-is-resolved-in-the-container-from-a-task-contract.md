# ADR-0022: The shutdown check is resolved in the container from a task contract

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-22 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0015 made `devcontainer:stop` run `devhost-shutdown-check` before stopping the container. The
bootstrap's devcontainer tasks are also used by consuming repositories that do not install the
devhost Feature, so the script does not exist there. In one such repository every plain
`task devcontainer:stop` was refused with exit 127 (command not found), and the generic refusal
message did not say why. The consumer had to pass `FORCE=1` every time, which skips the check
altogether. The forces: the stop task is shared by every repository, so it must not assume the
devhost; a repository that has its own idea of "safe to stop" should be able to say so without
editing the shared task; and a missing check must not look like a failing one.

## Decision

When `STOP_CHECK` is unset, the stop task runs one POSIX shell snippet inside the container, from
the workspace folder, and resolves the check in this order:

1. if `task` is on the PATH and `task --summary shutdown:check` succeeds (the repository's root
   Taskfile defines the task), it runs `task shutdown:check`;
2. otherwise, if `devhost-shutdown-check` is on the PATH, it runs that;
3. otherwise it prints `no shutdown check defined; stopping` and exits 0.

`shutdown:check` is the contract between a repository and the stop task: a repository defines that
task in its root Taskfile and the stop honours it. A check that exits non-zero still refuses the
stop, and `FORCE=1` still skips the check. `STOP_CHECK` stays as the explicit override.

When an explicitly configured `STOP_CHECK` exits 127, the host (the PowerShell module and its bash
twin) says the shutdown check is not installed in the container and names the three ways out
(define it, unset `STOP_CHECK` to use the default resolution, or `FORCE=1`), instead of the generic
refusal. A host task `devcontainer:prepshutdown` runs the same resolved or configured check inside
the running container without stopping it.

## Options considered

### Option 1: resolve in the container, task contract first (chosen)

The shared task works unchanged in every repository, a repository opts in by defining one task, and
the devhost keeps its script as the fallback. No repository has to know about the devhost to stop
cleanly.

### Option 2: keep the fixed default and tell consumers to set `STOP_CHECK`

No code change. It lost because every consumer without the devhost must configure around a default
that cannot work for them, and the failure looks like a refusal.

### Option 3: skip the check silently when the script is missing

Fixes the exit 127. It lost because it gives a repository no way to supply its own check, and an
explicitly configured check that is missing would pass unnoticed; here only the default resolution
falls through, and an explicit one reports exit 127.

## Consequences

- A consuming repository without the devhost stops with one message and no flag; one that wants a
  guard defines `shutdown:check`.
- The stop task now depends on the container having a POSIX `sh`; the snippet is passed as the
  existing base64 command, so it contains no single quote.
- The resolution is duplicated in the PowerShell module and the bash twin and must be kept in step;
  tests cover both.
- ADR-0015's "runs the shutdown check first" now means the resolved check; its text is not edited.
- The devcontainer-cli Feature and the bootstrap change together and need a version bump and a
  `task docs` run.

## Change log

| Date | Change |
|---|---|
| 2026-10-22 | First draft; approved by the Operator in the session. |
