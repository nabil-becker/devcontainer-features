# sign-packet: components

The Feature's own C4 views (AOF ADR 0007: a Feature may draw itself). Each element names the file it
comes from, so the drawing can be checked against the source. sign-packet keeps no state.

## Context

```mermaid
C4Context
  title sign-packet in its context
  Person(caller, "An operator or an agent", "sign-packet verify, check, version")
  System_Ext(agentic_register, "agentic-register", "the registers: kinds, rosters, anchors, rulings, prunes, stores")
  System_Ext(packet_relay, "packet-relay", "to come (AOF ADR 0024): packets between parties through a shared folder")
  System(sign-packet, "sign-packet", "Signed packets, named by their hash, chained per key: makes, checks and orders them")
  System_Ext(openssh, "OpenSSH ssh-keygen", "-Y sign and -Y verify, Ed25519")
  Rel(caller, sign-packet, "checks packet files with")
  Rel(agentic_register, sign-packet, "makes and reads its entries through; passes its own checks in")
  Rel(packet_relay, sign-packet, "will move and check packets with")
  Rel(sign-packet, openssh, "signs and verifies through")
```

## Components

```mermaid
C4Component
  title sign-packet components
  Container_Boundary(sign-packet, "sign-packet") {
    Component(cli, "sign-packet command", "Python", "version, check, verify: each packet file alone")
    Component(packet, "packet", "Python", "canonical JSON, the body's fields, the id, sign, signature check, a key's public half")
    Component(graph, "graph", "Python", "collect (checks 1 to 4), order (parents, chain, held, vouched absent, the layer's decide), forks")
  }
  Rel(cli, graph, "collects with")
  Rel(graph, packet, "parses and verifies with")
```

| Element | Source |
|---|---|
| `sign-packet` | `src/sign-packet/devcontainer-feature.json` |
| `cli` | `src/sign-packet/signpacket/cli.py` |
| `packet` | `src/sign-packet/signpacket/packet.py` |
| `graph` | `src/sign-packet/signpacket/graph.py` |
| `agentic_register` | `src/agentic-register/register/core.py` (imports `signpacket`) |
| `packet_relay` | AOF ADR 0024, decision 3; backlog item `packet-relay-feature` |
| `openssh` | `signpacket/packet.py`, `sign()` and `signature_ok()` |
