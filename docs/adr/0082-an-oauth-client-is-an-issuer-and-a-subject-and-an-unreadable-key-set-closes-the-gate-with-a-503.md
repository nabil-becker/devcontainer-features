# ADR-0082: An OAuth client is an issuer and a subject, and an unreadable key set closes the gate with a 503

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

Slice N5b (facilitator 0.8.0) makes the node an OAuth resource server for cloud AIs, as ADR-0070
decided. ADR-0070 and ADR-0076 leave open what "client" means for first-contact approval when the
caller holds an OAuth token, how a failure to read an issuer's keys is answered, and what the
record may carry about the caller. The con picked answers while building and listed them as decisions
needed; the Operator has not ruled.

## Decision

- An OAuth client is the pair issuer plus subject. The OAuth `client_id` is kept only as a label.
  Approval, revoke and limits apply per pair, with the same mapping as a bearer client (ADR-0076).
- The `via` field of a record carries transport `http`, auth `oauth`, client, issuer and subject.
- When an issuer's keys cannot be read, the gate answers 503 and stays closed; this is not counted
  against the caller.
- A request without a token gets 401 with a `resource_metadata` challenge, and the gate itself serves
  the RFC 9728 metadata (404 when no issuers are set).
- Each `http.issuers` entry is a map with a `name` (the named authorization server); a bare URL list is
  refused. `http.url` is required with issuers and must be https.

## Options considered

### Option 1: issuer plus subject (chosen)

A connector's `client_id` is shared by all its users and dynamic registration may issue a new one each
time, so approving it would approve everyone, or nobody twice. The subject is the person.

### Option 2: issuer plus `client_id`

Simpler to read, but it approves a whole connector at once and breaks when the id changes.

### Option 3: a hash of the subject in the record

Hides an email-shaped subject but loses auditability.

## Consequences

- The subject is written into the record and replicated; if an issuer's subject is an email, so is the
  record. NOTES says so.
- A revoked or denied client stays refused until a person runs `facilitator http forget` (ruling OA3); its next
  login is then new and held for approval.
- Opaque tokens and introspection are not supported; JWT only.
- The login flow is proven locally with Keycloak and Claude Code as the client (`task facilitator:oauth-local`,
  ruling OA5 as revised); a claude.ai connector needs a public https address and waits in the backlog.
- `http.insecure: true` allows plain http for a local machine or a test environment, and is refused under
  `preset: open` (ruling OA6).

## Change log

| Date | Change |
|---|---|
| 2026-11-24 | First draft (proposed). |
| 2026-11-25 | Accepted: the Operator ruled OA1 to OA6 (proposal, "Rulings on slice N5b"). |
