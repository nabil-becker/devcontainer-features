# Migrating to the agents Feature

For a consuming repository's maintainer. Releases: `agents` 1.0.0, `claude-code` 1.7.0,
`devcontainer-cli` 1.13.0 (the bootstrap). The design and its reasons are in
[the agents proposal](../proposals/agents.md).

## What changes

Before, each repository told Claude Code which session to resume by its id: `HOST_SESSION` (and
`HOST_SESSION_<DIR>`) in `.devcontainer/.env`, kept current by the `claude-host-pin` hook; several
sessions were a `SESSIONS` list in the root Taskfile for `devcontainer:claude:fleet`; some
repositories added a join script of their own. After, a repository lists its agents once, by name,
and starts any of them with one verb. The CLI finds each session again by its name and folder, so
nothing is pinned.

| Before | After |
| --- | --- |
| `task devcontainer:claude` (`DIR=`, `SESSION=`) | `task devcontainer:agent -- <name>` |
| `task devcontainer:claude:fleet` with `SESSIONS` | `kind: resident` entries; they start with the container (`agents:up`), `task devcontainer:agent -- <name>` attaches |
| `task claude-code:host` / `claude-code:fleet` inside | `task agents -- <name>` / `task agents:up` |
| `HOST_SESSION`, `HOST_SESSION_<DIR>` in `.devcontainer/.env` | the agent's `name` in the list |
| the `claude-host-pin` SessionStart hook | nothing (the name survives `/clear`) |
| a join script (attach to the running session, else start it) | a `resident` entry: start always attaches |

## Steps

1. **Take the releases.** Re-run the bootstrap (it vendors `devcontainer.yml` with
   `devcontainer:agent`), and make sure `devcontainer.json` pulls `claude-code:1` (1.7.0 or later
   brings `agent-adapter-claude`).
2. **Add the Feature** to `.devcontainer/devcontainer.json`:

   ```json
   "ghcr.io/nabil-becker/devcontainer-features/agents:1": {}
   ```

   It needs the go-task Feature for the `agents:*` tasks (the registry include in the root
   Taskfile is already there in a bootstrapped repository).
3. **Write `.devcontainer/agents.yml`**, one entry per session you start today. A `SESSIONS` line
   `name|session-variable|dir|extra claude args` becomes:

   ```yaml
   agents:
     - name: host              # the label of the SESSIONS line
       cli: claude
       kind: on-demand         # resident: keep it running in the background, attach on start
       folder: .               # the dir of the line, relative to the repository root
       args: [--remote-control]  # the extra claude args, one list item each
   ```

   Pick the kind per agent. `resident` runs in the background from the container's start and
   start attaches to it; `on-demand` opens a new interactive session each time (`--resume` for its
   latest conversation). An agent you drive from your phone through Remote Control stays
   `on-demand` with `--remote-control` in `args` until a background session is shown to be
   reachable that way (the proposal's fact 5). Several agents may share a folder.
   `task agents:check` (or `task devcontainer:agent:list`) reads the list and names any problem by
   line. Keep the file elsewhere with `AGENTS_FILE=<repo-relative path>` in `.devcontainer/.env`
   or `containerEnv`.
4. **Rebuild** (`task devcontainer:rebuild`), then `task devcontainer:agent:list`: each agent with
   its state. The residents were started by the container start; `task devcontainer:agent --
   <name>` attaches. A resident in a folder Claude Code has never trusted fails with `Workspace not
   trusted`: run `claude` there once and accept.
5. **Rename the task** wherever it is named: your README, skills, start-up scripts and
   `DEVCONTAINER_CONTRIBUTION.md` say `task devcontainer:agent -- <name>` (host) and `task agents --
   <name>` (inside) instead of `devcontainer:claude`, `claude-host`, `claude-code:host`.
6. **Remove the old pieces** once the new verb works for you:
   - `HOST_SESSION` and every `HOST_SESSION_<DIR>` line from `.devcontainer/.env` (and from a root
     `.env` or `.env.example`);
   - the `claude-host-pin` entry under `hooks.SessionStart` in `.claude/settings.json`;
   - the `SESSIONS` var of the `devcontainer` include in the root Taskfile;
   - a join script of your own and its tests (the `agents` and adapter unit tests in this
     collection cover the same cases with a fake `claude`).

## agents 1.0.1, claude-code 1.8.0, devcontainer-cli 1.14.0: a list that cannot be read, a retitled session, reset

What you see changes; nothing to edit unless you wrap `claude`.

- `task agents:list` (and `devcontainer:agent:list`) shows **`error`**, not `unknown`, when the CLI is
  there but its session list could not be read, with the reason below the table (for Claude Code: the
  call, its exit code or time-out, and Claude Code's own first line). `unknown` now means only "this
  CLI cannot list sessions at all".
- `task agents -- <name>` and the container start **start no resident** on an `error`: they say why,
  print how to resume by hand (`claude agents`; `cd <folder> && claude --resume`, pick the agent) and
  exit 1 (the container start goes on). Before, they started every resident as a fresh session, and
  the agents lost their context. `--resume` of an on-demand agent opens Claude Code's own picker
  instead of failing.
- An on-demand agent shows **`none`** unless a session runs (it showed its last stopped session).
- **A retitled session is still the agent's.** Claude Code can retitle a background session after a prompt; with
  claude-code 1.7.0 the agent then looked stopped, and `task devcontainer:agent -- <name>` started a second session
  beside the live one. 1.8.0 records each agent's session (in the Feature's volume) and finds it by that record. Until
  you take it, `/rename <agent name>` in each agent's session is the workaround; after it, not needed.
- **`task agents:reset -- <name>... | --all`** (`task devcontainer:agent:reset` from the host, devcontainer-cli 1.14.0)
  puts the agents' sessions in order instead of a script of your own: per agent the running session is kept, the other
  running ones are stopped (conversations kept), the record set again, a resident with none running started;
  `--purge` also removes the ended ones. Only the listed agents and their folders; a dry run unless `--yes`. It does
  not stop a session that is mid-turn, and with `--purge` does not remove a session where the folder has uncommitted
  changes (a plain reset only warns about them); `--force` overrides both. Refused from inside a Claude Code session. After the duplicates of a
  retitled agent: `task agents:reset -- --all`, read the plan, then `-- --all --yes`.
- **A wrapper around `claude`** that puts `--add-dir <dir>` before every argument breaks
  `claude agents --json` (`--add-dir` swallows `agents`; Claude Code answers `unknown option
  '--json'`), and the message now says a wrapper may be the cause. Drop the wrapper and set the
  claude-code option `"additionalDirectories": "<dir>[,<dir>...]"` (1.8.0): every session gets the
  folders, through a managed-settings file. It grants file access only; `--add-dir` also loaded the
  folder's `CLAUDE.md` and skills.

## agents 1.x to 2.0.0: one live copy per stateful agent

agents 2.0.0 gives every stateful agent an exclusive lease: a start through `agents` takes it
first, so a second start of a resident joins the running one and a second start of an on-demand
agent is refused while the first runs. Every entry of a 1.x list is stateful. The design is in
[the agents v2 proposal](../proposals/agents-v2.md), sections 5, 6, 8 and 12.

**Most repositories edit nothing.** What changes for a list with none of the new keys:

| What | 1.x | 2.0.0 | What to do |
| --- | --- | --- | --- |
| An entry without `lifecycle` | not a concept | `stateful`, `lease: container`, `identity` = its name | nothing |
| A resident started twice | the second attaches | the same, under the lease: two concurrent starts are one start and one join | nothing |
| An on-demand agent started in a second terminal while one runs | a second session | **refused** (exit 2), naming the holder | add `lifecycle: ephemeral` to an agent you run several of at once; its `--resume` is then refused |
| Duplicate sessions started outside `agents` | reported (`+N`) | still reported | nothing |
| First start after the upgrade | | a session already running is adopted; nothing restarts | nothing |
| A container restart | residents woken or started | the same; the old lease is dead (another container start) and taken over | nothing |
| `task agents:list` | `NAME KIND CLI STATE ID FOLDER` | adds `LIFECYCLE` and `LEASE` | a script reads `-- --json`, whose fields are only added to |
| `agents` / `task agents` with no name | the usage, exit 2 | the same, unless one agent is marked `default: true` | nothing; mark one to start it with no name |
| State | the markers folder | the same folder plus `leases/`, no volume | nothing |
| claude-code | the 1.8.x adapter | the same adapter works | nothing |
| Pin | `agents:1` | `agents:2` | change the Feature reference; `agents:1` never moves to 2 |

Steps:

1. Change `ghcr.io/nabil-becker/devcontainer-features/agents:1` to `agents:2` in
   `.devcontainer/devcontainer.json` and rebuild.
2. If anyone runs one on-demand agent in several terminals at once (a reviewer, a pair), give it
   `lifecycle: ephemeral`, or give each copy its own entry.
3. Optionally mark the agent you start most `default: true`; `task agents` with no name (from the
   host, `task devcontainer:agent` with no name) then starts it.
4. A refused start names the holder. If that holder is gone (a crashed terminal, an agent stopped
   outside `agents`) and the lease was not taken over on its own, `task agents:release -- <name>`
   frees it; `task agents:leases` shows every lease. `--force` frees a live one, which lets a
   second copy start.

The new keys `identity` and `definition` are read, checked and shown in 2.0.0 but not yet handed
to the CLI; keep the CLI profile (`--agent ...`) in `args` until the release that passes
`definition` (a later 2.x with claude-code 1.9.0). A list may not set both. A 2.x list on a 1.x
install reads the new keys as unknown (a warning) and takes no lease: the pin prevents that.
Each consumer's `.devcontainer/DEVCONTAINER_CONTRIBUTION.md` carries the line.

## What still works until claude-code 2.0

`claude-host`, `claude-fleet`, `claude-host-pin`, `task claude-code:host`, `task
claude-code:fleet`, `task devcontainer:claude` and `task devcontainer:claude:fleet` keep working
in claude-code 1.7.0 and devcontainer-cli 1.13.0. Each prints one line on stderr saying it is
deprecated and that claude-code 2.0 removes it. Nothing else about them changed, so you can move at
your own pace, one agent at a time; the old and the new verb see the same sessions (both read
`claude agents --json`), but only the new one finds them by name, so give a session started the old
way a name (`/rename <agent name>`) or let it end before the agent's first start the new way, or
`task agents -- <name>` will start a second session beside it.

## What 2.0 removes

claude-code 2.0.0 removes `claude-host`, `claude-fleet` and `claude-host-pin` and their tasks;
the next devcontainer-cli minor after it removes `devcontainer:claude` and
`devcontainer:claude:fleet`. In this collection's own repository that release also drops
`SESSIONS` from `Taskfile.yml`, `HOST_SESSION` from `.devcontainer/.env`, the pin hook from
`.claude/settings.json` and the `test:claude-fleet-task` test.
