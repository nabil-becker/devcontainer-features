# The way of working (devhost)

Included from CLAUDE.md. The words are in [LEXICON.md](../LEXICON.md), the process in
[PROCESS.md](../PROCESS.md), what is open in [TODO.md](../TODO.md); the ledger is
`docs/ledger/`, the ADRs `docs/adr/`.

## How work flows

1. **Start:** the briefing arrives on its own at session start (`devhost-briefing` on a
   workstation): the ledger entries since the last review and whether a review is due, what the
   backs left pending, the open backlog items and decisions, the month's agent spend. Read
   `TODO.md`, then branch; never commit to the base branch directly.
2. **Work:** commands through the Taskfile (`task --list`); propose rather than decide where the
   Operator's confirmation is needed; brief subagents (cons) with the hand-off shape (its Friction
   includes problems the con worked around, such as a command it retried another way, not only
   what blocked it) and size their models by blast radius (Sonnet by default, Opus only when the change reaches every consumer); a brief names the PR template when the con opens or describes a PR and passes the Operator's decisions in full; a con waits for its own background jobs, writes a long run (such as `task lint`) to its own log, hands back once, and never runs `pkill -f` with a pattern its own shell contains; a permission counts only when the Operator grants it in their
   own settings. Unattended work only under `/night-shift`.
   When the Operator starts a run of messages ("hold on", "wait", or `/walkie-talkie`), acknowledge each and act on "over" (the `walkie-talkie` skill).
3. **Close:** `/close-session`: the records checked (the scribe's entries, the backlog, the
   lexicon, the ADRs), `task devhost:verify` green, a Conventional Commit on a topic branch, the
   report in the hand-off shape (Outcome, Outputs, Friction, For the repository, Decisions
   needed). The host commits and pushes; the Operator merges (ADR 0040).

## The ledger

`docs/ledger/YYYY-MM.md` is append-only: one entry per unit of work, written by the scribe back
after each turn and each con's job, with its measured cost. A wrong entry is never edited; a
new entry with a `Corrects:` line replaces it. Every 25 entries (the setting; the entry rate in the cost report shows whether that is too often or too rarely) the briefing asks for a
review (`/ledger-review`), which reads the cost report first and turns each group of friction
into one action.

## Backs, stakes and quiet notices

Backs do the record-keeping in the background, inside the devhost only, never making you wait:
the **scribe** keeps the ledger, the **secretary** `TODO.md` (new items, decisions for the
Operator, ticking finished items), the **librarian** `LEXICON.md` and `docs/adr/` (new records,
a superseded status), the **tester** runs the suite when code changed.

- **Do not do their chores.** When something belongs to one of them (the Operator asks for a
  to-do, a term is settled, a decision is taken, work finishes), acknowledge it in one line and
  move on; the back collects it from the session.
- **Leave a stake when unsure.** If it might not be caught (it was implicit, or spread over
  several messages), put one plain line in your reply: `Stake for the <back>: <what> needs
  <what>.` Stakes are always read and treated as explicit requests. The Operator can write one
  too.
- **Do yourself only what they may not do:** reword or remove a `TODO.md` item, change a lexicon
  definition, rewrite or supersede an ADR, correct a wrong ledger entry (with a correcting entry,
  never an edit). Backs only add (and the secretary ticks); a guard undoes anything else.
- **Read their changes before each commit**: `git status` shows them; fix anything wrong,
  anything that quotes content or names a person the redact list covers.
- **Their notices are quiet**: they reach you as context on your next turn. Do not relay them.
  Mention one only when the Operator asks, when a back got something wrong, or when it is a
  pending item the Operator must act on, and then as a short closing line.
- On a workstation there are no backs: do their chores by hand at close (`/close-session`).

## Git rules

- Topic branches off the base branch, named `<type>/<backlog-id>/<n>` (`task devhost:branch -- <id>`; `task devhost:branches PRUNE=1` after a merge); never commit to it directly; Conventional Commits naming
  the backlog ids; the co-author trailer when an agent wrote the commit, at an unclaimable `@noreply.invalid` address (never `noreply@anthropic.com`, which links to a stranger's GitHub account).
- The pre-commit hook runs `devhost-verify`: the ledger append-only and well-formed, no secrets,
  no forbidden words, the ADR shape, every task described, every skill named. A refused commit is
  fixed, never bypassed (`--no-verify` only on the Operator's say-so, with the reason in the
  message and in the ledger entry).
- Paths and ids, never content: nothing committed holds real data, credentials, identifiers or a
  name from `.devhost/redact-names.txt` (ignored by git; the person is "the Operator").
- Git is the host's job (ADR 0040): it commits, pushes and opens the pull requests on topic
  branches and keeps the checkout current; the Operator reviews, merges and starts releases.

## Tasks are the API

One way to do each action: its task in `Taskfile.yml`, for engineers and agents alike, each with
a `desc`. The devhost tasks: `task devhost:briefing`, `task devhost:report`, `task devhost:costs`,
`task devhost:adr -- <title>`, `task devhost:verify`, `task devhost:init`.
