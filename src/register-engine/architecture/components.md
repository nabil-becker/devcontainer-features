# register-engine: components

The Feature's own C4 views (AOF ADR 0007: a Feature may draw itself). Each element names the file it
comes from, so the drawing can be checked against the source. register-engine keeps no state.

## Context

```mermaid
C4Context
  title register-engine in its context (AOF ADR 0028)
  Person(caller, "An operator or an agent", "register-engine version, check, types, verify")
  System_Ext(capabilities, "The capability Features", "agentic-memory, agentic-communication, agentic-trust, agentic-agents (to come): register types and the commands that write")
  System(register-engine, "register-engine", "Registers on signed packets: writing, reading many writers as one, stores, sync, views")
  System_Ext(sign_packet, "sign-packet", "the packet: canonical JSON, signature, id, chain, guards")
  Rel(caller, register-engine, "checks a store with")
  Rel(capabilities, register-engine, "give their types to (types.d); write and read through")
  Rel(register-engine, sign_packet, "makes and reads entries through")
```

## Components

```mermaid
C4Component
  title register-engine components
  Container_Boundary(register-engine, "register-engine") {
    Component(cli, "register-engine command", "Python", "version, check, types, verify: reads only")
    Component(core, "core", "Python", "roster, ruling, prune kinds; anchors; reading one register")
    Component(adapters, "adapters", "Python", "stores, sync, add, the guard, the checked record, the index, the change feed")
    Component(types, "types", "Python", "register types; the root-owned types folder they load from")
  }
  Rel(cli, types, "lists and gets types with")
  Rel(cli, core, "reads with")
  Rel(adapters, core, "checks and joins with")
  Rel(types, core, "uses Refused and the name rule of")
```

| Element | Source |
|---|---|
| `register-engine` | `src/register-engine/devcontainer-feature.json` |
| `cli` | `src/register-engine/registerengine/cli.py` |
| `core` | `src/register-engine/registerengine/core.py` |
| `adapters` | `src/register-engine/registerengine/adapters.py` |
| `types` | `src/register-engine/registerengine/registertypes.py` |
| `capabilities` | AOF ADR 0028; `AOF's aof/tooling/design/feature-domains.md` |
| `sign_packet` | `src/sign-packet/` (imported as `signpacket`) |
