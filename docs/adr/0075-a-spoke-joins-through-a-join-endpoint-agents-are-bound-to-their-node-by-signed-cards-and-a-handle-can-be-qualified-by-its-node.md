# ADR-0075: A spoke joins through a join endpoint, agents are bound to their node by signed cards, and a handle can be qualified by its node

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-23 |
| **Deciders** | the Operator; proposed by the host |

## Context

Slice N3 of the [facilitator-node proposal](../proposals/facilitator-node.md) built hub and spoke with local
and private trust (facilitator 0.4.0). Five points of ADR-0069, ADR-0071 and the rulings could not be built as
written; the Operator ruled on each (H1 to H5, 2026-11-21 to 2026-11-23, recorded in the proposal's "Rulings on
slice N3"):

- A spoke has no certificate before it joins, so lock one keeps it off SLIM, and ADR-0071's list of ports has
  no way in for it.
- dirctl 1.9.1 has no switch for mDNS: in the tests three Directory daemons found each other on one network
  segment, and its OCI registry accepted an anonymous push. ADR-0071 decision 4 cannot be met by configuration.
- OpenSSH cannot export an ed25519 key to PKCS8, so a node's certificate key and the agents' packet keys stay
  separate, and SLIM reads its TLS key from a file (ADR-0069 decisions 4 and 5).
- SLIM 3.4.6 checks no revocation list and reloads no certificate.
- Two nodes may expose agents with the same handle.

## Decision

1. **The join endpoint (H1, option A).** A hub opens an HTTPS join endpoint (`node.join`) only while a join
   token is live, and closes it 30 s after the last token is used or expires. The token (`node invite`: single
   use, 15 minutes) carries the hash of the domain's trust bundle: the token protects the hub, the hash protects
   the spoke. The spoke sends a CSR and gets its certificate from the hub's issuer. ADR-0071 decision 1's list of
   ports gains the join endpoint.
2. **Directory peering is off by default (H2, option A).** With `node.directory.peering: false` nothing of the
   Directory leaves loopback and nodes learn each other's agents from the signed cards. Peering on needs
   `node.directory.firewall` (`auto`: iptables drops UDP 5353; `external`: a person firewalls it); a hub then
   opens OCI and libp2p, and a spoke syncs the hub's records by registry, one way. An upstream issue asks for
   an mDNS switch. This is how ADR-0071 decision 4 is met.
3. **Agents are bound to their node by signed cards (H3, option A).** Each node signs a card with its
   certificate key: its certificate, its facilitator key and the keys of the participants it exposes. The hub
   passes every admitted card on in the roster. Lock two takes a packet's SPIFFE ID from its signer's key looked
   up in the admitted cards, and requires a qualified signer's node to be the node whose card binds the key.
   Agents get no certificates of their own until AGNTCY Identity (slice N5); revoking a node cuts off all its
   agents. The node's certificate key is a file in the state volume (mode 600) on every node, which widens
   ADR-0069 decision 4; a trust bundle holds the intermediate and the root, and a renewal restarts SLIM.
4. **A revoked node's TLS link may form until its certificate expires (H4, option A).** It gets no renewal
   (24 h certificates) and lock two refuses everything it sends. Rotating the mesh's SLIM app secret on every
   revoke is done before slice N5 (backlog `mesh-secret-rotation`).
5. **Qualified handles (H5, option B).** `@<handle>.<node>` names an agent on a node (for example
   `@b1.spoke-b`); handles (`a-z 0-9 _ -`) and node ids (`a-z 0-9 -`) cannot hold a dot, so the split is never
   ambiguous. A bare handle works when it names exactly one reachable agent; when it names several it is refused
   with the qualified names, with no local-first rule. The hub admits a second claim on a handle, and a shared
   conversation names every member `handle.node`.

## Options considered

- **H1:** carrying the certificate to each spoke by hand (no port, but `bao` and key files on every spoke); a
  SLIM listener without client certificates (no port, but lock one weakened for every node).
- **H2:** peering on by default, accepting that nodes find each other on the LAN.
- **H3:** a certificate per agent (more issuing and renewing, and SLIM checks only the node's certificate).
- **H4:** rotating the secret on revoke in slice N3 (every remaining node needs the new secret; delays N3).
- **H5:** refusing the second claim, so that a shared handle is reachable on neither node until one is renamed.

## Consequences

- One more port, open only for minutes at a time; `facilitator check` and the NOTES name it.
- No LAN discovery without a firewall the node checks for; a spoke without peering still sees the hub's agents.
- A compromised node exposes every agent on its card until it is revoked and its certificate expires.
- An ambiguous mention inside a conversation reuses the `unknown-handle` notice; an `ambiguous-handle` code waits
  for the next change of the conversation register type.

## Change log

- 2026-11-23: accepted (H1 to H5).
