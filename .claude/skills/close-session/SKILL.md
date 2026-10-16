---
name: close-session
description: The end-of-session checklist for this repository. Use it before ending any working session, before opening a pull request, and whenever the user says they are done, wrapping up, or asks to commit or push. It makes sure the records carry the session's work (the ledger entries checked, the backlog current), the guards pass, and the work is on a branch, reported in the hand-off shape.
---

# Close a session

A session that changed code or documents is not finished until the next session, on any
engineer's machine, can pick up from the repository alone. This is the order to do it in.

## Steps

1. **Account for the work in the records.** Every unit of work has a ledger entry; every open
   item is in `TODO.md` with an owner and a date; every settled term is in `LEXICON.md`; every
   decision that needed more than a line has an ADR (`/new-adr`). Inside the devhost the backs
   did most of this after each turn: read what they added (the quiet notices name it) and add or
   reword by hand only what they missed or got wrong. On a workstation there are no backs: write
   the entry, the items and the terms yourself, in the same shapes (`docs/ledger/README.md`,
   `TODO.md`'s header).

2. **Check the scribe's ledger entries; never edit one.** Each entry against what happened: every
   unit of work has one, including each con's job; the friction is complete and tagged; the
   Operator's decisions are theirs; no real data, credentials or forbidden words; the Measures
   line carries numbers. A wrong entry is corrected by a new entry with a `Corrects:` line.

3. **Run the guards and the checks.**

   ```sh
   task devhost:verify     # or: devhost-verify
   task check              # the repository's own suite, if it has one
   ```

   A finding is fixed, not skipped. `git commit --no-verify` only on the Operator's say-so, with
   the reason in the commit message and in the ledger entry.

4. **Scan the diff for boundaries.** The diff against the base branch must contain no
   credentials, no identifiers, no real data, no name from the redact list.

5. **Commit on a topic branch.** Never on the base branch directly. Conventional Commit messages
   naming the backlog ids; the agent's co-author trailer when the agent wrote the commit, at its `@noreply.invalid` address (ADR 0002). Commit
   and push only when the user asked for it. If they did not, stop here and report what is ready.

6. **Open the pull request** when asked, with the template filled in and the checks stated as run.

7. **Report, in the hand-off shape**, so that what the session lacked travels with what it made:

   ```
   Outcome:  two to five lines: what changed, which ids were added or changed
   Outputs:  the branch, the pull request, the files written
   Friction: what the session lacked or what went wrong, tagged
   For the repository: [tooling] ..., [docs] ..., [skill] ..., [process] ...
   Decisions needed: what is now the Operator's, and what the next session should start with
   ```

## Why

The next session reads the repository, not this conversation. If a decision, an item or a term
lives only here, it is gone. The checklist is short because every step has already bitten
someone.
