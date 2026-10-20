
# Devhost (host session, backs, ledger) (devhost)

The way of working of this collection's consumer repositories as an installable Feature: one host Claude Code session per repository (claude-host, from the claude-code Feature), cons (sub-agents) and backs - background agents that run from Claude Code's Stop and SubagentStop hooks after every turn and keep the ledger (scribe), the backlog (secretary) and the lexicon and ADRs (librarian) without the person waiting, plus a model-free tester that runs the suite when code changed. Installs devhost-run-job (the runner), the four jobs with their briefs and guards, the name guard (devhost-redact), the transcript condenser (devhost-condense), the briefing, cost report, ADR, verify and init tools, a named volume at DEVHOST_STATE (/var/lib/devcontainer-features/devhost) for the jobs' offsets, locks, logs and metrics, a post-create hook (devhost-setup) that makes it usable and reports whether the repository is wired, and the Feature Taskfile (task devhost:init scaffolds a repository). Every path and model is a DEVHOST_* / <JOB>_MODEL variable with a default. Needs python3 (standard library only; installed with apt when missing) and claude on PATH.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/devhost:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |

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

The briefing (`devhost-briefing`) also warns, in one line, when the repository has `src/devhost/devcontainer-feature.json` whose `version` is newer than the installed devhost (`$DEVHOST_SHARE/VERSION`, default `/usr/local/share/devhost/VERSION`; versions compared numerically): the backs run the installed devhost, so a fix in `src/devhost` is not live until the container is rebuilt. It says nothing when the versions are equal, when either is missing, or in a repository without `src/devhost`. The cost report (`devhost-report`, and the briefing's spend line) counts as ledger corrections only the `- **Corrects:**` lines that name an entry; `Corrects: none` is not one.

The runner reads the hook's JSON on stdin (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, and for `SubagentStop` `agent_id`, `agent_transcript_path`, `agent_type`), and prints the quiet notice as `{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": "Back <job> (quiet notice, do not relay unless asked or wrong): ..."}}` only when the back changed something. It exits 0 always: on a workstation (no container marker), inside a back's own `claude` run (`DEVHOST_JOB_CHILD`), when the job's lock is held, when too little is new, or when the job file is missing, it does nothing and says nothing. Sessions on a workstation where the Feature is absent get "command not found" from the hook; wrap the command as `command -v devhost-run-job >/dev/null && devhost-run-job scribe || true` if sessions run there too.

## The backs

- **scribe** (`SCRIBE_MODEL`, haiku): on `Stop` and `SubagentStop`, once 1500 new condensed characters are in (or a stake names it), and not more than once every 120 s unless four times that is new. Reads the new stretch of the transcript, the tail of the ledger and the units it held back last time; prints entries for finished units of work; the job fills each entry's Measures line with the cost from the transcripts (`devhost-costs --measures`; "not measured" when that tool is absent), passes everything through the name guard and appends to `$DEVHOST_LEDGER_DIR/YYYY-MM.md` (created with a `# Ledger, YYYY-MM` line). Append-only by construction: the model never touches the file. No guard needed.
- **secretary** (`SECRETARY_MODEL`, haiku): on `Stop` only, same thresholds. The model edits `$DEVHOST_BACKLOG` itself with `Read` and `Edit` on that one file (`Bash` off): adds items (`- [ ] **slug Title** (owner). ... Added YYYY-MM-DD.`) under Now/Next, decisions under `## Decisions for the Operator`, ticks finished items. The backlog guard (`guards.py backlog`) undoes a run that deleted, reworded or reordered a line; then the name guard runs on the file.
- **librarian** (`LIBRARIAN_MODEL`, sonnet): on `Stop` and `SubagentStop`, after 8000 new characters and ten minutes between runs for a session, after 8000 characters for a con's `SubagentStop` (`JOB_MIN_CHARS_SUB`; a stake wakes it). Edits `$DEVHOST_LEXICON` and `$DEVHOST_ADR_DIR/**` with `Read`, `Glob`, `Grep`, `Edit` (`Bash` off): new terms in the lexicon's style, new ADRs from the folder's `0000-template.md`, an index row in its `README.md`, a `superseded by` status on a replaced ADR. The docs guard (`guards.py docs`) restores the snapshot when an existing lexicon line or ADR changed beyond its Status row; the name guard runs on the lexicon and every new ADR.
- **tester** (`TESTER_MODEL`, none: cost 0 on its metrics line): on every `Stop`. Hashes the code under `TESTER_PATHS` (HEAD, the diff and untracked files; names, sizes and times outside git) and, when it changed since its last run, runs `TESTER_CMD` (`task test` when the root Taskfile has a `test` task; nothing otherwise, logged once) with `DEVHOST_JOB_CHILD=1` under `TESTER_TIMEOUT`. Speaks only when the suite is red (`tests red (...): N failed, first: ...`) or green again after red. A suite the environment cannot run (the Taskfile's "precondition not met" / "no Docker daemon here" output, or no Docker daemon for the default `task test`) is `skipped`, not red: one quiet notice when it first becomes skipped, then silence, and a previous red stays red (`last_real`); any other `TESTER_CMD` failure is red; a timed-out run keeps no hash and tries again after the next turn.

All four: one `claude -p --model <model> --settings '{"disableAllHooks": true}' --no-session-persistence --output-format json` run under a 540 s timeout (none for the tester), the stretch condensed by `devhost-condense` (the engineer's words, the inter's visible replies, which tools ran with their paths or commands, cons' hand-backs; never thinking or tool output; the latest 40 000 characters), the offset advanced only when the run ended `changed` or `nothing`, one metrics line per run in `runs.jsonl` (time, job, mode, agent type, session, engineer, model, stretch size, stakes, status, guard undos, duration, cost, tokens). Sub-agents of the kinds in `DEVHOST_JOB_SKIP_AGENTS` (read-only lookups) are not jobs.

## Commit-time guards

`devhost-verify` runs the guards listed in the docstring of `share/python/verify.py` (ledger append-only and shape, secrets, forbidden words, ADR shape, Taskfile descriptions, skill frontmatter, hook modes). `hook_modes` refuses any tracked file in `core.hooksPath` whose index mode is not 100755, naming the file and the fix (`git update-index --chmod=+x <file>` plus `chmod +x`); no hooks path, or an untracked one, passes quietly. `forbidden_words` skips the files listed in `.devhost/name-exceptions.txt` (tracked, one repository-relative path per line, `#` comments): the Operator's approved exceptions, such as a published paper that carries its byline; paths only, never a name.

## State

`DEVHOST_STATE` (`/var/lib/devcontainer-features/devhost`, the named volume `devhost-state-${devcontainerId}`) holds `<job>/offsets/<session id>` (how far each back has read each transcript), `<job>/lock`, `<job>/job.log`, `<job>/pending-<session id>` and `since-<session id>` (the scribe), `tester/code_hash` and `last_result`, and `runs.jsonl`. Nothing of it belongs in the checkout, so a synced checkout never carries it and the ledger diff is only the entries. The post-create hook (`devhost-setup`, also `task devhost:setup`) creates the directory and hands it to the remote user through `dcf-persist`, and reports what backs it; for the host disk, bind-mount a host folder on the same target as the other Features of this collection do. `task devhost:log` tails every `job.log`; `task devhost:jobs:state` lists sessions read, pending items, held locks and the tester's last verdict.

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
| `DEVHOST_NIGHT_SHIFT_DIR` | `docs/night-shift` | Night-shift reports (the briefing and report tools) |
| `DEVHOST_SHARE` | `/usr/local/share/devhost` | The installed devhost (its `VERSION` file is what the briefing compares with `src/devhost`) |
| `DEVHOST_JOBS_DIR` | `/usr/local/share/devhost/jobs` | Where `devhost-run-job <job>` finds `<job>/job.sh`; a repository's own set, same layout |
| `DEVHOST_JOB_CHILD` | unset | Set to `1` by the runner for the back's own `claude` and for the test suite, so nothing they start can start a back |
| `DEVHOST_CONTAINER_MARKERS` | `/.dockerenv /run/.containerenv` | Files whose presence means "inside a container"; the backs act only then |
| `DEVHOST_JOB_SKIP_AGENTS` | `Explore claude-code-guide statusline-setup` | Sub-agent types whose runs are not jobs |
| `DEVHOST_JOB_QUIET_SECS` | per job (120; librarian 600; tester 0) | Minimum seconds between two runs of one job, unless much is new or a stake names it |
| `DEVHOST_ENGINEER` | `operator` | A stable, non-identifying handle for whose machine this is, on the metrics line, in the entries and the cost report's file name. Never derived from git (the handle is committed and a git name may be a person's name); set it per engineer, e.g. `DEVHOST_ENGINEER=alice-laptop`, via the devcontainer `containerEnv` |
| `SCRIBE_MODEL`, `SECRETARY_MODEL`, `LIBRARIAN_MODEL`, `TESTER_MODEL` | `haiku`, `haiku`, `sonnet`, `none` | The model each back runs on |
| `TESTER_CMD` | `task test` when the root Taskfile lists a `test` task, else nothing | The test command the tester runs |
| `TESTER_PATHS` | `src tests scripts` | What the tester hashes to decide whether code changed |
| `TESTER_TIMEOUT` | `900` | Seconds the suite may take |
| `DEVHOST_REDACT_FILE` | `.devhost/redact-names.txt` | Ignored by git, one name per line (`#` comments); each replaced whole-word, case-insensitively, by `DEVHOST_REDACT_WITH` in everything a back writes |
| `DEVHOST_REDACT_WITH` | `the Operator` | The replacement (a possessive keeps its `'s`) |
| `DEVHOST_FORBIDDEN_WORDS` | empty | `;`-separated words (a client's name) replaced wherever they occur, inside a longer word too; the same list `devhost-verify` refuses at commit time |

`devhost-redact [file ...]` applies both lists to files in place (stdin to stdout without files); `devhost-condense <transcript.jsonl> <offset> [session|sub]` prints a stretch, for reading what a back read.

## Pairs with

- `ghcr.io/nabil-becker/devcontainer-features/claude-code`: `claude` itself and `claude-host`, which starts or resumes the host session by UUID (`HOST_SESSION`); the backs run the same `claude` headless. The session transcripts under `CLAUDE_CONFIG_DIR` are what the condenser and the cost tools read.
- `ghcr.io/nabil-becker/devcontainer-features/git`: its wrapper keeps `GIT_DIR`/`GIT_WORK_TREE` out of linked worktrees and of test fixtures, so a tester run or a con's worktree never commits onto the main checkout (a mistake the ledger of the original recorded).
- `ghcr.io/nabil-becker/devcontainer-features/go-task`: `task devhost:*` (version, setup, log, jobs:state, briefing, report, costs, adr, verify, init), and `task test` as the tester's default command.
- `ghcr.io/devcontainers/features/python` or the base image's `python3` (standard library only; apt installs it when absent).

## Where it comes from

Ported from the housekeeping of two private repositories: the agentic workspace where the roles were first built ("the office": helpers, housekeepers, contractors, a name guard turning people's names into "the Operator") and a client project that made it a shared, pushed repository (one level, no rooms; a container gate so a workstation session is never touched; the forbidden-words guard shared by the backs and the commit check; `merge=union` on the monthly ledger files; the cost measured from the transcripts, never by the model; the tester). The original's ledger lists the mistakes already fixed and kept fixed here: stakes mid-paragraph are missed, so a stake stands on its own line; a reply is written once per content block and the first record can carry a partial count, so the cost script keeps the fullest record; the guards undo a run that rewords or reorders rather than trust the brief; a test fixture under a container-wide `GIT_DIR` committed onto the real branch, hence the git wrapper and `DEVHOST_JOB_CHILD` on the suite; the librarian woken at the scribe's rate had nothing to do a third of the time, hence its own thresholds; the state out of the checkout, so nothing is synced or committed by mistake. Vocabulary and prefix changed with the words: housekeeper to back, helper to inter, contractor to con, `Housekeeper <job>` to `Back <job>`.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/devhost/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
