
# Agents (agents)

One list of a repository's agents (.devcontainer/agents.yml, or the repo-relative path in AGENTS_FILE: name, CLI, folder, args, kind, lifecycle, identity, lease, default), two kinds and one verb for every agent CLI: task agents -- <name> makes a resident agent run in the background and attaches to it, or opens a new session of an on-demand agent (--resume, --new); a stateful agent runs as exactly one live copy, guarded by an exclusive lease (a second start joins a resident or is refused for an on-demand agent; agents:leases, agents:release); agents:up starts every resident at container start (its postStartCommand, never fatal), agents:list, agents:stop, agents:logs, agents:check. Each CLI Feature supplies an adapter (agent-adapter-<cli> on PATH; the claude-code Feature ships agent-adapter-claude); a verb an adapter does not support falls back and says so. Installs a bash script and the Feature Taskfile; nothing downloaded.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/agents:2": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |

## What it installs

One standard way to start any agent, whatever its CLI. A repository declares its agents in one
list; the `agents` command (on PATH, `/usr/local/bin/agents`) reads it and does the right thing
for each agent's kind, through the adapter its CLI Feature supplies. The Feature installs that
bash script, the Feature Taskfile and an empty state folder; nothing is downloaded, so there is
nothing to verify. It installs no adapter: the `claude-code` Feature (1.7.0 or later) brings
`agent-adapter-claude`; other CLIs follow.

```
 HOST                                  DEVCONTAINER
 task devcontainer:agent -- host  -->  task agents -- host [--resume|--new]
                                          |
                                          v
                                       agent list (AGENTS_FILE, else .devcontainer/agents.yml)
                                          |
                     resident  <----------+---------->  on-demand
            running? attach : start-bg/wake, attach     new (default) / resume (--resume)
                                          |
                                          v
                                       agent-adapter-<cli>   (claude: claude --bg / attach / --resume ...)
 container start (postStartCommand): agents up --post-start -> every resident runs, none attached
```

## The agent list

`.devcontainer/agents.yml`, beside `devcontainer.json`, committed:

```yaml
agents:
  - name: host               # unique; letters, digits, - and _
    cli: claude              # picks the adapter: agent-adapter-claude
    kind: on-demand          # resident | on-demand
    folder: .                # repo-relative, default .
    args: [--remote-control] # handed to the CLI as they are (a YAML list, no shell quoting)
  - name: reviewer
    cli: claude
    kind: resident
    folder: rooms/review
    args:
      - --model
      - sonnet
```

2.0 adds five optional keys, all flat (one word each):

```yaml
  - name: tooling              # the handle
    cli: claude
    kind: resident
    lifecycle: stateful        # stateful (default) | ephemeral
    identity: tooling          # the principal it acts as; default: the name
    lease: container           # container (stateful, the default) | none (ephemeral, the default)
    definition: tooling        # the CLI's agent profile; read, checked and shown, not passed to the CLI in 2.0
    default: true              # at most one agent: what `task agents` with no name starts
```

| Key | Values | Rule |
| --- | --- | --- |
| `lifecycle` | `stateful` (default), `ephemeral` | `ephemeral` with `kind: resident` is refused (the container start would create and discard it every time). |
| `identity` | letters, digits, `-`, `_`; default the `name` | Two stateful agents may not share one; ephemeral agents may share each other's and one stateful agent's. |
| `lease` | `container`, `none` | A stateful agent's lease is `container` (`none` is refused: that is what `ephemeral` means); an ephemeral agent's is `none`. `machine` and `cluster` are reserved and refused (Limits). One word: `lease: { scope: container }` is refused with a line pointing at the flat form. |
| `definition` | letters, digits, `.`, `:`, `-`, `_` | Refused together with `--agent` in `args` (two sources for one fact). In 2.0 it is stored and shown only; `agents start` says so in one line and the CLI starts without it. A later 2.x hands it to the adapter. |
| `default` | `true`, `false` | At most one agent; `agents check` names it. `task agents` (no name), `agents` and `agents start` without a name start it exactly as `agents start <name>`; with none marked they print the usage (exit 2) as before. |

- `name`, `cli`, `kind` are required; `folder` defaults to `.` and must stay inside the
  repository; `args` default to none.
- Nothing else is read. An unknown key is a warning (with its line), not an error, so a
  repository can note things for itself. One file: no includes, no per-user overrides.
- A broken list is refused (exit 2) with every problem named by file and line. `task
  agents:check` reads and checks it without starting anything.
- The YAML is a small subset, read by awk: comments, plain, single- and double-quoted values, an
  `args` list in flow (`[a, "b c"]`) or block (`- a`) form. No anchors, no multi-line values, no
  `{ }` entries. Why awk: the Feature must work on every base image, and bash, awk and sed are
  what they all have; python3 and jq are not guaranteed (the CI matrix includes `debian:latest`
  and `ubuntu:latest`), and the other Features of this collection read JSON with sed for the same
  reason. A vendored YAML parser would be a larger, unverified download for a five-key file.

**Kinds and lifecycles.** `kind` says when it runs, `lifecycle` what it keeps:

|  | `resident` | `on-demand` |
| --- | --- | --- |
| **stateful** | runs in the background from the container start; its lease is held while it runs; a second start joins it | opens a session in this terminal; the lease is held for the session's life; a second start is refused (exit 2) while it runs |
| **ephemeral** | refused | a new session on every start, no lease, any number at once; `--resume` is refused (nothing is kept) |

**Kinds.** `resident`: runs continuously in the background; starting it means make sure it runs,
then attach. `on-demand`: starting it opens a new session in this terminal; it resumes its latest
conversation only when asked.

**Where the list is: `AGENTS_FILE`.** A path relative to the repository root (the nearest folder
at or above the current one holding `.devcontainer/`; an absolute path is used as it is),
resolved like every setting here (NFR-6), first wins:

| Source | Example |
| --- | --- |
| task variable (before the `--`) | `task agents AGENTS_FILE=ops/agents.yml -- host` |
| the root `.env`, then `.devcontainer/.env` | `AGENTS_FILE=ops/agents.yml` |
| the environment (incl. `containerEnv`) | `"containerEnv": {"AGENTS_FILE": "ops/agents.yml"}` |
| built-in default | `.devcontainer/agents.yml` |

There is no Feature option for it (`containerEnv` already covers "committed with the
repository"). A missing file is an error naming the path it looked for and where that path came
from. Task fills its variables from `.env` and the environment too, so the task hands its
variable over as `AGENTS_FILE_TASK_VAR`, and the command counts it as a task variable only when
it differs from both.

## The verbs

| Task | `resident` | `on-demand` |
| --- | --- | --- |
| `task agents -- <name>` | make sure it runs (start it, or wake a stopped one with its conversation), then attach | a new session in its folder, in this terminal |
| `task agents -- <name> --resume` | the same | resume its latest conversation (refused while that one runs) |
| `task agents -- <name> --new` | stop the running session and start a fresh one, after a yes/no question (`--yes` skips it), then attach | the same as plain |
| `task agents:up` | start every resident not running, attach none (the postStartCommand) | skipped |
| `task agents:list` | name, kind, CLI, state (`running`, `stopped`, `failed`, `none`; `+N` extra running sessions; `unknown` when the CLI cannot list, `error` when listing failed, with the adapter's reason below the table and as `"error"` in `--json`), id, folder; `-- --json` for agents | `running` with its id, else `none` (a stopped conversation is what `--resume` opens, not a state) |
| `task agents:stop -- <name>` | stop it; the conversation is kept. `-- <name> --extras` stops only the extra sessions | stop a running one, if the adapter can |
| `task agents:logs -- <name>` | recent output | recent output, if it ran in the background |
| `task agents:check` | read and check the list, print it | the same |
| `task agents:reset -- <name>... \| --all` | keep its running session, stop the others (conversations kept), record it again, start it if none runs; `--purge` also removes its ended sessions. A dry run unless `--yes` (below) | the same, nothing started |
| `task agents:leases` | every lease: handle, state (`held`, `starting`, `stale`, `unknown`), carrier, since, holder; `-- --json` | the same |
| `task agents:release -- <name>` | free a lease whose holder is gone; `--force` also a live one (a second copy may then start) | the same |
| `task agents` (no name) | the agent marked `default: true`, as if named | the same |
| `task agents:version` | the Feature version and the list in use | |

Extra CLI flags follow the name: `task agents -- reviewer --effort high`; after `--` everything
goes to the CLI, even `--resume`. They come after the list's `args`.

**No terminal.** `task agents` is `interactive: true`. When stdin or stdout is not a terminal (an
agent or a script calls it), a resident is made to run and the command prints how to attach
(exit 0); an on-demand agent is refused (exit 2), because a new interactive session without a
terminal is never what was meant. `--new` on a running resident without a terminal is refused
unless `--yes`.

**Two sessions for one agent** (a crash, a restore, Claude Code numbering a collision `host (2)`):
the newest is the agent's; the others are reported, never stopped on their own. `task
agents:stop -- <name> --extras` stops them.

**At container start** `agents up --post-start` first waits until the CLI's session list settles
(a CLI may restore background sessions after a rebuild; starting in that window makes copies):
two reads `AGENTS_SETTLE_INTERVAL` seconds apart (default 3) with the same running sessions, at
most `AGENTS_SETTLE_TIMEOUT` (default 30). Then each resident found stopped or failed is woken by
id and the rest are started. It never fails the container start: a missing list is one line, a
start that fails is said and the start goes on. `task agents:up -- --no-wait` skips the wait.

Exit codes of `agents`: 0 done, 1 failed, 2 bad use (unknown agent, broken or missing list,
refused), 3 the CLI cannot do it.

## The lease (2.0)

A stateful agent runs as exactly one live copy. Every start path through `agents` (`start`,
`--new`, `up`, `reset`'s start of a resident) takes the agent's lease first; `list`, `logs`,
`check`, `leases` and `release` take nothing.

```
start of a stateful agent h
  mkdir leases/h ok? -- yes --> write holder (starting) --> start --> holder: held, carrier
        | no
  read holder: dead? -- yes --> takeover lock, re-read, still dead: rename away, mkdir --> as above
        | starting: wait up to AGENTS_LEASE_WAIT (20 s), then as held
        | held
  resident: join (attach; no terminal: "h: running (id)", exit 0)
  on-demand: refuse, exit 2, naming the holder, agents:release and lifecycle: ephemeral
```

- **Where.** `/var/lib/devcontainer-features/agents/leases/<name>/holder` (key=value lines:
  `state`, `pid`, `pidstart`, `boot`, `container`, `carrier`, `time`), written to a temporary
  name and renamed. Folders are mode 0777 without the sticky bit, so a dead holder of another user
  (root at post-start, the remote user in a terminal) can be taken over; the container is
  single-tenant. A lease is keyed by name, not by list.
- **Dead or alive**, the first rule that applies: no holder file and the folder older than 5 s:
  dead (younger: starting); another container start (`boot`, the start of PID 1, the key the
  markers already use, so `docker restart` counts) or another `container` (the hostname): dead;
  `starting`: alive while its pid is (with the same start time; a reused pid is dead); `held`:
  alive while its pid is (a foreground session's wrapper) or the adapter's `list` shows the agent
  running, by name and folder (so a session id changed by `/clear` is still the agent); the
  adapter cannot list (exit 3) and no live pid: **cannot tell**, never taken over (the next
  container start frees it, or `agents:release -- <name> --force`); the listing failed: nothing
  taken on a guess (exit 1, as 1.x). That is NFR-12: liveness through the CLI adapter's list when
  it has one, else the Feature's own record (the holder's pid).
- **Takeover** is serialised by `leases/<name>.takeover` (mkdir; a lock whose pid is gone, or
  older than 5 s, is cleared): the taker re-reads the holder and, only if it is still dead, renames
  the folder away and takes it with `mkdir`. A third start that wins the `mkdir` first is a
  legitimate take. A takeover that finds the agent running (restored by the CLI after a restart)
  adopts it: nothing is started.
- **Held** by a resident's background session after the starting process exits (carrier
  `session:<id>`), and by the `agents start` process of an on-demand agent for the session's life
  (carrier `process:<pid>`; it waits for the session and releases on exit, `TERM` and `HUP`; an
  interrupt goes to the session). A resident whose CLI has no background mode runs in the
  terminal and holds it the same way.
- **Released** by `agents stop` after the adapter stopped the session (not `--extras`), by the
  foreground wrapper's exit, by a failed start, by `agents release` (dead holder; `--force` a live
  one), and by a takeover. A session started by hand, outside `agents`, never takes a lease; the
  duplicate report (`+N`, `--extras`) stays the backstop for those.
- **At container start** `agents up` never refuses and never fails: a held lease means running
  (one line, `h: running (id)`); a stale one (the old container start) is taken over and the
  resident started or adopted.

## Reset (1.0.1, output fixed in 1.0.2)

`task agents:reset -- <name>... | --all [--purge] [--include-unlisted] [--yes] [--force]` puts the listed agents'
sessions in order, from a container terminal:

- **Per agent:** its running session is kept (the one `task agents -- <name>` would attach: the adapter's recorded one
  first), every other running session of it is stopped (`claude stop`, conversation kept), the adapter records the kept
  one again, and a resident left with none running is started (woken with its latest conversation, or fresh).
- **`--purge`** also removes the agent's ended sessions (`claude rm`; Claude Code keeps the transcript and a worktree
  with unpushed work, and says so), so it starts from scratch. Continuity is then what the repository records, not the
  conversation.
- **Scope:** only the agents in the list and their folders, never every session the CLI knows (another repository's
  sessions in the same container are not looked at). A session in those folders that belongs to no listed agent is
  reported as `untouched`; `--include-unlisted` treats it like a duplicate (stopped; removed with `--purge`).
- **A dry run by default:** the plan, one line per session (agent, session id, state, action, why), and nothing
  changed. `--yes` applies it; on a terminal it asks instead.
- **Refused, unless `--force`:**
  - stopping a session that is mid-turn right now (the adapter's `session-busy`; Claude Code: status `busy` or state
    `working`; idle, waiting for input or blocked on a decision is not busy). The plan names the session. An adapter
    that cannot tell counts it as not busy and says so;
  - with `--purge`, removing a session (its conversation) where the folder has uncommitted changes (`git status`,
    tracked files). On a plain reset, and for the stops of a purge, uncommitted changes are a warning in the plan;
  - any stop or removal from inside a Claude Code session (`CLAUDE_CODE_CHILD_SESSION=1`, which Claude Code sets for
    its tools' commands), which may be one it would stop: run it from a container terminal or `task
    devcontainer:shell`.
- **Exit codes:** 0 done, 1 something failed (a stop, removal or start that errored), 2 a refusal and nothing failed
  (dry run or applied). When every action was refused the summary says how many ("1 refused (see above); nothing else
  to stop, remove or start."); "nothing to stop, remove or start." means nothing was refused either. The AGENT column
  is as wide as the longest name in the plan (16 at least; an unlisted session shows as `(name)`).
- An adapter without the optional verbs: `session-busy` missing counts as not busy (said);
  `session-stop` missing leaves the duplicate running (said, exit 1);
  `session-remove` missing skips `--purge` with a note; `record` missing is skipped.

## The adapter contract

Each CLI Feature installs one executable on PATH, `agent-adapter-<cli>`; `agents` calls it,
nothing else does. A list entry whose adapter is missing is an error naming the program and the
Feature to add.

```
agent-adapter-<cli> <verb> <name> <folder> [--extras] [-- args...]
  start-bg   start the agent in the background in <folder> (a fresh session); print its id
  wake       bring the agent's stopped or failed session back in the background, same conversation
  attach     open the agent's running session in this terminal
  resume     open the agent's latest conversation in this terminal
  new        open a new conversation in this terminal
  stop       stop the agent (--extras: only its extra sessions); keep the conversation
  logs       print recent output
agent-adapter-<cli> list       one line per session of this CLI, newest first:
                               name<TAB>id<TAB>state<TAB>folder (state: running | stopped | failed)
agent-adapter-<cli> hint <name> <folder>
                               optional: how to find and resume the agent by hand, printed when
                               its list fails (exit 3 or missing: a general line instead)
agent-adapter-<cli> <verb> <name> <folder>, optional (exit 3 or missing: skipped):
  record                       record the agent's running session as the agent's, or clear its record
agent-adapter-<cli> session-busy <id>     exit 0 mid-turn now, 1 not (idle, waiting, ended), 3 cannot tell
agent-adapter-<cli> session-stop <id>     stop that session (the id `list` printed); conversation kept
agent-adapter-<cli> session-remove <id>   remove that ended session from the CLI's list
agent-adapter-<cli> supports   the verbs it supports, one per line
Exit: 0 done, 1 failed, 2 bad use, 3 not supported by this CLI.
```

`<folder>` is absolute. A session is the agent's when its folder is the agent's and its name is
the agent's name, or that name with a collision number (`host (2)`). Identity is the name: the
adapter tags each session with it and finds it again by name and folder, so no id is written into
the repository.

When an adapter answers exit 3, the verb falls back, says so in one line, and never starts a
second copy of something that may be running:

| Not supported | Fallback |
| --- | --- |
| `start-bg` | the resident runs as on-demand: plain start opens `new`; `agents:up` skips it |
| `wake` | a fresh `start-bg` |
| `attach` | its `logs` and the reason; exit 1 |
| `resume` | `new` |
| `list` | the agent counts as not running; a resident is started at most once per container start (a marker under `/var/lib/devcontainer-features/agents`, keyed by the start of the container's PID 1), and the verb says that "make sure it runs" cannot be promised |
| `stop`, `logs` | say so; exit 3 |

**When `list` fails** (any exit but 0 and 3: the CLI is there but its list could not be read) it is
not "cannot list": the agent's state is `error`, and nothing is started on a guess, since the agent
may be running or have a conversation to resume. `task agents -- <name>` and `agents:up` start no
resident, say the adapter's reason, print how to resume by hand (the adapter's `hint`, for Claude
Code `claude agents` and `cd <folder> && claude --resume`) and exit 1 (`agents up --post-start` still
lets the container start go on). An on-demand plain start opens a new session as always; `--resume`
never turns into a new session (Claude Code's adapter opens its own picker instead).

## State

None that must survive a rebuild (NFR-1): the agents are the CLIs' own sessions, kept in each
CLI's state (claude-code's volume at `CLAUDE_CONFIG_DIR`). `/var/lib/devcontainer-features/agents`
(mode 1777, created at install, not a volume) holds the once-per-container-start markers of the
`list` fallback and, from 2.0, `leases/` (mode 0777); `AGENTS_STATE_DIR` points elsewhere.

**Reasoned exception to NFR-1 for the leases.** NFR-1 asks a Feature to keep state that must
survive in a volume. A lease must not survive: one that outlived a rebuild would be stale by
definition, so a volume would be the wrong default. A plain restart keeps the writable layer, so
the holder records the container start (`boot`) and the hostname, and either differing makes the
holder dead. A repository may bind-mount the folder (NFR-1 allows it); the same check covers that.

## Options

| Option | Default | What it does |
| --- | --- | --- |
| `installTaskfile` | `true` | Register `taskfile.yml` with the go-task Feature's registry, so `task agents*` exist. Turn it off only if you call `agents` directly. |

No option for the list's path: `AGENTS_FILE` is the one setting (above).

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/agents:2": {}
}
```

plus `.devcontainer/agents.yml` and the go-task registry include in the root Taskfile (the go-task
Feature's notes).

## Verify it works

```
$ task agents:check
agents: /workspaces/myrepo/.devcontainer/agents.yml (from the default (AGENTS_FILE is not set)): 1 agent(s), default host (agents with no name starts it)
  host: cli claude, on-demand, stateful (identity host, lease container), folder ., args: [--remote-control]
$ task agents:list
NAME             KIND       LIFECYCLE  CLI      STATE     LEASE                    ID                                     FOLDER
host             on-demand  stateful   claude   none      free                     -                                      .
$ task agents:leases
HANDLE           STATE      CARRIER                  SINCE     HOLDER
agents: no lease is held.
```

The post-start log shows one line per agent (`host: on-demand, not started`, `reviewer: started in
the background (...)`).

## Pairs with

- **An adapter per CLI**, from that CLI's Feature: `claude-code` 1.7.0 or later for `cli: claude`.
  `agents` names no CLI Feature in `dependsOn`; it finds adapters on PATH.
- **go-task** for the tasks (the `agents:` namespace; `task agents` is its default task).
- **devcontainer-cli** 1.13.0 or later on the host: `task devcontainer:agent -- <name> [flags]`
  and `task devcontainer:agent:list` run the same verbs in the container, starting it first.

## Limits

- The YAML subset above; anything else is refused with its line.
- `agents:up` at container start waits up to `AGENTS_SETTLE_TIMEOUT` seconds when a resident's
  CLI can list sessions.
- A resident whose folder the CLI has never trusted fails to start (Claude Code: `Workspace not
  trusted`; run `claude` there once and accept). The Feature does not mark folders trusted.
- Whether Claude Code's Remote Control reaches a background session is not established; an agent
  driven from a phone stays `on-demand` with `--remote-control` in its `args` until it is.
- The lease is per container. `lease: machine` (a named volume shared by containers on one
  engine) and `cluster` are refused in 2.0: there is no atomic step across containers in bash,
  awk and sed, and across machines it needs a server (the framework's register), not this Feature.
- The lease guards starts through `agents` only; `claude --bg --name <agent>` by hand takes none.
- `AGENTS_LEASE_WAIT` (default 20 s) bounds the wait for a start in progress; a container start
  with several residents waits at most that per agent held `starting`.
- Tested with fake adapters and a fake `claude` (`task test:agents-unit`, `task
  test:claude-unit`); no live CLI in CI.

## Why it exists

Claude Code's own agent view (`claude agents`) lists sessions, but it has no per-repository list,
no kinds and no way to say "this one always runs"; other agent CLIs have nothing of the kind, and
no published Feature offers one (NFR-9). The list, the kinds and the verbs belong to no single CLI,
so they live here and each CLI Feature adds only its adapter.

## Version and upgrade

`ghcr.io/nabil-becker/devcontainer-features/agents:2` follows 2.x; rebuild to update. `agents:1` never
moves to 2 on its own.

### Changes in 2.0.0

A stateful agent runs as exactly one live copy (the lease, above), the list grows `lifecycle`,
`identity`, `lease`, `definition` and `default`, and `agents leases` / `agents release` (tasks
`agents:leases`, `agents:release`) show and free the leases. `list` gains the `LIFECYCLE` and
`LEASE` columns (`--json`: `lifecycle`, `identity`, `lease`, `carrier`, added after the others) and
`check` shows the new keys and the default agent.

**Upgrade note.** A 1.x list needs no edit: every entry reads as `stateful` with an exclusive
lease. What changes for it: an on-demand agent started in a second terminal while one runs is
**refused** (exit 2) instead of opening a second session; give an agent you run several of at once
`lifecycle: ephemeral` (its `--resume` is then refused). A resident started twice still attaches;
a session already running at the first start is adopted, nothing restarts. Scripts that parse
the `list` table should read `-- --json`. claude-code 1.8.x works unchanged (`list` is all the
lease needs). Pin `agents:2`. The upgrade path is in
[docs/migrations/agents.md](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/migrations/agents.md).

### 1.x

1.0.0 is the first release. 1.0.2: `agents reset` output fixes: the keep reason is a full sentence, the AGENT column fits the longest
name, a refusal exits 2 (1 stays for a failure) and is counted in the summary; pair it with claude-code 1.8.1, whose
`session-remove` prints one line instead of two. 1.0.1: `task agents:reset` (above); a `list` that fails is state `error` and starts nothing (it showed `unknown`
and started residents as fresh sessions), with the adapter's reason and how to resume by hand; an
on-demand agent shows `none` unless a session runs (it showed yesterday's stopped one). Pair it with
claude-code 1.8.0, whose adapter reads the list sturdily and gives the reason and the hint, and finds an agent
again after Claude Code retitles its session (with 1.7.0 a retitled resident looked stopped and was started a second
time; `/rename <agent name>` in that session was the workaround and is no longer needed). It replaces claude-code's `claude-host`, `claude-fleet` and `claude-host-pin` and
the `SESSIONS` / `HOST_SESSION` settings, which claude-code 2.0 removes; the migration is in
[docs/migrations/agents.md](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/migrations/agents.md).


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/agents/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
