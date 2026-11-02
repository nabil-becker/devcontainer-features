---
name: night-shift
description: "Close up for the day and work an agreed list from TODO.md alone overnight, in the session the Operator leaves open, then walk them through it in the morning. Use it when the Operator says they are leaving - 'night shift', 'closing up', 'I'm heading out, need anything?', 'ending my day', 'work through these while I'm away', 'run the list overnight' - and when they come back and ask 'morning report', 'what happened overnight', 'what did you get done'. The main session only; never a separately launched background agent."
---

# Night shift

The Operator leaves; the main session keeps working, in the same session, on a list they
agreed, under stricter rules than the day; they review it in the morning. The night's work is a
branch the Operator keeps or reverts commit by commit, and nothing leaves the devhost.

It runs in this session, in auto mode: the terminal stays open and the workstation awake. No
separate unattended agent is launched. Cons (subagents briefed for one job) may be used inside
the session, within the cap, in a worktree when they change shared tooling.

## 1. Closing up (with the Operator, a few minutes)

1. **Need anything?** First list what you need from them before they go: the open decisions
   that block an item you could otherwise do tonight, each with your recommendation, and anything
   only they can do (a login; switching on auto mode; a file only they may write).
2. **Propose tonight's list** from `TODO.md`: only items that need no decision from the Operator,
   are bounded, can be undone, and can be proven by a test, a simulation or the checks. One line
   each: what "done" will mean, and what it will not touch. Leave out anything under "Decisions
   for the Operator", anything outward-facing (deploys, mail, services), and changes to
   permissions or hooks.
3. **Agree it.** The Operator strikes, adds, reorders. Default cap **$10** at list price for the
   night (they may change it); default stop time **07:00** local. An item they did not agree is
   not worked, however easy it looks.
4. **Write the plan** into `docs/night-shift/YYYY-MM-DD.md` (the shape in
   `docs/night-shift/README.md`): the items in order with their done-checks, the cap, the stop
   time and the start time in UTC. Cut the night's branch from the branch the day ended on:
   `git switch -c chore/night-shift/<n>` (the standing item `night-shift`, n the next number
   `task devhost:branches` has not used, merged ones included: the pre-push rule refuses a dated
   name and a reused one), and commit the plan as its first commit, so the
   whole night can be undone.
5. **Pre-flight check**, before they go; say any failure at once:
   - the session is in auto mode; if not, ask them to switch, since one permission prompt stalls
     the night;
   - `devhost-verify` and the repository's checks pass, so a failure overnight is tonight's;
   - nothing uncommitted besides the backs' latest writes;
   - `devhost-costs` noted in the plan as the starting figure;
   - they know to leave the terminal open and the workstation awake (sleep pauses the container).
6. Say "Night shift started" in one line, and begin.

## 2. The night rules

- **One item at a time, in plan order.** Build it the way the day would, with the test that
  proves it; run the checks; commit that item alone, with a Conventional Commit naming its id.
  If the check fails and a short fix does not make it pass, revert the item (`git checkout -- .`
  before the commit, `git revert` after) and mark it `undone`. Never carry a failure into the
  next item.
- **Never decide for the Operator.** A question, a real choice between alternatives, or anything
  `TODO.md` gives to the Operator: write it under Questions in the report with your
  recommendation, and skip or finish the item under a stated assumption only if the assumption is
  cheap to reverse.
- **Nothing leaves the devhost.** No push, no pull request, no deploy, no mail, no webhook beyond
  the fakes, no artifacts, links or messages to any service beyond the model itself.
- **Nothing irreversible.** No history rewrites, no deleting files the night did not create, no
  changes to `.claude/settings.json`, hooks or permissions, no `--no-verify`.
- **No new skills, no new directions.** A skill, a decision or a new direction that seems needed
  goes in the report as a proposal.
- **Keep to the cap.** Run `devhost-costs --since <start time>` after each item. If the next
  item would likely pass the cap, stop there. Stop at the stop time too.
- **Write the report as you go**, after each item, not at the end, so a stop at any point leaves
  a true record. The backs keep working after each turn, as in the day; read their changes
  before each commit.
- When the list is done, or a rule stops you, finish the report, commit it, and stop. Do not
  start work that is not on the plan.

## 3. The plan and report file

`docs/night-shift/YYYY-MM-DD.md`, one file, committed on the night's branch, in the shape
`docs/night-shift/README.md` gives. The scribe writes the night's ledger entries as usual; the
report is the walk-through, the ledger the record.

## 4. Morning

The briefing shows a night-shift report without a "Reviewed" line. When the Operator says
"morning report" (or asks what happened):

1. Walk through it: one line per item, then the questions and proposals.
2. For each item they keep or reject: revert the rejected ones on the branch (`git revert
   <commit>`, so the history says what was tried), and say what is back as it was.
3. Add `Reviewed by the Operator <date>.` as the report's third line and commit it.
4. Then the branch goes the normal way: `/close-session`, a pull request when they ask.

## Why

Unattended work is only safe when the rules are stricter than the day's: an agreed list, one
reversible commit per item with the checks green, nothing sent, nothing decided, a cap measured
from the session's own transcripts, and a report written as it goes. The branch is the sandbox
and the morning review is a set of commits the Operator keeps or reverts one by one.
