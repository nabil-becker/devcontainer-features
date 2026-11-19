# ADR-0060: The architecture is kept in a standing set of six documents, and every proposal carries its deltas

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-19 |
| **Deciders** | the Operator; proposed by the host |

## Context

Proposals describe a change to the design, but nothing kept the design itself current: after a
change was built, the picture of the architecture lived in scattered proposals and ADRs. The
architecture review ([ADR-0039](0039-an-architecture-review-comes-before-every-ruling-and-nfr-13-says-we-manage-the-environment-not-the-cli.md))
checks a proposal against the requirements and the records but had no standing documents to check
it against. The C4 views in `docs/model/` are guarded by the ontology guard
([ADR-0005](0005-the-ontology-is-the-canonical-model-and-a-guard-keeps-the-rest-in-line.md)) and
must stay where they are.

## Decision

The repository keeps six living architecture documents, the standing architecture set: State of the
Architecture, C4 Models, Workflows, Lifecycles, Data Flows, and Data Inventory and Models.

- Every proposal states which of the six it changes and carries the delta for each (the changed
  diagram or table). The architecture review flags a proposal that changes one without its delta,
  and a standing document that is missing or stale.
- The standing documents are updated in the same pull request as the change when it is built, not
  when the proposal is written.
- The practice is part of the devhost way of working that every consumer gets (the `devhost`
  Feature's templates and the exported seed), not a rule for this repository alone.
- An index `README.md` links the six. Here the set lives in `docs/architecture/`; the C4 views stay
  in `docs/model/c4-context.md` and `docs/model/c4-container.md`. A consumer may place its set
  elsewhere; the practice requires the six and an index, and the path is the repository's choice.
- The Data Inventory lists every place data is kept with its storage tier
  ([ADR-0045](0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md))
  and its sensitivity.
- The rule travels in the `devhost` Feature's templates (the `architecture-review` skill and
  `PROCESS.md`; devhost 1.14.1 to 1.15.0).
- Diagrams exist in both forms: Mermaid plus text committed in git is the reviewed source that the
  guards check; a Whiteboard board per diagram set is generated from it for the Operator to view and
  rearrange. The board is a view, never the source.

## Options considered

### Option 1: a standing set plus deltas, updated when built

The documents stay true to what exists, and a delta makes a proposal's effect reviewable. Updating
at build time keeps the set describing the system, not intentions.

### Option 2: update the standing documents when the proposal is written

Rejected: a proposal may be changed or abandoned, so the set would describe what does not exist.

### Option 3: proposals only, no standing set

Rejected: the current architecture has to be reassembled from many proposals and ADRs each time.

### Option 4: a rule for this repository only

Rejected: consumers would script their own architecture documentation, which the ecosystem treats
as a gap to close here.

### Option 5: boards as the source

Rejected: a board is not in git, cannot be checked by the guards and cannot be reviewed in a pull
request.

## Consequences

- The architecture review has something to check against, and a proposal's design effect is visible
  as a delta.
- A change that touches the architecture costs the builder a documentation update in the same pull
  request.
- Each consumer sets up its own index and set; the default path is `docs/architecture/`.
- A consumer that takes devhost 1.15.0 starts with the documents missing, which the review reports.
- Boards must be regenerated from the committed source when it changes.
- Backlog: the six documents (`architecture-docs`) and, after it, generating the Whiteboard boards
  from the committed diagrams (`architecture-whiteboards`).

## Change log

| Date | Change |
|---|---|
| 2026-11-19 | First draft; decided by the Operator. |
