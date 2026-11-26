# ADR-0087: A person gates agent-to-agent commands twice: the facilitator holds each message, and the receiving agent asks before acting

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-25 |
| **Deciders** | the Operator; proposed by the host |

## Context

The devhost is now a spoke of the workstation's facilitator hub (ADR-0084, ADR-0075), and the
office will be the second spoke. Agents in one devcontainer will be able to send commands to
agents in another. The Operator wants a person to approve such commands.

What exists today is `limits.<level>.approval: first-contact` with `approval_ttl` in `mesh.yml`
(ADR-0076): the first message from a new sender is held until a person approves it, and the
sender is then trusted for the TTL. It is built and checked for HTTP clients and for agents on
public nodes; Facilitator 0.9.0's first step established the fact for private spokes: the receiving node reads
the sender's card level, so `first-contact` set at `private` in the receiver's `mesh.yml` is enforced for another
node's agents (only the default, `none` at private, made it look public-only; a unit test says so). Nothing held
every message.

The facilitator only carries messages. Whether the receiving agent runs a shell command or edits
a file is decided by that agent's own harness, that is, Claude Code's permission mode in the
receiving devcontainer. So a human gate can sit in two different places.

## Decision

Both gates are used, layered, and neither replaces the other.

1. **The receiving agent asks (agent side).** A dedicated agent, `mesh`, runs Claude Code in its
   default permission mode, so it asks the person before every tool it runs on a request that
   came from another devcontainer. In a devhost's `mesh.yml` only `mesh` is exposed to the mesh
   (`mesh: private`); the host session, which runs in auto mode, stays local (`"*": local`) and
   cannot be reached from another node. This is configured per devhost (pull request #253).
2. **The facilitator holds every cross-node message (node side).** `limits.<level>.approval`
   gains the values `every-message` (each message from another node is held until a person approves that
   message) and `per-conversation` (the first message of each new cross-node conversation is held; once approved,
   that sender's rest of it flows), valid at `private`, `public` and for HTTP clients, refused at `local`. Held
   messages show in the person's `mail` and the turn hook line, are approved or denied with `facilitator approve`
   and `deny` (or the person's MCP tools `approve` and `deny`; a person only, refused in an agent's job), and each
   answer is a signed notice in the conversation and an audit entry (`message-approved`, `message-denied`), so
   `verify` shows that a person approved the message; a denial reaches the sender as a signed notice, and a message
   held more than 7 days is never delivered. The receiving node enforces it, so each devcontainer decides what it
   accepts. It ships as facilitator 0.9.0.

A devhost's `mesh.yml` sets `approval: every-message` for `private` only once a release that
knows the value is installed; an older node rejects an unknown value and falls back to
standalone.

## Options considered

### Option 1: both gates, layered (chosen)

Each covers what the other cannot: the node gate stops a message before it reaches an agent and
leaves an audit trail; the agent gate stops an action even for a message that was approved, or
that arrived over a path the node gate does not cover. The agent gate works today with no
release.

### Option 2: the facilitator gate only

Rejected: approving a message says nothing about what the agent then does with it; the receiving
agent in auto mode would act on an approved message without further asking.

### Option 3: the agent gate only

Rejected: the message reaches the agent unrecorded, there is no audit of the person's approval,
and the gate depends on every receiving harness being configured to ask.

### Option 4: rely on `first-contact` as it is

Rejected: it approves a sender once, not each command, and it asks nothing of later messages.

## Consequences

- A person's approval is required twice for a command that runs a tool: once for the message,
  once for the tool. This is slower by design.
- Only the `mesh` agent is reachable from other devcontainers; work wanted from the mesh has to
  go through it, and its tools are limited by what the person approves.
- Facilitator 0.9.0 (cross-node-approval) adds the values, the `mail`, `approve`
  and `deny` flow and the audit entries; until it is released the node gate stays at 0.8.0's
  settings.
- Each devhost that joins the mesh needs the `mesh` agent and the exposure setting in its
  `mesh.yml`; the office gets them when it joins.

## Rulings on the build (2026-11-25)

The Operator ruled AP1 to AP4 as recommended: (AP1) under `per-conversation` a denial answers that message only, and the
sender's next message is held again; (AP2) the gate holds what reaches an agent, and a message to a person still goes to
their `mail`; (AP3) the receiving node holds delivery, not the replicated data; (AP4) the turn-hook count may lag after a
held message ages past 7 days.

## Change log

| Date | Change |
|---|---|
| 2026-11-25 | First draft; accepted by the Operator ("both, layered"). |
| 2026-11-25 | The Operator ruled AP1 to AP4 as recommended. |
