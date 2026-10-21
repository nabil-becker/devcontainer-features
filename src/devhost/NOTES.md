## What it is

The way of working of this collection's consumer repositories, installable. Six words:

- **Devhost**: the dev container as the place where sessions run and the backs act.
- **Workstation**: the person's own machine outside the devhost; the backs' hooks do nothing there.
- **Host session**: the one Claude Code session per repository, started by `claude-host` (claude-code Feature, `HOST_SESSION`); the main inter.
- **Inter** (interface agent): an agent that works with a person, directly or through another inter.
- **Con** (consult agent): a sub-agent the host briefs for one job; its reply is a hand-off.
- **Back** (background agent): an agent that never works with a person; after each turn and each con's job it reads what was done and keeps one record current, on its own model, inside the devhost only.
- **Stake**: one plain line anyone leaves in a session for a back, `Stake for the <back>: <what> needs <what>.`, on a line of its own; lifted to the top of what every back reads and treated as an explicit request.
- **Quiet notice**: how a back reports: one line of context on the inter's next turn (`Back <job> (quiet notice ...)`), never a message to the person; the inter reads the change before the next commit and mentions it only when asked, when it is wrong, or when the person must act.

## Hooks

The hooks a repository puts in `.claude/settings.json` (`task devhost:init` writes them). Every back runs async from `Stop` (the host session) and, the scribe and the librarian, from `SubagentStop` (a con's own transcript); the briefing runs at `SessionStart`. Timeouts and `async` as the originals:

```json
"hooks": {
  "SessionStart": [
    {"hooks": [{"type": "command", "command": "devhost-briefing", "timeout": 30}]}
  ],
  "Stop": [
    {"hooks": [
      {"type": "command", "command": "devhost-run-job scribe", "async": true, "timeout": 600},
      {"type": "command", "command": "devhost-run-job librarian", "async": true, "timeout": 600},
      {"type": "command", "command": "devhost-run-job secretary", "async": true, "timeout": 600},
      {"type": "command", "command": "devhost-run-job tester", "async": true, "timeout": 600}
    ]}
  ],
  "SubagentStop": [
    {"hooks": [
      {"type": "command", "command": "devhost-run-job scribe", "async": true, "timeout": 600},
      {"type": "command", "command": "devhost-run-job librarian", "async": true, "timeout": 600}
    ]}
  ]
}
```

The briefing (`devhost-briefing`) also warns, in one line, when the repository has `src/devhost/devcontainer-feature.json` whose `version` is newer than the installed devhost (`$DEVHOST_SHARE/VERSION`, default `/usr/local/share/devhost/VERSION`; versions compared numerically): the backs run the installed devhost, so a fix in `src/devhost` is not live until the container is rebuilt. It says nothing when the versions are equal, when either is missing, or in a repository without `src/devhost`. It also warns, in one line, when `gh` is installed (`DEVHOST_GH` overrides the command, as for `devhost-branches`) and `gh auth status` fails or git has no credential helper for github.com (`credential.https://github.com.helper` or `credential.helper`), naming `gh auth login --web --git-protocol https` and `gh auth setup-git`; it says nothing when all is well or gh is absent. The cost report (`devhost-report`, and the briefing's spend line) counts as ledger corrections only the `- **Corrects:**` lines that name an entry; `Corrects: none` is not one. The report is built from a store committed beside it (`costs-YYYY-MM-<engineer>.jsonl`, one line per priced reply or back run, ids and numbers only) merged with this machine's transcripts and `runs.jsonl`, so a rebuild that empties those volumes no longer shrinks the month; a `baseline` line in the store carries figures whose records were lost before the store existed.

The runner reads the hook's JSON on stdin (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, and for `SubagentStop` `agent_id`, `agent_transcript_path`, `agent_type`), and prints the quiet notice as `{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": "Back <job> (quiet notice, do not relay unless asked or wrong): ..."}}` only when the back changed something. It exits 0 always: on a workstation (no container marker), inside a back's own `claude` run (`DEVHOST_JOB_CHILD`), when the job's lock is held, when too little is new, or when the job file is missing, it does nothing and says nothing. Sessions on a workstation where the Feature is absent get "command not found" from the hook; wrap the command as `command -v devhost-run-job >/dev/null && devhost-run-job scribe || true` if sessions run there too.

## The backs

- **scribe** (`SCRIBE_MODEL`, haiku): on `Stop` and `SubagentStop`, once 1500 new condensed characters are in (or a stake names it), and not more than once every 120 s unless four times that is new. Reads the new stretch of the transcript, the tail of the ledger and the units it held back last time; prints entries for finished units of work; the job fills the first entry's Measures line with the stretch's cost from the transcripts (`devhost-costs --measures`; "not measured" when that tool is absent) and points the stretch's other entries to it, so summing the ledger counts each stretch once; it keeps the PENDING line as `;`-separated items and drops one that comes back unchanged three runs in a row (`share/python/pending.py`, counts in `counts-pending-<session id>`), logging the drop; it drops a `Corrects: none` line (the ledger guard refuses one), passes everything through the name guard and appends to `$DEVHOST_LEDGER_DIR/YYYY-MM.md` (created with a `# Ledger, YYYY-MM` line). Append-only by construction: the model never touches the file. No guard needed.
- **secretary** (`SECRETARY_MODEL`, haiku): on `Stop` only, same thresholds. The model edits `$DEVHOST_BACKLOG` itself with `Read` and `Edit` on that one file (`Bash` off): adds items (`- [ ] **slug Title** (owner). ... Added YYYY-MM-DD.`) under Now/Next, decisions under `## Decisions for the Operator`, ticks finished items. The backlog guard (`guards.py backlog`) undoes a run that deleted, reworded or reordered a line; then the name guard runs on the file.
- **librarian** (`LIBRARIAN_MODEL`, sonnet): on `Stop` and `SubagentStop`, after 8000 new characters and ten minutes between runs for a session, after 8000 characters for a con's `SubagentStop` (`JOB_MIN_CHARS_SUB`; a stake wakes it). Edits `$DEVHOST_LEXICON`, `$DEVHOST_ADR_DIR/**` and (add-only, where `ontology.toml` exists) `$DEVHOST_MODEL_DIR/**` with `Read`, `Glob`, `Grep`, `Edit` (`Bash` off): new terms in the lexicon's style, new ADRs from the folder's `0000-template.md`, an index row in its `README.md`, a `superseded by` status on a replaced ADR. The docs guard (`guards.py docs`) restores the snapshot when an existing lexicon line, model line or ADR changed beyond its Status row, or left a model `.toml` file that does not parse (whatever the snapshot held); the name guard runs on the lexicon and every new ADR.
- **tester** (`TESTER_MODEL`, none: cost 0 on its metrics line): on every `Stop`. Hashes the code under `TESTER_PATHS` (HEAD, the diff and untracked files; names, sizes and times outside git) and, when it changed since its last run, runs `TESTER_CMD` (`task test` when the root Taskfile has a `test` task; nothing otherwise, logged once) with `DEVHOST_JOB_CHILD=1` under `TESTER_TIMEOUT`. Speaks only when the suite is red (`tests red (...): N failed, first: ...`) or green again after red. A suite the environment cannot run (the Taskfile's "precondition not met" / "no Docker daemon here" output, or no Docker daemon for the default `task test`) is `skipped`, not red: one quiet notice when it first becomes skipped, then silence, and a previous red stays red (`last_real`); any other `TESTER_CMD` failure is red; a timed-out run keeps no hash and tries again after the next turn.

All four: one `claude -p --model <model> --settings '{"disableAllHooks": true}' --no-session-persistence --output-format json` run under a 540 s timeout (none for the tester), the stretch condensed by `devhost-condense` (the engineer's words, the inter's visible replies, which tools ran with their paths or commands, cons' hand-backs; never thinking or tool output; the latest 40 000 characters), the offset advanced only when the run ended `changed` or `nothing`, one metrics line per run in `runs.jsonl` (time, job, mode, agent type, session, engineer, model, stretch size, stakes, status, guard undos, duration, cost, tokens). Sub-agents of the kinds in `DEVHOST_JOB_SKIP_AGENTS` (read-only lookups) are not jobs.

## Commit-time guards

`devhost-verify` runs the guards listed in the docstring of `share/python/verify.py` (ledger append-only, against the merge base of HEAD and the base ref so a branch behind it is not blamed for the base's new lines, and shape, with `Corrects: none` refused in entries dated 2026-10-19 or later; no merge-conflict marker at the start of a line in a tracked text file; secrets, forbidden words, ADR shape, Taskfile descriptions, skill frontmatter, hook modes, model). In a repository that carries the devhost's own source (`src/devhost/share/python/verify.py`, this collection), `devhost-verify` runs those source guards instead of the installed ones, so the hook, the task and a plain call all check a branch with the guards it changes. `hook_modes` refuses any tracked file in `core.hooksPath` whose index mode is not 100755, naming the file and the fix (`git update-index --chmod=+x <file>` plus `chmod +x`); no hooks path, or an untracked one, passes quietly. `forbidden_words` skips the files listed in `.devhost/name-exceptions.txt` (tracked, one repository-relative path per line, `#` comments): the Operator's approved exceptions, such as a published paper that carries its byline; paths only, never a name. `model` is quiet without `docs/model/ontology.toml`; with it, it checks the TOML, ids, types, relations, theme keys, the lexicon's bold terms against the ids' `term`s, and the Mermaid node ids of `docs/model/*.md` (an id, or `external-*`), each finding naming file:line and the fix.

## State

`DEVHOST_STATE` (`/var/lib/devcontainer-features/devhost`, the named volume `devhost-state-${devcontainerId}`) holds `<job>/offsets/<session id>` (how far each back has read each transcript), `<job>/lock`, `<job>/job.log`, `<job>/pending-<session id>`, `counts-pending-<session id>` and `since-<session id>` (the scribe), `tester/code_hash` and `last_result`, and `runs.jsonl`. Nothing of it belongs in the checkout, so a synced checkout never carries it and the ledger diff is only the entries. The post-create hook (`devhost-setup`, also `task devhost:setup`) creates the directory and hands it to the remote user through `dcf-persist`, and reports what backs it; for the host disk, bind-mount a host folder on the same target as the other Features of this collection do. `task devhost:log` tails every `job.log`; `task devhost:jobs:state` lists sessions read, pending items, held locks and the tester's last verdict.

## The site

`devhost-site` (`task devhost:site`, variables `OUT` and `PRS=1`) turns the repository's tracked docs and records into **one self-contained HTML page**, so the Operator reads the backlog, the ledger, the Features, the records and every doc in a browser, on a phone too, instead of the terminal or raw markdown. It is built in two halves on purpose:

- **The generator** (`share/python/site.py`, template `share/python/templates/site/index.html`): standard library only, deterministic (the same tree gives the same bytes, except `meta.generated`). It reads the working-tree content of `git ls-files`, builds one JSON document (what needs the Operator, backlog, ledger with corrections linked, cost headlines, Features, ADRs, proposals, night-shift reports, journal, optionally the open pull requests via `gh`, and every `*.md`), passes every string through the name guard (`devhost_common.redact_text`, the rule of `devhost-redact`) and embeds it in the page as `<script type="application/json" id="site-data">` with `<` escaped, so no document can end the script. The page renders everything client-side, fetches nothing (markdown comes from `marked` and `DOMPurify`, diagrams from `mermaid`, pinned on cdnjs), routes with plain hash tokens (`#home`, `#backlog`, `#ledger~<entry>`, `#d~docs~adr~0001-x.md`) and searches the title and text of every doc.
- **The host adapter**: the `publish-site` skill runs `task devhost:site PRS=1` and publishes `.devhost/site/index.html` with the Artifact tool (first time with the icon `home`, afterwards updating the URL kept in `.devhost/site-url`; both paths are ignored by git). Claude artifacts are only an easy site host. The output is a **fragment** (`<title>`, `<style>`, markup, scripts; no `html`, `head` or `body`) because that host wraps it; `devhost-site --standalone` writes a full document for any other host (GitHub Pages, a file share), which takes the same data and page unchanged.

Publishing is outward-facing: the skill runs only on the Operator's ask, never in a night shift, and an artifact is private until the Operator shares it. `task docs` regenerates this Feature's README from this file.

## Branches

Every branch is named `<type>/<backlog-id>/<n>`: `<type>` is `feature`, `fix`, `docs` or `chore`; `<backlog-id>` is an id of an item in `TODO.md` (the word after `**`, ticked or not); `<n>` is the workstream number, always present, from 1 (a parallel stream on the same item, such as a subagent in a worktree, takes the next number). `main`, `HEAD` and tags are exempt. A branch covering several items is named for the main one, the pull request lists all ids and commits name their own. Work with no item gets one first; the backs' records use the standing item `records`.

`devhost-branches` (tasks `devhost:branch` and `devhost:branches`):

- `task devhost:branch -- <backlog-id> [type]` refuses an id that is not in `TODO.md`, fetches, and creates `<type>/<id>/<n>` from `origin/main` (no upstream is set, so a plain push never targets `main`) with the next free `<n>` over local and remote branches.
- `task devhost:branches` lists every local and remote branch: its item and title (or "not an item" / "name breaks the rule"), its pull request state (one `gh pr list --state all` call; "unknown" without a logged-in `gh`; `DEVHOST_GH` names another command) and what it still adds to `main`, from `git merge-tree --write-tree` and `git diff --shortstat`, which sees through a squash merge where `git branch --merged` does not.
- `PRUNE=1` deletes, locally and on `origin`, only a branch that adds nothing and whose pull request merged (or that `main` contains), plus the worktree of a branch it deletes. It keeps the current branch, `main`, any branch that adds something, and says why. Run it after every merge.
- The briefing carries one line when a branch has work and no pull request, a merged one was left behind, or a name breaks the rule (quiet otherwise; without `gh` the pull-request counts are skipped and the line says so). The shutdown check reports unfinished work as a finding and a merged branch as a note.
- The `pre-push` hook (`task devhost:init` writes `.githooks/pre-push`, calling `devhost-branches --check-push`) refuses a push of a branch whose name breaks the rule or whose id is not in `TODO.md`, and a push to a branch whose pull request merged (a push recreates the branch and its commits miss `main`); the fix is a new branch from `origin/main` with the next `<n>`. Deleting a remote branch is always allowed. With `gh` unavailable it warns and skips the merged check.

Renaming a branch on GitHub closes the pull requests whose head is that branch (found 2026-10-20: #9 and #29 closed and were reopened as #30 and #31). A branch with an open pull request is renamed by pushing the new name, opening a new pull request that says it replaces the old one, and closing the old one.

## Shutdown

The dev container specification has no stop hook, so shutdown is three pieces (ADR 0015). `devhost-shutdown-check` (`share/python/shutdown.py`, `task devhost:shutdown-check`) tests the rules that can be written down and prints one `NOT READY` line per finding, exit 1; exit 0 and `ready to stop` when none fails. Its rules: the working tree has no changed or untracked file (ignored files do not count); the current branch has an upstream and no commit it lacks (no upstream, or a detached HEAD, is a finding); no `$DEVHOST_STATE/<job>/lock` is held (tried with `flock` without blocking, never created; the tester's lock reads as a test run in progress); no `<job>/pending-<session id>` file is non-empty (a stretch waiting to be logged); and the newest dated report in `DEVHOST_NIGHT_SHIFT_DIR` is not mid-plan (its `Result:` line is missing or has no `Ended`, or an item still reads `: planned`). Stashes are listed as notes. A new back or lock needs a rule here. The personal skill `walkie-talkie` (a run of messages started by `/walkie-talkie`, "hold on" or "wait": acknowledge each in one line, act on all at the word "over"; `.claude/skills/over/`, shipped by `devhost-init`, not in the seed's default skills) is separate. The skills `shutdown-devhost` (close the work, run the check, wait for the backs, ask about a night shift, name the stop command, report) and `restart-devhost` ship with `devhost-init`; `task devcontainer:stop` (the devcontainer-cli Feature's host tasks) runs the check inside the container before it stops it.

## Settings

Every script reads the same variables; a repository overrides them in `containerEnv` (or `.devcontainer/.env`), none needs a rebuild. Paths are relative to the root unless absolute.

| Variable | Default | What |
|---|---|---|
| `DEVHOST_ROOT` | `$CLAUDE_PROJECT_DIR`, else the hook's cwd or its nearest ancestor holding `.claude/settings.json` | The repository the backs keep; when set, it must hold `.claude/settings.json` or the backs stay quiet |
| `DEVHOST_STATE` | `/var/lib/devcontainer-features/devhost` | Job state (offsets, locks, logs, pending files, `runs.jsonl`); set by the Feature's `containerEnv` |
| `DEVHOST_LEDGER_DIR` | `docs/ledger` | Monthly ledger files `YYYY-MM.md` (scribe) |
| `DEVHOST_BACKLOG` | `TODO.md` | The to-do list with `## Now`, `## Next`, `## Decisions for the Operator` (secretary) |
| `DEVHOST_LEXICON` | `LEXICON.md` | The way-of-working words (librarian) |
| `DEVHOST_ADR_DIR` | `docs/adr` | Architecture decision records, with `0000-template.md` and an index `README.md` (librarian) |
| `DEVHOST_MODEL_DIR` | `docs/model` | The ontology (`ontology.toml`), theme labels and C4 views; the `model` guard checks them when `ontology.toml` exists (librarian adds) |
| `DEVHOST_NIGHT_SHIFT_DIR` | `docs/night-shift` | Night-shift reports (the briefing and report tools) |
| `DEVHOST_SHARE` | `/usr/local/share/devhost` | The installed devhost (its `VERSION` file is what the briefing compares with `src/devhost`) |
| `DEVHOST_JOBS_DIR` | `/usr/local/share/devhost/jobs` | Where `devhost-run-job <job>` finds `<job>/job.sh`; a repository's own set, same layout |
| `DEVHOST_JOB_CHILD` | unset | Set to `1` by the runner for the back's own `claude` and for the test suite, so nothing they start can start a back |
| `DEVHOST_CONTAINER_MARKERS` | `/.dockerenv /run/.containerenv` | Files whose presence means "inside a container"; the backs act only then |
| `DEVHOST_JOB_SKIP_AGENTS` | `Explore claude-code-guide statusline-setup` | Sub-agent types whose runs are not jobs |
| `DEVHOST_JOB_QUIET_SECS` | per job (120; librarian 600; tester 0) | Minimum seconds between two runs of one job, unless much is new or a stake names it |
| `DEVHOST_ENGINEER` | `operator` | A stable, non-identifying handle for whose machine this is, on the metrics line, in the entries and the cost report's file name. Never derived from git (the handle is committed and a git name may be a person's name); set it per engineer, e.g. `DEVHOST_ENGINEER=alice-laptop`, via the devcontainer `containerEnv` |
| `DEVHOST_REVIEW_EVERY` | `25` | Ledger entries since the last review at which the briefing says a review is due. The cost report's entry rate (per day, per week, days per review) shows whether that is too often or too rarely |
| `DEVHOST_MONTHLY_TARGET` | unset | A monthly list-price spend in dollars to measure against. The cost report adds a line "Spend $X of the $N target (Y%), a tracking point, not a cap." and the briefing's spend line says "of the $N target"; nothing warns, colours or blocks |
| `SCRIBE_MODEL`, `SECRETARY_MODEL`, `LIBRARIAN_MODEL`, `TESTER_MODEL` | `haiku`, `haiku`, `sonnet`, `none` | The model each back runs on |
| `TESTER_CMD` | `task test` when the root Taskfile lists a `test` task, else nothing | The test command the tester runs |
| `TESTER_PATHS` | `src tests scripts` | What the tester hashes to decide whether code changed |
| `TESTER_TIMEOUT` | `900` | Seconds the suite may take |
| `DEVHOST_REDACT_FILE` | `.devhost/redact-names.txt` | Ignored by git, one name per line (`#` comments); each replaced whole-word, case-insensitively, by `DEVHOST_REDACT_WITH` in everything a back writes |
| `DEVHOST_REDACT_WITH` | `the Operator` | The replacement (a possessive keeps its `'s`) |
| `DEVHOST_FORBIDDEN_WORDS` | empty | `;`-separated words (a client's name) replaced wherever they occur, inside a longer word too; the same list `devhost-verify` refuses at commit time |

`devhost-redact [file ...]` applies both lists to files in place (stdin to stdout without files); `devhost-condense <transcript.jsonl> <offset> [session|sub]` prints a stretch, for reading what a back read.

## The iteration package

`devhost-package` (`share/python/package.py`, `task devhost:package -- --iteration N --paper <file>`) assembles the seed an iteration exports (ADR 0008, `docs/proposals/iteration-package.md`): into a fresh folder (default `docs/iterations/export/`) it puts `papers/` (every paper of the package received, byte for byte and checked against that package's `PACKAGE.md`; the papers kept in `docs/iterations/papers/`; the new paper), `foundation/<repository path>` (the files named in the manifest `docs/iterations/foundation.txt`: one repository-relative path per line, `#` comments, `!path` for a file copied untouched) and a `PACKAGE.md` listing the iteration, the date, every file with its sha256 and kind (paper, original, derived, foundation) and the instruction that the folder is the source of the next export and must not be deleted. Front matter (iteration, date, sources) is added only to a Markdown file that has none and is not a received paper or an original; the script never touches a non-Markdown file. It refuses with exit 2, writing nothing, a missing manifest or entry, an output folder that is not empty, a received package with no `PACKAGE.md` and a received paper that is gone or whose hash changed. The package is a seed: it also carries, untouched (kind `original`), the seed's `README.md` at the root (`--readme`, default `docs/iterations/seed/README.md`), `starter/` (`--starter`, default `docs/iterations/starter`) and `skills/<name>/` for each skill of `--skills` (default `plant-a-seed,drop-a-seed,ledger-review,shutdown-devhost,restart-devhost`, copied from `.claude/skills/`); a missing one is refused. Options `--received`, `--papers`, `--foundation`, `--readme`, `--starter`, `--skills`, `--out`, `--date`. The judgement work (the closing interview, the paper, what is foundational) is the `drop-a-seed` skill, which hands its `journalist.md` brief to a writing subagent; both ship like the other skills by `devhost-init` (`.claude/skills/drop-a-seed/`).

## Pairs with

- `ghcr.io/nabil-becker/devcontainer-features/claude-code`: `claude` itself and `claude-host`, which starts or resumes the host session by UUID (`HOST_SESSION`); the backs run the same `claude` headless. The session transcripts under `CLAUDE_CONFIG_DIR` are what the condenser and the cost tools read.
- `ghcr.io/nabil-becker/devcontainer-features/git`: its wrapper keeps `GIT_DIR`/`GIT_WORK_TREE` out of linked worktrees and of test fixtures, so a tester run or a con's worktree never commits onto the main checkout (a mistake the ledger of the original recorded).
- `ghcr.io/nabil-becker/devcontainer-features/go-task`: `task devhost:*` (version, setup, log, jobs:state, briefing, report, costs, adr, package, verify, shutdown-check, init), and `task test` as the tester's default command.
- `ghcr.io/devcontainers/features/python` or the base image's `python3` (standard library only; apt installs it when absent).
