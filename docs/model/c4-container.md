# C4 container: inside the devhost

The host briefs cons; the backs keep the records after each turn; the back guard undoes a back
that changed what it may only add to; the guards check the records at commit time. Node ids are
ontology ids.

```mermaid
flowchart TB
  subgraph devhost["Devhost"]
    host["Host"]
    con["Con"]
    subgraph back["Backs"]
      scribe["Scribe"]
      secretary["Secretary"]
      librarian["Librarian"]
      tester["Tester"]
    end
    guard["Back guard"]
    guards["The guards"]
    ledger["Ledger"]
    backlog["Backlog"]
    lexicon["Lexicon"]
    adr["ADR"]
    journal["Journal"]
    drop-a-seed["Drop a seed"]
    journalist["Journalist (a brief, not a back)"]
    white-paper["White paper"]
  end
  host -->|briefs| con
  con -->|returns hand-off to| host
  scribe -->|writes| ledger
  secretary -->|keeps| backlog
  librarian -->|keeps| lexicon
  librarian -->|keeps| adr
  drop-a-seed -->|uses| journalist
  journalist -->|writes| white-paper
  guard -->|checks| backlog
  guard -->|checks| lexicon
  guard -->|checks| adr
  guards -->|checks| ledger
  guards -->|checks| adr
```

## The component registry (ADR-0063)

Built in slices 1 and 2: `component-registry` fetches its layers and resolves them; the
participant component runs `resolve` at every agent's start and `dcf-registry handover` gives the
skills to the CLI adapter's `skills` verb (ADR-0064). The dashed relations come later: the
launcher's share mount and who-you-are path, and the `http` and cloud-folder sources (slice 3).
OpenBao gives a `git` source its secret today, through `dcf-secret`.
Slice 4 (the first real use) adds the devhost Feature as a layer's owner: its image folder holds
the generic `architecture-review`, which this repository's own layer stacks on.

```mermaid
flowchart LR
  component-registry["component-registry: resolve, explain, handover, refresh"]
  participant-component["agents (participant component)"]
  cli-adapter["CLI adapter: skills verb"]
  launcher["Launcher: share mount, whoami"]
  master-of-secrets["OpenBao: source secrets"]
  external-sources["Layer sources: git, path, http, cloud folder, db"]
  external-sources -->|fetched by| component-registry
  master-of-secrets -->|gives secrets to| component-registry
  launcher -.->|later: mounts shares, sets whoami for| component-registry
  participant-component -->|runs resolve at start| component-registry
  component-registry -->|hands skills to| cli-adapter
  devhost["devhost Feature: the generic layer"] -->|a path layer for| component-registry
```
