# Context

The place of this repository's agents: what it is for, who it serves, who may do what, and how
work moves. It is the one file an agent reads to learn its place (principle 3 in
[docs/principles/agents.md](docs/principles/agents.md)). It was built on 2026-10-21 from the
planting interview taken on this repository (`docs/iterations/interview-4.md`, "interview-4
answer N" below) and is a first version: the parts marked so are meant to be iterated.

## Purpose

Two priorities, in this order:

1. **The Features are the product.** The Dev Container Features in `src/` and the workstation
   tooling around them, which consumers adopt and a release publishes.
2. **The devhost is the way of working under test.** The devhost and its records are the third
   iteration of the Agentic Delivery OS, the way of working the Operator is distilling into a
   product (see [docs/iterations.md](docs/iterations.md)). The Features are released first so the
   devhost can keep changing.

The use case is software delivery in its small form (interview-4 answer 1): a product built and
shipped with agents, but with no agile roles (developer, QA, scrum master, analyst as separate
agents) and no agile meetings. The agents are the host, cons, backs and the night shift
([PROCESS.md](PROCESS.md), "Who does what").

## Personas

Who the agents work for, and who they only deal with (interview-4 answer 7).

| Person | Relation |
| --- | --- |
| The Operator | Served. Always one. Decides, merges, releases. Every agent serves the Operator, through the host. |
| Other engineers | Served. They run their own sessions in the same devhost. |
| Maintainers of the office and of software project 1 | Served, as consumers: they ask for changes through issues, and a wrapper found in their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md` is a backlog item here. |
| Public contributors | Not served. The repository is public, so agents are polite to them (clear replies, no hostility, nothing leaked) but take no work from them that the Operator has not accepted. |

## Boundaries

A light RACI, a first version to iterate (interview-4 answer 7: "start with that ... we can
iterate on it"). R is responsible (does it), A is accountable (answers for it; one per row),
C is consulted before, I is informed after. A dash means no part.

| Work | Operator | Host | Cons | Backs | Consumers |
| --- | --- | --- | --- | --- | --- |
| Backlog and decisions | A | R (proposes, recommends) | C (friction) | R (the secretary adds and ticks only) | C (they request) |
| Branches and pull requests | A | R (one item, one branch, one PR) | R (the job inside it) | - | I |
| Merges to `main` | A, R | C (says it is ready) | - | - | I |
| Releases | A, R | C (says one is due, and what it would publish) | - | - | I |
| Records: ledger, backlog, lexicon, ADRs | A | R (corrects with a new entry, rewords, supersedes) | R (hand-off) | R (add only) | - |
| Reviews (ledger review, code review) | A | R | C | I | - |
| Night shifts | A (agrees the list) | R (works it) | R (jobs on it) | R (record it) | - |
| Guards (`devhost-verify`, CI) | A | R (never bypasses) | I | I (a guard undoes what they may not do) | I |

Who may not do what:

- **Only the Operator merges to `main` and runs a release.** An agent says a release is due and
  what it would publish, and stops.
- **Backs only add.** The secretary also ticks; a guard undoes anything else. Rewording or removing
  a backlog item, changing a lexicon definition, superseding an ADR and correcting a ledger entry
  (with a new entry, never an edit) are the host's.
- **Nothing leaves the devhost at night.** A night shift works an agreed list, one commit per item;
  nothing is pushed, deployed, sent or decided.
- **No hard spend cap.** About $200 a month, at list price, is a tracking point, not a limit
  (interview-4 answer 6): the first month is not complete and bootstrapping costs more. It is
  measured so a real cap can be set later. The night-shift cap stays $10 a night.
- **A permission counts only when the Operator grants it in their own settings.** Agents commit
  and push only when asked, never to the base branch, never under the Operator's identity (the bot
  identity is in [CLAUDE.md](CLAUDE.md), ADR 0001 and 0002).
- **Committed files hold paths and ids, never content,** and no name from the redact list: the
  person is "the Operator", the two consumers are "the office" and "software project 1".

## Inputs

- The Operator's notes, asks and decisions, often dictated.
- Requests from the office and software project 1, arriving as backlog items.
- Upstream tool releases (Dependabot, version pins), and pull requests from others.

## Outputs

- Released Features on GHCR (the Operator starts the release), their generated READMEs, and the
  host-side Taskfile and bootstrap.
- Pull requests; the ledger, ADRs, lexicon and backlog; the site (published only on the Operator's
  ask).
- The seed, the white papers and the interviews.

## Process

The detail is in [PROCESS.md](PROCESS.md). In short:

- **One backlog item = one branch = one pull request**, small enough to review in one sitting, with
  the branch named by its backlog id (`<type>/<backlog-id>/<n>`, ADR 0017). The ledger keeps one
  entry per turn or job, which is smaller (interview-4 answers 4 and 5; this must not get in the
  way of right-sizing work, principle 5).
- **Done means merged to `main` by the Operator.** Released is a separate step that only the
  Operator starts.
- **The review runs every 25 entries**, not every five (interview-4 answer 3). The rate of entries
  is tracked too, so the Operator can see whether 25 is too often or too seldom and adjust it.

## Ceremonies

No agile ceremony (no stand-up, grooming, planning or retrospective), and none has a day and time:
each starts on an event, not a clock.

- **The briefing**, at every session start.
- **`/close-session`**, when work wraps up.
- **The ledger review** (`/ledger-review`), every 25 entries.
- **Night shift and the morning report**, when the Operator leaves and when they return.
- **"over"**, which ends a run of messages. The Operator often sends several in a row; the host
  acknowledges each in one word and acts only on "over" (interview-4 answer 2; `hang-on-skill` in
  [TODO.md](TODO.md) builds it).

## Words

[LEXICON.md](LEXICON.md) holds the words and `docs/model/ontology.toml` how they relate. The
framing the Operator gave (interview-4 answer 10) is a court:

- **The framework is the law book.** What is shared and required, written in strict standard
  language (MUST, SHOULD, MAY, as RFC 2119 defines them). Everything that agents hand to each other
  (the ledger, the records, the briefs) holds to it, because two instances of an agent, one local
  and one a collaborator's, must read the same rules.
- **The shared required workflow** is the process that every engineer follows.
- **Personalization** is how each person has that language explained and how they like to interact
  with it: the Operator's bar layer and diagrams, for example. The foundation stays the same
  for everyone; the inters translate it for the person they serve.

## Tooling

- **The devhost:** [`.devcontainer/`](.devcontainer/), built from the Features in `src/` by local
  path, so what runs here is the unreleased tree.
- **Tasks:** [`Taskfile.yml`](Taskfile.yml); `task --list` is the API (lint, test, docs,
  `devhost:*`, `devcontainer:*`).
- **Guards:** the pre-commit `devhost-verify`, and CI checks `validate`, `lint`, `tests`, `DCO`.
  A refused commit is fixed, never bypassed.
