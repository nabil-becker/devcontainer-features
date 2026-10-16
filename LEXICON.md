# Lexicon

The words of the way of working in devcontainer-features, and what they mean here. Every other document
uses them in this sense. When a term changes, it changes here first. This file only grows: the
librarian back adds terms, an inter changes or retires one (a retired term is struck through
with the reason, never deleted).

The domain words of the project itself are not here; they live with the project's own documents.

## People and agents

- **The Operator**: the person who owns the repository. Brings notes, asks for work, reviews,
  decides and ratifies. Items marked for the Operator are not for a session to resolve.
- **Engineer**: anyone who works the repository with their own sessions on their own machine; the
  Operator is one. The cost report is per engineer.
- **Agent**: any model doing work for the repository: a Claude Code session, a subagent, or a
  background run. Every agent is an inter or a back.
- **Host** (the main session): the Claude Code session an engineer is talking to, the one that
  briefs and merges the work of the others; the main inter. The machine outside the container is
  the **workstation**, never "the host".
- **Inter** (interface agent): an agent that works with an engineer, directly or through another
  inter; the host is the main one.
- **Back** (background agent): an agent that never works with a person. After each turn, and after
  each con's job, it reads what was done and keeps one record current, so no inter spends a turn
  on upkeep. It reports only through a quiet notice. Each runs on its own model, inside the
  devhost only.
  - **Scribe**: the back for the ledger.
  - **Secretary**: the back for the backlog (`TODO.md`): adds items and decisions for the
    Operator, ticks finished ones; never rewords, removes or reorders.
  - **Librarian**: the back for this lexicon and the ADRs.
  - **Tester**: the back with no model: runs the suite after a turn that changed code and
    speaks only when it is red, or green again.
- **Con** (consult agent): an agent briefed by the host for one job, a Claude Code subagent, with
  its scope, model and isolation set for that job; it replies once, in the hand-off shape, and
  its job gets its own ledger entry. Not a standing role.
- **Night shift**: a host session the Operator leaves open, working an agreed list of backlog
  items alone under the night rules and a cap, reviewed in the morning report. Defined in the
  `night-shift` skill.

## Places

- **Devhost**: the dev container as the environment where sessions run and the backs act. The
  `devhost` Feature installs the tooling; its state lives outside the repository.
- **Workstation**: an engineer's own machine outside the devhost. The backs' hooks do nothing
  there.
- **Worktree**: a separate checkout of the repository on its own branch, where a con that changes
  shared tooling works; its work comes back as a merge, so a clash is a conflict, not an
  overwrite. Backs do not use worktrees.

## Work

- **Note**: something the Operator says in chat that the repository must remember; recorded in
  the ledger entry's Decisions and, when it is work, in the backlog.
- **Unit of work**: one thing an engineer asked for that got done or settled: a slice, a document
  change, a question answered, a decision taken; and every con's job. One ledger entry each.
- **Backlog item**: an engineering item that needs no external answer, named by its backlog id in `TODO.md`.
- **Backlog id**: the short descriptive kebab-case slug (two to four words, for example
  `release-collection`) that names a backlog item; unique in `TODO.md`, never reused, never
  renamed once written, and cited the same way in commits and ledger entries. It replaces the
  earlier `TD-nn` numbers, which survive only as `(was TD-nn)` on converted items.
- **Amend item**: a backlog item with the id `amend-<id>`, added by the secretary when a stake asks
  to change an existing item; it names the item and the change, and a person makes the change by
  hand, since backs never reword (ADR-0003).
- **Decision for the Operator**: an engineering choice only the Operator can make, listed under
  "Decisions for the Operator" in `TODO.md` with a recommendation.
- **Brief**: what an inter gives a con: the job, the scope and what is out of bounds, the model,
  the isolation, the reply shape.
- **Hand-off** (reply): what every handing-back ends with, in one shape: Outcome, Outputs,
  Friction, For the repository, Decisions needed.
- **Model sizing**: matching the model to the blast radius of the work: the strongest where others
  inherit the output, a mid tier for a bounded job an inter reviews, the smallest for chores.
  Checked against the measured costs at each review.
- **Trial**: running a new mechanism once on real (or, for tooling, synthetic) work before the
  process describes it.
- **Agentic Delivery OS**: the product the Operator is building: a set of tools that lets one
  person, technical or not, bootstrap a devhost. It is the foundation of a pyramid, and each
  iteration helps define that foundation (`docs/iterations.md`).
- **Iteration**: one project in which the way of working is tried and learned from: client
  engagement first, then DSNP, then this repository. The Operator decides when an iteration is
  done.

## Records

- **Ledger**: the append-only record of what agents did, in monthly files under `docs/ledger/`.
- **Entry**: one ledger record, one per unit of work: asked, came out, friction, learned,
  decisions, for the repository, decisions needed, measures. A wrong entry is corrected by a new
  one with a `Corrects:` line.
- **Friction**: what a unit of work lacked, got wrong or had to work out, tagged `[tooling]`,
  `[docs]`, `[skill: <name>]`, `[skill: new]` or `[process]`. "none" is a valid entry.
- **Measures**: the numbers of an entry: the stretch's cost at list price, its tokens and models,
  filled in by the scribe's script from the transcripts, never by a model.
- **Review**: reading the cost report and the entries since the last review, checking whether the
  last review's friction came back, and turning each group into one action; appended to the
  ledger as a `## Review` section. Run with `/ledger-review`.
- **Cost report**: `docs/ledger/costs-YYYY-MM-<engineer>.md`, the monthly agent costs on one
  engineer's machine (inters, cons, backs, by model), rebuilt by `devhost-report` with no model.
  Read first by the review.
- **List-price estimate**: every cost figure here: tokens priced at the published list price,
  which on a subscription measures use, not a charge.
- **ADR**: an architecture decision record in `docs/adr/`, for a decision whose reasoning does
  not fit in a line.
- **Ontology**: the canonical data model of the way of working: what kinds of thing exist (by
  plain base id), and how they relate (briefs, writes, keeps, checks, decides). The lexicon words,
  the themes and the C4 views must agree with it; it is not the instances, which the ledger holds.
- **White paper**: the account of one iteration, written once when the Operator calls it done, in
  plain words, function over form, every fact traceable to the ledger, ADRs, reviews and cost
  reports. Written by the journalist.
- **Iteration package**: what an iteration hands to the next, cumulative: every earlier white
  paper kept unchanged, plus the newest set of artifacts (a bootstrap prompt, context, whatever the
  iteration finds foundational), which each iteration merges into and replaces, so packages never
  nest. It carries the foundations of the Agentic Delivery OS, not the tooling, and says what to
  ingest and why, not how to transform it. In the life theme (ADR-0007) it is the **seed**, a label only:
  plain names stay in every id, path and sentence, as in ADR-0004
  (`docs/proposals/iteration-package.md`).
- **Docs site**: the one self-contained HTML page `devhost-site` builds from the docs and records,
  a homepage that leads with what needs the Operator. Publishing it is a separate skill, so the
  host (Claude artifacts today) can change without touching the page (ADR-0006).
- **C4 view**: a diagram of the system at one zoom level (Context, Container), written in Mermaid
  and named by ontology ids.

## Mechanisms

- **Hook**: a command Claude Code runs on an event, set in `.claude/settings.json`: SessionStart
  runs the briefing; Stop and SubagentStop start the backs.
- **Briefing**: what an inter is told at session start (`devhost-briefing`): the entries since
  the last review and whether a review is due, what the backs left pending, the open backlog
  items, the month-to-date agent spend.
- **Stretch**: the part of a transcript a back has not read yet, condensed to the engineer's
  words, the inter's replies and which tools ran.
- **Stake**: one plain line anyone leaves in a session when a chore might not be caught on its
  own: `Stake for the <back>: <what> needs <what>.` Lifted to the top of what every back reads;
  the one addressed treats it as an explicit request.
- **Quiet notice**: how a back reports: one line of context on the inter's next turn, never a
  message to the engineer; the inter reads the change before the next commit and mentions it
  only when asked, when something was wrong, or when the Operator must act.
- **Guard** (back guard): the script that undoes a back's run that changed what it may only add
  to (`devhost` `guards.py`: the backlog guard, the docs guard).
- **Name guard**: the replacement of every name in the ignored `.devhost/redact-names.txt` by
  "the Operator" in everything a back writes.
- **Metrics line**: the one JSON line every back run appends to its `runs.jsonl`: when, which
  back, model, size, outcome, guard undos, duration, cost, tokens.
- **The guards** (`devhost-verify`): the commit-time checks the pre-commit hook runs: the ledger
  append-only and well-formed, no secrets, no forbidden words, the ADR shape, every task
  described, every skill named.

## The Arthurian layer

A voice over the plain words, not a rename (accepted 2026-10-16, `docs/proposals/king-arthur-theme.md`).
The plain word stays in every id, path, command, field name and guard; the layer is for what a
person reads in chat. No committed output speaks in it: the journal is a record of the project's
iterations and stays in plain words (decided 2026-10-16).

| Plain word | In the layer |
|---|---|
| the Operator | the King (committed text still says "the Operator") |
| host | Merlin: counsels and briefs, never rules |
| con | a knight on one quest, returning with one report |
| backs | the household, who never meet the King |
| ledger | the Chronicle |
| backlog (`TODO.md`) | the Quest board |
| ledger review | the Round Table: the record read together, the King still decides |
| night shift | the vigil |
| `devhost-verify` and the guards | the castle watch |
| journalist back | the bard (a name only; its journal is written in plain words) |

## The life layer

A second voice over the plain words, for the whole series of projects, shared by every project
and sitting above each repository's own theme (the Arthurian layer here), not replacing it
(decided 2026-10-16, ADR-0007, `docs/proposals/iteration-package.md`). Labels and story only:
the plain word stays in every id, path, command, field name and guard, and nothing committed is
renamed. Each project is a tree growing in its own ground.

| Plain word | In the layer |
|---|---|
| iteration | generation |
| project | tree |
| project context | ground |
| iteration package | seed |
| white paper | fruit |
| a learning that changed the foundation | adaptation |
| a change that proved a one-off | shed trait |
| the series of iterations | lineage |
| iterations 1 and 2 (before any package existed) | first life, before seeds |
| this repository | the first seed-bearing tree |
