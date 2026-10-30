# ADR-0041: A session name is rendered by the agents Feature from a template and passed to the CLI adapter in an environment variable

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-30 |
| **Deciders** | the Operator; proposed by the host |

## Context

A remote session list showed four or five sessions all named after the same handle (`host`), one
per machine, so they could not be told apart. The handle is an address and stays path-safe
(`LEXICON.md`), so it cannot carry the machine. The proposal is `docs/proposals/session-names.md`
(pull request #126), with its architecture review (ADR-0039) and a facts check.

The review found the design fit with changes and no conflict with an ADR; it meets NFR-12 (works
on two vendors) and NFR-13 (we manage the environment, not the CLI). The facts check on the Claude
CLI showed that a name set with `--name` is pinned (`nameSource: user`) and survives the first
turn, a stop and a bare wake, a resume with a prompt, and Remote Control. What Remote Control's
own web or phone view shows could not be seen from the container and stays for the Operator to
look at.

## Decision

The agents Feature renders a session name once per start from a `sessionName` template (a
Feature option, default `{handle}`, so nothing changes until a repository sets it), with a
per-agent `session-name:` override in the agent list. The variables are `{handle}`, `{repo}` and
`{machine}`. `{machine}` comes from `DCF_HOST_MACHINE`, set by the launcher and mapped through
`containerEnv`; where it is empty the name renders the fixed word `container`, not the
hostname, which changes at rebuild.

The finished string reaches the CLI adapter in the environment variable `AGENT_SESSION_NAME`,
not as a changed argument. The agents Feature sets or clears it on every adapter call (start,
wake, stop, list), so a value cannot leak from a parent session into a nested `agents` call. A
CLI adapter that does not know the variable ignores it and falls back to the handle; the Claude
adapter maps it to `--name`. No capability is added to the adapter's `supports` verb list.

A stateful agent's name stays the same at every start. A changed template applies to new sessions
only: the adapter finds the agent again by its record, and also accepts the name it started with,
the rendered name and the bare handle, so a template change never starts a copy. A rendered name
over the length limit is refused, never cut; the limit is Claude Code's own where documented,
else this repository's stated choice (the agents 2.1.0 slice records which). `{run}` for ephemeral agents and `{user}` are deferred.
There is no rename verb.

The work is three slices that merge in any order and release together: the launcher sets
`DCF_HOST_MACHINE` (devcontainer-cli 1.16.2), the Claude adapter maps the variable (claude-code
1.9.0), and the agents Feature renders the name (agents 2.1.0). Integrations move to agents 2.2
and ephemeral runs to 2.3.

## Options considered

### Option 1: the agents Feature renders the name and hands it over in an environment variable

It keeps the template and its variables in one place, leaves each CLI adapter a single mapping
(Claude: `--name`), and degrades to the handle on an old adapter. It manages the environment and
not the CLI (NFR-13).

### Option 2: pass the name as a changed adapter argument

An old adapter would fail on an argument it does not know, and every vendor's adapter would have
to parse a new argument. Lost for compatibility.

### Option 3: each CLI adapter renders the name itself

Every adapter would repeat the template logic and the variables, and the names could differ per
CLI. Lost against NFR-12.

### Option 4: rename the session in place

Some CLIs can only rename after the fact, and an explicit rename verb adds surface for a problem
a stable name at start does not have. Deferred until a CLI needs it.

## Consequences

- Hosts on different machines show as, for example, `<machine> host` in the remote view; this
  repository uses `{machine} {handle}`.
- An existing consumer renders `container` for `{machine}` until it adds the `containerEnv`
  mapping for `DCF_HOST_MACHINE` (ADR-0024); the launcher hints when it is missing.
- The adapter's record now keeps the name a session started with, and `agents check` says when
  the running name differs from the rendered one.
- Ephemeral runs cannot be found again by name yet, because the adapter records one session per
  handle and folder; `{run}` waits for agents 2.3.
- To check by hand: what Remote Control's own view shows for a `--name` session.

## Change log

| Date | Change |
|---|---|
| 2026-10-30 | First draft, accepted on the Operator's ruling on the proposal with the review's changes. |
