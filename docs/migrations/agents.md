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

## agents 1.0.1 and claude-code 1.8.0: when the session list cannot be read

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
- **A wrapper around `claude`** that puts `--add-dir <dir>` before every argument breaks
  `claude agents --json` (`--add-dir` swallows `agents`; Claude Code answers `unknown option
  '--json'`), and the message now says a wrapper may be the cause. Drop the wrapper and set the
  claude-code option `"additionalDirectories": "<dir>[,<dir>...]"` (1.8.0): every session gets the
  folders, through a managed-settings file. It grants file access only; `--add-dir` also loaded the
  folder's `CLAUDE.md` and skills.

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
