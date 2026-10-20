---
iteration: 3
date: 2026-10-20
sources:
  - docs/adr/0015-shutdown-is-a-check-script-a-skill-and-a-host-stop-task-because-the-spec-has-no-stop-hook.md
---
# ADR-0015: Shutdown is a check script, a skill and a host stop task, because the spec has no stop hook

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

Stopping the devhost can cut off work that is half done: a back writing a ledger entry, a tester
run, a night shift mid-plan, commits not pushed, files left untracked. The Operator wanted the
host's ad-hoc shutdown preparation (commit and push check, backs idle with locks free, pending
stretches flushed, stash and untracked files reported) to become part of the devcontainer
lifecycle, either run when the container stops or run by the agent. Another project already has
the pair `shutdown-office` and `restart-office` as skills. The dev container specification has
start hooks (`postCreate`, `postStart`, `postAttach`) but no stop hook, so nothing runs
automatically when a container stops; shutdown has to begin in the agent or in the host task that
stops the container. The forces: rules that can be written down should be a script, not an agent
(principle 5, right-size the work), and the seed should carry the tooling a project needs to close
and resume cleanly (ADR-0014).

## Decision

Shutdown is three pieces.

- `devhost-shutdown-check`, a script (task `devhost:shutdown-check`), tests every rule that can be
  written down: the working tree is clean and pushed, no back's lock is held and no stretch waits
  to be logged, no tester run is in progress, no night shift is mid-plan. It lists any stash and
  untracked files, exits non-zero with its findings, and has unit tests.
- `shutdown-devhost`, a skill, is the agent's side: it closes the current work with
  `close-session`, runs the check, waits for the backs, asks the Operator about a running night
  shift, names the stop command, and reports what was saved, what is still open and how to
  resume. Its counterpart `restart-devhost` brings the devhost back where it was. Both ship in the
  seed's skills and with `devhost-init`.
- `devcontainer:stop`, a host task in the devcontainer-cli Feature, stops the container through
  the configured engine and runs the shutdown check first.

## Options considered

### Option 1: script, skill and host task (chosen)

Each piece does what it is suited to: the script holds the checkable rules and is tested, the
skill handles what needs judgment (asking about a night shift, reporting), and the host task is
the one place a stop can be intercepted, since the spec offers no hook.

### Option 2: a skill only, as in the office

Simplest, and proven elsewhere. It lost because the checks are mechanical, and an agent re-deriving
them each time is slower, costs tokens and can skip one; and nothing would stop a container
stopped from the workstation without the agent.

### Option 3: a stop hook in the container

Would make shutdown automatic. It is not possible: the specification has no stop event.

## Consequences

- A stop through `devcontainer:stop` is guarded; a stop by any other route (the container engine
  directly) is not, and the skill is then the only protection.
- The seed's skills list grows beyond the three ADR-0014 names: `shutdown-devhost` and
  `restart-devhost` join `plant-a-seed`, `drop-a-seed` and `ledger-review`.
- Backlog items `devhost-shutdown-check`, `shutdown-devhost` with `restart-devhost`, and
  `devcontainer-stop` carry the work; the Features that change need a version bump.
- The check must be kept in step with the backs: a new back or lock needs a rule in the script.

## Change log

| Date | Change |
|---|---|
| 2026-10-20 | First draft; accepted by the Operator in the session. |
