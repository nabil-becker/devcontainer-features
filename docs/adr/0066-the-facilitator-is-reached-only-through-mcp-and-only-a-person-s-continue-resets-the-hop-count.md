# ADR-0066: The facilitator is reached only through MCP, and only a person's continue resets the hop count

| | |
|---|---|
| **Status** | accepted (refined by [ADR 0076](0076-an-http-client-may-begin-a-conversation-under-a-persons-approval-and-public-under-team-reaches-only-a-nodes-own-http-clients.md)) |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

Facilitator 0.1.0 (ADR-0061) gave an engineer a terminal chat (`facilitator chat`, `facilitator send`)
beside the MCP server that gives each agent its tools. A message from the engineer reset the hop
count by itself, which is how a paused agent conversation resumed. The Operator ruled on
2026-11-20 to "remove the chat, essentially making it just accessible through the MCP", so a person
talks to the facilitator from their own Claude Code or Copilot session ("ask @jester for a joke")
instead of a separate terminal UI. The forces:

- a person must be able to start a conversation, see replies, read a conversation and resume a
  paused one without a second interface;
- the loop guard (hop count, message budget of 40, rate limit of 10 a minute) must keep working when
  a person's session sends messages, and an agent must not be able to defeat it;
- one MCP entry should serve every agent whose harness sets the handle and token.

## Decision

1. **MCP is the only way in.** A person is a participant of kind `human` (from `facilitator.yml`
   `humans:`), attached over the same MCP server with their own handle and token. The command line
   drops `chat` and `send`; `transcript`, `verify`, `status` and `check` stay as read-only admin
   tools; version, setup, start, infra, register, participants, snippet, mcp and model stay.
2. **Seeing replies is a non-blocking "any mail?" call.** That call is the contract. A turn hook
   that shows "N new messages" at each turn is a convenience, offered where the CLI has one
   (Claude Code does).
3. **Option A for hops.** A message sent through a person's session counts as a hop like any other.
   Only an explicit `continue` tool call resets the hop count (the MCP form of the old `/continue`),
   and only a `human`-kind caller may use it; an agent can neither call it nor claim to be human.
   The message budget and rate limit are unchanged.
4. **`facilitator mcp` reads `FACILITATOR_HANDLE`** (`--as` is still accepted), so one MCP entry
   serves every agent whose harness sets `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN`.

## Options considered

### Option 1: MCP only, hops count for a person's messages (chosen)

One interface for people and agents, one set of identities and tokens, and the guard has no
privileged sender that a prompt could imitate.

### Option 2: keep the chat beside MCP

Two interfaces to maintain and test; rejected by the Operator.

### Option 3: a person's message resets hops by itself (the 0.1.0 rule)

Through a person's own agent session, a model could send "as the person" and loop forever with
the guard silently reset. Rejected: reset needs an explicit, human-only call.

### Option 4: replies only by a turn hook

Only some CLIs have a turn hook, so it cannot be the contract; kept as a convenience.

## Consequences

- A person's session needs the facilitator's MCP entry, handle and token like an agent does;
  `facilitator snippet <human-handle>` prints how to add the turn hook.
- A person who sends several messages in a conversation must call `continue` to resume a paused one;
  the change is stated in the Feature's NOTES.
- Tests and docs that used `chat` or `send` move to the MCP tools (done in facilitator 0.2.0).

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's rulings of the same day. |
| 2026-11-20 | Numbered 0066: 0065 is the copilot pin (#207). |
- 2026-11-23: refined by ADR 0076 (rulings on slice N4).
