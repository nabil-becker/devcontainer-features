# ADR-0076: An HTTP client may begin a conversation under a person's approval, and public under `team` reaches only a node's own HTTP clients

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-23 |
| **Deciders** | the Operator; proposed by the host |

## Context

Slice N4 of the [facilitator-node proposal](../proposals/facilitator-node.md) built MCP over HTTP for
command-line agents with bearer tokens (ADR-0070; facilitator 0.5.0). Five points could not be built as
written; the Operator ruled on each (HC1 to HC5, 2026-11-23, recorded in the proposal's "Rulings on slice N4"):

- ADR-0066 says a chain begins with a person, but an HTTP client is not a person and nothing writes to it first.
- The `team` preset's ceiling is private, yet an HTTP client is public until `mesh.yml` trusts it.
- There is no register for enrolments outside a conversation.
- An approval could cover one client or one conversation.
- The `mcp` library brings 28 wheels per architecture into the bundle.

## Decision

1. **An approved HTTP client may begin a conversation (HC1, option A; a starting point, to revisit with
   use).** Its `say` is a chain root (hop 0) that no person wrote; the node signs it on the client's behalf and
   marks it `via` http, and `verify` accepts such a root. It is bounded by first-contact approval by a person,
   the public limits (rate 3 a minute across the client's conversations, 2 hops, budget 10) and the reach rule;
   `continue` and `approve` stay a person's. This refines ADR-0066 and ADR-0070 decision 4.
2. **Public under `team` reaches only this node's own HTTP clients (HC2, option A).** `expose: public` marks
   the agents they may reach; `trust` may map `http.<home domain>` only to private or public; public from
   other nodes stays slice N5. Refused under `solo`.
3. **Enrolments are audited in a hash-chained log until slice N5 (HC3, option A).** `token`, `approve`,
   `deny` and `revoke` are lines in `http/audit.jsonl`, each carrying the hash of the one before; approvals and
   denials are also signed notices in their conversations. N5 adds a signed audit register and replays the log.
4. **One approval per client (HC4, option A),** lasting `approval_ttl` (30 days at public) until it expires
   or the token is revoked.
5. **The `mcp` wheels are pinned in the bundle (HC5, option A)** by SHA-256 and URL in `install.sh`
   (`--require-hashes`), and a task regenerates that table before an `mcp` upgrade.

## Options considered

- **HC1:** the client may only reply (it could never begin); a person approves every conversation it starts.
- **HC2:** a new preset between `team` and `open`; no public under `team`, HTTP clients mapped to private (any
  token holder would get private reach).
- **HC3:** a signed audit register in N4 (delays the slice).
- **HC4:** an approval per conversation.
- **HC5:** refreshing the wheel table by hand.

## Consequences

- A token holder, once approved, can open conversations for 30 days within the public limits; revoking the token
  stops it at once.
- A whole rewrite of the audit log would not show until N5's signed register.
- The bundle is about 40 MB larger.

## Change log

- 2026-11-23: accepted (HC1 to HC5).
