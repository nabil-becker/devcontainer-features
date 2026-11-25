# ADR-0070: MCP over HTTP serves CLIs with bearer tokens first and cloud AIs with OAuth later, the node being a resource server only

| | |
|---|---|
| **Status** | accepted (decision 4 refined by [ADR 0076](0076-an-http-client-may-begin-a-conversation-under-a-persons-approval-and-public-under-team-reaches-only-a-nodes-own-http-clients.md); decisions 1 and 2 refined by [ADR 0082](0082-an-oauth-client-is-an-issuer-and-a-subject-and-an-unreadable-key-set-closes-the-gate-with-a-503.md)) |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0067 decision 2 lets clients that only speak remote MCP use MCP over HTTP (Streamable HTTP), the
node signing for them. The Operator ruled on 2026-11-20 on what ships when (AH, SP4) and on the last
readings (BA to BE). The spike found that Claude Code worked against an HTTP endpoint with a simple
token, and that cloud AIs need an OAuth 2.1 authorization server and an HTTPS address reachable from
the vendor's cloud, which a node on a laptop behind NAT does not have. The server library is the
`mcp` Python package (MIT); under the 2026-07-28 MCP spec there are no sessions, and a blocking
`receive` is one long POST answered by an SSE stream.

## Decision

1. **Slice N4 serves CLIs on the intranet with static bearer tokens** (Claude Code run in the spike,
   Copilot CLI from its documentation; N4's exit test runs both for real before 1.0). **Cloud AIs
   come with the public slice N5**, with OAuth.
2. **The node is an OAuth resource server only.** It validates tokens from issuers in an allow list
   (`http.issuers`), checks the audience (RFC 8707) and the scope, and publishes the protected-resource
   metadata (RFC 9728). It hosts no authorization server.
3. **The node signs on behalf of an HTTP client**, and every packet carries `data.via` naming the
   transport, the authentication and the client (ADR-0068).
4. **An HTTP client is never `human`.** It is offered the participant tools (`who`, `say`, `reply`,
   `receive`, `mail`, read-only `transcript`) and never `continue` or `approve`: only a person's local
   session resets the hop count (ADR-0066).
5. **An HTTP client is public by default**: a bearer-token client is mapped through
   `http.<home domain>`, which `mesh.yml` maps to `public` unless the engineer maps it to `private`
   (an intranet CLI, for example).
6. **First contact is approved by a person**; on a node with no person attached the approver is the
   hub's own `humans:` list, which must name at least one, or `check` refuses `approval: first-contact`.
7. **Slice N4 ships the single-node public rules** (visibility, first-contact approval, public limits);
   N5 ships the cross-node public rules and peer-to-peer.
8. **Beyond loopback TLS is required**, or the explicit `http.behind_proxy: true`. HTTP is off by
   default and is refused when the preset is `solo`.

## Options considered

### Option 1: bearer tokens for CLIs first, OAuth for cloud AIs later, resource server only (chosen)

Serves the clients that exist today with the least moving parts, and defers the authorization server
and the public address to the slice that needs them.

### Option 2: OAuth for every HTTP client from the start

Needs an authorization server and a public HTTPS address before any CLI can use the endpoint, though
the CLIs accept a token.

### Option 3: the node hosts its own authorization server

A new component to secure and operate in every node; an external identity provider already does it.

### Option 4: let an HTTP client continue or approve

Leaves a hole in the loop guard: a cloud AI could count as a person and reset the hop count.

## Consequences

- CLIs on the intranet can join without a key on their machine, at the weaker proof of ADR-0068.
- A node behind NAT is local only for cloud AIs.
- The capability matrix needs two MCP rows (stdio; Streamable HTTP with a bearer token or OAuth).
- Rate and abuse limits are built in N4 (per client, per source address, failed-authentication
  back-off, a cap on pending enrolments, a kill switch `http.enabled: false`).
- A first-contact message nobody answers is held 7 days (ruling BG).

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's rulings AH, SP4 and BA to BG of the same day. |
- 2026-11-23: decision 4 refined by ADR 0076 (rulings on slice N4).
- 2026-11-25: decisions 1 and 2 refined by ADR 0082 (rulings on slice N5b).
