> **Status:** research notes, saved 2026-11-03 so they are not lost. Part (a), the ledger review draft, is **on hold** until the move to the shared folder (the Operator, 2026-11-03); nothing in it is agreed or applied. Part (b), the anti-pattern and best-practice seed list, feeds the Feature docs work (each Feature's best practices and anti-patterns, the reference architectures).

# Ledger review 2026-11-03 (draft, read-and-propose)

Prepared by a con for the Operator, through the host. Nothing in the repository was edited by this job
(one side effect, see "What this review lacked": `devhost-report` regenerates the tracked cost files).
Working files in the same folder: `condensed.md` (every entry's Friction, Learned, For the repository and
Decisions needed, numbered 1 to 165), `report.log`, `report-log.log`, `input.md`.

Two parts:

- Part (a): the draft `## Review 2026-11-03` section, in the ledger's review shape.
- Part (b): the seed list of anti-patterns and best practices.

Section 0 is the notes from steps 0 to 2 that the draft leans on.

---

## 0. Notes behind the draft

### Cost report (steps 0)

Read: `costs-2026-11-operator.md` (generated 2026-11-03 ~19:17Z, it moves while sessions run),
`costs-2026-10-operator.md` and `costs-2026-10-unknown.md` ($0.44, one session on 2026-10-16, ignored).
`devhost-report --log` shows no error runs; two "skipped: lock busy" lines (secretary and librarian, this session).

| Figure | 2026-10 month (whole) | At the 2026-10-29 review | Change since | 2026-11 to date |
|---|---|---|---|---|
| Total | $834.31 | $628.24 | +$206.07 | $78.37 (39% of the $200 target, 3 days) |
| Inters | $546.10, 13 sessions | $427.85, 11 | +$118.25 | $35.85, 4 sessions ($6.91 to $11.71 each, 66 to 104 replies) |
| Cons | $246.37, 94 runs | $166.16, 64 | +$80.21, 30 runs | $37.11, 13 runs |
| Opus cons | 15 runs, $151.42 ($10.09 a run) | 9, $97.24 | +6 runs, +$54.18 ($9.03 a run) | 5 runs, $24.08 ($4.82 a run) |
| Sonnet cons | 78 runs, $94.83 ($1.22) | 55, $68.93 | +23 runs, +$25.90 ($1.13 a run) | 8 runs, $13.03 ($1.63 a run) |
| Backs | $41.84, 1555 runs | $34.22, 1262 | +$7.62 | $5.41, 219 runs |
| Undone by guards | 6 | 6 | 0 new | 0 |
| Ledger corrections | 21 | 19 | +2 (both in this range) | 0 |

Spend since the last review: about $284 ($206.07 October plus $78.37 November). November's pace per day with entries is
$26, October's was $76.

What to look for, signal by signal:

- **A con type on a large model at a low cost per run**: no new case of the shape the last review found. Opus cons
  cost 4 to 8 times a Sonnet con per run. The rule "Opus only when the change reaches every consumer" was followed for
  the devcontainer-cli build lock (#154, $6.97) and the launcher engine wait ($3.13), and for agents 2.0 slice 1
  ($11.88). Two Opus runs are doubtful: `cloud-folder:login` ($16.73, 2026-10-29, cloud-folder plus launcher, a feature
  work that reaches consumers but is bounded) and the secrets-master-split proposal ($3.14, 2026-11-03, a document).
  Action: none new, see group 13.
- **Inter cost per session rising**: no. November sessions run $6.91 to $11.71. October's total was two long
  sessions ($335.44, 1335 replies; $132.86, 518 replies) which were 86% of the month's inter spend; fresh containers
  and shorter sessions after the Rancher Desktop move (2026-10-31) cut that. No action.
- **Back cost per change**: librarian $0.73 (at the last review) to $0.78 (October) to $0.86 (November); scribe $0.01;
  secretary $0.02. The librarian is 80% of November's back cost ($4.31 of $5.41) for 5 changes, 14 pending notes and 13
  "nothing" runs of 32. The 2026-10-29 `librarian-threshold` item is not done (group 14).
- **"Nothing" runs**: librarian 58% in October (123 of 212, was 57%), 41% in November, plus 44% "pending".
  Tester: 556 of 559 in October and 80 of 80 in November, at no cost: it is a no-op because the devhost has no Docker
  (see group 1 and the proposed decision).
- **Undone**: none new. **Corrections**: the two in range are entries the host or a con got wrong (diagnosis blamed
  cloud-folder; a harvest compared against main and not the open PR), see group 12. **Stakes**: secretary 17 of 49
  runs in November (35%, October 12%). The stakes read as the filing route the Operator and host now use on purpose
  ("Stake for the secretary: ..."), and the secretary changed something in 41 of 49 runs, so they are being caught.
  One stake was not written (entry 163, the Docker Desktop backend message) and the item exists now
  (`launcher-docker-backend-message`). No action. **Errors**: none.

**Entry rate and cadence.** 166 entries since the last review in 5 days (33 a day; 15.7 a day in November, 38.9 in
October). The skill, `PROCESS.md`, `CONTEXT.md`, `CLAUDE.devhost.md` and the templates say "every 25 entries"; ADR 0021
and `DEVHOST_REVIEW_EVERY` say 75; entries 120 and 121 (2026-11-01) said the three documents were to be fixed to 75 and
`review-cadence-prose` (TODO.md) is open, so the contradiction is still there. At 25 a review would come every 1.6
days (far too often). At 75 it comes every 4.8 days, and in practice the reviews happened at 184 entries (10-29) and
166 now (2.2 to 2.5 times the setting), so 75 is also too often for how it is actually run. Proposed: 150, with the
prose fixed to say "the setting (150 here, ADR 0021)" (decision D1).

Entry count: the briefing says 165 entries since the review; the host's brief said about 151. The files hold 119
entries after the review heading in 2026-10.md and 47 in 2026-11.md (46 at read time; the scribe wrote
"Secrets master split proposal written" while this ran). Two entries are corrected by later ones (2026-10-30 "Start
failure traced to cloud-folder post-start..." by "Consumer diagnostics read..."; 2026-10-30 "Gap harvest of host session
85f32aa0..." by "Harvest of 85f32aa0 rechecked...") and were skipped.

### Recurrence (step 2), the promises of the 2026-10-29 review

| Promise | State | Evidence |
|---|---|---|
| Group 1: decision `local-container-tests-route`, podman/wslc spike first | Decision made, work NOT APPLIED | `podman-wslc-runner-spike` still `[ ]` (TODO.md, added 2026-10-16). Entries 33, 71, 73, 100, 151, 156, 157 say "no Docker here, container tests not run". The devhost moved to Rancher Desktop (2026-10-30/31) with no recheck. |
| Group 2: item `lint-quick-own-log` | NOT APPLIED, recurred | Item `[ ]`. 11 entries again (67, 83, 84, 99, 102, 116, 123, 132, 134, 151, 157): lint past 120 s, backgrounded and polled, one a `git stash` run past the limit. No `lint:quick` in `Taskfile.yml`. |
| Group 3: change `psscriptanalyzer-tracked-files` with a test | APPLIED | Entry 4 (2026-10-29): `.github/scripts/Invoke-PSScriptAnalyzer.ps1` lists `git ls-files`; `test/lint/psscriptanalyzer_files_test.sh`; `test:psscriptanalyzer-files` in `task lint`. The backlog item is still `[ ]` (tick it). |
| Group 4: change `todo-append-position` (merge=union, duplicate-id guard) | APPLIED, then needed two follow-ups | `.gitattributes` lines 14 and 15; `backlog_ids` guard in verify.py with tests. Union doubled three ticked items (entry 54), so a merge driver (`devhost-todo`, #121) and `repo:setup` loading it (#123, entry 58) followed; it ran clean on its first uses (entries 46, 59). GitHub's server-side merge still ignores both (entries 4, 76, 90). Item still `[ ]` (tick it). |
| Groups 5 and 6: brief guidance in CLAUDE.devhost.md (wait for own jobs, own log, hand back once, no `pkill -f` on a pattern your shell contains; PR template; full decisions) | APPLIED, partly effective | Text is in `.devhost/CLAUDE.devhost.md` line 16 and the template. No triple hand-back in this range, and cons 67, 83, 157 backgrounded with a log and waited. But a con killed its own shell with `pkill -f` twice on 2026-10-30 (entry 84) and cons 132 and 134 named the wrong PR template path or arrived half done. |
| Group 7: `open-questions-batch` walkthrough | NOT APPLIED (third review) | Item `[ ]`. Questions from the range still open when later entries are written: warning or refusal for `definition` in 2.0 and refusing `--resume` for ephemeral agents (entries 33, 35); stricter resume refusal (99); 480-minute unlock bound (151). |
| Group 8: `backs-paste-truncation` | NOT APPLIED | Item `[ ]`. Clipped or cut text again in entries 12 (section 5 clipped), 94 (options cut off), 138 (note cut off mid-word), 143 (recommendation cut off), 159 (answers as bare numbers). |
| Group 9: `branch-merged-conflict`; decision `stash-records-carry-clear` | Stash decision APPLIED; branch item NOT APPLIED | `stash-records-carry-clear` `[x]` 2026-10-29 (twelve dropped); entry 21 dropped the rebuild-wip stash. `branch-merged-conflict` still `[ ]`; entry 109 hit the sibling `branch-task-push-check`. |
| Group 13: Opus cons only when the change reaches every consumer | APPLIED | Guidance text present; see cost notes (Opus $9.03 a run since, $4.82 in November). |
| Group 14: `librarian-threshold` | NOT APPLIED | Item `[ ]`; per-change cost went from $0.73 to $0.78 to $0.86. |
| Added item `trust-agent-folders`, the Operator agreed | NOT APPLIED | Item `[ ]`; no `trustAgentFolders` in `src/claude-code`. The by-hand trust entry worked for the facts check (entry 2). |
| Deferred: agents v2 Claude Code facts | APPLIED | `agents-v2-claude-facts` `[x]` (#103, entry 3). |
| From the 2026-10-21 review, still recurring | `scribe-commit-verification` came back (entries 161, 162, 160); `feature-tests-new-checks` came back in spirit (container tests unrun, group 1); `worktree-commit-identity` not seen (entry 123: the wrapper sets `GIT_AUTHOR_*`). |

Score: of the 2026-10-29 review's 9 concrete changes and items (groups 2, 3, 4, 5/6, 7, 8, 9, 14, 13 plus
`trust-agent-folders`), 4 were applied (3, 4, 5/6, 13) and 6 were not (2, 7, 8, 9-branch, 14, `trust-agent-folders`),
plus the group-1 decision never started. The not-applied ones are all "an item, owner host" that nobody scheduled:
the backlog holds 208 open items and 41 decisions for the Operator (briefing).

---

# Part (a): draft section for `docs/ledger/2026-11.md`

## Review 2026-11-03

- **Entries reviewed:** 166, from "2026-10-29 Trust for agent folders: no setting; trustAgentFolders option accepted"
  (2026-10-29) to "2026-11-03 Secrets master split proposal written (docs/proposals/secrets-master-split.md, commit
  183b51e)" (2026-11-03). The briefing counted 165 when it ran, the host's brief said about 151. Two corrections in the
  range; the correcting entries were read instead.
- **Costs (costs-2026-10-operator.md, costs-2026-11-operator.md):** October closed at $834.31 (+$206.07 since the
  last review's $628.24): inters $546.10 in 13 sessions (two sessions, 86%); cons $246.37 in 94 runs (Opus $10.09 a
  run in 15 runs, Sonnet $1.22 in 78); backs $41.84 in 1555 runs, 6 undone by guards (none new); 21 ledger corrections
  (+2). November to date $78.37 against the $200 target (39%): inters $35.85 in 4 sessions; cons $37.11 in 13 runs
  (Opus $4.82 a run in 5, Sonnet $1.63 in 8); backs $5.41 in 219 runs, 0 undone, 0 corrections. The librarian costs
  $0.86 per change (scribe $0.01, secretary $0.02) and is 80% of back spend; the tester was a no-op in 80 of 80 runs.
  Entry rate 15.7 a day in November (38.9 in October), so a 75-entry review comes due every 4.8 days; this one came at
  166 entries, 2.2 times the setting.
- **Recurrence:** 4 of the 9 changes and items the 2026-10-29 review promised were applied
  (`psscriptanalyzer-tracked-files`, `todo-append-position`, the brief guidance for cons, Opus only where the change
  reaches every consumer) plus the stash decision and `agents-v2-claude-facts`. Not applied: `lint-quick-own-log` (11
  entries), `open-questions-batch` (third review), `backs-paste-truncation`, `branch-merged-conflict`,
  `librarian-threshold`, `trust-agent-folders`, and the podman/wslc spike behind `local-container-tests-route`. From the
  2026-10-21 review, `scribe-commit-verification` came back (three entries).
- **Groups and actions:**
  1. The devhost cannot run its own tests: no Docker, `task lint` stops at the first of 31 failing
     `test:cloud-folder-unit` cases and at `test:agents-lease`, so cons run lint piecemeal and container scenarios first
     run in CI (about 14 entries): reopened decision `local-container-tests-route` (Rancher Desktop changes the
     options) and change now `lint-hermetic-unit-tests`, merging three open items (`lint-isolate-feature-tests`,
     `cloud-folder-unit-env-leak`, `agents-lease-hermetic`) with a test that runs the unit tests in a poisoned
     environment.
  2. `task lint` runs past the 120-second tool limit; polling, shared logs, a self-inflicted `pkill -f` (about 12):
     reopened `lint-quick-own-log`, first in the queue.
  3. Flaky and racy tests (about 8: wake token, lease takeover, mount_fuse, engine-wait twice, busy port): new item
     `flaky-test-sweep`.
  4. Pull request mechanics found at push time: `feat/` against `feature/` in three briefs, the push check reading the
     backlog from main or the branch, a backlog item uncommitted when its code was pushed, records re-cut on a fresh
     branch (about 9): change now in the brief guidance, plus `branch-task-push-check` holds the tool side.
  5. TODO.md and ledger conflicts and doubled items (about 12): no new action; trend improved (the driver ran clean
     twice); GitHub's server-side merge is the remainder, held by `backlog-as-ledger` and the register move.
  6. Resident agents: copies, forks, stale records, retitles, resume (about 25 entries, claude-code 1.8.7 to 1.9.7 and
     agents 2.0.0 to 2.1.1 in 6 days): new item `agents-real-cli-canary`; the existing items `second-copies-real-service`,
     `fork-detection-check` and `rebuild-claude-code-2-1-314` become its first runs.
  7. A fix ships but nothing tells the consumer what to do (include line, containerEnv line, rebuild, pin, release
     order) (about 16): no new item; `changelog-per-feature` and the decision `changelog-approach` are the home, with a
     "consumer action" line recommended.
  8. Launcher and hooks hide or hang on host faults (ssh-add prompt, Docker Desktop backend, engine not answering, missing
     PowerShell, bootstrap settings) (about 10): no new item; `launcher-docker-backend-message`, `pwsh-missing-message`
     and `bootstrap-env-sources` hold the rest, and the lesson goes in the anti-pattern list.
  9. A rebuild or new container loses state and the briefing does not say so (gh login, memory, user settings, rclone.conf,
     ssh key, held stretches, installed devhost older than the source) (about 10): new item `restart-restore-report`.
  10. Records say something before it is verified (a release recorded from the host's report; a records PR written before
      the release run) (about 7): reopen `scribe-commit-verification` with these entries as evidence; no new item.
  11. Docs, notes and prose drift from code or from a decision, and decisions made in chat stay out of the ADR (about 16;
      the 25-or-75 contradiction, the vendor co-author trailer, the NFR count, adapter headers, retitle notes): change
      now `review-cadence-prose` with a test, and decision D1.
  12. Wrong first diagnosis, wrong subagent claim, a con that touched a parallel slice's files or arrived half done
      (about 9; the host's review caught each): no action; the review step works. Practices go in the list.
  13. Opus cons: no action; the rule held, watch the document-writing con at the next review.
  14. The librarian's cost per change: reopened `librarian-threshold` with a concrete first step (skip a stretch that is
      only questions and answers).
  15. The AOF register adoption met three upstream faults in three days on first real use (stray fences, hard links on
      the mount, roster without a `.pub`) (about 20 entries touch the thread): no new item; `import-stray-fence`,
      `register-store-no-hardlink`, `register-roster-traceback`, `aof-seed-ingest` and `secrets-master-split` hold it; one
      lesson for the list (probe the target store before building on it).
  16. Questions and tasks left open: 208 open items and 41 decisions for the Operator (briefing), `open-questions-batch` unrun for a third review,
      unticked finished items (`psscriptanalyzer-tracked-files`, `todo-append-position`, `ledger-review-104-entries`):
      walkthrough at this review's close; the host ticks the three.
  17. Tester is a no-op without Docker (80 of 80 runs): folded into group 1's decision.
- **What this review lacked:** a per-entry tag for the friction cause (groups were counted by hand from 166 entries,
  counts are "about"); the models of each con matched to its entry (the cost report gives per type and per agent id, not per
  entry, and 19 entries carry "counted in the first entry of the stretch" so their cost is not on them); a check that the
  promised items were scheduled (not only listed); the stretch of host work per model; six con jobs of 10-30 are in no
  entry (entry 96); the current session's records were still pending in the scribe (one entry arrived while the
  review ran).
- **Deferred:** the best-practice and anti-pattern seed list is the first input to `best-practices-antipatterns`, not
  yet in `NOTES.md` files; the ledger review cadence number (D1) until the Operator rules; groups 7 and 15 until
  `changelog-approach`, `secrets-master-split` and the AOF seed arrive.

### Proposed actions, one per group (for the Operator)

| # | Group | Kind | Id | Owner | Test that would have caught it, or the friction it removes |
|---|---|---|---|---|---|
| 1a | Devhost tests not hermetic; lint stops at first failure | change now | `lint-hermetic-unit-tests` (merges `lint-isolate-feature-tests`, `cloud-folder-unit-env-leak`, `agents-lease-hermetic`) | host | New lint step runs `test:cloud-folder-unit` and `test:agents-lease` with `CLOUD_FOLDER_MODE=bogus` and `AGENTS_SHARE_DIR=/nonexistent`; fails on main today (31 and 4 failures). Also make lint run every subtask and print all failures at the end (entries 102, 132, 134 asked for it). |
| 1b | No local container tests | decision | `local-container-tests-route` reopened (D2) | the Operator | Rancher Desktop is now the engine; the earlier choice (podman/wslc spike) was made when Docker Desktop and wslc were the options. |
| 2 | Lint past 120 s | reopened item, first | `lint-quick-own-log` | host | `task lint:quick` finishes under 120 s for a one-Feature change; each long run prints the path of its own log. Removes about 12 entries' friction. |
| 3 | Flaky tests | new item | `flaky-test-sweep` | host | `test:engine-wait` counts a fake clock, not wall seconds (failed twice under load); `mount_fuse` scenario gets a retry or a fix; rule: the first rerun-to-green gets an item. Test: `task test:repeat TEST=<name> N=20` runs a unit test repeatedly under `nice`; engine-wait passes 20 of 20. |
| 4 | PR mechanics at push | change now | brief guidance (CLAUDE.devhost.md and template) | host | One clause: name the branch with `task devhost:branch -- <id>` (types feature, fix, docs, chore), commit the backlog item with the change that cites it, touch only the files the brief names. Test: a unit test that the pre-push refusal names the allowed types. The tool side is `branch-task-push-check`. |
| 5 | TODO.md conflicts | no action | none (`backlog-as-ledger`) | host | Reason: the driver ran clean on its first uses; the remainder (GitHub's merge) goes away with the register move. Recheck at the next review. |
| 6 | Resident agents | new item | `agents-real-cli-canary` | host | `task agents:canary` in the devhost with Claude Code installed: start, stop, wake, simulate a rebuild (stale record), and assert exactly one session in `claude agents`; prints the Claude Code version. Fails on claude-code 1.9.6 for the stale-record case. Run before every claude-code or agents release. |
| 7 | Consumer ripple | no new action | `changelog-per-feature`, `changelog-approach` | host, the Operator | Recommend the decision picks B and each changelog entry has a "Consumer action" line (include line, containerEnv line, rebuild, release order). |
| 8 | Host faults hidden | no new action | `launcher-docker-backend-message`, `pwsh-missing-message`, `bootstrap-env-sources` | host | Held; add to the anti-pattern list. |
| 9 | State lost on rebuild | new item | `restart-restore-report` | host | `devhost-briefing` or `restart-devhost` prints what this start lacks: gh not signed in, memory folder empty, `rclone.conf` missing, ssh key locked, installed devhost older than the source (entry 141), and the records-out-of-git project status (entry 142). Test: briefing unit test with a fake older installed version. Next to `claude-state-survives`, `shutdown-stale-stretch`. |
| 10 | Records ahead of facts | reopen | `scribe-commit-verification` | host | Add the three new entries as evidence: the scribe checks the release run or registry tag before "released". |
| 11 | Doc drift, 25 or 75 | change now + decision | `review-cadence-prose` + D1 | host, the Operator | Test: a unit test in `test:devhost` fails when a document says "every N entries" with an N different from `DEVHOST_REVIEW_EVERY`'s default or from "the setting". |
| 12 | Wrong claims, review catches | no action | none | n/a | Reason: the host's review caught all four cases (entries 7, 43, 68, 81 corrected by 82); practices go in part (b). |
| 13 | Opus cons | no action | none | n/a | Reason: the rule held; next review looks at document-writing cons (the secrets proposal ran on Opus at $3.14). |
| 14 | Librarian cost | reopen | `librarian-threshold` | host | First step: skip a stretch that holds only questions and answers (about 14 pending carried runs of the same note, see `report-log.log`: one pending note was carried 3 runs and then dropped). |
| 15 | AOF upstream faults | no new action | the five items named | host | Held. |
| 16 | Open items | walkthrough + ticks | `open-questions-batch`; tick `psscriptanalyzer-tracked-files`, `todo-append-position`, `ledger-review-104-entries` | host | One walkthrough of the Operator's open decisions at this review's close. |
| 17 | Tester no-op | folded | into 1b | the Operator | If no Docker route lands, the tester should be switched off, not left waking 80 times a month (free, but it never reports). |

### Decisions for the Operator (with recommendations)

- **D1 `review-every-150`.** The setting is 75 (ADR 0021), the documents say 25, and the review has run at 166 and 184
  entries. Recommendation: set `DEVHOST_REVIEW_EVERY=150`, amend ADR 0021, and have the prose say "the setting".
- **D2 `local-container-tests-route` (reopened).** With the engine now Rancher Desktop, should the devhost get a
  container-test route (a Docker or podman socket for the devhost, with the NFR on agents controlling the container) or
  should container tests run from the workstation (`task devcontainer:test` through the launcher)? Recommendation: the
  workstation route, as a launcher task; it keeps the devhost without an engine socket and replaces the tester no-op.
- **D3 Consumer upgrade notes.** Settled by `changelog-approach`; recommendation B plus a "Consumer action" line.
- **D4 `open-questions-batch`.** Take the walkthrough now: the open ones from this range are the warning or refusal for
  `definition` in agents 2.0, the ephemeral `--resume` refusal, the stricter resume refusal (entry 99), the 480-minute
  unlock bound and `key:lock` key-mode guard (entry 151), and the "N waiting" wording (already settled, entry 159).

---

# Part (b): seed list of anti-patterns and best practices

Shape: Don't / Why (a real case: entry date + title, or an issue number) / Instead / Caught by. Tag: `src/<id>`, a
local Feature as `local-features/<id>`, or `combination`. "Caught by" says "nothing yet" when no guard, test or ADR
stops it, and names the open item. Cases are from the entries; test names are from `Taskfile.yml`.

## Anti-patterns

**AP1. `src/ssh-agent`**

- Don't: run `ssh-add` or any prompt in a start hook.
- Why: 2026-10-30 "Start hook no longer waits on ssh-add; passphrase prompt gets a bounded wait and a warning". The
  hook prompted on `/dev/tty`, the devcontainer CLI waited for every start hook, and the start hung about 775 s until
  the WSL exec connection dropped; the error named another Feature (corrected by 2026-10-30 "Consumer diagnostics read;
  copy cause and start hang settled").
- Instead: the start hook loads unprotected keys, skips protected ones with a warning naming `task ssh-agent:setup`,
  and exits 0; explicit setup waits up to `passphraseTimeout`.
- Caught by: ssh-agent 1.2.0 tests (a pty case) in `test:ssh-agent-unit`.

**AP2. `combination` (every Feature with a start or post-start hook)**

- Don't: leave an unbounded wait or a non-zero exit in a lifecycle hook.
- Why: 2026-10-30 "cloud-folder 1.3.1 makes the post-start run never fatal": mount wait (60 s) and reachability check
  (30 s per call) were unbounded, and a closed stdout pipe exited 141.
- Instead: bound every wait (`DCF_CLOUD_FOLDER_START_BUDGET`), always exit 0 from a start hook, and print a warning that
  names the task to run.
- Caught by: `test:cloud-folder-unit` for cloud-folder only; nothing yet for the other Features' hooks (a lint that
  scans hooks for `read`, `ssh-add`, `sleep` without a timeout).

**AP3. `src/claude-code`**

- Don't: wake a resident session with flags, or compare its saved options exactly with the agent's args.
- Why: 2026-10-30 "Restart-wake bug fixed in claude-code 1.9.1, PR #131 open" (copies under new ids) and 2026-10-30
  "Resident wake stays bare; extra saved options no longer start a copy": Claude Code adds options the operator never
  passed.
- Instead: a wake of an existing session is always bare; compare only the wanted options; warn when one is missing or
  changed and say that changed args apply at the next fresh start.
- Caught by: `test:claude-unit` adapter checks from 1.9.3; the real-CLI case is nothing yet (`agents-real-cli-canary`).

**AP4. `src/claude-code`**

- Don't: count a wake as done because a process exists.
- Why: 2026-10-30 "Consumer's claude-code 1.9.2 findings triaged": waking a session with no transcript crashed after
  the adapter had recorded it.
- Instead: confirm for `AGENT_ADAPTER_SETTLE` seconds (default 5), start fresh when the transcript is missing, and never
  record a crashed attempt; accept the cost (up to 45 s at `agents up` for nine residents, the Operator's call).
- Caught by: adapter unit checks (1.9.4); 2.1.314 behaviour is modelled from a report (open: `fork-detection-check`).

**AP5. `src/claude-code` and `src/agents`**

- Don't: trust a background-session record or a pid after a rebuild or an engine move.
- Why: 2026-11-03 "Stale background record cleared before agent wake; copy becomes an error (#155)": each `agents up`
  after a rebuild started two hidden copies; 2026-10-31 and 2026-11-02 "RS1 copy-on-wake report logged for the agents
  Feature backlog".
- Instead: prove a record dead (pid in another namespace, absent from `/proc`, or a different start time) before any
  wake; report a copy that still results as an error of the Feature; never start `attach` that wakes again within a
  short window.
- Caught by: 1.9.7 unit tests only; nothing yet against a real service (`second-copies-real-service`).

**AP6. `src/claude-code` and `src/agents`**

- Don't: fix a Claude Code behaviour from a consumer's report while this container runs another CLI version.
- Why: 2026-10-30 "Four fixes released: cloud-folder 1.3.1, ssh-agent 1.2.0, claude-code 1.9.4, agents 2.1.1": the
  container ran 2.1.308, the consumer 2.1.314, so fork detection shipped modelled, not run. Seven claude-code patch
  releases in 6 days followed.
- Instead: reproduce on the consumer's CLI version (rebuild first), and record the CLI version in the entry and the NOTES.
- Caught by: nothing yet (`rebuild-claude-code-2-1-314` is a one-off; `agents-real-cli-canary` proposed).

**AP7. `src/agents`**

- Don't: let concurrent takers claim a lease with a plain `mkdir` and test it with a report line.
- Why: 2026-10-30 "Lease takeover fix agents 2.0.2 merged (PR #122)": a flaky test was the symptom of three races in the
  published 2.0.0; 2026-10-29 "PR #117 opened: lease race fix for the concurrent-takeover test".
- Instead: test the invariant (exactly one session), treat a flaky concurrency test as a bug report, relax only
  stale-report wording.
- Caught by: `test:agents-lease` (it fails inside the devhost, group 1).

**AP8. `src/agents`**

- Don't: special-case one CLI by name in the vendor-neutral Feature, or put a vendor feature (Remote Control) in its spec.
- Why: 2026-10-29 "Contract test suite for agents adapters, two fake CLIs"; 2026-10-29 "Design split agreed: Remote Control
  in the Claude adapter, session names in the agents spec".
- Instead: each adapter picks its route; the Feature relies on the verb's exit code (`supports` only answers "can it").
- Caught by: `test:agents-contract` (fails if agents names `claude`), ADR 0037, NFR-12 and NFR-13.

**AP9. `src/devcontainer-cli`**

- Don't: hold a host-wide build lock that does not say who holds it, or keep it when BuildKit build contexts make it
  unnecessary.
- Why: issue #154, 2026-11-03 "Build lock names its holder and is skipped with BuildKit build contexts (#154)": an `up`
  waited behind unrelated no-cache builds with no clue why.
- Instead: write a holder file, print who holds it and how many wait ("N waiting", not "N ahead", the mutex is not
  first-come); skip with one line on buildx 0.8.0 or later.
- Caught by: `test:build-lock`.

**AP10. `src/devcontainer-cli`**

- Don't: run `devcontainer up` before the engine answers or before the arguments are validated.
- Why: 2026-11-02 "Docker ps failures in two stacks traced to the engine, not a race"; 2026-11-02 "Engine wait before up and
  nameless dc:agent refusal".
- Instead: wait (bounded) for the engine, check the agent name first, and print the engine's own error text.
- Caught by: `test:engine-wait` (flaky, wall-clock based; `flaky-test-sweep`).

**AP11. `src/devcontainer-cli`**

- Don't: hide the engine's error or name only the first Feature that failed.
- Why: 2026-11-03 "Docker Desktop build error explained: mount path fault, not the repository" and 2026-11-02 "Docker ps
  failures..." ("Command failed" only).
- Instead: print docker's text and name the Docker Desktop backend for "mount path must be absolute" and "failed to connect
  to the backend".
- Caught by: nothing yet (`launcher-docker-backend-message`).

**AP12. `src/devcontainer-cli`**

- Don't: ship a launcher change that needs a consumer line without saying so at the moment it matters.
- Why: 2026-10-29 "cloud-folder:login built as one command..." (the root include line) and 2026-10-30
  "devcontainer-cli 1.16.2 launcher passes DCF_HOST_MACHINE..." (the containerEnv line).
- Instead: the launcher warns and prints the exact line when it is missing; the bootstrap prints the include.
- Caught by: launcher hint tests in `test:bootstrap`; the changelog's consumer action (`changelog-per-feature`) is the
  long-term home.

**AP13. `src/cloud-folder`**

- Don't: build on a mount's file semantics you have not probed (hard links, modes, rename, conflict names).
- Why: 2026-11-03 "Ledger and register storage location answered; shared-folder mirror blocked by hard links" and
  2026-11-03 "Ledgers 2026-10 and 2026-11 imported into the register (550 entries)": the design assumed a mirror that
  rclone FUSE cannot take; the architecture review of 2026-10-31 had flagged 0444 and conflict names.
- Instead: before choosing a store, run a probe on the target (`ln`, `mv`, `chmod`) and fall back to copy; sync mode when
  mount is wrong.
- Caught by: nothing yet (`register-store-no-hardlink`, upstream). Tag combination with `local-features/agentic-register`.

**AP14. `src/cloud-folder`**

- Don't: pin different rclone versions on the workstation and in the container, or leave a sign-in callback port open.
- Why: 2026-10-29 "Question answered: personal OneDrive mount for this repository" (the pasted token was rejected);
  2026-10-29 "Question answered: can the rclone callback port be dynamic".
- Instead: pin one version in `devcontainer.json`, verify the workstation zip against SHA256SUMS, and open 53682 only while
  signing in, through the launcher.
- Caught by: `test:cloud-folder-login` (default pin equal to the Feature's; listener closed after success, failure,
  timeout).

**AP15. `src/ssh-agent`**

- Don't: let a timed unlock outlive its lifetime by loading the same key again at start.
- Why: 2026-11-03 "ssh-agent 1.3.0 adds timed key unlock and key lock": an unprotected key unlocked with a lifetime is
  reloaded without a limit at the next start.
- Instead: timed unlock is for protected keys; say so in NOTES.
- Caught by: NOTES only; the backlog item for start-hook reload is open (entry 151's "Backlog").

**AP16. `src/openbao`**

- Don't: put raft storage on an rclone or OneDrive mount.
- Why: 2026-11-03 "Secrets master split proposal written": file storage is gone in OpenBao 2.7.0 and the live store cannot
  sit on the shared folder.
- Instead: live store on a volume, backed up to the shared folder.
- Caught by: nothing yet (proposal section 14; `secrets-master-split`).

**AP17. `combination` (Features with container tests)**

- Don't: hard-code a Feature version in a container test.
- Why: 2026-10-29 "PR #110 CI fix: container tests moved to agents 1.0.3" (twice in a day) and 2026-10-30 "CI friction
  fixes...".
- Instead: take the version from the harness.
- Caught by: `versions:check` in `task lint` (stopgap; `test-version-from-harness`).

**AP18. `combination` (any unit test)**

- Don't: read installed Feature state or the session's variables (share dirs, `MODE`, `CLOUD_FOLDER_*`) in a unit test.
- Why: 2026-11-03 "Build lock names its holder and is skipped with BuildKit build contexts (#154)": 31 of 83 failures that
  stop `task lint`, in 11 entries since 2026-10-30.
- Instead: the test sets its own environment and paths.
- Caught by: nothing yet (`lint-hermetic-unit-tests`).

**AP19. `combination` (tests)**

- Don't: match a short id in logged output, or time a test by wall-clock seconds.
- Why: 2026-10-29 "PR #112 opened: flaky wake test fixed; #111 lint failure traced to it" (the token hit a temp folder
  name); engine-wait failed on a timing flake in entries 151 and 156.
- Instead: match the exact call; use a fake clock or tick count.
- Caught by: nothing yet (`flaky-test-sweep`).

**AP20. `combination` (agent briefs)**

- Don't: let a con run `pkill -f` with a pattern its own shell contains, or share a log with other cons.
- Why: 2026-10-30 "Start hook no longer waits on ssh-add..." (killed its shell twice) after the guidance was written;
  review 2026-10-29 group 5.
- Instead: stop by pid; wait on your own jobs; hand back once.
- Caught by: the brief guidance in `CLAUDE.devhost.md` only (a classifier also refused a `pkill` on 2026-11-03); no test.

**AP21. `combination` (briefs for parallel slices)**

- Don't: let a docs or ruling con edit files another slice owns.
- Why: 2026-10-30 "Session names ruling recorded in #126, ADR 0041 and tests item corrected" (a con edited the agents
  NOTES and README that slice 3 was rewriting; the host took the edits out).
- Instead: the brief lists the files the con owns; one PR touches only its own.
- Caught by: host review; nothing yet (proposed clause, action 4).

**AP22. `combination` (records)**

- Don't: merge TODO.md or the ledger with a plain union, or rely on GitHub's server-side merge.
- Why: 2026-10-30 "PRs #118 and #119 merged to main" (three ticked items doubled); 2026-10-30 "claude-code 1.9.4 fix opened
  as PR #137"... and "PR #135 merged to main with main merged in" (GitHub could not merge TODO.md).
- Instead: the `devhost-todo` merge driver (loaded by `task repo:setup`) and merge main into a branch that touches
  TODO.md before it merges.
- Caught by: the `backlog_ids` guard in `devhost-verify`; the driver (#121, #123).

**AP23. `combination` (branches)**

- Don't: name a branch `feat/...`, or push code whose backlog item is only in uncommitted records.
- Why: 2026-10-29 "Agents 1.0.3: CLI capabilities in agents check pushed", 2026-10-29 "Agents 2.0 slice 1 built...",
  2026-11-02 "Devhost seed change committed and opened as PR #148" (three times); 2026-11-02 "Launcher engine-wait and agent-name
  fixes committed and opened as PR #147".
- Instead: `task devhost:branch -- <id>` (feature, fix, docs, chore) and commit the item with the change.
- Caught by: the pre-push hook, after the fact (`branch-task-push-check`).

**AP24. `combination` (records)**

- Don't: record a release, merge or tick from the host's report.
- Why: 2026-11-03 "claude-code 1.9.7 released with the fix for #155" and 2026-11-03 "Records PR #159 opened..." (the 1.18.1
  run was not confirmed); corrected entries on 2026-10-19.
- Instead: read the workflow run and the registry tag (needs `read:packages`, entry 139), then write.
- Caught by: nothing yet (`scribe-commit-verification`).

**AP25. `combination` (decisions)**

- Don't: settle a point in chat and leave the ADR or ledger listing it open; or apply a decision to an open PR without
  checking whether its release already shipped.
- Why: 2026-11-02 "Operator confirms the three open calls on the ledger register guard"; 2026-11-03 "Queue wording changed
  to 'N waiting' in PR #158 (1.18.1)" (1.18.0 had shipped).
- Instead: write the decision in the ADR or ledger at once; check the release before touching an open PR.
- Caught by: nothing yet.

**AP26. `combination` (shell, config edits)**

- Don't: redirect a command's output onto the file it reads.
- Why: 2026-10-31 "Auto-mode settings merged into Claude settings; 27 lines confirmed" (a split paste emptied
  `settings.json` before `jq` failed).
- Instead: back up, write a temp file, replace.
- Caught by: nothing; practice from 2026-10-29 "Factcheck folder trusted in the Claude config, backup kept".

**AP27. `combination` (seed and registry)**

- Don't: depend on a registry image for something you also ship locally.
- Why: 2026-11-02 "Why the devhost still looks published: moved out of the release, old image and seed starter remain".
- Instead: the seed carries `local-features/devhost` as files and the GHCR package is deleted.
- Caught by: ADR 0044.

**AP28. `local-features/devhost`**

- Don't: let the briefing be silent about the installed tooling being older than the source, or about a project in flight.
- Why: 2026-11-03 "Devhost restarted after the rebuild" and 2026-11-03 "Cloud folder and ledger-out-of-git project status reported".
- Instead: the briefing warns on version gaps and names the records-out-of-git project.
- Caught by: nothing yet (`restart-restore-report`).

**AP29. `local-features/agentic-register` with `combination`**

- Don't: import a Markdown ledger without a dry run and an entry count, or run `roster --key` without the `.pub`.
- Why: 2026-11-03 "Ledgers 2026-10 and 2026-11 imported into the register (550 entries)" (stray fences needed a workaround)
  and 2026-11-03 "Operator's key signed host, scribe and secretary onto the agent roster" (a traceback).
- Instead: dry run first, compare counts, keep the `.pub` beside the key.
- Caught by: nothing yet (`import-stray-fence`, `register-roster-traceback`).

## Best practices

**BP1. `src/claude-code`**

- Do: write the Claude Code trust entry through a temp file and a replace, with a backup, when `claude --bg` refuses an
  untrusted folder.
- Why: 2026-10-29 "Factcheck folder trusted in the Claude config, backup kept"; a nested git worktree needs its own entry
  (2026-10-29 "Trust for agent folders...").
- Instead of: hand edits. Caught by: `trust-agent-folders` (open) would make the adapter do it.

**BP2. `src/ssh-agent`**

- Do: keep the private key out of the container's disk, load it from stdin with a lifetime, sign with only the `.pub` present.
- Why: 2026-11-03 "Secrets master split proposal written" (tested on OpenSSH 10.0) and 2026-11-03 "ssh-agent 1.3.0 adds timed key
  unlock and key lock".
- Caught by: ssh-agent 1.3.0 tests (logging `ssh-add` wrapper).

**BP3. `combination` (tests)**

- Do: prove a fix with the test failing without it, stashing only the fix file.
- Why: 2026-10-29 "claude-code 1.8.7 wake fixes: stop before resume, saved flag order, PR #105" (the first mutation check stashed the
  test with the fix); 2026-11-02 "Engine wait before up..." (a copy of the bootstrap tree with main's file).
- Caught by: practice only.

**BP4. `combination` (tests)**

- Do: stub the engine, rclone, `fusermount3` and the clock so the unit test runs Docker-free and fast; use a pty for prompt cases.
- Why: 2026-10-29 "cloud-folder:login built as one command..." (fake rclone zip, `SO_REUSEADDR`); 2026-10-30 "cloud-folder 1.3.1..."
  (a fake rclone writing 100000 lines to catch SIGPIPE).
- Caught by: `test:cloud-folder-login`, `test:cloud-folder-unit`, `test:build-lock`.

**BP5. `combination` (design review)**

- Do: check a review finding against the ADR list before accepting it, and run the architecture review before the ruling.
- Why: 2026-10-29 "PR #115 opened: architecture review before every ruling" (the subagent said NFR-11 and NFR-12 had no ADR; they
  have 0035 and 0037); 2026-10-31 "Architecture review of the records-out-of-git proposal: fit with changes" (it found a
  private repository was never weighed).
- Caught by: ADR 0039 and the architecture-review skill.

**BP6. `combination` (records, merges)**

- Do: test a merge driver in a scratch repository with a real merge, and check the guard against the doubled lines it
  can produce.
- Why: 2026-10-29 "Review changes applied: union merge, duplicate-id guard..." (a union merge can duplicate a line when both sides edit it).
- Caught by: `backlog_ids` tests in `test:devhost`.

**BP7. `combination` (diagnosis)**

- Do: write "cause not proven" when the cause is not proven, and check a blame against the evidence before filing it.
- Why: 2026-10-30 "Start failure traced to cloud-folder post-start and ssh passphrase wait" was wrong (the hook took 0.08 s) and
  was corrected the same day; 2026-10-30 "host-restart-copy fix committed..." said the cause was not proven.
- Caught by: the `Corrects:` line; nothing stops a first wrong entry.

**BP8. `combination` (after a rebuild or a new container)**

- Do: list what the new container lost before working (gh sign-in, memory, user settings, `rclone.conf`, the unlocked key,
  held stretches).
- Why: 2026-10-31 "Devhost back up on fresh container, status reported", "gh login restored...", "FUSE checked: usable...".
- Caught by: nothing yet (`restart-restore-report`, `claude-state-survives`).

**BP9. `combination` (storage)**

- Do: apply the four storage tiers: if losing a machine would lose something, it is in the wrong tier.
- Why: 2026-11-03 "Storage tiers adopted as governance; ADR staked"; 2026-10-31 "Records-out-of-git design proposal drafted".
- Caught by: ADR 0045.

**BP10. `combination` (Docker-free design, reference architecture seed)**

- Do: split a contract into "can it" (a side-effect-free `supports` answer) and "do it" (the verb's exit code as the
  run-time authority), and test that the two agree.
- Why: 2026-10-29 "Decision: keep the supports verb" and 2026-10-29 "Agents 1.0.3: CLI capabilities in agents check pushed".
- Caught by: `test:agents-contract`.

---

## Reading notes for the host

- Counts per group are by hand and overlap (an entry can sit in two groups); read them as "about".
- The entry numbers in Part 0 refer to the numbering in `condensed.md` (1 to 165, in file order).
- Every claim about a backlog item's state was read from `TODO.md` on disk at review time (working tree with the
  secretary's uncommitted additions; the briefing counts 208 open items and 41 decisions).
