# ADR-0021: The ledger review runs every 75 entries

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-21 |
| **Deciders** | the Operator; proposed by the host during the ledger review |

## Context

ADR-0019 set the review threshold at 25 entries and said the entry rate would be tracked so the
number could be judged from evidence. The review of 2026-10-21 is that evidence: 77 entries had
accrued since the previous review on 2026-10-20, about 43 entries a day, so a review fell due every
0.6 days. That is more often than the Operator wanted, which was the reason for moving off five
entries in the first place. The host offered two ways out: merge the existing
`ledger-review-cadence` branch, or raise the threshold. It recommended a threshold of about 75,
roughly one review a day.

## Decision

In this repository the ledger review is due every 75 entries (`DEVHOST_REVIEW_EVERY=75` in
`.devcontainer/devcontainer.json`'s `containerEnv`); the devhost Feature's default stays 25 for
consuming repositories, whose entry rate is lower. The entry rate stays tracked in
the cost report, so the number can be moved again when the rate changes. This supersedes the number
in ADR-0019; its tracking of the rate stands.

## Options considered

### Option 1: raise the threshold to 75 (chosen)

The Operator's choice. About one review a day at the current rate, with one setting changed and
nothing else.

### Option 2: merge the `ledger-review-cadence` branch

Offered as the alternative. Not chosen: the Operator preferred to change the number.

### Option 3: keep 25

Reviews would keep falling due every 0.6 days at this rate. Not chosen.

## Consequences

- Reviews interrupt about once a day instead of more than once a day; each reads about three times
  as many entries.
- Friction can wait longer before a review turns it into an action; the cost report and the
  briefing still show it between reviews.
- If the entry rate falls, 75 will be too high, and the rate tracking is how that shows.
- Text that still says 25 (lexicon, `PROCESS.md`, the `ledger-review` skill) needs changing by the
  Operator or the host; the librarian only adds.

## Change log

| Date | Change |
|---|---|
| 2026-10-21 | First draft. |
