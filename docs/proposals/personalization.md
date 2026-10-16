# Proposal: personal preferences across sessions, repos and agents

Status: draft, for the Operator to decide. Nothing here is implemented.

**The problem.** The Operator says "I like diagrams", "name backlog items by what they are", "delegate
to cons". Today that lands in the host's auto-memory, which only the host reads, only in this repo,
and which cons and backs never see. The same preference then has to be said again in the next repo,
or written into each skill (which commits a personal taste to a public repo).

## 1. What a preference is

| Kind | Example | Who it binds | Where it lives today | Committed? |
|---|---|---|---|---|
| Project rule | PRs only, DCO sign-off, bump the Feature version | everyone | `CLAUDE.md`, `PROCESS.md` | yes |
| Fact about the repo | consumers are the office and DSNP; `main` is protected | everyone, as information | `CLAUDE.md`, `README.md`, ADRs | yes |
| **Preference** | name items by description; delegate to cons; show C4 diagrams in the terminal | one person (the Operator), wherever they work | auto-memory (this repo only) | **never** |

Test: if a second engineer joined, would it bind them? Yes: project rule. No, it is how this person
likes to be told things: preference. Today's three memory files are all preferences in form
(feedback, with a why and a how to apply). One is half a rule: "stakes add, never reword" describes
how the backs work, so it belongs in `PROCESS.md` (a project rule found in memory; see section 6).

A preference changes **presentation and delegation style** (format, naming, level of detail,
who does what). It never changes a guard, a permission or what may be committed.

## 2. Where it lives: options

Facts checked in this tree:

- The claude-code Feature sets `CLAUDE_CONFIG_DIR=/var/lib/devcontainer-features/claude-code` and
  mounts a named volume there, `claude-code-config-${devcontainerId}`: it survives rebuilds, but it is
  **one volume per repo**, so it does not follow the Operator on its own. A repo can bind-mount a
  workstation folder on the same target instead (`src/claude-code/NOTES.md`), which is the only way
  one directory is shared.
- Auto-memory sits in that directory under `projects/<repo path slug>/memory/`: per repo by design.
- Backs run `claude -p --settings '{"disableAllHooks": true}' --no-session-persistence`
  (`run-job.sh`, `job_claude`). Nothing there turns off user memory or the user-level `CLAUDE.md`,
  and the environment (so `CLAUDE_CONFIG_DIR`) is inherited. Whether `-p` loads the auto-memory
  directory is **not verified**; assume not. Cons (subagents) inherit the project `CLAUDE.md`
  chain but not the host's conversation, so they know only what the brief says.
- `.devhost/redact-names.txt` shows the pattern for a personal, ignored file in the checkout.

| Option | Survives rebuild | Follows Operator across repos | Never committed | Read by backs (`claude -p`) | Read by cons | Operator edits it |
|---|---|---|---|---|---|---|
| A. User-level `CLAUDE.md` in the claude-code volume (`$CLAUDE_CONFIG_DIR/CLAUDE.md`) | yes | no, unless the volume is a shared bind mount | yes (outside the checkout) | very likely (same config dir; to verify) | via the host's brief only | in the container: awkward |
| B. Auto-memory directory | yes | no (keyed by repo path) | yes | unverified, assume no | no | by asking the host; files are plain markdown |
| C. Per-Operator file in a Feature state volume, keyed by `DEVHOST_ENGINEER` (e.g. `$DEVHOST_STATE/preferences/<handle>.md`) | yes | no, same one-volume-per-repo limit | yes | yes, the runner can pass it into each prompt | via the host's brief | in the container |
| D. Ignored file per repo (like `redact-names.txt`) | **no**: lives in the checkout; lost on a fresh clone | no, copied by hand | yes, if ignored | yes (the runner knows the root) | via the host | easy, but N copies drift |
| E. Workstation file, the bootstrap copies it into each devhost | yes (recopied at each `task devcontainer:up`) | **yes**, one source for every repo | yes (outside every checkout) | yes, once copied to C or A | via the host | **easy, one file, a normal editor** |

Reading the table: only E gives one source across repos and consumer repos; C or A is where the
copy lands inside the devhost so that every reader finds it at a fixed path. No option alone is
enough, and combining E with a fixed in-container target is the smallest design that is.

```
 workstation (source of truth, one file, never in a repo)
   %USERPROFILE%\.devcontainer-homes\operator\preferences.md
        |  bootstrap copies at `task devcontainer:up`
        v
 devhost, any repo: $DEVHOST_STATE/preferences/<DEVHOST_ENGINEER>.md   (read-only copy)
        |
        +--> host   : session-start hook prints it (like the briefing)
        |              |
        |              +--> cons  : host puts the relevant lines in each brief
        |
        +--> backs  : run-job.sh prepends it to each job prompt
        +--> briefing: lists it and any preference captured since the last review
```

## 3. How each reader gets it

| Reader | Mechanism | Cost of the change |
|---|---|---|
| Host | the briefing hook (already runs at session start) prints the preferences file, or `$CLAUDE_CONFIG_DIR/CLAUDE.md` is generated from it; the host then follows it like memory | a few lines in the briefing script |
| Cons | no inheritance: the host's brief carries the **relevant** lines. Add one line to the hand-off shape's brief: `Preferences: <the lines that apply to this job, or none>` | one line in `PROCESS.md` / the brief template; a con with no such line applies none |
| Backs | `run-job.sh` prepends the file to each job's prompt, marked as presentation-only; the redaction guard still runs on what the back writes | a few lines in the runner; small models get a short file, so keep it short |
| Briefing | shows the count of preferences and the ones new since the last review | a line in the briefing |

Example, a con's brief with the new line: `Preferences: describe items by what they are, never a bare id;
show the structure as a small ASCII diagram before the detail.`

Selecting "the relevant lines" is the host's judgement; tagging each preference with who it applies to
(`host`, `con`, `back:scribe`) keeps that mechanical:

```
- [all]   Name backlog items by what they are; an id may follow in parentheses.
- [host]  Delegate the doing to cons; keep the host to planning and review.
- [all]   Prefer a small diagram (C4 or ASCII) over a paragraph when showing structure.
- [scribe, secretary] Entries and items lead with the description.
```

## 4. How a new preference is captured

1. The Operator says it once, in a session ("I like diagrams").
2. The host acknowledges in one line and writes it to the preferences file (the in-container copy)
   as a tagged line, with the date. The host, not a back, writes it: a back reading a transcript would
   guess at tone, and a preference is the Operator's statement, not an inference. Where unsure,
   the host leaves `Stake for the secretary: ...` for a decision item rather than writing.
3. Because the in-container copy is derived, the host also tells the Operator once: "saved here;
   add it to the workstation file to keep it" (or a `task prefs:push` writes it back through the
   mounted folder, if the Operator accepts that).
4. Review: the briefing lists preferences added since the last review, and `/ledger-review` asks for
   each: keep, narrow (a tag), promote to a project rule (if it binds everyone), or drop.
   Friction recorded in the ledger ("had to repeat a preference") is the signal that a reader is
   missed.

Guards: preferences hold paths and phrasing, never real data or a name (the redaction list applies
when a back writes anything derived from them). A preference never widens a permission.

## 5. Recommendation

Make **E plus C** the design: one workstation file the bootstrap copies to
`$DEVHOST_STATE/preferences/<DEVHOST_ENGINEER>.md`; the host reads it at session start, the host's brief
carries the relevant lines to cons, and `run-job.sh` prepends it for the backs. Keep auto-memory for what
the host learns about a repo and leave its feedback files as they are until the trial says otherwise.

Two lines: the Operator edits one file on the workstation; every devhost, in every repo, hands it to
the host, its cons (through the brief) and its backs (through the runner).

### One-week trial

Scope: this repo only, by hand first (copy the file in, add the briefing line and the runner prepend
behind an env switch `DEVHOST_PREFERENCES`), nothing committed that is personal.

| Measure | How | Good looks like |
|---|---|---|
| Repeated preferences | ledger friction tagged "repeated a preference" | zero after day 2 |
| Cons that applied the brief's preference | spot-check 5 con replies | all that had the line |
| Back output matches (e.g. entries lead with a description) | read 5 ledger entries and items | at least 4 of 5 |
| Size and cost | prompt size of back runs, `devhost-costs` before and after | under a few percent more |
| Review burden | minutes spent at the ledger review on preferences | under 2 minutes |
| Leaks | `task devhost:verify` and `git status` | nothing personal staged |

Decide at the end: adopt, change the tags, or drop it.

## 6. Open questions and one finding

- **Finding:** "stakes add, never reword" in auto-memory is a project rule (how the backs and the
  guard behave), so it should live in `PROCESS.md` where cons and consumers see it; only the host
  reads it today.
- Does `claude -p` read the user-level `CLAUDE.md` and the auto-memory directory? Run one headless
  job with a marker line and see; the proposal's backs path does not depend on the answer (the runner
  prepends the file), but option A would.
- Workstation location and who copies: needs a bootstrap change in `bootstrap/` and, for consumers,
  an entry in their `DEVCONTAINER_CONTRIBUTION.md`.
- A shared bind mount for the claude-code volume (NOTES, line "bind-mounts a host folder") would also
  share auto-memory across repos; its mixed-project memory is a separate decision.

## Decisions needed

1. Adopt E plus C as the design (or prefer another row of the table)?
2. May the host write the in-container copy, with the Operator keeping the workstation file?
3. Run the one-week trial in this repo first?
