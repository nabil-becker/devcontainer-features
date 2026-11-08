# Proposal: least privilege for agents, ending in one agent Linux user

Status: proposed 2026-11-06, revised the same day (below). Awaits the Operator's ruling; build not
started. Backlog: `agent-linux-user`, moved to Now by `amend-agent-linux-user` (2026-11-06), and
`least-privilege-first`; `key-file-rotate` waits on it. Basis:
[agent-least-privilege-inventory.md](agent-least-privilege-inventory.md) (the inventory).

## Revision 2026-11-06

**What changed.** The first draft gave every identity in the agent list and every back its own
Linux user, with a shared group, name-derived uids, a hand-over to back users through `sudoers` and
an `agents boundary` check. On 2026-11-06 the Operator ruled **least privilege first, MVP**:
configure what already exists (each agent CLI's own OS sandbox, server-side GitHub rules, narrow
tokens, OpenBao policies, a separate Linux user without `sudo` or `docker`) before building
anything. This revision re-scopes the proposal to that MVP, in the inventory's delivery order:
eight steps of configuration, of which only the last but two (one `agent` user) changes how an
agent starts, and that one in its smallest form. Everything else of the first draft is kept as one
line each in section 12 ("Later"). Custom brokers (draft #187, `docs/proposals/brokers.md` on
`docs/broker-pattern/1`) are on hold and not part of this proposal; they are named only as the
later route for a residual with no native control (section 3.3).

**The architecture review below was of the earlier design** and is left as it was written. Its
sixteen findings against this revision (the inventory's section 6.1 mapping, checked; where this
revision differs from the inventory it says why):

| Finding | Now | Why |
|---|---|---|
| 1 git dir `config` not protected by its owner | residual, maybe closed in the container | ownership is no longer the control; the sandbox's `denyWrite` is by path (step 3) if test T3 passes; the workstation's own git stays open (3.3) |
| 2 every adapter verb as the agent's user | **closed by design** (the inventory said n/a) | step 6 does make one agent user, so it applies: `agents` calls every adapter verb through the switch, not only `start` (6.6) |
| 3 backs' `sudoers` rule too wide | n/a | no back users, no `sudoers` rule; the backs run as the user that runs the hooks |
| 4 cost report reads one user's transcripts | n/a | the agent user holds the whole Claude state volume (6.4), so all transcripts are in one place |
| 5 Claude memory path moves (ADR-0049) | n/a | the volume is handed over whole; no path moves |
| 6 Operator's long-lived processes miss the group | n/a | no new group: the agent's primary group is the remote user's own (6.5) |
| 7 ADR-0055's unix-socket listener | closed (step 5, effective with step 6) | an OpenBao listener setting; useful once the agent is not the remote user |
| 8 boundary check knows other Features | n/a | no `agents boundary` in the MVP; tests T1 and T9 check the paths (Later: a protected-paths contract) |
| 9 per-user Claude login in the agents Feature | n/a | one agent user keeps the existing login (6.4) |
| 10 token route rests on a long-lived daemon | n/a (the inventory said residual) | no `setup-token` route: the agent user keeps the existing login, so nothing is rotated into a running daemon |
| 11 `agents boundary` and the linter contract | n/a | not built |
| 12 shared names without an owner (`dcf-work`) | n/a | no shared group |
| 13 plain-`claude` warning has no mechanism | closed | a `SessionStart` hook in the managed settings (step 6, claude-code) |
| 14 tokens at rest outside ADR-0048 decision 1 | residual, named interim | the host's fine-grained GitHub token (step 1) until `openbao-agent-login`; decision 3 |
| 15 openbao version disagreement | n/a | the share tasks' refusal by user is not in the MVP (Later) |
| 16 cloud-folder `sync` and `host` modes | residual | step 7 sets access for `mount`; `sync` and `host` stay as they are (T12) |

## Who this serves

The Operator, through the host, who turned the OpenBao key file on before agents had their own user
(ADR-0056 decisions 8 and 9) and rotates it once they do; the maintainers of the office and of DSNP,
who adopt the `claude-code`, `gh`, `git`, `openbao`, `agents` and `cloud-folder` Features and today
keep secrets in a container where every agent can read them; and the engineers whose agents run in
those devcontainers, who must not lose a working session, a commit or a file to a permission error.

How to read it: section 1 is the ask; section 2 what was checked; section 3 the threat model and
what the MVP does not fix; section 4 the picture; sections 5 to 9 the eight MVP steps (each with its
owning Feature, the setting, the version bump and what a consumer changes); section 10 the slices;
section 11 the tests; section 12 what is kept for later; section 13 for the repository; section 14
the decisions. The architecture review (of the earlier design) is at the end.

## 1. The ask

The backlog item: "Claude Code and the background agents run as the Operator's user, so any agent
can read a key file kept in the container. Give agents a separate Linux user with no passwordless
`sudo`, then check that user cannot read the key file." The Operator's amendment of 2026-11-06 asked
for "their own independent Linux users"; the ruling of the same day put least privilege through
existing controls first and asked for the MVP.

Rulings it rests on: **ADR-0056 decisions 8 and 9** (the key file is on before agents have their own
user; `key-file-rotate` after); **ADR-0048** decision 1 (OpenBao is the master of every token) and
decision 4 (share tasks refuse inside an agent's job, today by variables); **ADR-0032** (Feature
settings go to Claude Code's managed settings, `/etc/claude-code/managed-settings.d/`, not the
user's file); **ADR-0036** (an agent's `identity`); **ADR-0020** (every container sees all of
`/git-dirs`); **ADR-0040** (the host commits, pushes and opens pull requests; the Operator merges);
**ADR-0055** (root-token generation on the loopback listener); **NFR-5, NFR-12, NFR-13** (Features
user-neutral; a contract works on two vendors; manage the environment, use the CLI's own features).

## 2. What was checked (2026-11-06)

The full table is the inventory's section 2; in short:

- Every actor (the host session, its cons, the four backs, a consumer's agent) is one user,
  `vscode` (uid 1000), with passwordless `sudo` and the `docker` group. Either is root.
- Everything a credential lives in (`$OPENBAO_STATE_DIR`, its `approle/`, `GH_CONFIG_DIR`,
  `rclone.conf`, the ssh-agent socket, `$CLAUDE_CONFIG_DIR`) is that user's, so every agent reads it.
- The checkout and `/git-dirs` are 9p mounts showing `root` 777; files made in the container keep
  their Linux owner. Every repository's git dir is writable, `config` and `hooks/` included.
- Claude Code 2.1.311's sandbox can start here (`bwrap` works as `vscode`) but is **not turned on**;
  no managed settings exist here (`/etc/claude-code/` is absent).
- Outbound HTTPS is open; OpenBao answers on loopback; Codex is not installed.
- `task repo:govern` already applies a `protect-main` ruleset here (no deletion, no force push,
  linear history, pull requests with one approval including code owners, the four required
  checks), and `.github/CODEOWNERS` covers `*`. The ruleset's bypass list has the repository Admin
  role in `pull_request` mode (section 13).

## 3. Threat model

### 3.1 Who and what

The attacker is an agent: a Claude Code session, a con inside it, a back, or anything they start,
doing what it should not because a prompt, a file or a tool output told it to, or by mistake. The
Operator, the workstation's Windows account and the container engine are trusted. A kernel escape
from a privileged container is out of scope.

### 3.2 What an agent must not read or do, and which step closes it

| # | Must not | Closed by (step) | Left open |
|---|---|---|---|
| A1 | Change GitHub rules, merge to `main`, release, or push to `main` | 1: ruleset, narrow token | the admin bypass while the token acts as the Operator (decision 4) |
| A2 | Read the Operator's OpenBao token, the AppRole ids, `hosts.yml`, `rclone.conf`; use `agent.sock` or `docker.sock` | 2: sandbox `denyRead`, no unix sockets (tool calls); 6: modes under another user (the process) | until step 6, the CLI's own process, hooks and MCP servers (T1) |
| A3 | Lift its own limits (settings, permission mode, unsandboxed commands) | 2: managed `allowManagedPermissionRulesOnly`, `disableBypassPermissionsMode`, `allowUnsandboxedCommands: false` | none inside Claude Code |
| A4 | Write what the Operator runs later (`.githooks/`, `Taskfile.yml`, `.devhost/`, `.claude/settings.json`) or the git dir's `config` and `hooks/` | 3: managed `denyWrite` | the CLI's own process; the workstation's git; review is the only check on a branch (3.3) |
| A5 | Use the backs' reach beyond their job | 4: narrow `claude -p` flags, the tester under `bwrap` | the backs share the host's user (step 6), so the host can read their AppRole ids; each AppRole's policy bounds it |
| A6 | Act as the Operator in OpenBao | 5: a per-agent AppRole with a read-only policy | the loopback listener answers anyone until step 6 and the unix listener |
| A7 | Become root (`sudo`, `docker`) | 6: the `agent` user has neither | the Operator's terminal keeps both, by design (decision 9) |
| A8 | Write the shared folder's records, sign with SSH keys | 7: mount access for the agent user; no key loaded by default | the backs' writes where records live in the shared folder |
| A9 | The same with a second CLI | 8: Codex `workspace-write` | CLIs without a sandbox |

### 3.3 What the MVP does not fix

Stated plainly, so nobody reads the boundary as wider than it is (the inventory's section 5):

- **The docker socket.** Whoever may talk to the daemon is root. Native controls only hide the
  socket (sandbox, group). Narrowing what a permitted caller may ask for needs rootless docker or an
  allow-list proxy, which is a custom broker (on hold).
- **The shared git dir.** `config` and `hooks/` are one set of files for this container, every other
  container of the repository and Windows git. The sandbox may protect them from tool calls (T3);
  nothing native protects them from the workstation's git or a second container (ADR-0020). The
  workstation-side check (the launcher compares `config` before `task dc:*`) is custom, so it waits.
- **Code the Operator runs later.** A branch checked out in the shared checkout is run by the
  Operator's `task`, by `.githooks/`, and by Windows `task dc:*`. The ruleset and CODEOWNERS stop it
  reaching `main`; nothing local stops it running.
- **A tool call versus the process around it.** Claude's sandbox wraps tool calls, not the session's
  own process, its hooks or its MCP servers (T1). Step 6 is what puts a boundary around those.
- **Cons share their parent.** A con is a subagent in its parent's process; its boundary is the
  parent's, and a GitHub rule is the only thing between a con and `main`.
- **`sudo` inside the sandbox fails** (`no_new_privs`). That is a control, and a cost: anything the
  host did by `sudo` moves to the Operator's terminal; a `sandbox.excludedCommands` entry would
  reopen the hole.
- **A domain allow-list keeps a data channel to every allowed domain** (a gist on github.com).
- **Codex is configured from its documentation**, not run here (T5).

## 4. The picture

```
 the Operator's user  vscode (remote user): sudo, docker, OpenBao token, hosts.yml,
 |                    rclone.conf, agent.sock; task dc:shell, VS Code, the launcher's exec
 |
 |  step 6: sudo -n -u agent  (agents start, every adapter verb)
 v
 agent  (one user: no sudo, no docker; primary group = vscode's; umask 002)
 |  its own: Claude state volume (handed over whole), GH_CONFIG_DIR with the narrow token (step 1),
 |           its AppRole ids (step 5), the backs' AppRole ids (shared, bounded by policy)
 |
 +-- claude (the host session)  --- managed settings (steps 2, 3), root-owned, cannot be lifted
 |     +-- tool calls  ====> bubblewrap sandbox: denyRead credentials, denyWrite hooks/Taskfile/
 |     |                     .devhost/git config, network allow-list, no unix sockets
 |     +-- cons (subagents: same process, same sandbox)
 |     +-- Stop hook -> devhost-run-job (runner, outside the sandbox)
 |           +-- scribe/secretary/librarian: claude -p, narrow --allowedTools (step 4), sandboxed
 |           +-- tester: bash under bwrap, credentials hidden (step 4)
 |
 GitHub: protect-main ruleset, CODEOWNERS, the host's fine-grained token (step 1)
 OpenBao: per-agent AppRole, read-only policy (step 5); unix listener for the Operator (step 5/6)
```

## 5. Steps 1 to 3: GitHub, then Claude Code's own sandbox and managed settings

Order: the inventory's, kept. Steps 1 to 5 are settings only: no new user, no new script, no change
to how an agent starts. Step 1 comes first because GitHub is where an agent's mistake becomes
permanent and the ruleset already exists. Steps 2 and 3 share one claude-code release, but step 2
waits for tests T1 and T3 (section 11): if the sandbox does not wrap the file tools and the backs,
or does not protect a git dir reached through a `.git` pointer file, the settings are chosen
differently (decision 2).

### Step 1. GitHub ruleset and a narrow token

| | |
|---|---|
| Removes | GitHub admin power in the agent's hands (inventory G6, G7) |
| Change | keep `protect-main` (already applied by `task repo:govern`); add a tag ruleset protecting release tags and require the release workflow's environment reviewers (both in `Set-RepoGovernance.ps1`); the host's GitHub login becomes a **fine-grained personal access token**: Contents write, Pull requests write, Metadata read, this repository only, an expiry; no Administration, Workflows, Actions or Secrets |
| Owning Feature | none for the ruleset (the repository; `task repo:govern`); `gh` stores the token in `GH_CONFIG_DIR` as today |
| Setting | `task repo:govern`; `gh auth login --with-token` from the Operator's terminal |
| Bump | gh: none (a NOTES patch, "logging in with a fine-grained token", if the slice writes one); no Feature changes |
| A consumer changes | runs its own governance (or the ruleset by hand) and makes a fine-grained token for its repository (T8) |
| Residual | the token is at rest in `hosts.yml` until `openbao-agent-login` (decision 3); the token acts as the Operator, so the ruleset's Admin bypass still lets it merge (decision 4, T6) |

### Step 2. Claude Code's sandbox through the managed drop-in, permissions locked

| | |
|---|---|
| Removes | secrets readable by a tool call, the docker and ssh-agent sockets, open egress, the agent lifting its own limits (G3, G11, G12, G14) |
| Change | the claude-code Feature writes, beside `additionalDirectories`, into the drop-in it already owns (`/etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json`, ADR-0032): `sandbox.enabled: true`, `sandbox.failIfUnavailable: true`, `sandbox.allowUnsandboxedCommands: false`, `sandbox.filesystem.denyRead` (the consumer's list), `sandbox.filesystem.allowWrite` (the checkout, the scratchpad, `/tmp`), `sandbox.network.allowedDomains` with `allowManagedDomainsOnly: true`, `allowLocalBinding: false`, no `allowUnixSockets`; and `allowManagedPermissionRulesOnly: true`, `disableBypassPermissionsMode: "disable"`, `allowManagedHooksOnly` where the consumer has no hooks of its own |
| Owning Feature | claude-code |
| Setting | new options `sandbox` (boolean, default false), `sandboxDenyRead`, `sandboxAllowWrite`, `sandboxAllowedDomains` (comma-separated, like `additionalDirectories`), `lockPermissions` (boolean, default false) |
| Bump | claude-code minor (1.10.0): opt-in, inert until set |
| A consumer changes | sets the options; lists its credential paths (the NOTES give this collection's: `$OPENBAO_STATE_DIR`, `/var/lib/devcontainer-features/{gh,cloud-folder,ssh-agent}`, `$CLAUDE_CONFIG_DIR/.credentials.json`, `/var/run/docker.sock`, `~/.ssh`) and its domains; moves anything it did by `sudo` from an agent session to the Operator's terminal |
| Residual | the CLI's own process, hooks and MCP servers (T1); a data channel to an allowed domain |

The credential paths are listed by the consumer in this MVP rather than shipped by each Feature:
each Feature writing its own protected paths for the sandbox would put CLI knowledge in it
(NFR-13), and a CLI-neutral protected-paths file is a build (section 12).

### Step 3. Write-deny on what the Operator runs later and on the git dir

| | |
|---|---|
| Removes | writes into `.githooks/`, `Taskfile.yml`, `.devhost/`, `.claude/settings.json`, the git dir's `config` and `hooks/`, and `GIT_CONFIG_GLOBAL` (G4, G5) |
| Change | `sandbox.filesystem.denyWrite` of those paths in the same drop-in; for the git dir, its real path (`/git-dirs/<owner>/<repo>/config` and `hooks/`) and other repositories' git dirs, with `objects`, `refs`, `logs`, `index`, `HEAD`, `packed-refs` and `worktrees` left writable; this repository's git dir loses `merge.devhost-todo.driver` (if present) and the `include.path`, and `core.hooksPath` moves to the global config through the git Feature's existing `hooksPath` option |
| Owning Feature | claude-code (the drop-in); git (existing `hooksPath` option); this repository's `task repo:setup` |
| Setting | new option `sandboxDenyWrite`; git's `hooksPath`; `task repo:setup` stops writing the git dir's `config` |
| Bump | claude-code: the same minor as step 2; git: none |
| A consumer changes | lists its own files to protect; sets `hooksPath` instead of a hooks path in the git dir |
| Residual | the workstation's git and other containers (3.3); which git commands write `config` and so fail under the rule (`git push -u`, `git branch --track`, `git worktree add` with per-worktree config) is test T10 |

The sandbox's built-in protections already cover `.git/config` and `.git/hooks` under the working
directory, and `.claude/commands`, `.claude/agents`, `.mcp.json`, shell rc files; whether that
reaches a git dir behind a pointer file is exactly T3.

## 6. Steps 4 to 6: the backs, OpenBao, one agent user

### Step 4. The backs' `claude -p` narrowed, the tester under `bwrap`

| | |
|---|---|
| Removes | the backs' reach beyond their job (inventory 3.3) |
| Change | `job_claude` in `run-job.sh` keeps `--settings '{"disableAllHooks": true}'`; the managed drop-in applies to `claude -p` as well (T1 confirms; if not, the job passes the same sandbox keys in `--settings`); the scribe, which today runs with default permissions, gets `--allowedTools "Read"` and `--disallowedTools "Bash" "Edit" "Write"` (its runner, not the model, signs and appends); the secretary and librarian keep their narrow `Edit` rules; the tester runs its suite under `bwrap` with the checkout read-write and the credential folders hidden (`--tmpfs` over them), the docker socket bound only if T4 shows the suite needs it |
| Owning Feature | devhost (local) |
| Setting | `job_claude` flags; each job's `--allowedTools`; the tester's command line |
| Bump | devhost minor (1.15.0); local, not published |
| A consumer changes | nothing (the devhost is this repository's) |
| Residual | the runner and the backs share the host's user (after step 6, `agent`); the tester keeps docker if T4 fails, and docker is root |

### Step 5. A per-agent OpenBao AppRole

| | |
|---|---|
| Removes | one OpenBao identity, the Operator's token, for every agent (G8) |
| Change | the host gets its own AppRole with a read-only policy on its paths, a token TTL of minutes, `secret_id_num_uses`, bound to `127.0.0.1/32`, and logs in itself (the backlog item `openbao-agent-login`); the backs keep theirs (they exist); once step 6 is in, the unauthenticated root-token endpoints move to a `listener "unix"` at mode 0600 owned by the Operator's user (ADR-0055 decision 6, review finding 7) |
| Owning Feature | openbao |
| Setting | `task openbao:approle:issue` (`bao write auth/approle/role/<agent> token_policies=... token_ttl=...`); a server listener setting |
| Bump | openbao minor (1.6.0) for the agent login; the listener in the same or the next minor |
| A consumer changes | issues a role per agent; the office moves its board tool to its role and drops its own key file and `secrets.env` |
| Residual | the ids are readable by whoever runs as the agent's user (by design: they are its login) |

### Step 6. One `agent` Linux user, without `sudo` or `docker`

The smallest form of the first draft: **one user for the host, its cons and the backs**, not one per
identity (that is a later option, section 12). Steps 1 to 5 already take away the credentials and the
write targets from tool calls; this step adds the kernel's boundary around what the sandbox does not
wrap: the CLI's own process, its hooks, its MCP servers and the backs' runner.

| | |
|---|---|
| Removes | root for the agent (`sudo`, `docker`) and the agent's reach into the Operator's state outside a tool call (G1, G2, G13) |
| Change | below, 6.1 to 6.7 |
| Owning Feature | agents (the user and the switch); claude-code, gh, ssh-agent, openbao, cloud-folder (one drop-in each); git (`core.sharedRepository`) |
| Setting | agents options `runAs` (`remote-user`, the default, or `agent`) and `agentUid` |
| Bump | agents minor (2.2.0); claude-code, gh, ssh-agent, openbao, cloud-folder, git minors for their drop-ins (inert unless `runAs` is `agent`) |
| A consumer changes | sets `"runAs": "agent"` and rebuilds; checks which agent tasks use `docker` or `sudo` (T13) and moves them to the Operator's terminal or CI; logs the agent's `gh` in with the narrow token |
| Residual | host, cons and backs read each other's state and the backs' AppRole ids (bounded by policy); the Operator's terminal keeps root (decision 9) |

**6.1 Made at install time.** With one fixed name, the user no longer depends on the agent list, so
the `agents` Feature's `install.sh` makes it at build time as root: `agent`, uid `agentUid` (default
2000, an option for an image that uses it), primary group the `_REMOTE_USER`'s primary group,
password locked, home in the image (nothing of value lives there; state is in the volumes, NFR-1),
not in `sudoers`, not in `docker`. No `sudo` is needed at start and no uid derivation. Where
`_REMOTE_USER` is unset or root, the option is refused with one line and agents run as today.

**6.2 The switch.** `agents start` and every other adapter verb (`list`, `logs`, `stop`, `reset`,
`attach`, the lease's liveness check, the post-start join; review finding 2) run the adapter through
`sudo -n -u agent -- /usr/local/libexec/agents/agent-env -- <adapter> ...`. `sudo` resets the
environment; `agent-env` rebuilds it: the container's variables minus each Feature's secret-bearing
ones and the patterns `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY` (decision 13), umask 002, then the
drop-ins of 6.3. An `agents start` run as `agent` is refused with one line (decision 12). Leases stay
the caller's.

**6.3 Drop-ins.** The agents Feature knows no CLI (NFR-13). A Feature that must change something for
the agent user ships `/usr/local/share/agents-feature/user-env.d/<feature>.sh`:

| Feature | Drop-in |
|---|---|
| claude-code | nothing to move (6.4); the `SessionStart` warning of 6.7 |
| gh | `GH_CONFIG_DIR=/var/lib/devcontainer-features/gh/agent` (700, `agent`), holding the step 1 token |
| ssh-agent | unset `SSH_AUTH_SOCK` |
| openbao | unset `BAO_TOKEN`; the token helper reads the agent's own token file (a new variable, review finding 15) |
| cloud-folder | unset `RCLONE_CONFIG` |

**6.4 Claude Code's state.** The Claude state volume (`$CLAUDE_CONFIG_DIR`) is handed to `agent`
once (`chown -R`), so the host keeps its login, its transcripts, its memory (ADR-0049's path does not
move) and the cost report still reads everything. The running daemon is restarted as `agent`. The
Operator's own `claude` in a terminal then has no login there; it is not the way agents start
(6.7).

**6.5 The shared checkout.** Files the agent makes keep `agent` as owner on the 9p mounts (section 2).
So the Operator's editor can still change them, `agent`'s primary group is the remote user's own,
`agent` runs with umask 002, and the git Feature sets git's own `core.sharedRepository=group` in the
checkout's git dir (NFR-13). The Operator's new files are 644 by default; an agent that must change
one is refused and says so (a profile umask 002 for the Operator is the alternative, decision 10).
All of this matters only if T2 shows modes hold on these mounts; where they do not, every file is
777 already and the rule costs nothing. `safe.directory` in the global config already lists the
checkout and its git dir.

**6.6 The backs.** They start from the host's `Stop` and `SubagentStop` hooks, so they run as
`agent`: no hand-over, no `sudoers` rule. Their AppRole folders (`approle/<back>/`) are handed to
`agent`; the Operator's token and `approle/` of the Operator stay `vscode` 600/700. The scribe's mirror
and the secretary's `TODO.md` in the shared folder need write there (step 7).

**6.7 The Operator's own session and the check.** The Operator's terminal, VS Code and the launcher's
`exec` stay `vscode`, with `sudo`, `docker` and every login; the share tasks run there. A `claude`
started as the remote user while `runAs` is `agent` prints one line from a `SessionStart` hook in the
managed settings ("this session runs as the Operator's user and can read its secrets; start agents
with task agents"); it warns, never blocks (decision 11, review finding 13). The backlog's check
("the agent user cannot read the key file") is test T9: a Feature test scenario in agents that, as
`agent`, expects refusal for `sudo -n true`, `$OPENBAO_STATE_DIR/token`, the Operator's `hosts.yml`,
`rclone.conf`, `agent.sock` and `docker.sock`, and is shown able to fail (once with a planted 644
token). `key-file-rotate` starts when T9 is green in this devhost.

## 7. Step 7: the shared folder and the ssh-agent

| | |
|---|---|
| Removes | the agent's reach into the shared folder's login and records, and into loaded SSH keys (G9, G10) |
| Change | `rclone mount` stays the Operator's user; a new access level for the agent user: `none` (today's: FUSE without `allow_other`, no other user can open it), `read` (`--allow-other --default-permissions`, files 644, folders 755, owner the Operator), `write` (the same with group write for the remote user's group); `user_allow_other` in `/etc/fuse.conf` when not `none`. The host's tool calls get `sandbox.filesystem.denyWrite` of the mount point (step 3), so only the backs' runner writes. ssh-agent: no key loaded at start; `task ssh-agent:key:load` at a sitting with a lifetime (`ssh-add -t`); `mode: none` for a consumer whose agents need no SSH |
| Owning Feature | cloud-folder; ssh-agent (existing options) |
| Setting | cloud-folder option `agentAccess` (`none`, `read`, `write`; default `none`); ssh-agent's existing `mode` |
| Bump | cloud-folder minor (1.4.0); ssh-agent none (a NOTES patch at most) |
| A consumer changes | picks `read` where no back writes records there, `write` where one does (this devhost, while the ledger mirror and `TODO.md` live in the shared folder); chooses `mode: none` or key loading per sitting |
| Residual | `write` lets the agent change shared records; `sync` and `host` modes are not covered (review finding 16, T12); within a loaded sitting the Operator's processes may sign (agents get no socket) |

## 8. Step 8: the second vendor (NFR-12)

| | |
|---|---|
| Removes | the same gaps for Codex as steps 2 and 3 for Claude Code |
| Change | Codex's own sandbox: `sandbox_mode = "workspace-write"`, `[sandbox_workspace_write] network_access = false` and `writable_roots` (the checkout, the scratchpad), `approval_policy = "on-request"`; fixed by a managed `requirements.toml` so the agent cannot choose `danger-full-access` |
| Owning Feature | none carries Codex today; the agents NOTES document the settings, and the consumer writes `CODEX_HOME/config.toml` and `requirements.toml`; when a Codex adapter or Feature ships, it writes them (its own minor) |
| Setting | Codex's `sandbox_mode`, `network_access`, `writable_roots`, `approval_policy`, `requirements.toml` |
| Bump | agents patch (NOTES) now |
| A consumer changes | writes the two files for each Codex agent |
| Residual | from Codex's documentation, not run here: what it protects on this layout (git dir behind a pointer, `/git-dirs`) and whether it runs under the devcontainer's seccomp is T5; a CLI with no sandbox (Gemini, Copilot) has only step 6 |

## 9. What breaks, and the versions

Every step is opt-in: no option changes behaviour until a consumer sets it, so every step is a
minor (or no Feature change). What an adopter notices:

| Step | What changes for whoever turns it on |
|---|---|
| 1 | the host cannot change repository settings or rulesets; a release tag is protected |
| 2 | `sudo` from a tool call fails; a domain not in the list fails; a permission prompt cannot be bypassed |
| 3 | an agent cannot edit hooks, `Taskfile.yml`, `.devhost/` or the git dir's `config`; the commands T10 lists need their alternatives (`push.autoSetupRemote`, an explicit remote) |
| 4 | none for users; a back that relied on Bash now fails its job and says so |
| 6 | agent sessions lose `sudo`, `docker` and the Operator's logins; `task test` in an agent session reports "skipped" without docker; files are owned by `agent` |
| 7 | the shared folder is readable (or writable) by the agent user |

Making `runAs: agent` the default is a major (agents 3.0.0) and is not part of this proposal
(section 12).

## 10. Slices, in delivery order

Each with its version bump, CHANGELOG entry and `task docs`; the host commits, pushes and opens
them; the Operator merges and releases.

0. **Tests T1 to T8** in a scratch devhost (section 11), reported in this proposal; T1 and T3 decide
   step 2's settings. Records with the ruling: an ADR "least privilege first: agents run in their
   CLI's sandbox, then as one agent user", amending ADR-0048 decision 1 (the named interim token)
   and ADR-0036 (identity gains a Linux user only later); the lexicon gains **Agent user**.
1. **Step 1**: `Set-RepoGovernance.ps1` (tag ruleset, release environment), the host's fine-grained
   token. No Feature.
2. **Steps 2 and 3**: claude-code 1.10.0 (sandbox and lock options); `task repo:setup` stops writing
   the git dir's `config`; this devhost turns them on.
3. **Step 4**: devhost 1.15.0.
4. **Step 5**: openbao 1.6.0 with `openbao-agent-login`.
5. **Step 6**: agents 2.2.0 and the drop-in minors (claude-code, gh, ssh-agent, openbao,
   cloud-folder, git); T9 green; then the Operator runs `key-file-rotate`.
6. **Step 7**: cloud-folder 1.4.0.
7. **Step 8**: agents NOTES patch; T5's result decides whether more is needed.

Model sizing: slices 2, 4, 5 and 6 reach every consumer of those Features: Opus. Slices 0, 1, 3 and 7:
Sonnet.

## 11. Tests

Slice 0 (from the inventory's section 8; T1 and T3 gate step 2):

| # | Unknown | Test | Pass means |
|---|---|---|---|
| T1 | Does Claude's sandbox wrap Bash calls, file tools and the backs' `claude -p`, and does `permissions.deny` or `sandbox.filesystem.denyRead` win for a Read? | in a scratch devhost, a managed drop-in with `sandbox.enabled` and a `denyRead` of a temp file; from a session `cat` it and Read it; run a back's `claude -p`; read the exit text, never the contents | all three refuse, the back with the managed drop-in alone |
| T2 | Do `chown` and modes hold on the 9p `/git-dirs` and checkout? | in a temp folder on `/git-dirs` (not a repository's), `chown`, `chmod 600`, then `sudo -u nobody test -r` | refused; if not, step 6 protects nothing on these mounts and 6.5 is moot |
| T3 | Does the sandbox's write protection cover a git dir reached by a `.git` pointer, and a nested repository's `.git/config`? | with the sandbox on, `touch` and `mv` over `config` and `hooks/` of a temp git dir behind a pointer file; `git config --local x.y z` | refused for `config` and `hooks/`; allowed for `objects/` and `refs/` |
| T4 | Can the tester run the suite under `bwrap` with docker-in-docker? | `bwrap` with the socket bound and the credentials hidden, `task test FEATURE=git` | passes; if not, the tester is the one actor left with docker |
| T5 | What does Codex's `workspace-write` protect on this layout, and does it run under the devcontainer's seccomp? | Codex in a scratch container, a `config.toml`, the writes of T3 | the same refusals, or a list of what differs |
| T6 | Does the narrow token still do what the host does, and refuse the rest? | the token of step 1: `git push`, `gh pr create`, `gh pr ready`; then `gh api` to change a ruleset, and `gh pr merge` on an unapproved pull request | the first three work; the ruleset change is refused; the merge result decides decision 4 |
| T7 | Does a sandboxed call reach OpenBao on loopback, and can a back's runner still log in? | with step 2's drop-in, `curl` loopback from a tool call, then `devhost-run-job scribe` | the tool call is refused; the runner logs in |
| T8 | Does a fine-grained token for the office's repository cover its pull-request workflow? | the office runs T6 in its repository | same as T6 |

Results of T1 and T3 (2026-11-08): see the inventory's "Test results (2026-11-08)" in `agent-least-privilege-inventory.md`; both partial.

Later slices (kept from the first draft's tests, where one agent user still needs them):

| # | Unknown | Test |
|---|---|---|
| T9 | The boundary: can `agent` read what it must not? (the backlog's check) | the agents scenario of 6.7, red once with a planted token, then green |
| T10 | Which git commands the host and cons use write the git dir's `config`? (first draft U9) | the host's usual sequence with `config` write-denied; list each failure |
| T11 | Does `claude attach` under `sudo -n -u agent` behave in the Operator's terminal? (U4) | attach to a resident from `task dc:shell` and from the launcher |
| T12 | Does `rclone mount --allow-other --default-permissions` hold for `read` and `write`; what do `sync` and `host` modes give the agent user? (U5, review finding 16) | mount each way; read and write as `agent` |
| T13 | What in the office and DSNP agent sessions uses `docker`, `sudo` or the Operator's logins? (U12) | their ledgers and transcripts searched; one session each with `runAs: agent` |
| T14 | Does `core.sharedRepository=group` leave Windows git working on the shared git dir? (U2) | `git status`, `commit`, `gc` from Windows git |

## 12. Later (kept so nothing is lost)

One line each; none is in the MVP.

- **One user per identity in the agent list** (first draft option B), with name-derived uids
  (`20000 + cksum mod 10000`) and an optional `uid:` key; made at start from the list.
- **One user per back** (`back-scribe` and the others) and the runner's hand-over through a narrow
  `sudoers` rule (review finding 3's shape: only the hooks' user, no wildcard, standard input).
- **A shared group `dcf-work`** with a fixed gid, setgid folders and a shared `src/common` script
  (review finding 12); needed only when there is more than one agent user.
- **Per-user Claude logins**: `claude setup-token` in `CLAUDE_CODE_OAUTH_TOKEN` (test U3, review
  finding 10) or an adapter verb `login` (review finding 9).
- **Per-user Claude state** under `claude-code/users/<user>/` and the cost report across users
  (review findings 4, 5).
- **`agents boundary`** as a command with each Feature's protected paths in `boundary.d/` and the
  linter contract (review findings 8, 11); the same file could feed the sandbox's `denyRead`.
- **The share tasks refuse by user** (caller must own `$OPENBAO_STATE_DIR`) beside the variables in
  an openbao minor, the variables dropped at its major (review finding 15).
- **The default flip**: agents 3.0.0 makes `runAs: agent` the default; claude-code 2.0.0.
- **An agent that starts another agent** (a rule for the helper alone).
- **A GitHub App** (or a machine user) for the host, so its identity is not the Operator's and the
  ruleset's Admin bypass does not apply to it; then installation tokens minted through OpenBao.
- **Custom brokers** (#187, on hold): the route for what has no native control: an allow-list in
  front of the docker daemon, git operations that must not touch the git dir's `config`.
- **The workstation-side `config` check** in the launcher (review finding 1), with the launcher
  installed per user and refreshed only from `main` (section 13).
- **Mounting only the repository's own git dir** instead of all of `/git-dirs` (reopens ADR-0020).

## 13. For the repository (found while writing)

- **The `protect-main` ruleset lets the Admin role bypass in `pull_request` mode**
  (`Set-RepoGovernance.ps1`). The host's pull requests are opened as the Operator, who cannot
  approve their own, so the bypass is how they merge today. It also means any token acting as the
  Operator, a fine-grained one included, can merge an unapproved pull request if it has Contents and
  Pull requests write (T6 confirms). Decision 4.
- **The launcher runs from the checkout.** Windows `task dc:*` runs `Taskfile.yml` and the vendored
  launcher on whatever branch an agent left, as the account that opens the OpenBao key file; no
  Linux user or sandbox closes that. Worth its own backlog item: a per-user installed launcher
  refreshed only from `main`.
- **`task repo:setup` writes the git dir's `config`** (`include.path`, hooks path, alias). Under
  step 3 that file is write-denied to agents; the hooks path belongs in the global config through the
  git Feature's `hooksPath`.
- **The shared folder is unreachable by any other user today** (FUSE without `allow_other`),
  root included; the cloud-folder NOTES could say so.
- **`dcf-persist` hands a folder to "the current user"**: called as `agent` it would try `sudo` and
  fail quietly. Its NOTES should say which user it serves.

## 14. Decisions for the Operator

1. **The MVP in the inventory's order** (GitHub; sandbox and locked permissions; write-deny; the
   backs; a per-agent AppRole; one agent user; the shared folder and ssh-agent; Codex), every step
   opt-in. *Recommendation: yes.*
2. **Tests T1 and T3 run first and gate step 2**: if the sandbox does not cover file tools and the
   backs (T1) or the git dir behind a pointer (T3), step 2's settings are re-chosen before release.
   *Recommendation: yes.*
3. **The host's GitHub login becomes a fine-grained token**, at rest in `hosts.yml`, as a named,
   bounded interim exception to ADR-0048 decision 1 that ends when `openbao-agent-login` ships.
   *Recommendation: accept.*
4. **The ruleset's Admin bypass** (section 13): keep it for now and accept that the host's token can
   merge, or take it out and merge through a second reviewer. *Recommendation: keep it for the MVP,
   measure it in T6, and move the host to a GitHub App identity (Later).*
5. **Strict sandbox**: `failIfUnavailable: true` and `allowUnsandboxedCommands: false` whenever the
   sandbox option is on, so a session never silently runs unsandboxed and `sudo` moves to the
   Operator's terminal. *Recommendation: yes.*
6. **Credential paths listed by the consumer** in claude-code's options (the NOTES give this
   collection's list), not shipped per Feature, for the MVP. *Recommendation: yes; a protected-paths
   contract later.*
7. **One `agent` user** for the host, its cons and the backs, not one per identity or per back.
   *Recommendation: yes; per identity is a later option.*
8. **The user is made at install time** (`runAs`, `agentUid` default 2000), and the Claude state
   volume is handed to it whole, so the host keeps its login, history and memory. *Recommendation:
   yes.*
9. **The Operator's user keeps passwordless `sudo` and `docker`**; trust runs one way.
   *Recommendation: keep.*
10. **Shared files**: `agent`'s primary group is the remote user's, umask 002 for `agent`, git's
    `core.sharedRepository=group`; the Operator's own umask unchanged. *Recommendation: yes, if T2
    shows modes hold.*
11. **A `claude` started as the Operator's user warns, never blocks.** *Recommendation: warn.*
12. **An agent cannot start another agent.** *Recommendation: yes; revisit when one must.*
13. **The agent's environment: the container's variables minus a deny list** (each Feature's secret
    variables and the patterns of 6.2). *Recommendation: deny list.*
14. **No `docker` for the agent user**; the tester runs under `bwrap` and, if T4 fails, reports
    "skipped" here while the suite runs in CI and the Operator's terminal. *Recommendation: yes.*
15. **The shared folder's `agentAccess` is `write` in this devhost** while the backs write records
    there, `read` for a consumer whose agents only read. *Recommendation: yes.*
16. **`key-file-rotate` starts when T9 is green in this devhost.** *Recommendation: yes.*

## Architecture review (2026-11-06)

Reviewed cold against the proposal, `docs/principles/non-functional-requirements.md`, `docs/adr/`
(0012, 0016, 0020, 0024, 0026, 0028, 0031 to 0033, 0036, 0037, 0040, 0045, 0046, 0048, 0049, 0055,
0056), `docs/proposals/agents-v2.md` section 14, `LEXICON.md`, and the code the design leans on:
`src/agents/agents.sh` (2.1.3), `src/claude-code/agent-adapter-claude.sh` (1.9.9),
`src/git/git-setup.sh`, `src/gh/gh-setup.sh`, `src/openbao/openbao-lib.sh`, `openbao-server.sh` and
`openbao-token-helper.sh` (1.5.0), `src/cloud-folder/cloud-folder-setup.sh` (1.3.3), the shared
`dcf-persist.sh`, and the devhost's `share/bin/run-job.sh`, `lib.sh` and
`share/python/session_cost.py` (1.14.1). The runtime facts of section 2 were not re-run (read-only
review of the tree). Who it serves: the Operator, who rules on it and rotates the OpenBao key file
after it; the maintainers of the office and DSNP, who adopt it opt-in; the engineers whose agents
must not lose work to a permission error.

**Verdict:** fit with changes

The threat model is honest (3.3 states what a user does not fix), option B is ADR-0036's identity
one level down, the switch uses `sudo`'s own environment reset, and per-user state through
drop-ins keeps CLI knowledge out of the agents Feature. Three findings must be settled before
slice 2 is built: the git dir's `config` is not protected by its owner as designed (finding 1),
every adapter verb, not only `start` and `attach`, has to run as the agent's user (finding 2), and
the backs' `sudoers` rule is wider than the hand-over it is meant for (finding 3). The rest are
placement and record fixes.

### Requirements (NFRs), one line each

- **NFR-1 owns-its-state**: met. Per-user state lives in the Features' volumes (`users/<user>/`,
  sections 7 and 8.2); homes are image-only and hold nothing of value (6.2).
- **NFR-2 registered-taskfile**: met if `agents:boundary` and the login task get a `desc` (sections
  10, 8.4); see finding 9 for where the login task belongs.
- **NFR-3, NFR-4, NFR-9**: do not apply (nothing downloaded, no official Feature for this).
- **NFR-5 idempotent-and-user-neutral**: met in intent: users are made at start, never fatal, and the
  remote user is resolved at run time (6.1). See finding 6: the install step can use the spec's
  `_REMOTE_USER` for the group without assuming a user.
- **NFR-6 one-way-to-configure**: partly met. `runAs` and the `dcf-work` gid option are named, their
  override variables are not (section 11, 6.3). Finding 12.
- **NFR-7 agent-ready**: partly met. `agents:boundary` is non-interactive; the per-user login (8.4
  option a) opens a browser and must be `interactive: true`.
- **NFR-8 documented-to-the-standard**: met if each slice's NOTES name the drop-in contract, the
  per-user folders and the `runAs` limits; slices 1 to 6 do not list the NOTES.
- **NFR-10 tested-on-base-images**: met in plan (slice 2's two-user scenario, 10's red-then-green
  run). U6 must settle the CI images without `sudo` before the scenarios are written.
- **NFR-11 linter-cli-contract**: needs a written exception or a fuller fit. `agents boundary`
  borrows ADR-0035's exit codes (section 10) but is a runtime probe, not a path checker: no
  `path:line: rule` line, no `--format json`. Finding 11.
- **NFR-12 vendor-neutral-contracts**: met. The switch (`sudo -n -u` plus `HOME`) works on any CLI,
  and every CLI in the matrix keeps its state under `HOME` or its own home variable
  (`CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `CODEX_HOME`, `GEMINI_CLI_HOME`), so a drop-in per CLI
  Feature suffices. The one Claude-only risk is named: section 14.1 says process env does not reach
  a Claude background session, which is why U3 matters (finding 10).
- **NFR-13 manages-the-environment-not-the-cli**: met for the core (which user an agent runs as is
  environment; `core.sharedRepository` is git's own feature). Not met in three places: the
  boundary list names other Features' paths (finding 8), `agents:login` runs `claude` from the
  agents Feature (finding 9), and the plain-`claude` warning has no stated mechanism (finding 13).

### Decisions (ADRs)

No accepted ADR is contradicted outright. The slice-0 ADR must say what it amends:
**ADR-0036** (the lease folder's 0777, accepted "for a single-tenant container", becomes the
caller's 755; identity gains a Linux user), **ADR-0048 decision 4** (the refusal moves from
variables to the user), **ADR-0056 decisions 8 and 9** (closed when slice 6 is green),
**ADR-0049 decision 4** (the memory path moves, finding 5), **ADR-0033** (the adapter's
`agents.tsv` becomes per user, finding 2), and that it reopens **ADR-0055 decision 6** (finding 7).
It leaves **ADR-0020** as it is (3.3 and 15 state the residual), **ADR-0016** as it is (the bot
identity still keys on `CLAUDECODE`, which agent users keep), and is consistent with **ADR-0040**
(the host still does the git work, with its own credential, 8.5). Section 1 cites ADR-0045 for
"state lives in a Feature volume, never only in a home folder"; that rule is NFR-1, ADR-0045 is the
machine-loss rule. ADR-0046 is superseded by ADR-0048 and does not bear on this.

### Findings

1. **The git dir's `config` is not protected by being the Operator's file (sections 7, 9, 10).**
   git writes `config` through `config.lock` and a rename, and `rename(2)` needs write permission
   on the folder, not on the file. The git dir must be group-writable for objects, refs, `HEAD`
   and the index (`core.sharedRepository=group` makes its folders 2775), so an agent user can
   replace `config` with `git config`, `mv` or `rm`, whatever its owner and mode. The sticky bit
   on the git dir would stop that, but also stops each user replacing the other's `HEAD`,
   `index` and `packed-refs`, which git rewrites the same way. The workstation threat of 3.3
   (`core.fsmonitor` run by Windows git) therefore stays open. Recommended change: drop the
   ownership rule as a control and make test U9 a rename-over test; if it confirms the gap, close
   the threat on the workstation side instead (the launcher checks the git dirs' `config` against
   the last known copy before any `task dc:*` runs Windows git, with the item section 15 proposes
   for the launcher) and say in 3.3 that the container cannot close it.

2. **Every adapter verb has to run as the agent's user, not only `start` and `attach` (8.1, 8.6).**
   The claude adapter keeps its records under `$CLAUDE_CONFIG_DIR/agent-adapter-claude/`
   (`agents.tsv`, ADR-0033) and reads liveness from `claude agents --json`, which lists only the
   sessions of the calling user's config folder and daemon. Run as the Operator's user, `list`,
   `logs`, `stop`, `reset`, the lease's liveness check (`agents.sh` asks the adapter's list when a
   holder's pid is gone) and the post-start join would all see no sessions, and `agents:up` would
   start a second resident. Recommended change: section 8.1 states that `agents` calls every adapter
   verb through `agent-env` as the agent's user, and slice 2's scenario checks `list`, `stop` and a
   lease takeover across two users, not only a start.

3. **The backs' `sudoers` rule is wider than the hand-over (8.3).** `%dcf-work ALL=(back-scribe)
   NOPASSWD: devhost-run-job --handover * scribe` lets every agent user, the reviewer included,
   run as `back-scribe`; `*` in a `sudoers` argument matches across spaces; and `run-job.sh`
   already takes a job *path* (`*/*` or `*.sh`, sourced, relative to the agent-writable checkout).
   An agent could then run its own code as a back and sign the ledger as the scribe. Recommended
   change: grant the rule to the user that runs the hooks (`agent-host`), with no wildcard, the
   hand-over on standard input (`devhost-run-job --handover-stdin scribe`), and the runner refusing
   a job path whenever `SUDO_USER` is set.

4. **The cost report and the briefing's spend read one user's transcripts (not in section 7).**
   `session_cost.py` reads `$CLAUDE_CONFIG_DIR/projects/`; with one 700 folder per user, the host's
   `task devhost:costs`, the briefing's month's spend and the ledger review see only the caller's
   own sessions, and a back after the hand-over cannot measure the host's stretch. Recommended
   change: add a row to section 7: the runner measures the stretch's cost as `agent-host` before
   the hand-over and passes the numbers in the hand-over file, and the month's report runs as the
   Operator's user (which reads every user's folder through `sudo`) or from the backs' `runs.jsonl`.

5. **Claude Code's memory moves, and ADR-0049 decision 4 points at the old path (7, decision 6).**
   ADR-0049 places memory at `claude-code/projects/*/memory/` and owes a tier-3 mirror of it. The
   one-time move puts it under `users/agent-host/`, 700, and other agents start with none.
   Recommended change: slice 3 names the new path in the claude-code NOTES and the mirror's
   backlog item, and the slice-0 ADR records the amendment.

6. **The Operator's long-lived processes would miss the group (6.1, 9).** Users and group membership
   made at start reach new `devcontainer exec` shells, but the VS Code server and anything started
   before the hook keep their old groups, so the Operator's editor could not write an agent's
   group-writable file until the next start. The Feature spec hands `install.sh` the
   `_REMOTE_USER` (the claude-code Feature already reads it), so the group and the remote user's
   membership can be made at build time without assuming a user (NFR-5). Recommended change: the
   install step creates `dcf-work` and adds `_REMOTE_USER` to it when set; the start hook only makes
   the agent and back users.

7. **ADR-0055's open unix-socket listener is decided by this proposal (3.3, U8).** ADR-0055 left
   option 3 open because "it does not keep out agents, which run as the same user". With agent
   users it does: a `listener "unix"` at mode 0600 owned by the Operator's user, carrying the
   unauthenticated root-token endpoints, removes the "disturb a recovery" residual of 3.3.
   Recommended change: slice 5 moves the setting to the Operator-owned unix listener and leaves the
   TCP listener at the default, and the slice-0 ADR settles ADR-0055 decision 6 that way.

8. **The boundary check knows other Features (section 10).** 8.2 says the agents Feature knows no
   CLI and no other Feature, yet the check's list names `$OPENBAO_STATE_DIR/token`, `approle/`,
   `GH_CONFIG_DIR/hosts.yml`, `RCLONE_CONFIG`, `SSH_AUTH_SOCK` and the git configs. Recommended
   change: each Feature ships its protected paths beside its drop-in (`boundary.d/<feature>`, one
   path or socket per line with the expectation), and `agents boundary` reads those plus
   `AGENTS_BOUNDARY_PATHS`, as 8.2 already does for the environment.

9. **The per-user Claude login is placed in the agents Feature (8.4 option a, 11 step 3).**
   `task agents:login -- <name>` "runs `claude` as that user": the agents Feature would then know a
   CLI (NFR-13). Recommended change: make it an optional adapter verb `login` (exit 3 where a CLI
   has no login, NFR-12), which `agents login <name>` calls as the agent's user.

10. **The token route of 8.4 rests on a Claude daemon that outlives the environment.** Section 14.1
    of agents-v2 says the process environment does not reach a Claude background session; the
    first `--bg` per user starts that user's daemon with whatever environment it had, and a
    rotated `CLAUDE_CODE_OAUTH_TOKEN` will not reach a running daemon. Recommended change: U3 also
    rotates the token and checks that a resident picks it up (or that the drop-in restarts that
    user's daemon), before decision 9 is taken as the token.

11. **`agents boundary` and the linter contract (section 10).** It cites ADR-0035's exit codes but
    is a probe over the running container, not a tool over paths. Recommended change: write it as
    a named exception in the agents NOTES (no paths, no `-`), and keep the rest of the contract:
    one `<user>: <check>: <path>` line per readable item and `--format json`, so the briefing and
    CI read it without parsing prose.

12. **Shared names live in several Features without an owner (6.3, 7, 9).** `dcf-work` and its gid
    are an agents option, but cloud-folder's mount (`--gid dcf-work`), git's shared repository,
    the devhost's state folders and the Operator's umask all depend on them, and slice 4 puts the
    Operator's umask drop-in in the git Feature. Recommended change: a shared script in
    `src/common` (vendored, as `dcf-persist.sh` is) defines the group from one variable
    (`DCF_WORK_GROUP`, `DCF_WORK_GID`), each Feature behaves as today when the group is absent, and
    the umask drop-in moves to the agents Feature that turns agent users on.

13. **The plain-`claude` warning has no mechanism (8.6, decision 7).** A wrapper around `claude`
    would be the Feature intercepting the CLI. Claude Code has its own hook for this, and ADR-0032
    already writes Feature settings into the managed settings folder. Recommended change: slice 3
    ships the warning as a `SessionStart` hook in the managed settings, active only when `runAs` is
    `agent-user` and the uid is the remote user's.

14. **The token files at rest per agent sit outside ADR-0048 decision 1 (8.4, 8.5).** OpenBao is the
    master of every token the collection stores, gh tokens named; option 8.5 b keeps a
    fine-grained token per agent in a gh folder and 8.4 b a `setup-token` in a file until
    `openbao-agent-login`. Recommended change: the slice-0 ADR states both as a bounded interim
    exception to ADR-0048 decision 1, ending when `openbao-agent-login` ships, so no other store
    cites it.

15. **Section 11 and slice 5 disagree on openbao's version.** Section 11 lists "refuse by user, not
    by variable" as breaking (openbao major); slice 5 ships it in a minor. Recommended change: the
    minor adds the user check alongside the variables (refuse if either says agent), and only
    dropping the variable check waits for the major. The user check itself should be
    Feature-local: refuse unless the caller owns `$OPENBAO_STATE_DIR`, which needs no knowledge of
    the agents Feature. The token helper reads a fixed `$OPENBAO_STATE_DIR/token` today, so the
    drop-in of 8.2 needs a new variable for the token file rather than a second `OPENBAO_STATE_DIR`.

16. **Two cloud-folder modes are not covered (7, U5).** The design treats `mount` only. `sync` mode
    writes with umask 077 into a folder owned by the remote user, so agents could not read the
    records there; `host` mode is a bind mount whose owners depend on the engine (as U1). The
    office runs `host` mode. Recommended change: section 7's row covers all three modes (`sync` with
    umask 007 and group `dcf-work`; `host` under U1), and U5 tests each.

### Lexicon

The proposal uses the Operator, host, con, back, resident, handle, identity, lease, CLI adapter,
storage tier and custody as defined. Slice 0 adds **Agent user** and **The Operator's user**, which
is right; "remote user" is used without a lexicon entry and should be defined inside "The Operator's
user". The user name `agent-host` joins "agent" and the handle `host`, while "Host" is both the main
session and, in ADR-0024, the workstation; the lexicon entry for Agent user should say the name is
`agent-<identity>` and that `agent-host` means the agent whose identity is `host`. **Back identity**
already means a back's AppRole; the Linux user of a back needs its own word (Back user) so the two
are not confused. The **Tester** has no model, so it needs no Claude login (8.4 counts one per back).

### Placement

| Element | Layer | Why |
|---|---|---|
| `runAs`, users from the list, `agent-env`, the drop-in folder, refusal of `agents start` by an agent | agents Feature option and start hook | the environment: who an agent runs as (NFR-13) |
| `uid:` per agent | agents list spec | a fact about the agent, CLI-neutral; acceptable |
| `dcf-work` group and gid | shared script in `src/common`, read by each Feature | several Features depend on it (finding 12) |
| Per-user state variables | each CLI or tool Feature's drop-in | each Feature knows its own state (8.2, correct) |
| Protected paths for the check | each Feature, beside its drop-in | finding 8 |
| Claude login per user | claude-code adapter verb `login` | finding 9 |
| Claude credential in the environment | claude-code drop-in | correct (8.4) |
| Plain-`claude` warning | claude-code managed settings hook | finding 13 |
| `core.sharedRepository`, `safe.directory` for worktrees | git Feature | git's own features (correct) |
| The Operator's umask 002 | agents Feature (not git) | finding 12 |
| `allow_other` mount | cloud-folder Feature | correct; all modes, finding 16 |
| Share-task refusal by user, agent token file | openbao Feature | correct; Feature-local check, finding 15 |
| Back users, hand-over, `sudoers` rule | devhost local Feature | backs are a devhost concept (correct); rule shape, finding 3 |
| Per-agent GitHub token | the Operator, stored by the gh drop-in | consumer act; ADR-0048 interim, finding 14 |
| `AGENTS_BOUNDARY_PATHS`, moving the office's key file | consumer config | correct (section 11) |
| Workstation-side git `config` check | launcher (devcontainer-cli) | finding 1; ADR-0024 puts the host there |

### Open questions for the Operator

- **The git dir's `config` (finding 1).** Accept that the container cannot protect it and close the
  workstation threat in the launcher, or keep the ownership rule and accept the residual until U9
  runs. *Recommendation: the launcher check, filed with section 15's launcher item; the ownership
  rule is not a control.*
- **ADR-0055 decision 6 (finding 7).** Move unauthenticated root-token generation to an
  Operator-owned unix listener as part of slice 5. *Recommendation: yes.*
- **Who reads the agents' transcripts for the cost report (finding 4).** The Operator's user through
  `sudo`, or a group-readable `projects/` that reopens T7. *Recommendation: the Operator's user,
  with the stretch's cost carried in the hand-over.*
- **The interim token files (finding 14).** Accept per-agent GitHub and Claude tokens at rest in
  the Features' volumes until `openbao-agent-login`, as a named exception to ADR-0048 decision 1.
  *Recommendation: accept, bounded by that item.*
- **Who may hand over to a back (finding 3).** Only `agent-host`, or every agent user.
  *Recommendation: only the user that runs the hooks.*
