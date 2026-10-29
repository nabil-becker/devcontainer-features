# ADR-0037: A contract for agent CLIs must work on two vendors or name its fallback (amends ADR-0036)

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-29 |
| **Deciders** | the Operator; proposed by the host (`docs/proposals/agents-v2.md`, section 14.3) |

## Context

ADR-0036 accepted agents v2 (the lease, integrations, ephemeral runs). The Operator then asked that
the other agent CLIs be checked, so that nothing is designed that only one vendor can do. A
capability matrix of Claude Code, Copilot, Codex, Gemini and OpenCode, built from official docs and
source only (PR #106, section 14.3 of the proposal), showed that v2 as accepted leaned on Claude Code
in several places: the lease asked whether its holder lives through `claude agents --json`; resident
agents rest on `--bg`, native only in Claude Code and OpenCode; "only the settings file reaches the
session" is how Claude Code's supervisor works, while the other four run the session as a child
process, so the environment reaches it; waking with no flags rests on Claude's saved options; the
trust gate differs per CLI; and every CLI has a native one-shot mode that the contract did not use.
The same decisions were applied to the proposal and to the binding requirements
(`docs/principles/non-functional-requirements.md`) in commit 2074629 on PR #106.

## Decision

ADR-0036 stands. It is amended in these ways, none of which reverses it.

- **The rule.** A new non-functional requirement, NFR-12 `vendor-neutral-contracts`: a contract for
  agent CLIs must work on at least two vendors' CLIs, or name its fallback, and a design is checked
  against the capability matrix before it is accepted.
- **Each adapter picks its route.** How the `env` of an integration reaches a session is the
  adapter's choice, not the Feature's. The settings-file route stays as the Claude Code adapter's
  mapping. A refusal names "the adapter (and the release that adds it)", not a `claude-code` release.
- **Two optional adapter verbs.** `trust <folder>` (the trust gate, which differs per CLI) and
  `run-once` (an ephemeral run through the CLI's native one-shot mode). An adapter that lacks one
  answers exit 3, and the Feature falls back.
- **Liveness.** The lease asks the adapter's list whether its holder lives when the adapter has one.
  Otherwise the agents Feature uses its own record, and the holder is a process (`process:<pid>`).
  This refines ADR-0036's "asked of the CLI adapter by agent name and folder".
- **No agents-owned background carrier yet.** The agents Feature does not run a CLI as a detached
  process itself. An adapter with no background mode serves on-demand and ephemeral agents only until
  that exists.
- **The second adapter is GitHub Copilot CLI**, for on-demand and ephemeral work first (a new slice 6
  of the agents proposal, `agent-adapter-copilot`). OpenCode is the better fit for resident agents
  and the lease and is a later candidate. The Feature that ships the Copilot adapter is proposed as
  `copilot-cli`; that name is not yet confirmed.
- **Contract tests.** The agents Feature is run in `task lint` against two fake adapters, one
  Claude-like and one minimal (no background mode, no list), and a list that uses only the minimal
  adapter must never call anything named `claude`. This is being built on
  `chore/agent-kind-standard/1`.

## Options considered

### Option 1: a two-vendor rule, optional verbs and a second adapter now (chosen)

It puts the guard in the architecture rather than in one proposal, keeps ADR-0036's decisions, and
the fake adapters make a Claude-only behaviour fail in `task lint` instead of in a consumer.

### Option 2: keep v2 as accepted and add other CLIs when asked

Cheapest now, but the lease, the environment route and resident agents would each be reworked for
the second vendor, with consumers already depending on the Claude-shaped behaviour.

### Option 3: build the agents-owned detached process now

It would give every CLI resident agents, but it is a new supervisor to own and test. Deferred; the
liveness rule above is written so it can be added later.

### Option 4: OpenCode as the second adapter

The better match for resident agents and the lease, so it stays the next candidate. Copilot was
chosen first because on-demand and ephemeral work is what the optional verbs cover.

## Consequences

- A new contract is checked against the matrix before acceptance; a Claude-only design must name its
  fallback or change.
- Non-Claude agents are on-demand and ephemeral only until a background carrier exists.
- Claude's supervisor facts move from the contract into the Claude adapter's mapping.
- Open: the Feature name `copilot-cli`, which of section 14.3's points 1, 2, 3, 5, 7 and 8 are
  accepted (they are still written as proposals), and the use of "adapter", "integration", "source"
  and "sink" (a language audit is running; no terms are settled here).
- Backlog: the Copilot adapter slice and the optional verbs, secretary's.

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First draft, accepted: the Operator decided the rule, the contract tests and Copilot as the second adapter. |
