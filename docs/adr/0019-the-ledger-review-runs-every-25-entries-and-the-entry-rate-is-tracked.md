# ADR-0019: The ledger review runs every 25 entries, and the entry rate is tracked

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-21 |
| **Deciders** | the Operator; proposed by the host during the seed self-interview |

## Context

The briefing asks for a ledger review every five or so entries (`ledger-review` skill). The
Operator found that too frequent. During the self-interview on `docs/seed-self-interview/1`
(question 3 of 10) the host offered three alternatives and the Operator chose by chat. The
Operator also said the right number depends on how fast entries are produced: five is enough at
one entry a week and far too often at twenty-five a week, so the repository must track enough to
tell whether the chosen number was right (the continuous improvement principle, P2).

## Decision

The ledger review is due every 25 entries. The repository tracks the rate of ledger entries over
time, so that the cadence can be adjusted from evidence rather than from feel. Existing text that
says "every five or so entries" is updated to match by the Operator or the host, since the
librarian only adds.

## Options considered

### Option 1: every 25 entries (chosen)

The Operator's choice. Fewer interruptions, and with the rate tracked the number is a lever that
can be moved when the evidence says so.

### Option 2: once a week at a named day and time

Recommended by the host, with the review, the costs and the open decisions together. Not chosen:
the Operator preferred a count over a calendar slot.

### Option 3: after each finished backlog item

Ties the review to the work, but items vary widely in size, so the interval would too. Not chosen.

### Option 4: every ten entries

Halves the old frequency but keeps the same shape. Not chosen.

## Consequences

- Reviews interrupt less often; more friction accumulates between them, so the review reads
  more entries each time.
- The entry rate must be measured and shown (the briefing or the cost report); until it is,
  the 25 cannot be judged. A backlog item for the secretary.
- The briefing's due-review threshold, the `ledger-review` skill description, `PROCESS.md` and
  the briefing text still say five; they need changing by hand.

## Change log

| Date | Change |
|---|---|
| 2026-10-21 | First draft. |
