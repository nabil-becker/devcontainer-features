# ADR-0036: A stateful agent holds an exclusive lease, and integrations plug in through `agent-integration-<id>` executables

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-29 |
| **Deciders** | the Operator; proposed by the host (`docs/proposals/agents-v2.md`) |

## Context

In agents 1.x one agent is spread over three places: the list says its name, CLI, folder and kind,
a profile is a `--agent` pair in `args`, and the identity it signs its writes with has to be
smuggled in as `--settings` JSON in `args`. Nothing in the Feature knows that two copies of one
agent must not run; a duplicate session is reported after the fact (`+N` in `agents:list`,
`agents:stop --extras`). The maintainers of a consuming framework asked for the agent list to be
the whole definition: who the agent is, how many copies may run, where it runs and what it plugs
into. The proposal was merged as `docs/proposals/agents-v2.md` (#101) and the Operator accepted its
recommendations on 2026-10-29. Its five facts about the real Claude Code are checked separately
and do not change the decisions below.

## Decision

Every stateful agent takes an exclusive lease, and the Feature reaches a framework only through
integration executables. This is `agents` 2.0.0 for the lease and 2.1.0 for the integrations.

- **Lifecycle.** A new list key `lifecycle` is `stateful` (the default) or `ephemeral`, independent
  of `kind`. `ephemeral` with `resident` is refused.
- **The lease.** A stateful agent takes a lease at every start through `agents`: `mkdir` of
  `leases/<handle>/` in the Feature's state folder, with a holder file (state, pid and its start
  time, boot, container, carrier, time). The key `lease` is a flat scalar, `container` (stateful,
  the default) or `none` (ephemeral); `machine` and `cluster` are refused and the words reserved.
  There is no volume: a lease that survives a rebuild is stale. A takeover lock
  (`leases/<handle>.takeover`) serialises takers. Whether the holder lives is asked of the CLI
  adapter by agent name and folder, never by comparing session ids, because `/clear` changes the
  id. When it cannot be told, the lease is treated as held.
- **Join or refuse.** A second start of a resident joins the running copy; a second start of an
  on-demand stateful agent is refused (exit 2). A container start never fails on a held lease.
  Two stateful entries may not share an `identity`. The lease directory is mode 0777 without the
  sticky bit, which the Operator accepted for a single-tenant container.
- **The integration contract.** One executable per integration, `agent-integration-<id>`, on PATH:
  `<verb> <handle> [key=value ...]`, with the verbs `env`, `before-start`, `after-start`,
  `lease-taken`, `lease-released`, `stop`, `check` and the CLI contract's exit codes. An
  integration never parses the list; a new fact is a new `key=value`, and unknown keys are ignored.
  The list names them in `integrations`, and `integrations-required` (a subset) names the ones whose
  absence or failure blocks a start. `env` output reaches the session through the adapter
  (`AGENTS_DEFINITION`, `AGENTS_ENV_FILE`); the Feature itself exports `AGENTS_HANDLE`,
  `AGENTS_IDENTITY` and `AGENTS_LIFECYCLE`. The key for the CLI profile stays `definition`.
- **Slices.** agents 2.0.0 (the lease), agents 2.1.0 (integrations), claude-code 1.9.0 (the adapter
  mapping), agents 2.2.0 (ephemeral runs). No release until the claude-code slice; the Operator
  starts it.

## Options considered

### Option 1: an exclusive lease per stateful handle, and integrations as executables (chosen)

The lease needs only `mkdir` and files, which bash has, and it turns the duplicate report into
prevention. The executable contract mirrors the existing adapter contract, so the Feature learns no
framework name and the framework needs no knowledge of the list's format.

### Option 2: keep reporting duplicates (1.x)

No behaviour change, but two live copies of one principal write as the same identity before anyone
looks.

### Option 3: a lease optional per agent

A stateful agent without a lease is the 1.x behaviour, which `ephemeral` already names; an opt-out
would keep two meanings of "stateful".

### Option 4: a wider scope (machine, cluster) in 2.0

There is no cross-container atomic primitive in bash, awk and sed; across machines needs a server,
which is the framework's register, not this Feature.

### Option 5: the lease in a volume, or an inline map (`lease: { scope: container }`)

A volume would keep a stale lease across a rebuild. An inline map is outside the awk list parser's
subset, which was checked by running `agents check`; the flat scalar needs no second grammar.

### Option 6: the Feature calls a framework directly, or integrations read the list

Puts a project's name or the list's format into the Feature, or the other way round.

## Consequences

- Duplicate copies of a stateful agent are prevented for starts that go through `agents`; a session
  started by hand takes no lease, so the `+N` report stays as the backstop.
- This is a major version: an on-demand agent run in several terminals is now refused unless the
  list gives it `lifecycle: ephemeral`. `docs/migrations/agents.md` is the upgrade path, and
  consumers' `DEVCONTAINER_CONTRIBUTION.md` carries the line.
- A framework writes two integrations (register an agent and its identity, make it reachable)
  against slice 2; none exists until then.
- The agents Feature gains a state area under `leases/` and the tasks `agents:leases` and
  `agents:release`; its NOTES record the volume exception.
- An integration cannot veto a stop in 2.x; a vote that can needs its own design.
- Open and not decided here: `--bg` for ephemeral runs, refusing `--resume` for an ephemeral agent,
  a separate verb for a purge, and the wait defaults.

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First draft, accepted: the Operator accepted the proposal's recommendations. |
