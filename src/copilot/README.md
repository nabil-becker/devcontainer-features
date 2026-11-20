
# GitHub Copilot CLI (copilot) (copilot)

GitHub Copilot CLI (https://docs.github.com/copilot/concepts/agents/about-copilot-cli) as a member of this collection's ecosystem, and the second vendor for the participant component's contracts: brings the CLI in through dependsOn on the official ghcr.io/devcontainers/features/copilot-cli (which installs it; this Feature installs no binary of its own) and adds agent-adapter-copilot (new, resume, run-once for the facilitator's pump, mcp-attach; exit 3 for the verbs Copilot has no local route for), the participants option (the participant component, one shared copy with claude-code), the attach option (attach: facilitator registers the facilitator's MCP entry through `copilot mcp add`, with no token in it), COPILOT_HOME as a named volume so a copilot login survives rebuilds, and a post-create hook (copilot-setup) that makes it usable and private. Never logs in and never stores a token. Plus the Feature Taskfile.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/copilot:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| participants | Install the participant component: the agent list (.devcontainer/participants.yml or PARTICIPANTS_FILE; agents.yml and AGENTS_FILE still work), the agents command and the agents:* tasks, which call agent-adapter-copilot for an entry with cli: copilot. One copy in /usr/local/lib/dcf-participant, shared with claude-code and the deprecated agents Feature, whichever installs it (the newest wins). Copilot has no local background mode, so a copilot participant is on-demand or ephemeral, never resident. | boolean | false |
| attach | 'facilitator': at post-create (and by task copilot:attach) register the facilitator's MCP entry through Copilot's own command (copilot mcp add facilitator ...), so a Copilot session can use receive, reply, say and who. The entry carries no token: the harness starts copilot with FACILITATOR_HANDLE and FACILITATOR_TOKEN in its environment. Does nothing, and says so, while the facilitator Feature is not installed. Empty: nothing is registered. Other values are reserved and fail the build. | string | - |

## How it fits

```text
  ghcr.io/devcontainers/features/copilot-cli --dependsOn--> copilot (the CLI, installed there)
                                                               |
  participant component <-- agent-adapter-copilot -------------+   copilot mcp add facilitator
  (participants: true; one copy,                               |        ^
   shared with claude-code)                                    |        | attach: facilitator
                                                               v        |
              volume: COPILOT_HOME  (login, settings, sessions, mcp-config.json)
              gh  --installsAfter--  (a gh login token is one way Copilot gets its token)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Login (when made with `copilot login`), settings, session history, the facilitator MCP entry | named volume at `COPILOT_HOME` (`/var/lib/devcontainer-features/copilot`); a repo may bind-mount a host folder there | 4 working set |
| Agent list (with `participants: true`) | `.devcontainer/participants.yml` in the repository | 1 git |
| Leases and start markers (with `participants: true`) | `/var/lib/devcontainer-features/agents`, not a volume; a lease must not survive a rebuild | 4 working set |
| A token in `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` | the environment of the process that starts copilot; this Feature stores none | not stored |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What this Feature is

GitHub Copilot CLI (`copilot`) as a named agent beside Claude Code in a devcontainer, on the engineer's
own Copilot subscription. It is the second real vendor for the participant component's contracts
(NFR-12, ADR-0037): a contract that works on Claude Code and on Copilot, not on one of them.

It is an **augmentation** of the official Feature (NFR-4). It installs no binary and downloads
nothing. What it adds:

- **`agent-adapter-copilot`**, the participant component's adapter for the Copilot CLI (below).
- **`participants`**, the participant component, exactly as `claude-code` installs it, into one shared
  place.
- **`attach`**, the facilitator's MCP entry, registered through Copilot's own command.
- **`COPILOT_HOME` as a named volume**, so a login survives a rebuild, made usable and private by a
  post-create hook (`copilot-setup`).
- The Feature Taskfile (`copilot:version`, `login`, `config`, `setup`, `attach`).

## The CLI comes from the official Feature (`dependsOn`)

GitHub publishes `ghcr.io/devcontainers/features/copilot-cli` (in `devcontainers/features`, maintained by
the VS Code and Codespaces teams). NFR-4 says to augment an official Feature, and this one does it
through `dependsOn`, which is **an exception to this repository's "installsAfter only" rule**
(CONTRIBUTING): the Operator chose it on 2026-11-20, after the host asked, so that listing only
`ghcr.io/nabil-becker/devcontainer-features/copilot:0` gives an image with `copilot` in it. `az` and
`phi-check` do the same with the Azure CLI and Python.

```json
"dependsOn": { "ghcr.io/devcontainers/features/copilot-cli:1": {} },
"installsAfter": [ ".../go-task", ".../common-utils", "ghcr.io/nabil-becker/devcontainer-features/gh" ]
```

`installsAfter` `gh` stays: Copilot reads `GH_TOKEN` and `GITHUB_TOKEN`, so a repo that wants the gh login
to serve as Copilot's token (with a token that carries the Copilot Requests permission, see Login) gets
gh set up first. It is `installsAfter`, never `dependsOn`: Copilot does not need gh.

What follows from using the official Feature, which this Feature does not change:

- **There is no `version` option here.** A Feature's option cannot be passed into its `dependsOn`
  (the entry is fixed text), so there is nothing to forward. To pin, list the official Feature yourself
  with its `version` (`"ghcr.io/devcontainers/features/copilot-cli:1": {"version": "1.0.114"}`); the
  devcontainer CLI then installs it **twice**, once with each set of options, and which run comes last,
  so which version stays, is not fixed by the spec (the same finding as `az`'s). Say so on the backlog
  if you need a hard pin.
- **Its install is not checksum-verified, and `latest` is a moving target.** The official `install.sh`
  downloads `copilot-linux-<x64|arm64>.tar.gz` from the GitHub release with `wget` and unpacks it without
  checking it against the release's `SHA256SUMS.txt` (NFR-3 is the official Feature's gap, not this one's,
  which downloads nothing). With `version` on `latest` or `prerelease` it also runs `copilot update` at
  every container start (a flag file, `/etc/devcontainer-copilot-cli/auto-update`). Copilot itself also
  updates when a session starts, unless `COPILOT_AUTO_UPDATE=false`. A repo that needs a reproducible
  Copilot sets a version on its own entry of the official Feature and `COPILOT_AUTO_UPDATE=false` in its
  `containerEnv`.
- **It leaves the binary owned by the publisher's CI user.** The official `install.sh` unpacks the release
  archive as root and tar keeps the archive's owner (`runner`, uid 1001), so `/usr/local/bin/copilot` is
  not root's. This Feature runs `chown root:root` on it at build (the one thing of the official install it
  touches), and its scenario checks that the owner is root.
- **Debian and Ubuntu only** (apt), as the official Feature says.
- When `copilot` is absent anyway (a tool that ignores `dependsOn`), `install.sh` prints a loud warning
  and still installs the adapter, the hook and the Taskfile; `copilot-setup` repeats the warning.

## Options

| Option | Default | What |
| --- | --- | --- |
| `installTaskfile` | `true` | the Feature Taskfile |
| `participants` | `false` | install the participant component (one shared copy) |
| `attach` | empty | `facilitator`: register the facilitator's MCP entry; other values fail the build |

## Participants (`participants`)

`"participants": true` runs the participant component's own installer (`participant/install-participant.sh
--by copilot`), the same one `claude-code` runs. One copy lands in `/usr/local/lib/dcf-participant`; when
`claude-code`, the deprecated `agents` Feature or another Feature has put the same or a newer copy there,
nothing is copied (the newest wins, ADR-0061), so Claude Code and Copilot together leave one copy and one
`agents` command, in either order. The list is `.devcontainer/participants.yml`:

```yaml
participants:
  - name: copilot-lead
    cli: copilot
    kind: on-demand
```

Copilot CLI has no documented local background session, session list or stop, so a copilot participant is
**on-demand or ephemeral**. A `kind: resident` entry falls back as the component says: `agents` reports
that copilot has no background mode and opens a new session in the terminal instead (it runs as
on-demand), and starts nothing on a guess. There is therefore no start hook in this Feature (`claude-code`
has one for its residents). Lease liveness has no adapter list to ask, so the component uses its own
record (ADR-0037).

## The adapter (`agent-adapter-copilot`)

On PATH, root-owned; the component and the facilitator's pump call it, nothing else does. It follows the
contract in the agents NOTES ("The adapter contract"): `<verb> <name> <folder> [-- copilot args]`, exit 0
done, 1 failed, 2 bad use, 3 not supported. `supports` lists the verbs that work, and a Docker-free test
checks that it agrees with every verb (`test/agents/unit/contract_test.sh`, the contract tests that run
against two fake adapters and now the two real ones).

| Verb | Copilot |
| --- | --- |
| `new` | `copilot --name <session name>` in the folder (a terminal is needed) |
| `resume` | `copilot --resume <session name>` in the folder |
| `hint` | prints how to resume by hand |
| `run-once` | one non-interactive turn, for the facilitator's pump: the prompt on stdin, the reply on stdout, `copilot -p <prompt> --silent --no-ask-user --no-auto-update` |
| `mcp-attach facilitator` | `copilot mcp add facilitator ...` (see Attach); not a verb of the contract yet |
| `start-bg`, `wake`, `attach`, `list`, `stop`, `logs`, `record`, `session-*` | exit 3: no local background session, list or stop |
| `trust` | exit 3: Copilot keeps its trusted folders in its own `config.json`, which a Feature never edits (NFR-13); `--trust-folder` trusts one prompt-mode run only |

The session name is `AGENT_SESSION_NAME` when the caller sets it (one line), else the handle.

**`run-once` and trust.** With no one to ask, a tool the CLI would ask about is refused. A turn may use
tools only when the caller passes `--allow-tool '<rule>'` after `--`, or sets
`AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS=1` (`--allow-all-tools`, off by default: an unattended turn that
runs shell commands is the engineer's decision, not the adapter's). `AGENT_ADAPTER_COPILOT_CONTINUE=1`
keeps one conversation per name and folder across turns with `--session-id` set to a UUID derived from
both; unset, each turn is a fresh session and carries its own context (the facilitator sends the
conversation with each message). The prompt travels as an argument (that is what `-p` takes), so other
processes of the same Linux user can read it in the process list; it is refused above 100000 bytes.

## Attach (`attach`)

`attach: facilitator` registers the facilitator's MCP server in Copilot **through Copilot's own command**,
never by editing a file (NFR-13): at post-create, and by `task copilot:attach` at any time. It needs **no
login** (`copilot mcp add` only writes `mcp-config.json` in `COPILOT_HOME`; checked on Copilot CLI 1.0.114).

The entry is one, named `facilitator`:

```text
copilot mcp add facilitator -- sh -c 'exec facilitator mcp --as "${FACILITATOR_HANDLE:?...}"'
```

- **No token in the entry (ruling O).** The facilitator's participant token (`FACILITATOR_TOKEN`) is made
  again at every container start, so an entry holding it would go stale and leak into a file. The
  harness starts copilot with the token in its environment, and the MCP server it starts inherits it.
- **No handle in the entry either.** The facilitator's own snippet names the handle in the entry
  (`facilitator mcp --as <handle>`), but one `COPILOT_HOME` serves every Copilot participant in the
  container, and an entry per handle would give each session every handle's server. So the entry takes
  the handle from `FACILITATOR_HANDLE`, and the harness starts a participant as
  `FACILITATOR_HANDLE=copilot-lead FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/copilot-lead)" copilot`.
  The two variables are this Feature's convention; the facilitator reads `--as` only today.
- **With no facilitator on PATH** it registers nothing and says so ("the facilitator Feature is not
  installed; there is no entry to register"); the intent stays in the option, and `task copilot:attach`
  registers once the facilitator is there. A rerun replaces the entry (remove, then add), so it is
  idempotent and a stale entry never stays.
- **Unverified without a login:** that Copilot starts the stdio server with its own environment (the
  CLI's documentation does not say). The manual checklist below covers it; if it does not, the fallback
  is `--env` on the entry, which puts a token in a file and so needs the Operator's say.

## Login (this Feature never logs in and never stores a token)

The Feature keeps `COPILOT_HOME` (`/var/lib/devcontainer-features/copilot`) as a named volume and nothing
else: no login, no token, no token variable in `containerEnv` (NFR-13). Copilot takes its token from, in
this order of precedence, from GitHub's CLI documentation:

1. `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN` in the environment of the process that
   starts copilot (these win over a stored login; in Codespaces the auto-injected `GITHUB_TOKEN` does not
   win over a `/login` account).
2. A login made with `copilot login` (the device-code flow in a devcontainer; `task copilot:login`), or
   `copilot login --with-token` with the token on standard input. Copilot stores it in the system
   credential store, or, with none (there is none in a devcontainer), in a plain file under `COPILOT_HOME`,
   which is the Feature's volume: it survives rebuilds and sits at storage tier 4.

The token must be a **fine-grained personal access token with the "Copilot Requests" permission**, or an
OAuth token from the GitHub Copilot CLI app or from the GitHub CLI (`gh`) app. **Classic personal access
tokens (`ghp_`) are not supported.** Where the token comes from (OpenBao, the Operator's shell) is the
harness's choice, not this Feature's; for the facilitator's pump the Operator's ruling is that it comes
from OpenBao into the environment of `facilitator serve`.

`COPILOT_HOME` must not be writable by group or other: Copilot refuses to write to one that is ("The
storage directory is writable by group or other users"; found while building this Feature). Docker
volumes arrive owned by root and mode 755, so `copilot-setup` hands the folder to the remote user with
`dcf-persist` and runs `chmod go-w` on its top level. A bind mount a repo puts on the same target is
treated the same.

## What works without a login, and what needs one

| Without a login | Needs a login (or a token) |
| --- | --- |
| install, `copilot --version`, `copilot mcp add|list|remove` and so `attach` | `copilot` itself, interactive or `-p` |
| `copilot-setup`, the volume, its permissions | `agent-adapter-copilot new`, `resume` and `run-once` (they start the CLI) |
| `agent-adapter-copilot supports`, `hint`, `mcp-attach`, exit 3 for the rest | the facilitator's pump through `run-once` |
| the participant component, `agents check`, `agents list` | |

No automated test needs a login. The Docker-free adapter tests use a fake `copilot`; the Feature scenarios
use the real CLI for `--version` and `copilot mcp` only.

## Manual checklist (with your own Copilot subscription; none runs in CI)

1. `task copilot:login` (or export `COPILOT_GITHUB_TOKEN` with a fine-grained token that has "Copilot
   Requests"); `task copilot:config` shows no value, only where the login comes from.
2. Rebuild the container; the login is still there (`copilot` starts without asking).
3. `printf 'Say hello in five words.' | agent-adapter-copilot run-once pilot "$PWD" --` prints a reply and
   exits 0. Run it with a folder you have never opened in Copilot: it must not hang on a trust prompt (the
   undocumented cell: `-p` and trust). Note what happens.
4. `AGENT_ADAPTER_COPILOT_CONTINUE=1`: run two turns, the second asking for the first's answer; the same
   UUID must resume the session (the undocumented cell: `--session-id` with `-p`).
5. `agent-adapter-copilot new pilot "$PWD"` opens a session named `pilot`; leave; `resume pilot "$PWD"`
   resumes it by name (does `--resume <name>` find it?).
6. With the facilitator Feature and a participant `pilot` of `cli: copilot` registered: `task copilot:attach`,
   then `FACILITATOR_HANDLE=pilot FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/pilot)" copilot`, and
   ask it to call the `who` tool. If it does not see the tools, the entry's environment did not reach
   the server: say so (see Attach).
7. A resident entry (`kind: resident`, `cli: copilot`) in the list: `task agents -- dozer` says copilot has
   no background mode and opens a session in the terminal.

## Anti-patterns

### Don't put a token in `copilot mcp add --env`

The facilitator's token is made again at each container start and lives in the environment of the
harness. An `--env FACILITATOR_TOKEN=...` entry writes it to `mcp-config.json`, where it goes stale and
sits in a file. Use the environment.

### Don't edit `config.json` for trusted folders

It is the CLI's own state (trusted folders, signed-in accounts, plugins). A Feature that writes it breaks
the line "manage the environment, not the CLI" (NFR-13); `trust` answers exit 3 for that reason.

## Pairs with

- `ghcr.io/devcontainers/features/copilot-cli`, pulled in through `dependsOn`, for the CLI itself.
- **claude-code**: the first vendor of the participant component; both with `participants: true` leave one
  copy of the component.
- **facilitator**: `attach: facilitator` registers its MCP entry; its pump runs `agent-adapter-copilot
  run-once`.
- **gh**: ordered before this Feature with `installsAfter`; a token from its login can serve as Copilot's
  (`GH_TOKEN`) when it has the Copilot Requests permission.
- **go-task**: the Taskfile (`copilot:*`).

## Changes

### [0.1.0] - 2026-11-20

#### Added

- **The first version: GitHub Copilot CLI as a named agent beside Claude Code** (backlog
  `copilot-feature`, ruling D20, ADR-0061). It is 0.1.0, not 1.0.0: the CLI itself is generally available
  (1.0.x), but this Feature's adapter and `attach` have been run only against a fake `copilot` and the
  real CLI's `--version` and `mcp` commands, never with a Copilot login (see the manual checklist in the
  notes); 1.0.0 follows that run.
- **It depends on the official Feature (NFR-4, the Operator's ruling of 2026-11-20).**
  `dependsOn` on `ghcr.io/devcontainers/features/copilot-cli:1` installs the CLI; this Feature installs no
  binary and downloads nothing. That is this repository's exception to "`installsAfter` only", made by
  the Operator, as `az` and `phi-check` do. `installsAfter` `gh` stays. There is **no `version` option**:
  an option cannot be forwarded into `dependsOn`, so to pin, list the official Feature with its own
  `version` (the devcontainer CLI then installs it twice, and the final version is not fixed by the spec).
  The official Feature's own install is not checksum-verified, `latest` self-updates, and it leaves the
  binary owned by uid 1001 (the release archive's owner), which this Feature hands to root; see the notes.
- **`agent-adapter-copilot`**, the participant component's adapter for the Copilot CLI: `new`, `resume`,
  `hint`, `run-once` (one non-interactive turn through `copilot -p`, for the facilitator's pump) and
  `mcp-attach`. Verbs Copilot has no local route for (`start-bg`, `wake`, `attach`, `list`, `stop`,
  `logs`, `record`, `session-*`) and `trust` answer exit 3. A copilot participant is on-demand or
  ephemeral, never resident. The contract tests (`test/agents/unit/contract_test.sh`) now run against the
  real Copilot adapter as well as the two fakes.
- **The `participants` option** (boolean, default `false`): installs the participant component exactly as
  `claude-code` does, one shared copy in `/usr/local/lib/dcf-participant` (component 1.1.0).
- **The `attach` option** (`facilitator`, or empty): registers the facilitator's MCP entry through
  `copilot mcp add facilitator` at post-create and by `task copilot:attach`. It needs no login. The entry
  holds no token and no handle: start copilot with `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN` in its
  environment. It does nothing while the facilitator Feature is not installed.
- **`COPILOT_HOME` is a named volume** (`/var/lib/devcontainer-features/copilot`), so a `copilot login`
  survives rebuilds, and `copilot-setup` makes it usable and owner-only (Copilot refuses a home writable
  by group or other). The Feature never logs in and never stores a token (NFR-13).
- The Feature Taskfile: `copilot:version`, `copilot:login`, `copilot:config`, `copilot:setup`,
  `copilot:attach`.

Nothing to do: a new Feature. To use it, add `ghcr.io/nabil-becker/devcontainer-features/copilot:0`
and sign in with `task copilot:login`, or set `COPILOT_GITHUB_TOKEN`.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/copilot/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/copilot/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
