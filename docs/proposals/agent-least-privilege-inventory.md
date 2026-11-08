# Least privilege of agents and backs: an inventory

draft 2026-11-06

Status: a read-only inventory, not a design. It serves the Operator, through the host, and the
maintainers of the office and DSNP whose agents run in devcontainers. It was asked for by the
Operator's direction of 2026-11-06: **least privilege first, MVP**. Configure what already exists
(each agent CLI's own OS sandbox, server-side GitHub rules, narrow tokens, OpenBao policies,
separate Linux users) before building anything; custom brokers (draft #187,
`docs/proposals/brokers.md` on `docs/broker-pattern/1`) are on hold. A later step re-scopes
[agent-linux-user.md](agent-linux-user.md) from this inventory; that file is not edited here.

How it was made: paths, owners and modes were listed in the running devhost, as the remote user,
on 2026-11-06. No file was read for its contents and no variable's value is quoted. Where a fact
could not be confirmed it says so, and section 8 turns it into a test.

## 1. The one fact that shapes everything

Every actor below is **one Linux user**, `vscode` (uid 1000), with passwordless `sudo` (`NOPASSWD:
ALL` in `/etc/sudoers.d/vscode`) and the `docker` group (the socket `/var/run/docker.sock` is
`root:docker` 660, and the daemon is root). Either is root. So today the host session, a con and
each back hold the same set of powers, and the table in section 3 differs per actor only in what
the actor needs, not in what it can do. The gap is the same for all; what differs is which control
fits each.

```
                 what each actor can do TODAY           what it NEEDS
  host session   everything vscode can (root)    -->    repo write, git on a topic branch,
  con            same (a subagent, same process)        pull request, ledger/TODO via backs
  scribe         same, plus the ledger key              read transcript, sign ledger entry
  secretary      same                                   edit TODO.md only
  librarian      same                                   read repo; edit LEXICON.md, docs/adr
  tester         same                                   run the suite (needs docker)
  office agent   same, as the remote user               its folder, its CLI login, its own jobs
```

## 2. What exists today (paths and modes, no contents)

| Path or reach | Owner and mode | What it gives whoever reads or writes it |
|---|---|---|
| `id`, groups | `vscode` in `vscode`, `docker`, `pipx` | `docker` is root on the container |
| `sudo -n -l` | `(root) NOPASSWD: ALL` | root: every file below, other users' memory, mounts |
| `/var/run/docker.sock` | `root:docker` 660 | start a privileged container with the host's mounts: root, and the checkout and `/git-dirs` rewritten |
| `$OPENBAO_STATE_DIR` (`token`, `server.hcl`, `audit.log`, `keyfile-pending`, `renewer.pid`, `raft/`) | `vscode` 700 or 600, the folder 755 | the Operator's OpenBao token: every secret in the vault |
| `$OPENBAO_STATE_DIR/approle/{scribe,secretary,librarian,tester,backup}/` | `vscode` 700 | each back's role id and secret id: read the register keys the role may read |
| OpenBao on loopback `127.0.0.1:8200` (8201 cluster) | open to any local process | unauthenticated root-token attempt endpoints (ADR-0055) |
| `$CLAUDE_CONFIG_DIR` (`.credentials.json` 600, `.claude.json` 600, `history.jsonl` 600, `settings.json` 644, `projects/` 755, `daemon/` 700, `sessions/` 700) | `vscode` | the Claude login; every transcript; the settings that govern the session |
| `$GH_CONFIG_DIR/hosts.yml`, `config.yml` | `vscode` 600 | the Operator's GitHub login: any push, merge, release, settings change the login allows |
| `$GIT_CONFIG_GLOBAL` (git volume, `gitconfig`) | `vscode` 644 | the identity and `safe.directory`; a `core.hooksPath` or `core.sshCommand` here runs on every git call |
| `/var/lib/devcontainer-features/cloud-folder/rclone.conf` | `vscode` 600 (folder 700) | the shared-folder login (SharePoint or OneDrive) |
| `/var/lib/devcontainer-features/ssh-agent/agent.sock` | `vscode` 600 in a 1777 folder | sign with every loaded SSH key |
| `/mnt/cloud-folder` | `vscode` 700, FUSE without `allow_other` | read and write the ledger mirror and shared records; only `vscode` (not root) can open it |
| `/var/lib/devcontainer-features/agents` | 1777, `leases/` 777 | forge or steal a lease (ADR-0036 accepted that) |
| The checkout `/workspaces/devcontainer-features` | 9p (drvfs) bind, shows `root` 777; `.git` is a 74-byte pointer file, 777 | write any file, including `Taskfile.yml`, `.githooks/`, `.claude/settings.json` (644 `vscode`), the skills |
| `/git-dirs` (every repository's git dir, the office's and DSNP's too) | 9p, `root` 777 | write `config` and `hooks/` of any repository; the workstation's git then runs them (a `core.fsmonitor`, `core.hooksPath`, a merge driver) |
| This repository's git `config` (keys listed, values hidden) | holds `core.hookspath` and branch settings; no `merge.*.driver` key appeared in `git config --list` on 2026-11-06 (the broker review reported one; it may be gone, or in a config this listing does not read) | runs work-tree code at the next git call, on the workstation too |
| Managed settings for Claude Code | `/etc/claude-code/` does not exist here; `~/.claude` does not exist; user settings carry only `voice`, `theme`, `autoMode` and similar, no `permissions`, no `sandbox` | nothing is denied at the user level; the project's `.claude/settings.json` allows `task *`, read-only git, `devhost-*` and denies `Read(./.env*)` only |
| Sandbox ingredients | `/usr/bin/bwrap` present and `bwrap --ro-bind / / true` exits 0 as `vscode` here; `socat` present; Claude Code 2.1.311 | Claude Code's sandbox can start in this devhost (confirmed); it is **not turned on** (no `sandbox` key in any settings file seen) |
| Network | outbound HTTPS to the internet works (`example.com` answered 200); loopback OpenBao answers | exfiltrate anything the user can read, to anywhere |
| Kernel | `ptrace_scope` 1, `legacy_tiocsti` 0 (from agent-linux-user section 2; not re-run) | same-user processes may not be attached to by non-descendants; no keystroke push |
| Codex | not installed in this devhost (`codex` not found, no `~/.codex`) | the second vendor's controls below are from its documentation, not run here |

## 3. Per actor: can, needs, gap, existing control, residual

"Can" is the same for every actor today (section 1), so each row lists the part that matters for
that actor. Controls are named by their exact setting. Claude Code's settings were confirmed by
listing the keys in the installed `claude` binary (2.1.311): `sandbox.enabled`,
`sandbox.autoAllowBashIfSandboxed`, `sandbox.excludedCommands`, `sandbox.allowUnsandboxedCommands`,
`sandbox.failIfUnavailable`, `sandbox.enableWeakerNestedSandbox`,
`sandbox.filesystem.{allowWrite,denyWrite,allowRead,denyRead,allowManagedReadPathsOnly,disabled}`,
`sandbox.network.{allowedDomains,deniedDomains,allowManagedDomainsOnly,allowUnixSockets,allowAllUnixSockets,allowLocalBinding,httpProxyPort,socksProxyPort}`,
and the managed-only switches `allowManagedPermissionRulesOnly`, `allowManagedHooksOnly`,
`allowManagedMcpServersOnly`, `disableBypassPermissionsMode`. What was **not** confirmed: the
default values and the exact precedence between `permissions.deny` and `sandbox.filesystem.*` (the
documentation was not looked up in this run; test T1 settles it).

### 3.1 The host session (the main Claude Code session, `agents start host`)

| | |
|---|---|
| Reads today | everything `vscode` can: tokens, AppRole files, `hosts.yml`, `rclone.conf`, every transcript, all repositories' git dirs |
| Writes today | the checkout, `/git-dirs`, `$CLAUDE_CONFIG_DIR` (its own settings), `$GIT_CONFIG_GLOBAL`, `/mnt/cloud-folder`, any state volume; root through `sudo` and `docker` |
| Reaches today | all of the internet, loopback OpenBao, the docker daemon, the ssh-agent socket |
| Needs | read and write in the checkout and its worktrees (scratchpad); git add, commit, push on a topic branch and open the pull request (CLAUDE.md: the host commits and pushes; ADR-0040); read the briefing, ledger, TODO; run `task`; GitHub (api.github.com, github.com), the model API, package registries when a task installs; read `/mnt/cloud-folder` records; run `task test` (docker) when the host allows it |
| Needs not | the OpenBao token, the AppRole files, `rclone.conf`, `agent.sock`, the Operator's `hosts.yml` (if a narrow token exists), `sudo`, root, other repositories' git dirs, merge and release rights |
| Gap | everything in "needs not" is readable or writable |
| Existing control | (a) Claude sandbox: `sandbox.enabled: true`; `sandbox.filesystem.denyRead` for `$OPENBAO_STATE_DIR`, `/var/lib/devcontainer-features/{cloud-folder,ssh-agent,gh}`, `/git-dirs` outside this repository, `~/.ssh`; `sandbox.filesystem.allowWrite` the checkout, the scratchpad, `/tmp`; `sandbox.filesystem.denyWrite` `.githooks`, `Taskfile.yml`, `.devhost`, `.claude/settings.json`; `sandbox.network.allowedDomains` github.com, api.github.com, the model API, the registries; `sandbox.allowUnsandboxedCommands: false`; `sandbox.failIfUnavailable: true`; all in a managed drop-in (`/etc/claude-code/managed-settings.d/`, which the claude-code Feature already writes for ADR-0032) so the session cannot lift them; `allowManagedPermissionRulesOnly: true` and `disableBypassPermissionsMode: "disable"`. (b) A fine-grained GitHub token for the host: Contents write, Pull requests write, Metadata read, one repository, no Administration, no Workflows, no Actions. (c) GitHub rulesets (below). (d) The `sudo` and `docker` rows below |
| Residual | the sandbox covers tool calls, not the host session's own process, hooks or MCP servers (to confirm, T1); `docker.sock` if `sudo` or `docker` are not removed; the git dir's `config` (T3); code the Operator runs later from the shared checkout (agent-linux-user 3.3) |

### 3.2 A con (a subagent inside the host session)

| | |
|---|---|
| Reads and writes today | the same as its parent; it is a subagent in the parent's process, with the parent's user, environment and sandbox |
| Reaches today | the same |
| Needs | its worktree and its branch (`<type>/<id>/<n>`), read the repo, run `task` for its checks, commit on its branch (CLAUDE.md: cons commit on their branch); no push unless the brief says so |
| Gap | a con may read the OpenBao token, write other branches' worktrees, and push |
| Existing control | the parent's sandbox applies (the sandbox is per tool call, not per session). A subagent's own narrowing is the agent definition's `tools` and `permissions` (`.claude/agents/*.md` frontmatter `tools:` or `disallowedTools:`), and the brief's model size. `sandbox.filesystem.allowWrite` with the worktree path gives a per-worktree write scope only if a session is started per worktree (an agent in the list with `folder: <worktree>`) |
| Residual | a con cannot get a Linux user of its own (agent-linux-user 3.3); its boundary is its parent's. A GitHub rule is the only thing between a con and `main`. Whether `isolation: worktree` is useful under the sandbox is unknown (it fails here already, CLAUDE.md) |

### 3.3 The backs (each runs `claude -p` through `devhost-run-job`, async from a `Stop` hook)

Common to all four: the runner (`share/bin/run-job.sh`) runs as `vscode` in the host's session
hook, reads the transcript of the stretch, calls `claude -p --settings '{"disableAllHooks": true}'
--no-session-persistence` with the host's login (`$CLAUDE_CONFIG_DIR`), and writes the notice and
metrics to `$DEVHOST_STATE`. Its own limits are per job, passed as `--allowedTools` and
`--disallowedTools`.

| Back | Needs | Today's limit | Gap | Existing control | Residual |
|---|---|---|---|---|---|
| scribe | read the stretch's condensed transcript; read the repo's ledger tail; sign and append one ledger entry (its OpenBao key via its AppRole, `dcf/register/scribe` only); write the shared-folder mirror | `claude -p` with no `--allowedTools` (default permissions, to confirm); AppRole read by the runner, not exported; but any code as `vscode` can read `approle/scribe/` | its `claude` run holds the host's login and could be told by a transcript to read other secrets; the runner and the back share a uid | `claude -p --settings` add `{"sandbox": {...}}` and `--allowedTools "Read" "Bash(devhost-ledger *)"` with the managed read-deny of `$OPENBAO_STATE_DIR`; OpenBao policy `dcf/register/scribe` read only (exists); a second login is `openbao-agent-login` | the runner and the claude run still share a uid until separate Linux users |
| secretary | read TODO.md and the stretch; edit `TODO.md` only | `--allowedTools "Read" "Edit(/<todo>)" --disallowedTools "Bash"` | Read is unbounded (secrets are readable); the Edit rule is already narrow | add `sandbox.filesystem.denyRead` (managed) for the credential paths; the Edit rule stays | minimal |
| librarian | read the repo; edit `LEXICON.md` and `docs/adr/` | `--allowedTools "Read" "Glob" "Grep" ...` (Edit rules for the two paths, in the job file) | Read unbounded, same as above | same managed read-deny | minimal |
| tester | run the suite (`task lint`, `task test`, which may need docker-in-docker) with a timeout, `DEVHOST_JOB_CHILD=1` | runs `bash -c "$cmd"` as `vscode` with docker and sudo available, no model | the suite's code is the checkout's code: whatever an agent put there runs with root-equivalent powers | the Claude sandbox does not apply (no model, a plain `bash`): run the suite under `bwrap` (present, works here) with the checkout read-write and the credentials hidden, or leave `docker` for the tester only (T4); `sandbox.excludedCommands` is for Claude's own Bash tool, not this | the docker socket is root; there is no native control for "docker for the tester only" short of a separate user in a `docker` group, or rootless docker |
| backup (the OpenBao snapshot job, if enabled) | read `raft/`, write the backup target | AppRole `backup` 700 | not in the Operator's brief; listed because it is in `approle/` | its AppRole policy | none new |

### 3.4 An agent from the agents Feature's list, as the office or DSNP would run it

(The list is `.devcontainer/agents.yml`, one entry per agent: `name`, `cli`, `kind`, `folder`,
`args`; here only `host`. The office and DSNP add their own, with their own `folder`.)

| | |
|---|---|
| Reads and writes today | the same as `vscode`: all consumer repos' git dirs under `/git-dirs` (ADR-0020 shares them), the office's key file and `secrets.env` (agent-linux-user T4), its own and every other agent's Claude state |
| Reaches today | the internet, loopback OpenBao, the docker socket |
| Needs | its `folder` and its CLI's state, its CLI login, the model API, the repository's own forge, the secrets named in its `integrations` (agents-v2) |
| Gap | the consumer's agent holds the same keys as the Operator |
| Existing control | per CLI, in the consumer's list or managed settings: for `claude`, the sandbox keys of 3.1 written by the consumer's `.claude/settings.json` or the managed drop-in; for `codex`, `sandbox_mode = "workspace-write"` with `[sandbox_workspace_write] network_access = false` and `writable_roots`, `approval_policy = "on-request"` or `"never"`, set in `~/.codex/config.toml` or a managed `requirements.toml` (from Codex's documentation; Codex is not installed here and none of this was run); for GitHub, a fine-grained token per consumer repository; for OpenBao, a per-agent AppRole (`openbao-agent-login`) |
| Residual | what the CLI's sandbox does not cover: the agent's own process, a CLI with no sandbox (Gemini, Copilot: the matrix in agents-v2 section 14 lists what each offers; not re-checked here), the git dir's `config`, the docker socket |

## 4. The gaps, each with the control that closes it and what is left

| # | Gap | Control that exists | Setting | Residual |
|---|---|---|---|---|
| G1 | Passwordless `sudo` | the image's sudoers file is the base image's | remove `/etc/sudoers.d/vscode` for agent users; the Operator's user keeps it. As a first step in the devhost, a `sudo` password for `vscode` is **not** a control: the agent is `vscode` | none once agents are not `vscode` (agent Linux users, #186) |
| G2 | `docker` group | Linux groups | agent users not in `docker`; the Operator's user keeps it | the Operator's terminal holds root-equivalent power; tester needs docker (T4) |
| G3 | Credential files readable by the agent | Claude sandbox read-deny, then separate users | `sandbox.filesystem.denyRead` of `$OPENBAO_STATE_DIR`, `.../gh`, `.../cloud-folder`, `.../ssh-agent`, `$CLAUDE_CONFIG_DIR/.credentials.json`; later modes 700 under another user | a process outside a tool call (the CLI itself, a hook, an MCP server) is not sandboxed (T1) |
| G4 | Write anywhere in the checkout, including what the Operator runs later (`Taskfile.yml`, `.githooks/`, `.claude/`) | Claude sandbox write rules; GitHub CODEOWNERS and rulesets for what reaches `main` | `sandbox.filesystem.denyWrite` for those paths; the sandbox's built-in mandatory write protections already cover `.claude/commands`, `.claude/agents`, `.mcp.json` and shell rc files | the Operator's own terminal and Windows `task dc:*` run whatever was written on the checked-out branch; only review catches it |
| G5 | Git dir's `config` and `hooks/` writable (and shared with the workstation and with every other container) | the sandbox's mandatory write protections list `.git/hooks` and `.git/config` (found in the binary; `sandbox.filesystem.allowGitConfig` lifts the `config` one) | managed `sandbox.filesystem.denyWrite` of `/git-dirs` and of the git dir's `config` and `hooks/`; `sandbox.filesystem.allowWrite` only the git dir's `objects`, `refs`, `logs`, `index`, `HEAD`, `packed-refs`, worktree folders | **whether it covers this layout is unknown**: the mandatory list names `.git/config` and `.git/hooks` under the working directory; here `.git` is a pointer file and the real directory is `/git-dirs/<owner>/<repo>`. Test T3. Even if it covers tool calls, it does not cover a process outside the sandbox and the workstation's own git |
| G6 | Push, merge, release, settings changes by anyone holding the Operator's GitHub login | GitHub server-side rules | a ruleset on `main` (no direct push, required checks `validate`, `lint`, `tests`, `DCO`, linear history, no force push, no deletion), required review by the Operator, CODEOWNERS on `Taskfile.yml`, `.githooks/`, `.github/`, `.devhost/`; tags protected (releases); `GITHUB_TOKEN` default read in Actions; the release workflow guarded by an environment with required reviewers | an agent holding a token with Administration can change the rules; so the host's token must not have it (G7) |
| G7 | The Operator's `hosts.yml` is the agent's GitHub login | fine-grained personal access token or GitHub App installation token | permissions: Contents write, Pull requests write, Metadata read (no Administration, no Workflows, no Actions write, no Secrets), selected repository, an expiry; or an App with the same, for the consumer's repository only | a token at rest in a file until the OpenBao AppRole (`openbao-agent-login`) mints it; ADR-0048 decision 1's named interim (agent-linux-user review finding 14) |
| G8 | One OpenBao identity: the Operator's token | OpenBao policies and AppRoles | per-agent and per-back AppRole with its own policy (`path "dcf/register/<back>" { capabilities = ["read"] }` and nothing else), token TTL a few minutes, `secret_id_num_uses`, bound CIDR 127.0.0.1/32 (already so for backs); the agent logs in itself (`openbao-agent-login`) | the loopback listener answers anyone; the unauthenticated root-token endpoints (ADR-0055): a unix socket listener at mode 600 for the Operator's user (agent-linux-user review finding 7), only useful once users differ |
| G9 | `rclone.conf` and the shared folder are the agent's | rclone's own config encryption, narrow remote scope | a remote limited to the folder `Agent Artifacts/devcontainer-features` (a SharePoint site or OneDrive folder token with scope to it, if the provider's app registration allows; not confirmed here); `rclone mount --read-only` for agents that only read; `--allow-other` with the group only when agent users exist | `rclone.conf` readable by the mounting user |
| G10 | ssh-agent socket usable by any process | `ssh-add -c` (confirm each use), key lifetime `-t`, keys not loaded by default | no key in the agent unless a sitting loads it (secrets-master-split) | within a loaded sitting, any same-user process may sign |
| G11 | Network: everything outbound | Claude sandbox's proxy; Codex's `network_access = false` | `sandbox.network.allowedDomains` (an allow-list), `allowManagedDomainsOnly: true`, `deniedDomains`; `allowLocalBinding: false` so a tool call cannot talk to a loopback listener it opens; `allowUnixSockets` empty so the docker and ssh-agent sockets are unreachable | the sandbox's network filter is a domain proxy: a data channel to an allowed domain (e.g. a gist on github.com) stays open; this is inherent |
| G12 | The docker socket | none native | `sandbox.network.allowUnixSockets` empty and `sandbox.filesystem.denyRead: ["/var/run/docker.sock"]` close it for Claude's tool calls; removal from the group (G2) for the user | **no native control** for a process that is allowed docker; rootless docker or a docker proxy with an allow-list (a custom broker, on hold) are the only others |
| G13 | Another agent's Claude state and login | separate users, mode 700 | `CLAUDE_CONFIG_DIR` per user (agents Feature drop-in, agent-linux-user 8.2) | none inside one user |
| G14 | A permission prompt answered by the agent itself | Claude permission settings | managed: `allowManagedPermissionRulesOnly: true`, `disableBypassPermissionsMode: "disable"`, `permissions.deny` (`Read(./.env*)` exists), `sandbox.allowUnsandboxedCommands: false` (no `dangerouslyDisableSandbox`) | `permissions.defaultMode` the agent can pass on its command line if the session is started by the agent (agent-linux-user: refusal of `agents start` by an agent) |
| G15 | Leases and runtime state folders 777 | file modes | `/var/lib/devcontainer-features/agents` 755 and `leases/` 700 under the caller once users differ (ADR-0036 amended) | none |

## 5. What has no native control (the residual column, collected)

1. **The docker socket** (G12): the container is privileged for docker-in-docker; whoever may talk
   to the daemon is root. Native controls only hide the socket (sandbox, group); none narrows what
   a permitted caller may ask for.
2. **The shared git dir** (G5): `config` and `hooks/` are one set of files for the container, every
   other container of the repository and Windows git. The sandbox's write protection may cover
   tool calls in this checkout; nothing native covers the workstation's git or a second container
   (ADR-0020). Windows-side detection (the launcher compares `config` against the last known copy
   before `task dc:*`) is the item agent-linux-user's review proposed; it is a custom check, so it
   waits.
3. **Code the Operator runs later** (G4): a branch checked out in the shared checkout is run by the
   Operator's `task`, by `.githooks/`, and by Windows `task dc:*` as the Windows account. Server-side
   review of the pull request catches it after the fact; no local control.
4. **A tool call versus the process around it**: Claude's sandbox wraps Bash tool calls (and, per
   its settings, file tools by permission rules), not the session's own process, its hooks, its
   MCP servers or the scribe runner. To confirm (T1).
5. **Cons share the parent** (3.2): no user of their own.
6. **`sudo` inside a sandbox**: bubblewrap and seccomp set `no_new_privs`, so `sudo` fails inside the
   sandbox. This is a control (the agent cannot `sudo` from a sandboxed call), and a cost: anything
   the host must do by `sudo` has to run outside the sandbox (the Operator's terminal) or through a
   `sandbox.excludedCommands` entry, which would reopen the hole. Brokers finding 9 says the same.
7. **GitHub rules do not bind an Administration token** (G6, G7): server-side rules protect against
   what the token cannot do, so the token's permission set is the control, not the ruleset alone.
8. **Codex** (second vendor, NFR-12): from its documentation, `sandbox_mode` offers read-only,
   workspace-write (Landlock and seccomp on Linux; network off by default) and danger-full-access;
   writable roots and the network switch are configurable; a managed `requirements.toml` can fix
   the allowed modes. It is not installed in this devhost, so none of this was run, and whether it
   protects the git dir the way Claude's list does is not known (T5).

## 6. The two architecture reviews, finding by finding

Each finding is mapped to **closed** (by a native control, the setting named), **residual** (no
native control; stays and is said so), or **n/a** (it belongs to a design that is on hold or does
not arise without it).

### 6.1 `agent-linux-user.md` (architecture review 2026-11-06, 16 findings)

| # | Finding in short | Verdict | Row, or why |
|---|---|---|---|
| 1 | The git dir's `config` is not protected by being the Operator's file (rename over needs the folder) | residual, maybe closed in the container | G5 and T3: the sandbox's write protection is by path, not by owner, so it avoids the rename problem for tool calls if it covers the path; the workstation half stays |
| 2 | Every adapter verb must run as the agent's user | n/a for now | a consequence of separate users; without them the verbs run as one user; revisit when #186 is built |
| 3 | The backs' `sudoers` rule is wider than the hand-over | n/a | no `sudoers` rule is needed by the MVP; the rule exists only in the multi-user design; the backs stay `vscode` and are narrowed by their own `--allowedTools` and sandbox (3.3) |
| 4 | The cost report reads one user's transcripts | n/a | one user keeps one transcript folder |
| 5 | Claude's memory path moves (ADR-0049) | n/a | only when users are made |
| 6 | The Operator's long-lived processes miss the group | n/a | same |
| 7 | ADR-0055's open unix-socket listener | closed after G1 and G8 | a root-token endpoint on a unix socket 600 is an OpenBao listener setting, native, useful once the agent is not `vscode` |
| 8 | The boundary check knows other Features | n/a | `agents boundary` is the multi-user check; the substitute is a managed-settings test (T1) listing the denied paths, which is each Feature's own path in its own drop-in |
| 9 | The per-user Claude login sits in the agents Feature | n/a | no per-user login in the MVP |
| 10 | The token route rests on a daemon that outlives the environment | residual | applies to any per-user Claude token; test U3 of the proposal |
| 11 | `agents boundary` and the linter contract | n/a | not built |
| 12 | Shared names without an owner (`dcf-work`) | n/a | no shared group in the MVP |
| 13 | The plain-`claude` warning has no mechanism | closed | a `SessionStart` hook in the managed settings (already how ADR-0032 writes managed settings) |
| 14 | Tokens at rest per agent outside ADR-0048 decision 1 | residual (named interim) | G7: until `openbao-agent-login`; no native control for a token file at rest besides mode 600 and a separate user |
| 15 | Section 11 and slice 5 disagree on openbao's version | n/a | a design-level correction |
| 16 | Cloud-folder `sync` and `host` modes not covered | residual | G9: `host` mode is a bind mount whose owners depend on the engine; test U1; only read-only mount flags are native |

### 6.2 `brokers.md` (architecture review 2026-11-06, 20 findings; on hold)

| # | Finding in short | Verdict | Row, or why |
|---|---|---|---|
| 1 | git's repository config outranks the broker's; this repo's already runs work-tree hooks | closed in part | G5: deny write on `config` and `hooks/`; also remove `core.hooksPath` pointing into the work tree from the git dir's `config` and put it in the global config (the git Feature's `hooksPath`, `GIT_CONFIG_GLOBAL`) with the sandbox denying write there; the fix of `task repo:setup` is repository work |
| 2 | A merge driver in this git dir runs a work-tree script | closed by removal, if still present | delete the `merge.devhost-todo.driver` key if it is there (not seen on 2026-11-06); with G5 the agent cannot add one; a plain config change, no new code |
| 3 | A brokered hook re-enters the broker | n/a | no broker |
| 4 | The rule has no `secure_path` | n/a | no `sudoers` rule |
| 5 | The git dir still needs `core.sharedRepository` | n/a | one user |
| 6 | Submodules and nested repositories run a config the agent wrote | residual | no native control; `safe.directory` exact paths (never `*`) in the git Feature; `submodule.recurse=false` in the global config; the sandbox's mandatory write protection names `.git/config` under the working directory, which would cover a nested repository's too if it is by pattern (test T3) |
| 7 | Push rules hold only while no agent holds a credential | closed by a native control | G6 and G7: a ruleset and a narrow token make the push rule a server rule; the broker's "advisory" objection falls |
| 8 | The first allow-list leaves out everyday verbs | n/a | no broker |
| 9 | `sudo` cannot run inside a CLI sandbox | closed, as a control | row 6 of section 5: the same fact makes the sandbox itself the barrier against `sudo` |
| 10 | A GitHub App key in the broker's memory | n/a | no broker; a fine-grained token or an installation token minted by OpenBao (G7, G8) |
| 11 | An SSH certificate needs more of ADR-0058 amended | n/a | an OpenBao CA for GitHub is a later route; not an MVP step |
| 12 | The reserved id range contains `dcf-work`'s gid | n/a | no broker accounts |
| 13 | The branch rule is a way-of-working rule in a published Feature | closed | a GitHub ruleset's branch name pattern restriction (or the repository's `pre-push` hook) holds it, in the consumer's repository, not in a Feature |
| 14 | `brokerCredentials: file` keeps a token at rest | residual | same as agent-linux-user 14, G7 |
| 15 | Who owns the broker's OpenBao role | n/a | no broker; the per-agent AppRole (`openbao-agent-login`) keeps the openbao Feature as owner |
| 16 | The include and hooks are described wrongly (the `include.path` resolves under `/git-dirs`) | closed by removal | drop the include from `repo:setup` and from the git dirs; this repository's fix, not a control |
| 17 | `fetch` must not move the ref the hooks are read from | n/a | hooks are the repository's own `.githooks/` read from the work tree; the control is G4 (deny write) and review |
| 18 | The callers group is wider than the callers | n/a | no broker |
| 19 | Section 2 cites the wrong finding for docker | n/a | a record fix in a draft |
| 20 | The git broker stands on test U3 (`chown` and modes on the 9p mount) | residual and the key unknown | T2: on this mount everything shows `root` 777; if modes do not hold, separate Linux users cannot protect the git dir or the checkout, and only the sandbox (path-based, in the tool's own bwrap) and the forge remain |

## 7. The MVP list, in delivery order

Smallest change that removes the biggest privilege first. Each is configuration of something that
already exists, not a build. "Owner" is the Feature (or place) that carries the setting; Features
stay opt-in and a consumer adopts by option.

| Step | Removes | Change | Owning Feature | Setting or task |
|---|---|---|---|---|
| 1 | GitHub admin power in the agent's hands (G6, G7) | a ruleset on `main` of each repository (here `task repo:govern`, if it covers it, else by hand): no direct push, required checks, review, CODEOWNERS for `Taskfile.yml`, `.githooks/`, `.github/`, `.devhost/`; protect release tags; a fine-grained token (Contents write, Pull requests write, Metadata read, one repository, an expiry) in place of the Operator's login for the host | the repository (rulesets), `gh` Feature (token in `GH_CONFIG_DIR`) | `task repo:govern`; `gh` login with the narrow token; a note in NOTES |
| 2 | Secrets readable by a tool call (G3, G12, G11 first part) | turn on Claude Code's sandbox in a managed drop-in: `sandbox.enabled: true`, `sandbox.failIfUnavailable: true`, `sandbox.allowUnsandboxedCommands: false`, `sandbox.filesystem.denyRead` of the credential paths and `docker.sock`, `sandbox.filesystem.allowWrite` of the checkout, scratchpad and `/tmp`, `sandbox.network.allowedDomains` | claude-code (already writes `/etc/claude-code/managed-settings.d/` for ADR-0032) | a new option, e.g. `sandboxDenyRead` and `sandboxAllowedDomains`, written by `claude-additional-dirs.sh`'s sibling; the consumer's list of domains |
| 3 | The agent lifting its own limits (G14) | `allowManagedPermissionRulesOnly: true`, `disableBypassPermissionsMode: "disable"`, `allowManagedHooksOnly` where the consumer has no hooks of its own | claude-code | same drop-in |
| 4 | Writes into what the Operator runs later and into the git dir (G4, G5) | `sandbox.filesystem.denyWrite` of `.githooks`, `Taskfile.yml`, `.devhost`, `.claude/settings.json`, and the git dir's `config` and `hooks/`; remove `merge.devhost-todo.driver` and the `include.path` from the git dir and from `repo:setup`; move `core.hooksPath` to the global config; run test T3 first | claude-code (the drop-in), git (global config, `repo:setup` lives here) | `sandbox.filesystem.denyWrite`; `task repo:setup` |
| 5 | The backs' own reach (3.3) | per job `--settings` with the sandbox keys (or the managed ones apply to `claude -p`; test T1) and `--allowedTools` kept narrow; the tester under `bwrap` | devhost (local Feature) | `job_claude` flags in `run-job.sh`; the jobs' `--allowedTools` |
| 6 | One OpenBao identity (G8) | per-agent AppRole with a read-only policy and a short token; the agent logs in itself | openbao (item `openbao-agent-login`) | `bao write auth/approle/role/<agent> token_policies=... token_ttl=...`; `task openbao:approle:issue` |
| 7 | Root for agent users (G1, G2) | no `sudo` and no `docker` for the agent's user: only after the agent is not the Operator's user; this is #186 re-scoped to the smallest form: one `agent` user for the host and its cons (not per agent, not per back), launched by `sudo -n -u agent` with its own `CLAUDE_CONFIG_DIR` | agents | `runAs` option; the `sudoers` and `docker` group files |
| 8 | Reach of the shared folder and the ssh-agent (G9, G10) | read-only mount for agents that only read; no key loaded by default | cloud-folder, ssh-agent | `rclone mount --read-only`; `ssh-add -c -t` at the sitting |
| 9 | The second vendor (NFR-12) | the Codex equivalent of steps 2 to 4 in the consumer's list: `sandbox_mode = "workspace-write"`, `network_access = false`, `writable_roots`, `approval_policy` | agents (adapter drop-in) or the consumer | `CODEX_HOME/config.toml` or a managed `requirements.toml` |

Steps 1 to 5 need no new Linux user, no new script and no change to the agents Feature; they are
settings. Step 7 is the first that changes how an agent starts, and it comes last because steps 1
to 6 already take away the credentials and the write targets; step 7 adds the boundary around
anything the sandbox does not wrap.

## 8. The unknowns, each as a test

| # | Unknown | Test | Pass means |
|---|---|---|---|
| T1 | Does Claude's sandbox wrap what is needed (Bash calls, but also file tools and the backs' `claude -p`), and does `permissions.deny` or `sandbox.filesystem.denyRead` win for a Read of a path? | in a scratch devhost, write the managed drop-in with `sandbox.enabled: true` and a `denyRead` of a temp file; from a session, `cat` it, Read it, and run a back's `claude -p` with `--settings` the same; read the exit text, never the contents | all three refuse; the back refuses with the managed drop-in alone |
| T2 | Do `chown` and modes hold on the 9p `/git-dirs` and checkout? | in a temp folder on `/git-dirs` (not a repository's), `chown`, `chmod 600`, and open it as another uid (`sudo -u nobody test -r`) | the other uid is refused; if not, separate users protect nothing on these mounts |
| T3 | Does the sandbox's write protection cover a git dir reached by a `.git` pointer (`/git-dirs/<owner>/<repo>/config`, `hooks/`) and a nested repository's `.git/config`? | with the sandbox on, from a tool call, `touch` and `mv` over a copy of a git dir's `config` kept in a temp git dir pointed to by a pointer file; also `git config --local x.y z` | refused for `config` and `hooks/`; allowed for `objects/` and `refs/` |
| T4 | Can the tester run the suite under `bwrap` with docker-in-docker, or does it need the group? | `bwrap` with the socket bound and the credentials hidden, run `task test FEATURE=git` | passes; if not, the tester is the one actor left with the group |
| T5 | What does Codex's `workspace-write` protect on this layout (git dir, `.codex`, `/git-dirs`), and does it run under the devcontainer's seccomp? | install Codex in a scratch container, write a `config.toml`, try the same writes as T3 | the same refusals, or a list of what differs |
| T6 | Does the GitHub token's permission set still allow what the host does (push, PR create, mark ready)? | a fine-grained token with the set of step 1; `gh pr create`, `gh pr ready`, `git push`; then `gh api` to change a ruleset | the first three work; the last is refused |
| T7 | Does a sandboxed call reach OpenBao on loopback only when `allowLocalBinding` and the allowed domains say so, and can a back still reach it as the runner (outside the sandbox)? | with step 2's drop-in, `curl` loopback from a tool call, then run `devhost-run-job scribe` | the tool call is refused; the runner logs in |
| T8 | Does the fine-grained token or GitHub App for the office's repository cover its pull-request workflow? (the office's rules were not read here) | the consumer runs the same set as T6 in its repository | same as T6 |

## Test results (2026-11-08)

Run by a con in the live devhost with `claude -p --settings <file in a scratch folder>` (Claude
Code 2.1.311, `--model haiku`, small `--max-turns`; about USD 0.06 for 11 runs), against temp files
holding a dummy line; no real credential path was probed and no file contents were read back. The
sandbox keys were `enabled`, `failIfUnavailable`, `allowUnsandboxedCommands: false` and
`filesystem.{denyRead,allowRead,denyWrite,allowWrite}`. Most runs used `defaultMode:
bypassPermissions` in the settings file so that only the sandbox and the `permissions` rules
could refuse; the back-like run used the default mode with `--allowedTools`. A `Read(/abs)` rule is
relative to the project root: an absolute path needs `Read(//abs)` (the first try with one slash
refused nothing).

### T1: what the sandbox wraps, and which rule wins

| Probe | Expected | Result |
|---|---|---|
| Bash `cat` of a `denyRead` file | refused | refused: `Permission denied`, exit 1 |
| Bash `cat` of a file outside every list (control) | allowed | allowed, exit 0 |
| Read tool on a `denyRead` file | refused | **allowed** |
| Write tool over a `denyWrite` file | refused | **allowed** (file changed) |
| Bash `echo >>` to a `denyWrite` file | refused | refused: `read-only file system` |
| Read tool on a file under `permissions.deny` `Read(//path)` | refused | refused: `File is in a directory that is denied by your permission settings` |
| Bash `test -r` / `wc -c` on a file under `permissions.deny` `Read` only (not in `denyRead`) | refused | refused: `permission denied` (the `permissions.deny` Read rule is merged into the sandbox for Bash) |
| Bash append to a file under `permissions.deny` `Write`/`Edit` only | refused | refused: `read-only file system` (merged the same way) |
| Write tool over a file under `permissions.deny` `Write` | refused | refused: `File is in a directory that is denied by your permission settings` |
| `permissions.allow` `Read(//path)` on a file that is in `denyRead`: Read tool | n/a | allowed (the Read tool never consults the sandbox) |
| same file: Bash `cat` | which wins | **refused**: `denyRead` beats `permissions.allow` for Bash |
| file in `denyRead` and `allowRead`, with `permissions.deny` `Read`: Read tool | which wins | refused (`permissions.deny` wins on the file tool) |
| same file: Bash | which wins | **allowed**: in the sandbox `allowRead` re-allowed it over `denyRead` and over the merged `permissions.deny` (one sample) |
| back-like `claude -p` (the flags of `job_claude`: `--settings` with `disableAllHooks` and the sandbox keys in one JSON, `--no-session-persistence`, `DEVHOST_JOB_CHILD=1`, default permission mode, `--allowedTools "Bash" "Write"`): Bash read of a `denyRead` file and append to a `denyWrite` file | refused | refused, both; Write over a path under `permissions.deny` refused |
| the same run with the managed drop-in alone, no `--settings` | refused | **not run** (see below) |

Verdict T1: **partial**. The sandbox wraps Bash calls and everything a Bash call starts, and a
`claude -p` run of the backs' shape honours the sandbox keys given in `--settings`. It does not wrap
the file tools: `Read`, `Write` and `Edit` are governed only by `permissions` rules, and
`sandbox.filesystem.denyRead` and `denyWrite` do not reach them. Precedence: for the file tools
`permissions.deny` is the only control (and beats `allowRead`); for Bash the sandbox lists apply
and `permissions.deny` Read and Write rules are merged into them; `denyRead` beat a
`permissions.allow`, and `allowRead` re-allowed a path over `denyRead` (one sample, so
unconfirmed for the merged deny). Not run here: the "managed drop-in alone" half, because writing
`/etc/claude-code/` is barred in the live devhost. Steps for a scratch container: build it from the
tree, as root write `/etc/claude-code/managed-settings.d/50-sandbox.json` with the sandbox keys and a
`denyRead` of a temp file; as the agent's user, with no `--settings`, run `claude -p --model haiku
--max-turns 6` with the prompt "run `cat <temp file>` with Bash" and "Read `<temp file>`"; refused
means the managed layer applies to `claude -p`; also run it with `DEVHOST_JOB_CHILD=1` and the
job's `--settings '{"disableAllHooks": true}'`, which would show whether a `--settings` flag
weakens or replaces a managed key.

### T3: a git dir behind a pointer file

Layout: a temp repository `repo/` whose `.git` is a file `gitdir: <path>` to
`gitdirs/owner/repo/` elsewhere in the scratch folder, plus a nested repository `repo/sub/`.
`allowWrite` listed `repo/` and the git dir (what a commit needs). Config A: nothing more.
Config B: also `denyWrite` of the git dir's `config` and `hooks`. Every probe was first run
outside the sandbox as a control: all allowed.

| Probe (from a Bash call) | Expected | A: defaults | B: explicit `denyWrite` |
|---|---|---|---|
| `touch` / append to the git dir's `config` | refused | **allowed** | refused (`read-only file system`) |
| `mv -f` a file over `config`; `cp` over it | refused | **allowed** | refused (`inter-device move failed`; `cp` read-only) |
| `mv config config.bak` (move it aside) | refused | **allowed** | refused |
| `touch` a file in `hooks/`; `mv` a file into it | refused | **allowed** | refused |
| `mv hooks hooks.bak` (move the directory aside) | refused | **allowed** (the directory was gone afterwards) | refused |
| `git config --local x.y z` | refused | **allowed** | refused (`could not write config file`) |
| `git add` and `git commit` | allowed | allowed | allowed |
| `touch` in `objects/` and `refs/heads/` | allowed | allowed | allowed |
| overwrite or `touch` the `.git` pointer file in the work tree | not asked | refused (`read-only file system`) | refused |
| `touch` / append to `sub/.git/config`; `touch sub/.git/hooks/h` | refused | refused | refused |
| `git -C sub config --local x.y z` | refused | refused (`Device or resource busy`) | refused |
| `touch repo/a.txt` (control) | allowed | allowed | allowed |

Verdict T3: **partial, and passes with an explicit list**. The default protection covers the `.git`
pointer file and a nested repository's `.git/config` and `.git/hooks` inside the work tree, but
not the git dir the pointer leads to: with defaults the agent can rewrite `config` and `hooks/`
there. With `denyWrite` naming the target's `config` and `hooks`, those are refused, including
moving them aside, while commits, `objects/` and `refs/` keep working. Caveats: the rule is by
path, so it must name the real `/git-dirs/<owner>/<repo>/config` and `.../hooks` (the git Feature's
wrapper knows the path; the drop-in needs it per repository); the denied entries are bind-mounted
read-only, so any command that rewrites `config` (`git config --local`, `git push -u`, `git branch
--track`, test T10) fails; and, from T1, the file tools are not covered by `denyWrite`, so the same
paths also need `permissions.deny` rules for `Edit` and `Write`.

### What it means

- **Step 2 (turn on the sandbox)**: it can be turned on for Bash, which is where `cat`, `curl`,
  `git` and every started process run, and the backs' `claude -p` accept the keys in `--settings`.
  It is not enough alone: each protected path needs both `sandbox.filesystem.denyRead` or
  `denyWrite` (Bash) and a `permissions.deny` rule for `Read`, `Edit` and `Write` (file tools),
  which the managed drop-in can carry with `allowManagedPermissionRulesOnly` (step 3). Use
  `permissions.deny` `Read(//path)` for the credential paths: it is merged into Bash as well, so
  one list in the permissions form covers both (keep `allowRead` out of the drop-in: on Bash it
  re-allowed a denied path). The gate is partly
  met: step 2 may go ahead on that condition; the managed-drop-in-alone question (T1) is still
  open and must be run in a scratch container before the backs rely on the managed layer.
- **The git dir residual (steps 4, 5)**: closed for Bash by listing the pointer target's `config` and
  `hooks` in `denyWrite`; the defaults do not do it. The drop-in is written per repository from the
  git Feature's resolved path (or a pattern, untested). Closed for the file tools only with
  `permissions.deny` `Edit` and `Write` rules on the same paths. Open: the CLI's own process, hooks
  and MCP servers are outside both layers (as T1 and the inventory's residual already say), and a
  `config`-writing git command fails under the rule.

## Sources

Read in the devhost on 2026-11-06: `id`, `sudo -n -l`, `stat` of the paths in section 2,
`mount`, `ss -ltn` (listening ports only), `bwrap --ro-bind / / true`, the listing of settings
keys in the installed `claude` binary (2.1.311), `.claude/settings.json` and the user settings
keys (not values), `.devcontainer/agents.yml`, `local-features/devhost/share/bin/run-job.sh`,
`lib.sh` and the four jobs' tool flags, `docs/proposals/agent-linux-user.md` (its architecture
review) and `git show origin/docs/broker-pattern/1:docs/proposals/brokers.md` (its review). Not
confirmed: Claude's documented defaults and precedence (the documentation was not looked up), everything
about Codex, the office's and DSNP's own settings, and the GitHub rules and token set of any
repository (not read; the proposals name them).
