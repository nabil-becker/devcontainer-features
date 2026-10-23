---
name: ledger-review
description: Review the ledger (docs/ledger/YYYY-MM.md, written by the scribe back) every 25 entries, reading the month's agent-cost report first, and turn what the entries recorded (friction, learnings, measures, questions) into one concrete change per group - a TODO.md item, a decision for the Operator, a change made now with its test, or no action with a reason - starting by checking whether the last review's friction came back. Use it when the briefing says a review is due, or when the Operator asks what keeps going wrong, what the agents cost, or whether a model is the right size.
---

# Review the ledger

The ledger is only worth keeping if it is read. A review is where its entries become changes:
one per group, small, with a test where it is tooling. Every 25 entries (the setting; the entry rate in the cost report shows whether that is too often or too rarely), a review; each
review starts by checking whether last time's friction came back, because an agreed fix can go
unapplied; and it starts from the numbers, so the models can be right-sized.

## Steps

0. **Read the cost report first.** `task devhost:report` (or `devhost-report`) rebuilds
   `docs/ledger/costs-YYYY-MM-<engineer>.md` for this machine; read the other engineers' beside
   it. Its "What to look for" list turns cost into friction: a con type on a large model at a
   low cost per run, inter cost per session rising, a back's cost per change rising, many
   "nothing" runs, guard undos, ledger corrections, frequent stakes, errors
   (`devhost-report --log`). Backs are improved through this loop like any skill: their briefs,
   thresholds and models.

1. **Find the entries to review.** The last `## Review YYYY-MM-DD` section in the monthly files
   closes the previous review; the entries after it are the input (the briefing counts them).
   Skip an entry that a later entry `Corrects:`; read the correcting one instead. Fewer than four
   entries: say so and stop, unless the Operator asked anyway.

2. **Check recurrence first.** For each change the previous review promised (its actions, and the
   `TODO.md` items it added), check that it was applied: the item ticked, the test that exists,
   the skill that changed, the model that moved. A promised change that was never made is
   reopened in this review before anything new is considered.

3. **Group what the entries say.** Read every entry's *Friction*, *Learned*, *Measures*, *For the
   repository* and *Decisions needed*, and the cost report's findings. Group by cause, not by
   wording: a document that drifts, a task that is missing, a skill that is silent on a case, a
   question that keeps being asked, a cost that keeps being paid, a model oversized for its work.
   Measures are read as a trend.

4. **One action per group.** Exactly one of: a `TODO.md` item with owner, date and the friction it
   should make go away; a decision for the Operator under "Decisions for the Operator" in
   `TODO.md`, with a recommendation; a change made now in this branch, with the test that would
   have caught it when it is tooling (a model moved for a job is a change too); or no action,
   with the reason written down. Prefer the smallest change that removes the cause.

5. **Append the review section.** Put the proposed actions to the Operator in a few lines; on
   agreement, append to the current monthly file a `## Review YYYY-MM-DD` section: the entries
   reviewed (first and last date and title), the cost report's headline numbers, each group with
   its action and id, what the review itself lacked, and what is deferred. The review is never
   edited afterwards; the next one starts from it.

6. **Close.** `task devhost:verify`, then `/close-session` as usual. The pull request's
   description is the review section, expanded.

## Why

A log nobody reviews is a cost without a return. The review is short because every entry already
says what it lacked; the work is to decide once per cause, and to keep a promise once made.
