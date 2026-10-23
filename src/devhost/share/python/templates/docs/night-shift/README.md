# Night-shift reports

One file per night the Operator leaves a host session working an agreed list of `TODO.md` items
alone: `YYYY-MM-DD.md`, the plan and the report in one, committed on the night's branch
(`chore/night-shift/<n>`, the standing item `night-shift` and the next unused number). The `night-shift` skill holds the rules; the shape is:

```
# Night shift YYYY-MM-DD

Plan: <n> items · Cap $<cap> · Stop <time> · Started <UTC time> at $<starting figure> · Branch chore/night-shift/<n>
Result: Done <n> · Skipped <n> · Undone <n> · Cost about $<x> of $<cap> · Ended <time>, <why>

## Items

### 1. <slug> <title>: planned | done | skipped | undone
- Done means: <the done-check agreed at closing up>
- What changed: <in the Operator's terms: what is different now, not how>
- Check: <how the done-check was met>
- Commit: <id>
- Why skipped or undone: <one line, if so>

## Questions for the Operator
- <each with a recommendation>

## Proposals
- <skills, backlog items, decisions that came up>
```

In the morning the Operator walks through it, keeps or reverts each commit, and the line
`Reviewed by the Operator YYYY-MM-DD.` is added as the report's third line. The briefing names
every report here that lacks that line.
