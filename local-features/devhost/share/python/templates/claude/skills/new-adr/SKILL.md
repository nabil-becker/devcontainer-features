---
name: new-adr
description: Write an architecture decision record for this repository. Use it when a decision needs more reasoning than a backlog item or a ledger line holds, when two or more options were seriously weighed, when a choice constrains how people work (branching, tooling, review) or how the system is shaped (a boundary, a protocol, a store), or when the user asks for an ADR, a decision record, or to "write up why we chose X". Not for choices a single line states completely.
---

# Write an ADR

An ADR is the long form for the few decisions that need it. [docs/adr/README.md](../../../docs/adr/README.md)
holds the format, numbering and lifecycle.

## Steps

1. **Confirm it deserves one.** If the decision, its source and its consequence fit in a backlog
   item or a ledger line, write that and stop. The test: will someone ask "why" in a year, and
   would the line answer them?

2. **Create the file** from the template with the next number:

   ```sh
   task devhost:adr -- Short title of the decision     # or: devhost-adr Short title of the decision
   ```

   This writes `docs/adr/NNNN-short-title-of-the-decision.md` and adds the index row to the ADR
   README.

3. **Fill the sections in order.** Keep the headings exactly; `devhost-verify` checks them.
   - *Context*: the situation and the forces, each with its source (a note, a document, a
     measurement, with the date).
   - *Decision*: full sentences, present tense, specific enough to check the repository against.
   - *Options considered*: the chosen one first with why it wins, then each losing option with why
     it lost. An option nobody would have chosen is padding; leave it out.
   - *Consequences*: easier, harder, and what must now be done, with backlog items if any. Name
     the open questions it leaves.

4. **Status.** `proposed` until the Operator confirms (then `accepted`) or rejects (`rejected`). A
   change to an accepted ADR is a new ADR that supersedes it; the old text is not edited beyond
   its status line.

5. **Close out.** `task devhost:verify`, then as in `/close-session`.

## Why

The backlog is for finding decisions; the ADR is for trusting them later. Writing the losing
options down is what stops the same debate from recurring when the person who remembers it is
unavailable.
