---
name: drop-a-seed
description: Export the seed at the end of a project (the iteration), the folder the next project plants from. Use it when the Operator calls the iteration done, asks to drop or export a seed, to write the paper (the white paper), or to package the iteration.
---

# Drop a seed

A **seed** is a plain folder that carries the way of working to the next place: a `README.md` to
point an agent at, a `starter/`, the skills `plant-a-seed`, `drop-a-seed` and `ledger-review`, every
paper so far and the foundation. `devhost-package` assembles it (ADR 0008); the judgement work is
here: the closing interview, the paper, and what is foundation. Plain words (ADR 0004). You draft;
the Operator decides and trims.

## Steps

1. **Read before asking.** The records in order: `docs/ledger/*.md` oldest first (skip an entry a
   later one `Corrects:`, keep the correction in the story), each `## Review` section,
   `docs/night-shift/`, `docs/adr/`, the cost reports `docs/ledger/costs-*.md` (`task devhost:report`
   rebuilds one), `git log`. Then the seed received: `docs/iterations/package/` (its `README.md`,
   its papers), and `docs/proposals/iteration-package.md`.
2. **The closing interview.** Ask only what the records cannot answer, and say which blank each
   question fills. Short numbered rounds (about ten questions, a recommendation on each, answerable
   as "1 yes, 3 no"); explain every term in the question, the Operator should not need the lexicon;
   anything longer than a screen goes in a page, not in chat. "Skip" is an answer: it becomes a
   marked gap, never a guess. Save the answers **word for word** to
   `docs/iterations/interview-<N>.md`; a decision left only in chat gets lost. Topics:
   - *The intent behind the records:* why the big turns happened, what was planned, what was drift,
     what was a reaction. Ask for intent before calling anything drift; it may have been the plan.
   - *Where the missing data lives:* cost history, transcripts, notes on another machine or tool.
     Ask before writing "not measured".
   - *The story in their words:* how the Operator would tell the iteration in two sentences and
     what surprised them. It is the spine of the paper.
   - *Keep, change, drop:* which practices earned a place in the next seed and which did not.
     It settles the foundation (step 5).
   Also settle identity and names (who commits, what a public paper may name) before anything is
   committed.
3. **Name the iteration** with the Operator: its number and, if it has one, its short name.
4. **The paper.** Propose an outline first (sections in story order, the records each draws on, the
   gaps you already see) and wait for the Operator. Then, section by section, hand
   [journalist.md](journalist.md) together with the records and the interview to a writing
   subagent; show the Operator each section and ask what is wrong, missing or unclear; revise
   from the answer. The file is `docs/iterations/papers/iteration-<N>.md`. Check again at the end
   that every number and claim has its source and every guess its marker; offer cuts, never
   apply them.
5. **Settle the foundation** with the Operator: one path per line in
   `docs/iterations/foundation.txt` (`#` comments; `!path` marks a file copied untouched). It holds
   only what the Operator names; the tooling is not foundation (the OS is not the package).
6. **Assemble.** `task devhost:package -- --iteration <N> --paper docs/iterations/papers/iteration-<N>.md`
   (`--out` for another folder; `--readme`, `--starter`, `--skills` if the seed's parts live
   elsewhere). Exit 2 is a refusal with its reason (a missing README, starter or skill, a missing
   manifest entry, a non-empty output folder, a received paper that changed): fix the cause, never
   work around it. Read `PACKAGE.md` with the Operator, then `task devhost:verify` and
   `/close-session`.

## Why

The records fade and a summary hides what it left out; detail can be trimmed later but never
recovered. The interview gets the intent the records do not hold, so the paper can be honest about
why, not only what.
