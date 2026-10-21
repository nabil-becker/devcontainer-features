# ADR-0018: Start and stop are idempotent prerequisites, and rebuild continues after a failed stop

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-21 |
| **Deciders** | the Operator; proposed by the host |

## Context

The host-side tasks (`task devcontainer:*`, alias `dc:`) had `up` and `stop`, but `claude`,
`shell`, `pwsh`, `exec` and `rebuild` each assumed the container was already in the right state.
`stop` run twice, or with nothing running, ran the shutdown check through an exec that could
start a container. The Operator asked for `dc:start` and `dc:down` as aliases of `up` and `stop`,
and for both to be idempotent so other tasks can depend on them. For `rebuild`, the host proposed
that `FORCE=1` skip the shutdown check; the Operator answered that no skipping is needed as long
as the rebuild continues when the stop fails.

## Decision

`dc:start` is an alias of `dc:up` and `dc:down` of `dc:stop`. Both are idempotent: starting a
running devhost changes nothing, and stopping one that is not running prints "already stopped"
and exits 0 without running the shutdown check or starting anything. A new `running` task
reports the state by exit code (0 running, 1 not running, 2 the engine failed); an engine error
makes `stop` fail visibly and is never reported as "already stopped".

`claude`, `shell`, `pwsh` and `exec` depend on `up`. `rebuild` runs `stop` with the shutdown
check first; if that stop fails for any reason it prints one line saying the stop did not
complete cleanly and rebuilds anyway. `FORCE=1` still skips the check.

## Options considered

### Option 1: idempotent aliases as prerequisites; rebuild continues on a failed stop

Any lifecycle task can be a dependency of another without a caller scripting around the state,
and a rebuild is never blocked by a stop that cannot finish.

### Option 2: rebuild requires `FORCE=1` to skip a refusing check

Keeps the check binding, but a rebuild stuck behind a failed stop needs a second invocation. The
Operator declined it.

### Option 3: separate start and stop tasks beside up and stop

Two names for the same action against "one way to do each action". Aliases keep one task.

## Consequences

- Tasks that need a running devhost declare `up` instead of documenting a manual step.
- A rebuild can proceed past a refused shutdown check, so unsaved work can be lost; the check's
  findings are shown first, and the Operator accepted this.
- Consumers get the tasks by re-running the bootstrap; the change ships as devcontainer-cli 1.4.0,
  and the Operator starts that release.
- The PowerShell path of `running` was checked by PSScriptAnalyzer only, not at runtime.

## Change log

| Date | Change |
|---|---|
| 2026-10-21 | First draft. |
