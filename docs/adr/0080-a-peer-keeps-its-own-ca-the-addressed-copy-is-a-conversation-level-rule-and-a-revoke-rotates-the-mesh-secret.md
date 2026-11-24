# ADR-0080: A peer keeps its own CA, the addressed copy is a conversation-level rule, and a revoke rotates the mesh secret

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

Slice N5a adds peer-to-peer nodes and the cross-node public level (ADR-0067, ADR-0069, ADR-0075,
ADR-0078). Building it found three places where the rulings did not hold as written:

- A peer has no hub and no OpenBao, yet issues certificates for its own domain. Real SLIM refused
  every leaf under a CA with a URI name constraint (NameConstraintViolation).
- A partial replica cannot be a real sub-DAG: in sign-packet's `graph.order` an entry whose `prev`
  is absent is refused unless a prune of a ruled fork vouches for it.
- A revoked node must lose the SLIM mesh, and SLIM has one shared secret per mesh; there is no
  handover with two apps running.

The slice is built, and its Docker flow `test/facilitator/p2p_flow.sh` passed end to end twice in a row,
rotation shown on real nodes. The Operator ruled on 2026-11-24 (PP1 to PP4, all as recommended); see
[Rulings on slice N5a](../proposals/facilitator-node.md#rulings-on-slice-n5a-2026-11-24).

## Decision

1. A peer is its own issuer: a local CA key file in the state volume at mode 600, used when
   `node.issuer` names no OpenBao; as in ADR-0078 the key may instead live in OpenBao or an ssh-agent (K5). The CA constrains DNS names only, never URIs. This widens
   ADR-0069 decision 4 and sits in the file position of ADR-0078.
2. `copy: addressed` is a rule at conversation level, not a sub-DAG: the issuer replicates only
   conversations the public node is a member of, a write is refused when a message in such a
   conversation is not addressed to that node's members, and `verify` reports a lineage leaving the
   replica as "partial (copy addressed)" with exit 0.
3. `node revoke` starts a rotation of the mesh SLIM secret: the remaining nodes receive the new
   secret under the old one and restart their peers part onto it, waiting up to 120 s for absent
   nodes. A node away longer runs `node secret` by hand (PP3; an automatic re-fetch is a later backlog item).
   A revoke is not gossiped: each node revokes for itself (PP4).
4. The signed audit register (type `audit`) records enrolments and join, approve, revoke and rotate
   events.

## Options considered

### Option 1: the chosen ones

They meet the exit tests with the smallest change and keep register-engine untouched.

### Option 2: a true partial replica

Needs an "elided" notion in register-engine so that a missing `prev` is accepted. Not recommended now.

### Option 3: rotation by handover with two apps, or a join-endpoint re-fetch for stragglers

Safer for absent nodes, but SLIM offers no two-secret handover and the re-fetch needs a fresh token
flow. Kept as the follow-up.

### Option 4: a peer's CA key in OpenBao only

Would keep ADR-0069 intact but make a peer depend on a server it is meant to run without.

## Consequences

- A peer's CA key on disk is a bounded widening of the custody rules; OpenBao stays optional.
- A node that missed a rotation stays out until its secret is set by hand.
- A revoke by one peer does not stop the others trusting the node.
- Every CA a node makes now carries a DNS name constraint only (the home-domain CA too).
- Backlog: real sub-DAG partial replicas, a stable `p2p_flow.sh`, a rotation proof on real nodes.

## Change log

| Date | Change |
|---|---|
| 2026-11-23 | First draft, proposed from the N5a con's hand-off. |
| 2026-11-24 | Accepted on the Operator's rulings PP1 to PP4. |
