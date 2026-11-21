---
name: design-review
description: Run a design review with the Operator on Whiteboard boards - one board per standard architecture artifact (State of the Architecture, C4 Models, Workflows, Lifecycles, Data Flows, Data Inventory and Models), decisions laid out as options with a recommendation, rulings recorded the moment they are given, boards refreshed after every ruling or merge. Use it when the Operator asks to review, design, explain or decide anything architectural, asks for "the boards", "the artifacts", "refresh the boards", "what are the open decisions", "explain <decision>", or says they are a visual learner. Board craft (how to write a board) is the review-boards skill.
---

# Design review on boards

The Operator is a visual learner and a weak reader. A design is reviewed on boards, not in the
console: the console carries two or three lines and the link; the board carries the explanation,
next to the thing it explains. Git (proposals, ADRs, `docs/architecture/`) stays the durable,
reviewed record; boards are the view the Operator reviews and rules from.

## The standard artifacts: one board each

Six boards, one per standing architecture document (ADR-0060), titled `<Subject>: <artifact>`:

| Board | Shows | Form |
|---|---|---|
| State of the architecture | what is built, in progress, next, and what waits on the Operator | three columns + "Waiting on you" + links to the other five |
| C4 models | context (people, systems around it) and containers (what is inside) | two sections side by side |
| Workflows | who does what, in order | one lane per flow, steps left to right |
| Lifecycles | the states things pass through | state pills in a line, loops drawn as arrows back |
| Data flows | how data moves, trust lines | sources left, processing middle, consumers right |
| Data inventory and models | each piece of data, where, tier, sensitivity; the model | a table, then the model as boxes |

The State board is the entry point: every other board links back to it, and it links to all five.
Details of each board's skeleton: [references/artifacts.md](references/artifacts.md).

Do not make one-off boards for an explanation or a decision. Put it on the standard board it
belongs to (a decision on State, a mechanism on Workflows or Data flows, a shape on Data inventory).
If one-offs were made, fold their content into the standard boards and delete them (one delete at a
time; each needs the Operator's confirmation).

## The flow

1. **Draft.** Start from what is known: the proposal, the repo, the conversation. Make the six
   boards early, at low fidelity; the Operator reacts better to a board than to a paragraph.
2. **Restate the model when understanding drifts.** If statements about the design are getting
   inconsistent, stop and put "the model, as I understand it" on the State board with the points
   to confirm. Rewrite the other boards only after the Operator confirms.
3. **Decisions.** Every open choice is a card: the question, two to four options, what each means
   with a concrete example, and one recommendation (said in chat; on the board only if asked).
   Show the catch visually (a peach card). Concrete configs beat descriptions: when asked "what
   would that look like", draw the actual files and the resulting table.
4. **Wait for the ruling.** Short answers are rulings: "1234 y", "A1 y, A3 no", "agreed, option 2".
   A question is never a ruling: "lets do A3" may mean "let's discuss A3" - if a message could be
   either, explain; do not build. If a ruling was acted on by mistake, retract it at once
   (tell every agent that acted, reopen the record) and say so plainly.
5. **Record immediately, then take the explanation down.** An explanation or "for review"
   section lives on a board only while the decision is open. Once the Operator rules:
   - In the repo: the proposal or ADR (the librarian back writes ADRs; a stake if it might be
     missed), the backlog decision ticked (stake for the secretary). Keep the rationale with the
     ruling there, not only in chat.
   - On the boards: **delete the explanation section** (options, catches, worked examples) and
     fold the outcome into the standing board where the subject lives, in one or two lines citing
     the record (a model rule on Data inventory and models, a precedence rule on Workflows, a
     contract change on C4). The State board's "Decided" list gets one line. Close the gap.
   "If I decided, I don't need the explanation anymore because it should be documented
   appropriately in the artifacts" (the Operator, 2026-11-21).
6. **Refresh after every ruling, merge or release; cleaning is part of every refresh.** Boards go
   stale on every merge. Refresh from git (git wins on any contradiction), list what changed, and
   clean as you go: decided explanation sections come off (step 5), superseded sections become
   one "Decided: ..." line, one-offs are folded in, gaps closed. Only open decisions keep an
   explanation.

## Decisions on the State board

- **Waiting on you:** one compact table or card: call, question, recommendation. Ask in chat for
  "yes/no on X1 to Xn"; the Operator answers in shorthand.
- **Decided:** one line per call the moment it is ruled: call, decision, where it is recorded
  (PR, ADR). Its explanation section is deleted at the same time (flow step 5).
- **For review:** an explanation section for an open call (the picture, the options, the catch),
  placed under the State board's columns. It exists only until the ruling.
- **Call ids:** prefix per area and keep them unique for the review (A1-A4 agent definitions, S1-S3
  skills folders); never reuse letters that also name slices or PRs.
- **Order of a State board:** title, one-line takeaway, a "current as of <date>" line, then the
  columns (built / in progress / next), waiting on you, decided, links.

## Words and names

- Describe items by what they are; an id may follow in brackets (never a bare id).
- Name the thing the Operator named ("the component registry"), not internal codenames.
- Plain words on boards: a few words per box, a takeaway of at most ten words per board.
- Use the borrowed analogy the Operator offers (e.g. "the Windows Registry") as the map, not the
  name of the product.

## Who does the work

The host plans, judges and talks to the Operator; board writes, refreshes and clean-ups go to a
subagent (Sonnet) with explicit layout rules from the review-boards skill and the list of what is
true now (versions, PRs, rulings with dates). Review its report; relay what changed in a few lines.
Never let two agents write the same board at once.

Lessons from the sessions this skill came from: [references/lessons.md](references/lessons.md).
The links of past review boards, worth opening as examples, are private and kept out of git:
`boards/examples.md` in the shared records folder (`$DEVHOST_RECORDS_DIR`).
