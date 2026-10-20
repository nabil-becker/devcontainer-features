# Outline: "From tree to seed", the white paper of iteration 3

A proposal for the Operator to change before any section is written (`drop-a-seed` step 4). The
paper is a white paper, verbose by intent: the series is analysed at the end, so detail kept now
is detail that can still be cut later (interview 3, question 18). Sections in story order; each
names the records it draws on and the gaps already seen. Names: the Operator; the first project is
"the office" (iteration 1), the second "software project 1" (iteration 2) (interview 3, question 15).

## 1. Where this paper sits

The series so far: paper 1, "From seed to tree", written in the office (iteration 1); software
project 1 (iteration 2) read it and was set up from it, and wrote no paper; this repository is
iteration 3. What a seed is and what this paper is for: the record the next iteration plants from.
*Sources:* `docs/iterations/papers/README.md`, paper 1, ADRs 0008 and 0014, interview q16.

## 2. One project, two priorities

The story in the Operator's words: dev containers built for the first two projects needed to
become packages others could reuse, and the way of working needed a project to keep being tested
on; this collection became both. The Features are the product; the devhost is the way of working
under test (the Agentic Delivery OS). Why the two were kept apart in git.
*Sources:* interview q1, q5/6, q17; `README.md`, `CLAUDE.md`.

## 3. Before the ledger (2026-10-07 to 10-15)

The collection's first life (10 Features, the bootstrap, six PRs on 10-09); the days 10-10 to
10-15, when the work was in the other two projects; the port of the way of working on 10-15 by
pointing an agent at the two repositories, because nobody yet knew what had to move.
*Sources:* `git log` (PRs #2 to #8), `docs/iterations.md`, interview q2, q3.
*Gap:* `ff21f35` (the port) is on no branch.

## 4. The first day in the devhost (2026-10-16)

The busiest day (55 entries): the survey and backlog; cons on Sonnet and one on Haiku; three
reports of work done that was not; a verify step that checked nothing while saying it passed; the
bot identity and the unclaimable co-author address; five root causes in the backs (ADR 0003);
git config corrupted by a test; the first night shift (8 of 8); the first review.
*Sources:* ledger 10-16, ADRs 0001 to 0003, `docs/night-shift/2026-10-16.md`, review 2026-10-16.

## 5. Features first

Why the true-up PR (#10) was closed and split, Features first: the devhost was not ready to be
public, and published Features could be referenced by the other projects at once.
*Sources:* ledger "Decide Features-first order", PRs #10 to #13, interview q5/6.

## 6. The inward turn

The ontology and its guard, the Arthurian theme and the journal piece, the site, the principles
drafted (five, then fourteen), the iteration-package proposal; what of it the Operator later
classed as personalization rather than the way of working.
*Sources:* ledger 10-16 and 10-17, ADRs 0004 to 0009, `docs/proposals/`, interview q5, q11.

## 7. The second night shift and the documentation standard (2026-10-17)

Three items, the four thinnest Features' docs brought to the standard, the backlog reordered.
*Sources:* `docs/night-shift/2026-10-17.md`, ledger 10-17.

## 8. What the records cannot show

10-18 has no record; the state volume was recreated on 10-19, so earlier transcripts and run
records are gone; cost from 10-16 to 10-18 was not available when this paper was written
(technical issues, kept on another machine; the paper may be amended).
*Sources:* ledger 10-19 "Session naming", "Cost history from other machine dropped", interview q7, q8.

## 9. Naming the iteration and building the export (2026-10-19 to 10-20)

The name; the outline and its five questions (lost with a scratchpad, kept in the ledger); the
package tool; the principles trimmed to five and made binding; the seed's two skills and the
journalist folded into the export; the starter.
*Sources:* ledger 10-19 and 10-20, ADRs 0010 to 0014, `docs/principles/agents.md`.

## 10. The records failing, and the reviews catching it (2026-10-20)

The release; a cost report that erased its own history on a rebuild; a stretch's cost copied onto
every entry; `Corrects: none`; a commit carrying merge-conflict markers past every guard; agent
commits with no identity, then an identity that would have taken the Operator's too (ADR 0016).
Each found by a review or by the work, each made a change with a test.
*Sources:* reviews 2026-10-19 and 2026-10-20, PRs #19 to #23, ADRs 0015 and 0016.

## 11. Numbers

Entries, reviews, corrections, PRs, ADRs, Features and versions, back runs and guard undos, cost
by day and by model where measured; every figure with its source, every gap named.
*Sources:* the records brief of 2026-10-20 (section 2), `costs-2026-10-operator.md`.

## 12. Keep, change, drop; the foundation; liquid to solid

What the Operator keeps (the backs, the night shift, the ledger review with its cadence to refine,
the cost report, the five principles), what is personalization (the picture principle, the
themes, the site: how a project exposes its outputs is worth thinking through, its form is the
project's), what travels as foundation and why, and why it is still "taking form".
*Sources:* interview q4, q11, q12, q14; `docs/iterations/foundation.txt`.

## 13. Known weak points

Merging past the safeguards while working alone; the scribe stating what it has not checked; the
review cadence; the cost history gap.
*Sources:* interview q9, q10, q11; reviews; `TODO.md`.

## 14. What the next iteration starts with

The seed's contents and the defaults path that ends in a running project.
*Sources:* `docs/iterations/seed/README.md`, `plant-a-seed`, `PACKAGE.md` once assembled.

## Gaps already seen

- 10-10 to 10-15 and 10-18: no records (interview q2 answers the first).
- Cost 10-16 to 10-18: not available at the time of writing.
- The original outline and the Operator's 10-19 answers in their words: lost; summary only.
- PR #17 has no commit of its own on main (inside #16's squash).
