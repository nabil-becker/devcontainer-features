# ADR-0061: The facilitator is built on AGNTCY first, the MCP connection is split in two, and the agents Feature moves into a shared participant component

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-19 |
| **Deciders** | the Operator; proposed by the host |

## Context

The facilitator proposal (`docs/proposals/facilitator-agent.md`, section "Ruling (2026-11-19)",
on branch `docs/facilitator-agent/1`) designs a facilitator that lets agents of different CLIs
talk to each other. The Operator ruled on its open cards on 2026-11-19. The forces:

- AGNTCY (its Agent Directory and SLIM transport) could be adopted first, or after a lean
  version of our own. Several of its facts were "not checked" in the proposal: downloads,
  checksums, arm64 builds, ports, memory and where it keeps data.
- Each agent's CLI starts a small MCP program that gives the agent four tools (`receive`,
  `reply`, `say`, `who`). One half of it depends on how each vendor's CLI registers an MCP
  server; the other half depends on the facilitator and AGNTCY.
- The agent-orchestration Features (signed packets, the register engine, the file relay)
  exist in a private repository the Operator owns. This repository will own them going forward.
- The `agents` Feature (published, 2.1.x) holds the agent list, kinds, lease, session names and
  launcher verbs. The facilitator needs that code, and no other Feature can reuse it as it is.

## Decision

1. **AGNTCY comes first.** The environment is shaped around what AGNTCY's components need, not
   the other way around. There is no fallback until the lean hatch (step 5 below): a machine on
   which AGNTCY does not run has nothing until then. A hands-on spike (step 0) comes first to
   confirm AGNTCY's downloads, checksums, arm64 builds, ports, memory, start-up time and data
   locations, to send and receive through SLIM from Python, and to test whether a Claude Code
   session keeps listening on a waiting `receive` for a long time (and try the Agent Client
   Protocol on Copilot and Gemini). Its findings note replaces every "not checked" in the
   proposal.
2. **The MCP connection is split in two.** The shared participant component and the vendor
   Features add the MCP entry to each CLI and say who the agent is (the thin, vendor-facing
   side). The facilitator Feature carries the MCP server itself (the heavy side: SLIM client,
   signing, token check, hop counting).
3. **Three Features are taken over from the private repository and owned here:** `sign-packet`
   (every message is a signed packet; the signer), `register-engine` (conversations kept as a
   register; the facilitator supplies the conversation type) and `packet-relay` (the lean hatch:
   passes signed packets through a shared folder). `agentic-register` and `agentic-a2a` stay
   where they are, and the devhost keeps its current register copy. Each Feature is taken over
   on its own branch (`feature/aof-features-takeover/<n>`) and pulled by the Operator one at a
   time.
4. **The `agents` Feature's code moves, unchanged, into `components/participant/`**: shared code
   copied into each Feature that uses it (as the `common` helpers are), never published alone.
   `claude-code` gains the option `participants: true`, which installs it. `agents` 2.2.0 is
   deprecated in favour of it and keeps working with the same tasks and `agents.yml`. This
   repository's devhost swaps `agents` for `claude-code` with `participants: true`.
5. **The order of work is:**

   ```
   0 spike → 1 AOF Features in → 2 agents → shared component
     → 3 first version on AGNTCY (Claude + a local model, signed)
     → 4 Copilot Feature → 5 lean hatch (packet-relay)
     → 6 AI facilitator → 7 retire agents
   ```

   Signing is in the first version, not added later.
6. **Gaps the proposal's subagent filled, which stand unless the Operator objects:** facilitator-only
   settings (such as the default responder) live in the facilitator's own settings file, not in
   the shared agent list; the local model is one more kind of CLI, so the shared component stays
   shell-only and `claude-code` users get no Python; sign-packet does the signing and the
   facilitator registers agents in the directory.

## Options considered

### Option 1: AGNTCY first, split MCP, own the three Features, agents into a component

AGNTCY's requirements shape the environment from day one, so nothing built has to be reworked
around it; the spike removes the unchecked facts before code depends on them. The MCP split
puts what changes with vendors apart from what changes with us. Owning the three Features means
a missing conversation type is just facilitator work. Moving `agents` into a component gives the
facilitator its participant code without a breaking change.

### Option 2: a lean version first, AGNTCY later

Gives a fallback early, but builds the transport and directory twice and shapes the environment
around our own pieces, to be reshaped for AGNTCY. Lost: the Operator chose to lead with AGNTCY's
requirements.

### Option 3: the whole MCP connection in each vendor Feature, or all of it in the facilitator

Each vendor Feature would carry the SLIM and signing logic (duplicated, and needing Python in
every CLI Feature); or the facilitator would need to know every vendor's registration command.
Lost to the split.

### Option 4: take all five AOF Features

Pulls in `agentic-register` and `agentic-a2a`, which the facilitator does not need and which
would put an older copy of the register in competition with the devhost's. Lost: the Operator
chose sign-packet, register-engine and packet-relay only.

### Option 5: leave `agents` as it is and build the facilitator pieces beside it

No migration, but two copies of the agent list, kinds and lease code to keep in step. Lost.

## Consequences

- The spike is the protection against there being no fallback: until step 5, AGNTCY failing to
  run on a machine means nothing works there.
- Three Features (`sign-packet`, `register-engine`, `packet-relay`) enter `src/` under this
  repository's registry; each needs the Feature checklist (metadata, docs, tests, changelog) and
  a release the Operator starts.
- The facilitator supplies the conversation type for `register-engine`; the extra work is in
  its build slice.
- A new `copilot` Feature carries the Copilot adapter (step 4); the backlog item for the
  adapter is amended to say so.
- The `agents` Feature is deprecated at 2.2.0 and retired at step 7; consumers keep working in
  between and move to `claude-code` with `participants: true` at their pace.
- The detail boards of the proposal are redrawn to the rulings (register becomes
  `register-engine`, lean delivery `packet-relay`, signer `sign-packet`).

## Change log

| Date | Change |
|---|---|
| 2026-11-19 | First draft, from the Operator's rulings of the same day. |
| 2026-11-19 | Renumbered from 0060, which PR #193 took. |
