# Proposal: one agent list, two kinds, one verb for every agent CLI

Status: decided 2026-10-27 by the Operator: D1–D5 as recommended, and no limit on resident agents per folder. Facts 5 and 6 are still for the workstation. Slices 2 and 3 built 2026-10-27 (`agents` 1.0.0, claude-code 1.7.0, devcontainer-cli 1.13.0; "As built" below), not yet released. Written 2026-10-27 from the Operator's direction of the same day. Backlog: `agent-kind-standard` (it carries `fleet-design-rethink`'s fact list); decision `session-concept-drop`; replaces `claude-host-join-running` (paused). No Feature code yet.

Who this serves: every consuming repository's maintainer, and the engineers who start agents in a devcontainer. They get one standard way to start any agent, whatever its CLI.

## As built (slices 2 and 3, 2026-10-27)

Where the build differs from the text below, the build is what ships:

- **Task names.** A Feature's tasks live under its id, so inside the container the verb is `task agents -- <name>` (the
  namespace's default task), `task agents:up`, `agents:list`, `agents:stop`, `agents:logs`, plus `agents:check`; from
  the host `task devcontainer:agent -- <name>` and `devcontainer:agent:list`. The command behind them is `agents`
  (`agents start|up|list|stop|logs|check`).
- **A task variable goes before the `--`:** `task agents AGENTS_FILE=ops/agents.yml -- host` (after it, it is a CLI
  argument).
- **The contract has one more verb, `wake`:** bring a stopped or failed session back in the background with its
  conversation (Claude Code: `claude --bg --resume <session id>`, fact 3). `start-bg` always starts a fresh session.
  `wake` unsupported falls back to a fresh `start-bg`, said in one line. `list` prints the sessions newest first, and
  `stop` takes `--extras` (stop the agent's other running sessions, keep the newest). `<folder>` is absolute.
- **A stopped resident** is woken with `wake` whether or not there is a terminal (then attached from one), rather than
  `claude attach <id>` / `claude respawn <id>`. `attach` on a stopped session still restarts it.
- **On-demand `resume`** finds the agent's newest session by name and folder in `claude agents --json --all` and runs
  `claude --resume <session id>`, never `--resume <name>`; it is refused while that session runs.
- **D5 as decided:** claude-code is **1.7.0** (not 2.0.0): the adapter is added, and `claude-host`, `claude-fleet`,
  `claude-host-pin`, `devcontainer:claude` and `devcontainer:claude:fleet` keep working with one deprecation line each.
  `devcontainer:claude` keeps its behaviour rather than becoming `devcontainer:agent -- <first resident>`.
- **The list's YAML** is a subset read by awk (no python3 or jq on every base image); unknown keys warn, anything
  outside the subset is refused with its line.
- **This repository** lists `host` as `on-demand` with `--remote-control` (D2) and adds the Feature to its devhost;
  `SESSIONS`, `HOST_SESSION` and the pin hook stay until 2.0 (section 8).
- The consumer migration note is `docs/migrations/agents.md`.
- **agents 1.0.1, claude-code 1.8.0 (2026-10-28):** a `list` that fails (exit 1, not 3) is a state of its own,
  `error`: section 6's "counts as not running, start once" applies only to exit 3; on `error` no resident is started,
  the adapter's reason and an optional adapter verb `hint <name> <folder>` (how to resume by hand) are printed, and
  on-demand `--resume` never becomes `new` (Claude Code's adapter opens `claude --resume`, its picker). `agents:list`
  shows an on-demand agent as `running` or `none` only. The Claude Code adapter reads the list past surrounding lines,
  retries a time-out or an empty answer once, and names the cause; the trigger was a consumer's `claude` wrapper that
  put `--add-dir` first, which the new claude-code option `additionalDirectories` replaces.

## 1. The direction (given, not reopened)

1. Each repository declares its agents in **one list**: a name, a CLI, a folder, extra args, and a kind.
2. **Two kinds.** `resident`: runs continuously in the background and starts with the container; "start" means make sure it runs, then attach. `on-demand`: "start" opens a new session; a resume only on request.
3. **One verb** for everyone: `task agent -- <name>` inside, `task devcontainer:agent -- <name>` from the host. It does the right thing for the kind.
4. Each CLI Feature supplies an **adapter** with the same verbs. Claude Code first; Copilot CLI and others later. An adapter may say "not supported"; the verb then falls back (section 6).
5. The list's **path is configurable** (the Operator, 2026-10-27). Default `.devcontainer/agents.yml`.

The session leaves the domain. An agent is a name, a folder and a kind. Which session runs it is the adapter's business.

## 2. The picture

```
 HOST                                   DEVCONTAINER
 ----                                   ------------
 task devcontainer:agent -- host
   | (passes through, starts the
   |  container first)
   v
 task agent -- <name> [--resume|--new]
   |
   v
 agents list  (AGENTS_FILE, else .devcontainer/agents.yml)
   |   host:     cli=claude   kind=resident   folder=.
   |   reviewer: cli=claude   kind=on-demand  folder=rooms/review
   |   pair:     cli=copilot  kind=on-demand  folder=.
   v
 kind?
   +-- resident ----> adapter: list -> running?  no -> start-bg
   |                            |                     (stopped -> restart)
   |                            v
   |                         attach   (no TTY: print how, exit 0)
   |
   +-- on-demand ---> adapter: new          (default)
                               resume       (with --resume)
   v
 adapter for the CLI:  agent-adapter-<cli>
   claude  -> claude --bg / attach / --resume / agents --json / stop
   copilot -> (later)  verbs it lacks answer "unsupported" (exit 3)

 container start (postStartCommand): task agent:up
   -> every resident: make sure it runs (no attach)
```

## 3. The list

Default path `.devcontainer/agents.yml`, beside `devcontainer.json`, committed.

```yaml
# .devcontainer/agents.yml
agents:
  - name: host            # unique in the list; letters, digits, - and _
    cli: claude           # picks the adapter: agent-adapter-claude
    kind: resident        # resident | on-demand
    folder: .             # repo-relative; the session's working folder
    args: [--model, opus] # handed to the CLI as they are (a YAML list, no shell quoting)
  - name: reviewer
    cli: claude
    kind: on-demand
    folder: rooms/review
    args: [--model, sonnet]
  - name: pair
    cli: copilot
    kind: on-demand
    folder: .
```

Rules, kept small on purpose:

- `name`, `cli`, `kind` are required. `folder` defaults to `.`, `args` to none.
- Nothing else is read. Unknown keys are a warning, not an error, so a repository can note things for itself.
- One file. No includes, no per-user overrides.

**Where the list lives.** One plain variable, `AGENTS_FILE`, a path relative to the repository root (the folder holding `.devcontainer/`). It follows NFR-6: resolved from the task's CLI variable, then `.env` / `.devcontainer/.env`, then the environment. Unset: `.devcontainer/agents.yml`. The `agents` Feature may also take an option, `agentsFile`, which only sets the environment default (written at install, read when `AGENTS_FILE` is unset). Order, first wins:

| Source | Example | When to use |
|---|---|---|
| task variable | `task agent -- host AGENTS_FILE=ops/agents.yml` | a one-off run, a test |
| `.env` / `.devcontainer/.env` | `AGENTS_FILE=ops/agents.yml` | per checkout |
| environment (incl. `containerEnv`) | `"containerEnv": {"AGENTS_FILE": "ops/agents.yml"}` | per repository, committed |
| Feature option `agentsFile` | `"agents": {"agentsFile": "ops/agents.yml"}` | per repository, committed |
| built-in default | `.devcontainer/agents.yml` | almost always |

Recommendation: the variable only, no Feature option (decision D3). The option is a second way to say the same thing, and `containerEnv` already covers "committed with the repository". A missing file is an error naming the path it looked for and where that path came from.

## 4. The verbs

| Verb | `resident` | `on-demand` |
|---|---|---|
| `task agent -- <name>` | make sure it runs, then attach | a new session in its folder, in this terminal |
| `task agent -- <name> --resume` | same as above | resume this agent's latest conversation (adapter `resume`) |
| `task agent -- <name> --new` | stop it, start a fresh one, attach (asks first; decision D4) | same as plain start |
| `task agent:up` | start every resident not running (container start) | skipped |
| `task agent:list` | each agent: kind, state (running, stopped, none), id | the same, from the adapter's `list` |
| `task agent:stop -- <name>` | stop it; the conversation is kept | stop a running one, if the adapter can |
| `task agent:logs -- <name>` | recent output | recent output, if running in the background |

Extra CLI flags pass through after the name: `task agent -- reviewer --effort high`.

**No TTY.** `task agent` is `interactive: true`. When stdin or stdout is not a terminal (an agent or a script calls it), a resident is made to run and the verb prints the attach command and exits 0; an on-demand agent is refused (exit 2), because a new interactive session without a terminal is never what was meant. This holds whatever fact 4 turns out to be.

**Identity is the name.** The adapter tags each session with the agent's name and finds it again by name and folder. No UUID is written anywhere in the repository.

## 5. The adapter contract

Each CLI Feature installs one executable, `agent-adapter-<cli>` on `PATH`. The `agents` Feature calls it; nothing else does.

```
agent-adapter-<cli> <verb> <name> <folder> [-- args...]
  start-bg   start the agent in the background in <folder>; print its id
  attach     open the running agent in this terminal
  resume     open the agent's latest conversation in this terminal
  new        open a new conversation in this terminal
  list       print one line per session of this CLI: name<TAB>id<TAB>state<TAB>folder
             state: running | stopped | failed
  stop       stop the agent; keep its conversation
  logs       print recent output
  supports   print the verbs it supports, one per line
Exit: 0 done, 1 failed, 2 bad use, 3 not supported by this CLI.
```

**The Claude Code adapter** (`agent-adapter-claude`, from the claude-code Feature):

| Verb | Claude Code call | Rests on |
|---|---|---|
| `start-bg` | `cd <folder> && claude --bg --name <name> <args>` | fact 1 |
| `list` | `claude agents --json --all`, kept where `name` and `cwd` match | fact 2 |
| `attach` | `claude attach <id>` (the id from `list`, never the name: the name matches "part of a name" and only while running) | facts 1, 4 |
| `resume` | `cd <folder> && claude --resume <name> <args>` | fact 3 |
| `new` | `cd <folder> && claude --name <name> <args>` | |
| `stop` | `claude stop <id>` | fact 1 |
| `logs` | `claude logs <id>` | fact 1 |

A stopped or failed resident is restarted by `claude attach <id>` (the docs: attaching to a stopped session restarts it from its saved conversation) or, without a terminal, `claude respawn <id>`.

**Two residents by the same name** (Claude numbers a collision `host (2)`): the adapter keeps the newest by `startedAt`, reports the others and stops nothing. `task agent:stop` with `--extras` stops them. That is today's fleet rule, kept.

## 6. When an adapter says "not supported"

| Verb unsupported | Fallback |
|---|---|
| `start-bg` | a resident runs as on-demand: plain start opens `new`, with one line saying the CLI has no background mode. `agent:up` skips it with the same line. |
| `attach` | print `logs` (if supported) and the reason; exit 1. |
| `resume` | `new`, with one line saying the CLI cannot resume. |
| `list` | the agent counts as not running. A resident is then never started twice by `agent:up` within one container start (a marker under the Feature's state folder); otherwise "make sure it runs" cannot be promised, and the verb says so. |
| `stop`, `logs` | say so; exit 3. |

Rule: a fallback never starts a second copy of something that may be running, and always says in one line what it did instead.

## 7. Facts from Claude Code 2.1.308, and how they shape this

Checked 2026-10-27 in this devhost with `claude --help`, the subcommands' `--help`, the docs at code.claude.com (agent-view, sessions, remote-control), and harmless calls on a session name that does not exist. **No background session could be started here**: `claude --bg` in an untrusted folder exits with `Workspace not trusted. Run claude ... once and accept the trust prompt`, and the only trusted folder is this repository's main checkout, which another session was using. Accepting trust for a scratch folder is a change to the Operator's Claude state, so it was not done. A script for the live checks is in section 11.

**Live run, 2026-10-27** (the Operator allowed one throwaway folder to be trusted; the trust entry was removed afterwards and both test sessions were stopped and removed):

- **1:** `claude --bg --name zz-throwaway-agtest ...` started `d7aba308`; `claude logs <name>` and `claude logs <name prefix>` both worked; `claude stop <name>` failed (`No job matching`, exit 1): **stop takes the id only, confirmed**.
- **2:** `claude agents --json` showed `"name": "zz-throwaway-agtest"`, `"kind": "background"`, a `sessionId` and `status`/`state`. **Confirmed live**; `/clear` still not driven.
- **3:** `claude --bg --resume <full session id>` woke the same id (`note: woke session d7aba308 with its saved options (--name, --model)`): **confirmed live**. `claude --bg -c` started a copy under a new id with a `note:` line: **confirmed live**.
- **4:** `claude attach <name>` with stdin and stdout not a terminal printed `Attaching…` and exited 0 at once: it does not hang and does not fail, but it is no use to a non-interactive caller. **The adapter attaches only from a terminal** (section 4's rule stands).
- **5, 6:** not testable from here; still for the Operator (`/remote-control` inside an attached background session; one rebuild).

| # | Fact | Result | Evidence |
|---|---|---|---|
| 1 | A background session can be named, and `attach`, `logs`, `stop` take the name | **Partly confirmed (docs and help)**; live run untestable here | `claude --help`: `-n, --name <name>`; `attach <id\|name>` "Part of the session name works too"; `logs <id\|name>`; `stop\|kill <id>` and `rm <id>` take the id only. The docs: names need 2.1.290+; `attach` by name "only while its process is running". `claude attach zz-nonexistent-agtest` prints `No job matching 'zz-nonexistent-agtest'. Run 'claude agents' to list running sessions.`, exit 1 (same for `logs`, `stop`, `rm`). |
| 2 | The name shows in `claude agents --json` and survives `/clear` | **Confirmed (docs)**; `/clear` could not be driven non-interactively | The docs list `name` as a field "when set"; here the list shows `name` for every session. Sessions docs: after `/clear` "the new session keeps a name you set with `--name` or `/rename`". A `/rename` survives a supervisor restart. |
| 3 | A background session can continue a conversation | **Confirmed (docs and help)**; live run untestable here | `--bg` help: "With --resume <session-id>, continues that session in the background under the same ID". The docs: `--bg` with `--continue`, a bare `--resume`, or `--resume <name>` "always starts a copy" and prints a `note:` line. |
| 4 | A caller without a TTY can attach; attach on a stopped session | **Partly**: the not-found path needs no TTY (exit 1); attaching to a running session without a TTY is untested | Docs: attach "takes over the terminal"; attaching to a stopped or failed session "restarts it from its saved conversation" (by id). Not stated whether attach refuses without a TTY. |
| 5 | A background session can be reached through Remote Control | **Not documented**; untestable here | Remote Control docs: auto-connect applies to "every interactive session"; "each interactive Claude Code process registers one remote session". Agent-view docs never mention Remote Control. Third-party write-ups say background sessions are not reachable from a phone. |
| 6 | Background sessions after a container rebuild | **Untestable from inside; the Operator to test on the workstation** | Docs: "Shutdown or restart stops running sessions"; within 48 hours they show as failed and attach or reply restarts them from the saved conversation; older ones show stopped. State lives in `CLAUDE_CONFIG_DIR` (`jobs/`, `daemon/roster.json`), which the claude-code Feature keeps in a volume. The Feature's NOTES (1.6.0) record a consumer seeing the supervisor restore background sessions after a rebuild. |

How they shape the design:

- **Identity by name, action by id** (facts 1, 2). The adapter finds the agent by `name` and `cwd` in `claude agents --json --all`, then always calls `attach`, `stop`, `logs` with the id. That avoids the "part of a name" match (`host` would match `host-review`) and the "name only while running" limit.
- **No pins** (fact 2). The name survives `/clear`, so nothing has to write a new id back. This is what lets `HOST_SESSION`, the pin hook and the stale-pin warnings go.
- **Resume by id in the background** (fact 3). A stopped resident is brought back with `attach <id>` or `respawn <id>`, never with `--bg -c` or `--bg --resume <name>`, which start copies.
- **No TTY, no attach** (fact 4). Section 4's rule does not depend on what attach does without a terminal.
- **Remote Control** (fact 5). If a background session cannot be reached from a phone, the host agent as a resident loses phone access. Fallback: keep `kind: on-demand` for the agent the Operator drives from the phone, started with `--remote-control` in `args`. Decision D2.
- **Rebuild** (fact 6). `agent:up` at container start first waits for the list to settle (today's fleet rule, from `claude-fleet`), then restarts each resident found stopped or failed by id, and starts the rest fresh.

## 8. What goes away, and the migration

| Goes | Replaced by |
|---|---|
| `HOST_SESSION`, `HOST_SESSION_<DIR>` in `.env` | the agent's `name` in the list |
| the `claude-host-pin` SessionStart hook | nothing (the name survives `/clear`) |
| `claude-host`: its refusals, attach advice, `CLAUDE_HOST_*` variables | `task agent`, by kind |
| `claude-fleet` and the `SESSIONS` include variable | the list and `task agent:up` |
| `devcontainer:claude`, `devcontainer:claude:fleet` | `devcontainer:agent` |
| `CLAUDE_HOST_JOIN` (requested, paused) | a resident always attaches |

Versions (D5, as built): claude-code **1.7.0** adds the adapter and prints a one-line deprecation note from the three old scripts, which keep working; a new `agents` Feature **1.0.0**; devcontainer-cli **1.13.0** adds `devcontainer:agent` and `devcontainer:agent:list`, and `devcontainer:claude` and `devcontainer:claude:fleet` keep working with a deprecation line. claude-code **2.0.0** then removes `claude-host`, `claude-fleet`, `claude-host-pin`, and the next devcontainer-cli minor removes `devcontainer:claude` and `devcontainer:claude:fleet`.

What removes the old pieces, and when (none of them goes in the 1.7.0 build):

| Piece | Removed by |
|---|---|
| `claude-host`, `claude-fleet`, `claude-host-pin` and `task claude-code:host` / `:fleet` | claude-code 2.0.0 |
| `devcontainer:claude`, `devcontainer:claude:fleet`, the `HOST_SESSION` / `SESSIONS` notes in `bootstrap/devcontainer.yml` | the devcontainer-cli minor that follows claude-code 2.0.0 |
| this repository's `SESSIONS` var in `Taskfile.yml`, `HOST_SESSION` in `.devcontainer/.env`, the `claude-host-pin` hook in `.claude/settings.json`, `test:claude-fleet-task` | the same change as claude-code 2.0.0 |
| a consumer's pins, hook, `SESSIONS` and join scripts | the consumer, following `docs/migrations/agents.md`, before it takes claude-code 2.x |

Per consumer:

- **This repository.** `SESSIONS: "host|HOST_SESSION|.|"` in `Taskfile.yml` becomes `.devcontainer/agents.yml` with `host` (`kind` per decision D2). Drop `HOST_SESSION` from `.devcontainer/.env`, the `claude-host-pin` hook from `.claude/settings.json`, `test:claude-fleet-task`. The `restart-devhost` skill and the devhost Feature's description and setup message name `task agent -- host` instead of `claude-host`.
- **The office.** It runs several agents in one container (the source of the fleet's 1.6.0 lessons). Its `SESSIONS` lines become list entries, one per agent, `kind: resident` for the ones kept running. Its `HOST_SESSION_<DIR>` lines go.
- **Software project 1.** One host session today: one `resident` or `on-demand` entry; its pin goes.
- **agentic-operating-framework.** Its `scripts/join.sh` (what `CLAUDE_HOST_JOIN` was for) is replaced by a `resident` entry; its `scripts/test-join.sh` cases become the adapter's unit tests (a fake `claude`). It drops both once `agents` 1.0.0 ships.

Each consumer's `.devcontainer/DEVCONTAINER_CONTRIBUTION.md` gets the migration note: add the `agents` Feature, write the list, remove the pins and the hook, rename the task.

## 9. Where it lives

Recommendation (decision D1): **a small new Feature, `agents`**, that owns the list, `task agent*`, the kind logic, the fallbacks and `agent:up` (as its `postStartCommand`). CLI Features each add only `agent-adapter-<cli>`. `agents` names no CLI Feature in `dependsOn`; it finds adapters on `PATH`, and a list entry whose adapter is missing is an error naming the Feature to add. It installs a bash script and a taskfile, nothing downloaded.

The simpler option, weighed: put it all in claude-code now and split later. It is less to ship today, but the list, the kinds and the verbs would then belong to one CLI, and the Copilot adapter would have to depend on claude-code or copy the logic. The split is the point of the standard, so it should be there from the start.

## 10. The backs and the devhost here

- The backs run from the repository's `.claude/settings.json` `Stop` hooks (`devhost-run-job`, `claude -p`). Every Claude session in the folder fires them, residents included. One resident (the host) changes nothing. Several residents may share a folder (the Operator, 2026-10-27: no limit). Each fires the backs only when it takes a turn, so an idle resident costs nothing and the cost follows the work, which the ledger should record anyway. The backs already serialise on a per-job lock (`run-job.sh`, `flock`): a `Stop` that finds the lock busy is skipped and picked up from its session's offset on the next turn, so nothing is torn or written twice; a record may arrive a turn late under load (see "Still open"). An agent may still have its own folder (`dir`) when that suits it.
- `restart-devhost` and `shutdown-devhost` name `task agent:list` and `task agent -- host`.
- The shutdown handshake tabled in `fleet-design-rethink` (votes from busy agents) is not part of this proposal; `agent:stop` is enough to build it on later.

## 11. Slices

1. **The facts, live.** The Operator runs the script below in a trusted throwaway folder on the workstation's devcontainer, plus a rebuild with one resident running (fact 6) and `/remote-control` inside an attached background session (fact 5). One ledger entry with the results. Script: `run-facts.sh` (handed over with this proposal; not committed).
2. **`agents` 1.0.0 and the Claude adapter** (claude-code 2.0.0): the list, `AGENTS_FILE`, the verbs, the fallbacks, `agent:up`; unit tests with a fake adapter and a fake `claude`; this repository migrates.
3. **devcontainer-cli**: `devcontainer:agent` and the deprecated `devcontainer:claude` alias.
4. **Consumers**: migration notes; the office and agentic-operating-framework move.
5. **A second CLI** (Copilot CLI): its adapter, proving the contract and the fallbacks.

## 12. Non-functional requirements

- **NFR-1 owns-its-state:** `agents` keeps only the `list`-fallback marker, in `/var/lib/devcontainer-features/agents`. Sessions stay in each CLI's own state (claude-code's volume).
- **NFR-2, NFR-7:** `task agent*` in the Feature's taskfile, `version` first, every task with a `desc`; `agent` and its `--resume`/`--new` forms `interactive: true`; `agent:list` prints a machine-readable form with `-- --json`.
- **NFR-4 augments-not-replaces:** the adapter calls the CLI as installed; nothing is wrapped or replaced.
- **NFR-5:** `agent:up` is idempotent: a second run starts nothing.
- **NFR-6:** `AGENTS_FILE` is the one setting, resolved in the usual order.
- **NFR-8, NFR-9:** NOTES to the standard; NFR-9: Claude Code's own agent view lists sessions but has no per-repository list or kinds, and no other CLI has one.
- **NFR-10:** tests on the base images, with fake CLIs (no login, no network).
- **No process of ours on the host** (ADR 0024): the host task only passes through. The background processes are the CLIs' own, inside the container.

## 13. Decisions for the Operator

- **D1 Where it lives.** A new `agents` Feature with adapters in the CLI Features (recommended), or everything in claude-code for now.
- **D2 The host agent's kind here.** `resident` (recommended once fact 5 shows a background session can be reached through Remote Control), else `on-demand` with `--remote-control` in its `args` until it can.
- **D3 The list's path override.** The `AGENTS_FILE` variable only (recommended), or also a Feature option `agentsFile`.
- **D4 `--new` on a resident.** Stop the running one and start fresh after a yes/no question (recommended), or refuse and point to `agent:stop`.
- **D5 claude-code 2.0.0 removes `claude-host`, `claude-fleet`, `claude-host-pin` outright** after one 1.x release with a deprecation note (recommended), or keeps them as thin shims over `task agent`.

## 14. Still open (unverified facts, not decisions)

- Fact 1 live: `claude stop <name>` (help says id only); whether `logs` matches a prefix of the name.
- Fact 4: `claude attach <id>` on a running session without a TTY.
- Fact 5: Remote Control for a background session, attached or not.
- Fact 6: background sessions after a container rebuild with the claude-code volume.
- The workspace trust prompt: a resident in a folder that was never trusted fails to start (`Workspace not trusted`). Whether `agent:up` should say so and stop, or the claude-code Feature should mark the repository's folders trusted (a change to the user's Claude state; not proposed).
- Idle cost: the supervisor stops a finished, unattached session after about an hour; a resident then restarts on attach. Whether residents should be pinned (`Ctrl+T`, no CLI flag found) to stay warm.
- Worktree isolation: a background session moves into its own git worktree under `.claude/worktrees/` before editing, unless `worktree.bgIsolation` is `none`. With this repository's git wrapper (ADR 0020) that may fail as the Agent tool's isolation does (`devhost-worktree-isolation`); a resident here probably needs `bgIsolation: none`.
- Under several busy residents in one folder, how late do the backs' records arrive (a `Stop` skipped on a busy lock is caught up on that session's next turn)? A load check, not a design question.
