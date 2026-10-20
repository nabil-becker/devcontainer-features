---
name: plant-a-seed
description: Plant a seed, the exported way of working (the Agentic Delivery OS), in a new or existing project - read the seed's papers and foundation, interview the person, write their answers down, propose a plan, apply it once they decide, and record the first ledger entry. Use it when the person points you at a seed's README.md, or asks to plant or import a seed, or to set up the way of working in a repository.
---

# Plant a seed

A seed is a plain folder exported at the end of a project by `drop-a-seed`: papers (what was
learned), a foundation (what to adopt), a starter (files to copy) and these skills. Planting is
the other half of the cycle: the person's project gets the way of working, shaped to how they
work. The interview in `INTERVIEW.md` does the shaping; you hold their hand through it.

## Steps

1. **Read the seed.** Its `README.md`, the papers oldest first, the foundation, the starter.
   Note what each foundation piece is for; you will propose from them later.

2. **Read the target.** The directory you were started in: blank, or an existing repository.
   For an existing one, read its README, layout, tooling, `.devcontainer/`, git history and any
   agent files (`CLAUDE.md`, `AGENTS.md`). Ask nothing the target already answers.

3. **Run the interview.** Follow `INTERVIEW.md`: the opening, the two use cases, then the five
   principles in order, personalization first. Short rounds, example answers beside each
   question, a recommendation on each. The guide says what must be answered; you choose the
   questions and their order.

4. **Write the answers down, word for word.** Save them to `docs/iterations/interview-<N>.md` in
   the target (`N` is the next free number). A skipped topic is a marked gap, never a guess.
   A decision left only in chat gets lost.

5. **Propose a plan.** New repository: the starter files, the foundation pieces, the order.
   Existing repository: what to add, what to adapt, what to leave alone, and what each change
   touches. Mark each foundation piece adopt, adapt or leave out, with the reason. Put it in one
   page or a numbered list the person can answer with "1 yes, 3 no".

6. **Apply it only after the person decides.** Work on a topic branch in an existing
   repository, never on the base branch. Before the first commit: fill the redact list and
   settle the identity agents commit as (principle 3). Copy from `starter/`; follow
   `starter/SETUP.md` for the dev container.

7. **Set up the ledger and record the first entry.** Create the ledger by the shape the foundation
   gives, and write its first entry: what was asked (the seed planted), what came out, the
   friction met, the cost. Run the project's checks if it has any, and report in the hand-off
   shape (Outcome, Outputs, Friction, For the repository, Decisions needed).

## Defaults

Every step has a default. If the person says "skip the interview, just build", use the defaults:
the person picks the use case closer to their work (software delivery or personal assistant) and
its answers fill every part they do not change. Purpose still has to be asked: it has no default
and cannot be backfilled. Say what you assumed in the plan.

## Rules

- You propose; the person decides. Never choose for them what the guide marks as theirs.
- Never put a name, credential or real identifier in a committed file; paths and ids, not content.
- Explain every term in the question. The person should not need the lexicon to answer.
- Do not run the closing topics of the guide; those belong to `drop-a-seed`.
