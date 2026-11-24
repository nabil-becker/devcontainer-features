# ADR-0069: Node certificates are issued by an OpenBao PKI per trust domain, and two locks keep each trust level apart

| | |
|---|---|
| **Status** | accepted (amended by [ADR 0075](0075-a-spoke-joins-through-a-join-endpoint-agents-are-bound-to-their-node-by-signed-cards-and-a-handle-can-be-qualified-by-its-node.md): decisions 4 and 5; decision 1 by [ADR 0078](0078-a-node-issues-certificates-itself-by-default-with-the-ca-key-in-openbao-else-an-ssh-agent-else-a-file.md): a built-in issuer by default; decision 4 widened by [ADR 0080](0080-a-peer-keeps-its-own-ca-the-addressed-copy-is-a-conversation-level-rule-and-a-revoke-rotates-the-mesh-secret.md): a peer's own CA key is a file) |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0067 puts the mesh on SPIFFE identities. Two questions were left: who issues the certificates,
and how a trust level is actually enforced. The Operator ruled on 2026-11-20 on the issuer (AB) and
on the spike's findings (SP1, SP2). The spike
([docs/spikes/2026-11-21-slim-spiffe.md](../spikes/2026-11-21-slim-spiffe.md)) found:

- SLIM accepts SVID-shaped certificates from plain files, so SPIRE's Workload API is not needed, and
  SPIRE costs about 160 MB more across its two daemons;
- **SLIM checks only that a certificate chains to the CA bundle a listener holds; it never checks the
  SPIFFE ID or the trust domain.** A client claiming to be in "intranet" with a certificate from the
  "local" CA was admitted;
- a certificate needs a DNS name equal to the dialer's `server_name` besides its URI SAN.

OpenBao is already the repository's key store (ADR-0048) and signs SSH certificates under the
pattern of ADR-0059. The spike used `openssl`, not OpenBao PKI.

## Decision

1. **The issuer is an OpenBao PKI engine**, one CA per trust domain. A certificate carries a URI SAN
   `spiffe://<trust-domain>/...` and a DNS SAN equal to the `server_name`, is `CA:false`, and is
   written to files that SLIM reads and reloads by `reload_interval`. SPIRE is optional and later.
2. **For intranet use** the hub's OpenBao is unsealed by hand after each start (ADR-0048), certificates
   last 24 hours and are renewed at half life, and the root CA is kept offline: the hub's OpenBao
   holds an intermediate only. The facilitator reaches OpenBao by an AppRole over the compose network.
   The step that creates the PKI roles needs a root token made from the shares (ADR-0050).
3. **Automatic unsealing is decided before the public level** (slice N5): a public certificate of
   1 hour cannot wait for a person. Until then a sealed OpenBao means no renewals, and local and
   private nodes have a day.
4. **The local domain** may be self-issued by the node, its CA key in OpenBao when a vault exists and
   in the state volume otherwise. That is a written exception to ADR-0048, the same fallback the 0.2.0
   keys have.
5. **Two locks, both required.** Lock one, the listener: each trust level has its own SLIM listener
   with its own CA bundle, so a client of another level cannot connect. Lock two, the application:
   the facilitator checks every signed message's SPIFFE ID against the node's `mesh.yml`, and the
   domain the ID names must equal the domain whose CA signed the certificate. Neither lock alone is
   enough: lock one does not tell two domains of one level apart, and lock two cannot see a
   connection SLIM already admitted.
6. The `openbao` Feature gains the PKI configuration (`openbao:pki:*`, as ADR-0059's `openbao:ssh:*`).

## Options considered

### Option 1: OpenBao PKI issues certificate files, with two locks (chosen)

No new daemon, one key store, and the spike showed files are enough for SLIM. The two locks close the
gap the spike found.

### Option 2: a SPIRE server and agent per issuing node

The reference implementation with rotation and federation built in, but two more daemons and a
database for every hub, and SLIM works without its Workload API.

### Option 3: self-issued certificates everywhere

Zero dependencies, but a self-signed domain cannot federate; kept for the local level only.

### Option 4: rely on SLIM's own check alone

Rejected by the spike: SLIM never checks the SPIFFE ID or the trust domain.

## Consequences

- The Operator unseals the hub's OpenBao by hand after every start for as long as the mesh is private.
- Certificates are the revocation mechanism: a revoked node's certificate expires within its TTL.
- Two listeners with different CA bundles on one node were not tried in the spike; that, and whether
  OpenBao PKI issues certificates with the right SANs, are first tasks of N3. The fallback for the
  first is one SLIM process per level.
- A federated CA's rotation reaching a running node is unverified (roots are read once at start).
- The `openbao` Feature needs a release with the PKI configuration.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's rulings AB, SP1 and SP2 of the same day. |
- 2026-11-23: decisions 4 and 5 amended by ADR 0075 (rulings on slice N3).
- 2026-11-23: decision 1 amended by ADR 0078 (a node issues certificates itself by default).
- 2026-11-24: decision 4 widened by ADR 0080 (a peer keeps its own CA).
