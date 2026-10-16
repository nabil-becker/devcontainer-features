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
      journalist["Journalist (planned)"]
    end
    guard["Back guard"]
    guards["The guards"]
    ledger["Ledger"]
    backlog["Backlog"]
    lexicon["Lexicon"]
    adr["ADR"]
    journal["Journal"]
  end
  host -->|briefs| con
  con -->|returns hand-off to| host
  scribe -->|writes| ledger
  secretary -->|keeps| backlog
  librarian -->|keeps| lexicon
  librarian -->|keeps| adr
  journalist -.->|keeps| journal
  guard -->|checks| backlog
  guard -->|checks| lexicon
  guard -->|checks| adr
  guards -->|checks| ledger
  guards -->|checks| adr
```
