# Workflows

The main flows, in order. Sources: [PROCESS.md](../../PROCESS.md), [CLAUDE.md](../../CLAUDE.md),
[CONTRIBUTING.md](../../CONTRIBUTING.md), `.github/workflows/`, `.claude/skills/*/SKILL.md`.
Part of the [six](README.md). Node ids are ontology ids where they name a model thing; sequence diagrams use short ids, since a hyphen breaks a participant name there.

## 1. A session, start to close

The host commits and pushes; the Operator reviews and merges (ADR 0040).

```mermaid
sequenceDiagram
  actor operator as Operator
  participant host as Host
  participant guards as Guards
  participant gh as git and GitHub
  Note over host: SessionStart hook
  host->>host: briefing (ledger, backlog, spend)
  host->>gh: branch task devhost:branch
  operator->>host: asks
  host->>host: work through tasks
  operator->>host: close-session
  host->>guards: task devhost:verify
  guards-->>host: green
  host->>gh: commit, push, open PR
  operator->>gh: review, squash merge
```

The briefing arrives on its own. Work happens on a topic branch, never on `main`. Close runs the
records check, the guards and the diff scan before the commit.

## 2. A proposal

```mermaid
flowchart LR
  write["Write the proposal<br/>docs/proposals/"] --> review["architecture-review<br/>a subagent, the proposal alone"]
  review --> section["Adds an Architecture review section<br/>design sections untouched"]
  section --> rule{"The Operator rules"}
  rule -->|decided| backlog["backlog-item<br/>and an adr if long"]
  rule -->|declined| keep["Stays, with status line"]
  backlog --> build["Build in a PR<br/>updates the architecture documents"]
```

No proposal is in force until the Operator accepts it. The review comes before every ruling
([ADR 0039](../adr/0039-an-architecture-review-comes-before-every-ruling-and-nfr-13-says-we-manage-the-environment-not-the-cli.md)).
A proposal names which of the six architecture documents it changes ([README](README.md)).

## 3. A Feature change to a release

```mermaid
flowchart TB
  b["Topic branch<br/>type/id/n"] --> c["Change src/id/"]
  c --> v["Bump version<br/>and CHANGELOG entry"]
  v --> d["task docs<br/>commit src/id/README.md"]
  d --> pr["Pull request"]
  pr --> checks{"Required checks"}
  checks --> val["validate"]
  checks --> lint["lint"]
  checks --> tests["tests"]
  checks --> dco["DCO"]
  val --> m["Operator squash merges"]
  lint --> m
  tests --> m
  dco --> m
  m --> rel["release workflow<br/>manual, on main, the Operator starts"]
  rel --> reg["feature-registry<br/>ghcr.io tags: major, major.minor, full, latest"]
```

An agent says a release is due and what it would publish; it never runs it. Until the release, a
Feature cannot be named in `installsAfter` or pulled by a consumer. The release workflow needs
no write access: READMEs are committed, and the lint workflow checks they are current.

## 4. A con's job

```mermaid
sequenceDiagram
  participant host as Host
  participant con as Con
  participant hook as Stop hook
  participant scribe as Scribe
  host->>con: brief (job, bounds, model, branch, who you serve)
  con->>con: work, waits for its own jobs
  con-->>host: hand-off (Outcome, Outputs, Friction, For the repository, Decisions needed)
  host->>host: checks it, a report is not evidence
  con->>hook: job ends
  hook->>scribe: start
  scribe->>scribe: ledger entry with measured cost
```

One job per con, sized by blast radius (Sonnet by default, Opus only when the change reaches
every consumer, with the reason in the brief). A con replies once. Each job gets its own ledger
entry.

## 5. The backs after a turn

```mermaid
flowchart LR
  turn["Turn or con's job ends"] --> hook["hook"]
  hook --> scribe["scribe -> ledger"]
  hook --> secretary["secretary -> backlog"]
  hook --> librarian["librarian -> lexicon, adr"]
  hook --> tester["tester -> suite"]
  scribe --> g{"guard:<br/>only added?"}
  secretary --> g
  librarian --> g
  g -->|yes| qn["quiet-notice"]
  g -->|no| undo["guard undoes it"]
  qn --> host["host reads it before the next commit"]
  stake["stake: one plain line"] -.-> hook
```

Backs run in the background, inside the devhost, and never make the host wait. They only add
(the secretary also ticks). Anyone leaves a stake when something might be missed. On a
workstation there are no backs; `/close-session` does their chores by hand.

## 6. After a merge, and shutdown

```mermaid
flowchart LR
  merged["PR merged"] --> pull["git switch main, git pull"]
  pull --> prune["task devhost:branches PRUNE=1"]
  stop["Operator: shut down"] --> check["shutdown-devhost skill<br/>devhost-shutdown-check"]
  check --> wait["wait for the backs"]
  wait --> halt["task devcontainer:stop"]
  halt --> back["restart-devhost, or task devcontainer:up"]
```

A merged branch is never pushed to again; a new branch starts the next piece of work.
