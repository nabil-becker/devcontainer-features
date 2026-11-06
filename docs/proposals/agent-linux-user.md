# Proposal: agents run as their own Linux users

Status: proposed 2026-11-06. Awaits the architecture review and the Operator's ruling; build not
started. Backlog: `agent-linux-user`, moved to Now by `amend-agent-linux-user` (2026-11-06);
`key-file-rotate` waits on it.

Who this serves: the Operator, through the host, who turned the OpenBao key file on in this devhost
before agents had their own user (ADR-0056 decisions 8 and 9) and rotates it once they do; the
maintainers of the office and of DSNP, who adopt the `agents`, `claude-code`, `git`, `gh`,
`openbao` and `cloud-folder` Features and today keep secrets in a container where every agent can
read them; and the engineers whose agents run in those devcontainers, who must not lose a working
session, a commit or a file to a permission error.

How to read it: section 1 is the ask; section 2 what was checked in this devhost; section 3 the
threat model, including what a separate user does not fix; section 4 the picture; sections 5 to 10
the design, each with its options and a recommendation; section 11 what a consumer changes and
what breaks; section 12 the slices; section 13 the unknowns, each as a test; section 14 the
decisions for the Operator; section 15 what was found for the repository. The architecture review
goes at the end, written by the host after this draft.

## 1. The ask

The backlog item, as written: "Claude Code and the background agents run as the Operator's user,
so any agent can read a key file kept in the container. Give agents a separate Linux user with no
passwordless `sudo`, then check that user cannot read the key file." The Operator's amendment of
2026-11-06 asks for agents to run "as their own independent Linux users", next, with the scope
unchanged.

Rulings it rests on:

- **ADR-0056 decisions 8 and 9.** Until agents run as their own Linux user, any agent could harvest
  the quorum (the OpenBao key file's two shares cross the container's memory at each unlock) and
  use the Operator's token. The Operator chose to turn `unlock: keyfile` on anyway and to rotate
  the key file and the shares once this is done (`key-file-rotate`).
- **ADR-0048 decision 4.** Every task that handles a share or a token refuses inside an agent's
  job. Today that refusal reads environment variables (`DEVHOST_JOB_CHILD`, `CLAUDECODE`,
  `OPENBAO_AGENT_JOB_VARS`), so it stops only an agent that does not unset them.
- **ADR-0036.** An agent in the list has an `identity`, the principal it acts as; two stateful
  agents may not share one. A Linux user per identity is the same idea one level down.
- **ADR-0020.** Every container sees all of `.git-dirs`; the git Feature's wrapper maps the
  checkout's pointer onto `/git-dirs`.
- **ADR-0040.** The host commits, pushes and opens pull requests; the Operator merges.
- **ADR-0045.** Losing a machine loses nothing: a user's state lives in a Feature volume, never
  only in a home folder.
- **NFR-5, NFR-12, NFR-13.** Features stay user-neutral; a contract for agent CLIs works on two
  vendors or names its fallback; a Feature manages the environment and uses the CLI's own
  features.
- **`openbao-agent-login`.** Each agent gets its own narrow AppRole, fetched in the tool's own
  process; the office waits on it to drop its own key file and `secrets.env`.

## 2. What was checked in this devhost (2026-11-06)

Read-only checks in the running devhost, as the remote user. Nothing was changed.

| Fact | Seen |
|---|---|
| Who runs what | Every process but `dockerd` and the init runs as `vscode` (uid 1000): the host session (`agents start` then `claude --remote-control`), its tool calls, the backs, `bao server`, the OpenBao renewer, `rclone mount`, `ssh-agent`, the pwsh of the launcher's `exec` |
| `sudo` | `sudo -n true` succeeds: `/etc/sudoers.d/vscode`, from the base image, gives the remote user passwordless `sudo` |
| Groups | `vscode` is in `docker` (the docker-in-docker daemon runs as root, so the socket is root) |
| OpenBao state | `$OPENBAO_STATE_DIR` is `vscode` 755; `token`, `audit.log`, `server.hcl`, `keyfile-pending`, `renewer.pid` and the folder `approle/` (the backs' ids) are 600 or 700, owned by `vscode` |
| Claude Code state | one volume, `CLAUDE_CONFIG_DIR=/var/lib/devcontainer-features/claude-code`, owned by `vscode`; `.credentials.json` 600; transcripts under `projects/`; the background daemon's state under `daemon/` |
| gh, rclone | `GH_CONFIG_DIR` (`hosts.yml` 600) and `RCLONE_CONFIG`'s folder (700), both `vscode` |
| git | `GIT_CONFIG_GLOBAL` in the git volume, 644, holding `safe.directory` for the checkout and its git dir |
| ssh-agent | socket `agent.sock` 600 `vscode`, in a 1777 folder |
| agents leases | `/var/lib/devcontainer-features/agents` 1777, `leases/` 0777 (ADR-0036 accepted that for a single-tenant container) |
| The checkout and `/git-dirs` | 9p (drvfs) bind mounts with `metadata`: files that never had Linux owners show as `root` 777; files made in the container keep their Linux owner and mode (`.env` is `vscode` 644). Every repository under `.git-dirs` is there, 777 |
| The shared folder | `rclone mount` as `vscode`, FUSE without `allow_other`; `/etc/fuse.conf` has no `user_allow_other`. Today no other user, root included, could open `/mnt/cloud-folder` |
| Kernel | `kernel.yama.ptrace_scope` 1; `dev.tty.legacy_tiocsti` 0 (an agent cannot push keystrokes into the Operator's terminal) |
| umask | 022 |

Two things follow. First, the users alone do not stop much while every agent sits in the `docker`
group or holds `sudo`: either is root. Second, the shared folder, which the backs and the host
read and write, would vanish for any user but `vscode` until the mount is changed.

## 3. Threat model

### 3.1 Who and what

The attacker is an agent: a Claude Code session, a con inside it, a back, or anything they start,
doing what it should not, because a prompt, a file or a tool output told it to, or by mistake. The
Operator, the workstation's Windows account and the container engine are trusted. A kernel escape
from a privileged container is out of scope (this devhost runs `--privileged` for docker-in-docker
on hosts that allow it).

### 3.2 What an agent user must not be able to read or do

| # | Must not | Today | Closed by |
|---|---|---|---|
| T1 | Read the Operator's OpenBao token (`$OPENBAO_STATE_DIR/token`) or act as the Operator in OpenBao | can | the file stays 600 under the Operator's user |
| T2 | Read the quorum while the launcher's unlock passes it on standard input, or the server's memory | can (same user; `sudo` for memory) | another uid cannot read `/proc/<pid>/fd`, `mem` or `environ`; no `sudo` |
| T3 | Read the backs' AppRole ids (`approle/<back>/`) or another agent's | can | each set owned by its own user, 700 |
| T4 | Read the office's own key file and `secrets.env` (not the OpenBao key file) | can | moved under the Operator's user, 600 (section 11) |
| T5 | Use the Operator's GitHub login, cloud-folder login, or SSH agent | can | `hosts.yml`, `rclone.conf`, `agent.sock` stay the Operator's |
| T6 | Become root: `sudo`, the `docker` group, a setuid helper of ours | can (`sudo`, `docker`) | not in `sudoers`, not in `docker`; section 7 |
| T7 | Read another agent's Claude Code state (transcripts, login) | can | one state folder per user, 700 |
| T8 | Write the Operator's Feature state (`git` global config, `gh`, OpenBao, `rclone`) | can | owned by the Operator's user, not group-writable |

### 3.3 What a separate user does not fix

Stated plainly, so nobody reads the boundary as wider than it is:

- **Code the Operator runs later.** The checkout is shared and writable by agents (that is their
  job). The Operator runs `task` from it in a terminal that holds the token and `sudo`; Windows
  runs `task dc:*` from the same folder, through OneDrive, as the Windows account that opens the
  OpenBao key file. An agent that edits `Taskfile.yml`, `.githooks/` or the vendored launcher on
  any branch the checkout is on gets its code run as the Operator at the next command. Review
  catches it only once it reaches a pull request. Section 15 proposes a separate item.
- **The git dir's config.** The git dir under `/git-dirs` is also the workstation's. A
  `core.fsmonitor`, `core.hooksPath` or `core.sshCommand` written into its `config` runs on the
  workstation the next time Windows git touches that repository. Section 9 makes `config` the
  Operator's; that is test U9.
- **Every repository's git dir** is in every container (ADR-0020). An agent in this devhost can
  write the office's git config. Unchanged by this proposal; the same file rule narrows it.
- **The loopback OpenBao listener** answers anyone in the container. Without a token an agent can
  still start or cancel a root-token attempt (ADR-0055), so it can disturb a recovery, never
  finish one (test U8).
- **Process lists.** `/proc/<pid>/cmdline` is world-readable; the rule that no secret is ever an
  argument stays.
- **Cons share their parent's user.** A con is a subagent inside its parent's process; it cannot
  be given a user of its own. Its boundary is its parent agent's.
- **A `claude` the Operator starts in their own terminal** (or the VS Code extension) runs as the
  Operator's user and has everything. Section 8 makes it say so.

## 4. The picture

```
 workstation (Windows, the Operator's account)
   %LOCALAPPDATA%\...\openbao\*.keyfile (DPAPI)      task dc:* --- devcontainer exec (as remote user) ---+
                                                                                                         |
 container ----------------------------------------------------------------------------------------------v--------
                                                                         can read / use:
                                                                         Op    host  rev   scribe
 the Operator's user  vscode, uid 1000, sudo, docker
   task dc:shell, VS Code terminal, launcher exec (keyfile unlock stdin)
   bao server + renewer, rclone mount, ssh-agent, dockerd socket
   OpenBao token, audit.log, server.hcl ................................ x     -     -     -
   GH_CONFIG_DIR (Operator), rclone.conf, agent.sock, docker.sock ...... x     -     -     -
   git global config (GIT_CONFIG_GLOBAL) ............................... rw    r     r     r

 agent-host  uid 2xxxx, group dcf-work, no sudo
   claude --remote-control (the host) -> its cons, its tool calls, its hooks
   claude-code/users/agent-host  (login, transcripts, daemon) .......... x     x     -     -
   gh/users/agent-host, openbao/agents/agent-host (its AppRole) ........ x     x     -     -

 agent-reviewer  (a resident from the agent list) ..... same shape ..... x     -     x     -

 back-scribe  uid 2xxxx, group dcf-work, no sudo
   devhost-run-job scribe, claude -p, its AppRole ids, key on tmpfs .... x     -     -     x

 shared, group dcf-work, read and write
   the checkout, its git dir (not config), /mnt/cloud-folder ........... rw    rw    rw    rw

 x = read (and use);  r = read only;  rw = read and write;  - = refused by the kernel
```

`x` for the Operator in every row is deliberate: the Operator's user keeps `sudo` (decision 5),
so trust runs one way. An agent cannot read the Operator's things; the Operator can read an
agent's.

## 5. How many users

| Option | What it isolates | Cost |
|---|---|---|
| A. One shared agent user (`agent`) for every agent and back | the Operator's secrets from all agents (T1, T2, T5, T6, T8) | agents and backs read each other's state and the backs' ids (T3, T7 open); one Claude login |
| **B. One user per identity in the agent list, and one per back** | all of T1 to T8 | one Claude login (or one token, section 8.4) and one GitHub credential per user; the backs need a hand-over from the hook (section 8.3) |
| C. One user per running session | the same as B, plus two runs of one agent apart | uids churn, so a volume's files lose their owner; a con still cannot have one; a resumed session must find its old uid. Rejected |

**Recommendation: B**, delivered as A first where it is cheaper (slice 2 makes one user per
identity; a list with one agent is option A). It is what the Operator asked for ("independent"),
it is ADR-0036's identity one level down, and it is the shape `openbao-agent-login` needs: an
AppRole per agent whose ids only that agent can read. A con is never a user (section 3.3).

Two agents may share a user only by sharing an `identity`, which ADR-0036 already allows for
ephemeral agents and one stateful one.

## 6. Making the users

### 6.1 When

| Option | For | Against |
|---|---|---|
| a. At install time, from a Feature option (`agentUsers: host,reviewer`) | no `sudo` needed at start; works where the remote user has none | a second list beside `agents.yml` (two sources for one fact); a new agent needs a rebuild; the workspace is not mounted at build, so the list cannot be read |
| **b. At start, from the agent list** | one source; a new agent needs no rebuild | needs root at start (the remote user's `sudo`, or a root start hook: test U6) |
| c. At the first `task agents -- <name>` only | lazy | residents start at the container start; the backs' users must exist before the first turn |

**Recommendation: b, with c as the fallback.** The `agents` Feature's start hook (`agents up
--post-start`) creates every identity's user before any resident starts, and `agents start`
creates a missing one. The install step makes only what does not depend on the list: the group
`dcf-work`, the helper of section 8, and the `sudoers` file of section 8.3. A consumer whose
remote user has no `sudo` at start gets one line ("agent users need root at start; agents run as
the remote user") and today's behaviour.

The backs' users (`back-scribe`, `back-secretary`, `back-librarian`, `back-tester`) are made the
same way from `DEVHOST_BACKS`, by the devhost's own start hook.

### 6.2 Names

`agent-<identity>`, lowercased, and `back-<name>`. An identity that differs only in case from
another, or makes a name longer than 32 characters, is refused by `agents check` with its line.
Login shell: the remote user's. Password: locked. Home: `/home/<user>`, in the image, so lost at a
rebuild, which is right: nothing of value lives there (state is in the Features' volumes, NFR-1).

### 6.3 uids and gids that survive a rebuild

The volumes keep numeric owners. A rebuild that hands `agent-host` a different uid would leave its
Claude state owned by nobody.

| Option | Stable across rebuilds | Stable across list edits |
|---|---|---|
| i. Next free uid, in list order | only if the order never changes | no |
| **ii. Derived from the name: `20000 + (cksum of the user name mod 10000)`** | yes | yes |
| iii. Recorded in a volume (name to uid) | yes | yes, but the agents Feature has no volume on purpose (ADR-0036) |
| iv. A required `uid:` key per agent | yes | yes, but every list must carry numbers |

**Recommendation: ii, with an optional `uid:` key** to settle a collision. `cksum` is POSIX and on
every base image (NFR-10). A collision with an existing user or another agent is refused by
`agents check`, naming both. The group `dcf-work` has a fixed gid (19999 by default, a Feature
option for an image that already uses it). Test U11 checks the collision rate on realistic names.

## 7. Who owns what

| Thing | Owner after this | Mode | Notes |
|---|---|---|---|
| The checkout (bind mount; OneDrive on the workstation) | as created; group `dcf-work` | files 664, folders 775 (umask 002 for agents) | section 9; behaviour per engine is test U1 |
| The git dir under `/git-dirs` | as created; `core.sharedRepository=group` | git sets group modes itself | `config` stays the Operator's, 644 (test U9) |
| `GIT_CONFIG_GLOBAL` (git volume) | the Operator's user | 644 | holds `safe.directory`, hooks path, the credential helper line; no secret (checked in slice 4) |
| Claude Code state | one folder per user: `claude-code/users/<user>/`, 700 | | today's top-level state moves to the default agent's folder once (decision 6) |
| gh | the Operator's login stays at `GH_CONFIG_DIR`; each agent its own `gh/users/<user>/` | 700 | section 8.5 |
| OpenBao server, token, audit log, `approle/` of the Operator | the Operator's user | 600 / 700 | unchanged; T1, T2 |
| A back's AppRole ids | `back-<name>`, under `openbao/backs/<name>/` | 700 | moved from `approle/<back>/` |
| An agent's AppRole ids (`openbao-agent-login`) | `agent-<identity>`, under `openbao/agents/<identity>/` | 700 | the agent may hold its own narrow login; OpenBao's policy is the boundary |
| ssh-agent socket | the Operator's user | 600 | agents get no socket; `SSH_AUTH_SOCK` is unset for them |
| `rclone.conf`, the cloud-folder login | the Operator's user | 600 | unchanged |
| `/mnt/cloud-folder` (the shared folder) | mounted by the Operator's user, `--allow-other --default-permissions --gid dcf-work --umask 0007` | 770 / 660 | needs `user_allow_other` in `/etc/fuse.conf` (test U5) |
| devhost state (`runs.jsonl`, the jobs' offsets, logs) | group `dcf-work`; one subfolder per back owned by it | 2775 / 664 | |
| agentic-register store | `back-scribe` writes; group `dcf-work` reads | 750 / 640 | `devhost-ledger show` for everyone |
| agents leases and markers | the Operator's user (the `agents` command runs as it) | 755 | agent users cannot take another's lease |
| `/var/run/docker.sock` | root, group `docker`; agents not in it | 660 | decision 4 |
| `sudoers` | no entry for an agent or back user, except the hand-over of section 8.3 | 440 | T6 |

## 8. Launching an agent as its user

### 8.1 The switch

`agents` runs as whoever calls it (the Operator's user in a terminal, the start hook, the
launcher's `devcontainer exec`), resolves the agent's user, and runs the adapter as that user
through one helper the Feature installs:

```
 task agents -- host        (the Operator's user, or the launcher's exec, or the start hook)
   agents start host
     lease taken             (as the caller: leases are the Operator's)
     sudo -n -u agent-host -- /usr/local/libexec/agents/agent-env agent-host -- \
         agent-adapter-claude start host . -- --remote-control
       agent-env: HOME, USER, LOGNAME, SHELL of agent-host; umask 002; cd the folder;
                  the container's variables minus the deny list; the drop-ins of section 8.2
       agent-adapter-claude: claude --remote-control ...   (now uid agent-host)
```

| Option for the switch | For | Against |
|---|---|---|
| **`sudo -n -u <user>` from the caller** | the remote user already has it; the start hook too; `sudo` logs it | needs `sudo` (a consumer without it stays on today's behaviour) |
| `runuser` or `setpriv` as root | no `sudoers` involved | needs root first, so `sudo` anyway from a terminal |
| A setuid helper of our own | no `sudo` | a root binary we would have to maintain; rejected (T6) |
| `ssh` to localhost per user | clean session | an sshd and keys per user; rejected |

**Recommendation: `sudo -n -u`.** `sudo` resets the environment by default, which is what we
want: the helper rebuilds it on purpose. Which variables pass is decision 3: the container's
variables minus a deny list (each Feature names its secret-bearing variables, plus the patterns
`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY`), or an allow list. The boundary check (section 10)
prints the name of every passed variable that matches a pattern.

An agent cannot start another agent in the first version: `agents start` run by an agent user is
refused with one line (decision 8). The host does not start agents today; when it must, a rule
for the helper alone is the later step.

### 8.2 Per-user state: drop-ins, not knowledge in the agents Feature

The agents Feature knows no CLI and no other Feature (NFR-13). A Feature that needs per-user state
installs a drop-in, `/usr/local/share/agents-feature/user-env.d/<feature>.sh`, which `agent-env`
sources with the user's name: it may set or unset variables and name folders to create (made by
`agents` as root, owned by the user, 700). The ones this collection ships:

| Feature | Drop-in |
|---|---|
| `claude-code` | `CLAUDE_CONFIG_DIR=.../claude-code/users/<user>`; the Claude credential (section 8.4) |
| `gh` | `GH_CONFIG_DIR=.../gh/users/<user>` |
| `ssh-agent` | unset `SSH_AUTH_SOCK` |
| `openbao` | unset `BAO_TOKEN`; point the token helper at `openbao/agents/<identity>/token`; `DCF_SECRET_AS` defaults to the agent's role once `openbao-agent-login` ships |
| `cloud-folder` | unset `RCLONE_CONFIG` |
| `devhost` (local) | the backs' hand-over (section 8.3) |

The other way considered: the integration contract's `env` verb (ADR-0036). It is per agent and
named in the list; per-user state must apply to every agent without the list naming it, so a
drop-in folder fits better and stays a plain file contract. Both work on any CLI (NFR-12).

### 8.3 The backs

The backs start from the host's Claude hooks (`Stop`, `SubagentStop`), so they start as
`agent-host`. The runner hands each back over to its own user:

```
 agent-host: Stop hook -> devhost-run-job scribe
   condenses the stretch it would have given the back (as today) into a hand-over file,
   mode 640, group dcf-work, in a fresh folder
   sudo -n -u back-scribe -- devhost-run-job --handover <file> scribe      (the one sudoers rule)
 back-scribe: logs in with its own AppRole ids, fetches its key onto tmpfs (as today, now
   unreadable by agent-host), runs claude -p, signs into the register
```

The `sudoers` rule names the exact command per back: `%dcf-work ALL=(back-scribe) NOPASSWD:
/usr/local/bin/devhost-run-job --handover * scribe`, and the same for the other three. The runner
validates the hand-over file (a path in its own folder, nothing else). The tester back runs the
suite; without the `docker` group it reports "skipped" as it does today where there is no daemon
(decision 4).

### 8.4 Claude Code's login, per user

Each user has its own `CLAUDE_CONFIG_DIR`, so each needs a login.

| Option | For | Against |
|---|---|---|
| a. The Operator logs each user in once (`task agents:login -- <name>`, which runs `claude` as that user) | Claude Code's own login and refresh; one revocable login per agent | one browser login per agent and per back, again after a volume reset |
| **b. One long-lived token from `claude setup-token`, kept by the Operator's user, passed to each agent in `CLAUDE_CODE_OAUTH_TOKEN` by the claude-code drop-in** | one step for all; nothing per user to log in | every agent can read the token in its own environment (it is the agent's credential anyway); whether `--bg`, the daemon and `--remote-control` accept it is test U3 |
| c. One credentials file shared by group | none to log in | Claude Code rewrites the file on refresh, so owner and mode drift; two users refreshing at once; rejected |

**Recommendation: b if test U3 passes, else a.** Either lives in the claude-code Feature's drop-in,
never in the agents spec (NFR-13). The token itself goes to OpenBao when the Operator's secrets
move there (ADR-0048 decision 1); until then a file under the Operator's user, 600.

### 8.5 GitHub, for the host's commits and pull requests

The host pushes and opens pull requests (ADR-0040), so `agent-host` needs a GitHub credential;
the Operator's `hosts.yml` is out of its reach (T5).

| Option | For | Against |
|---|---|---|
| a. Copy the Operator's token into the agent's gh folder | works at once | the same reach as today on GitHub; two copies of one token |
| **b. A fine-grained token or a GitHub App installation token per agent, limited to its repositories (contents, pull requests), in its own gh folder** | narrow; revocable per agent; the audit names the agent | the Operator makes one per agent once |
| c. Fetched per call from OpenBao (the board tool's way, `openbao-agent-login`) | nothing at rest | waits on `openbao-agent-login` |

**Recommendation: b now, c when `openbao-agent-login` ships.** The git credential helper line in
the global config (`gh auth git-credential`) stays; it reads whichever `GH_CONFIG_DIR` the user
has.

### 8.6 Remote Control, the workstation, and the Operator's own session

- **Remote Control** is unchanged in mechanism: the host session runs `--remote-control` as
  `agent-host`, with its own Claude login, so the phone reaches the same session as before.
- **From the workstation** nothing changes: `task devcontainer:agent -- host` runs `task agents --
  host` through `devcontainer exec` as the remote user, and `agents` switches.
- **Attaching to a resident** runs `claude attach` as the agent's user, in the Operator's terminal
  (`sudo -n -u`; the terminal stays the Operator's, and the kernel refuses keystroke injection,
  section 2). Test U4.
- **The Operator's interactive session stays the remote user**, with `sudo`, `docker`, the token
  and every login: `task dc:shell`, the VS Code terminal, the launcher's `exec`. It is where the
  gate's tasks run (`openbao:unseal`, the key file's tasks, `ssh-agent:key:load`), and the only
  place they work: their refusal stops reading environment variables and checks the user (an agent
  user is refused even with every variable unset).
- **A `!` command in the host** runs as `agent-host`: no `sudo`, no token. The Operator who needs
  either opens `task dc:shell`.
- **A plain `claude` in the Operator's terminal** runs as the Operator and has everything. The
  claude-code Feature prints one line when `claude` starts as the remote user while agent users are
  on: "this session runs as the Operator's user and can read its secrets; start agents with task
  agents". It warns, never blocks (decision 7).

## 9. The shared checkout: file modes and git

Two users now write the same files. Without a rule, a file the host makes (644, owner
`agent-host`) cannot be changed by the Operator's editor, and the reverse.

| Option | How | For | Against |
|---|---|---|---|
| **i. A shared group and umask 002** | every agent user and the Operator's user in `dcf-work`; agents run with umask 002; the checkout's folders set to group `dcf-work` with the setgid bit, so new files inherit it; the Operator's shells get umask 002 from a profile drop-in | plain Unix; works on a disk that keeps owners | setgid on the 9p mount is test U1; the Operator's editor (VS Code server) must also use umask 002 |
| ii. The agents' primary group is the Operator's (`vscode`) | no new group | nothing to set on folders | gives every agent the Operator's group on every group-readable file |
| iii. Rely on the mount ignoring owners | files without Linux metadata show as `root` 777 today | nothing to do | only true for old files on one engine; a new file keeps its owner (section 2) |

**Recommendation: i.** It is per engine: on wslc and docker on WSL the 9p mount stores Linux
owners; Docker Desktop's file sharing may not (test U1). Where owners are not kept, every file is
writable by everyone already, and the rule costs nothing.

**git.** The git dir is written by both users (objects, refs, the index). git has its own setting
for exactly this, `core.sharedRepository=group`: it creates objects and refs group-writable
itself (NFR-13: use the tool's feature). `git-setup` sets it in the checkout's git dir. Windows git
reads the same config and ignores the setting (test U2).

**The git dir's `config`** is the one file an agent must not write (section 3.3): it stays owned by
the Operator's user, 644. What an agent loses: `git push -u` and `git branch --track` cannot record
the upstream, and `git worktree add` cannot turn on per-worktree config. Test U9 lists every
command the host and cons use that writes it; `push.autoSetupRemote` and an explicit remote in
`git push` cover the common case.

**`safe.directory`.** git refuses a repository whose top folder or git dir another user owns. The
global config, readable by every user, already lists the checkout and its git dir; `git-setup`
adds each worktree root a con makes (or `*` in this devhost, where every folder is the Operator's
or an agent's; decision in slice 4 by the Operator's existing option `safeDirectory`). The bot
identity (ADR-0016, `commitWhenEnv: CLAUDECODE`) is unchanged.

**Worktrees** in a con's scratchpad (`/tmp/claude-<uid>/...`) are per uid already; their entries in
the git dir's `worktrees/` follow the group rule.

## 10. The check

The backlog asks for "a test that the agent user cannot read the key file". The OpenBao key file
itself is on the workstation (DPAPI), out of any container user's reach; what the container holds
is what it unlocks. So the check is a list, run as each agent user, every line expected to fail:

```
 agents boundary [<name>]          (also: task agents:boundary; the briefing shows one line)
   read  $OPENBAO_STATE_DIR/token, audit.log, server.hcl, keyfile-pending   -> refused
   read  $OPENBAO_STATE_DIR/approle/* and another agent's or back's ids     -> refused
   read  /proc/<bao server pid>/environ, mem; /proc/<unlock pid>/fd/0       -> refused
   read  the Operator's GH_CONFIG_DIR/hosts.yml, RCLONE_CONFIG              -> refused
   use   SSH_AUTH_SOCK of the Operator; /var/run/docker.sock                -> refused
   run   sudo -n true                                                       -> refused
   write the git dir's config; GIT_CONFIG_GLOBAL                            -> refused
   read  every path in AGENTS_BOUNDARY_PATHS (a consumer's own: the office's key file, secrets.env)
   read  another agent's CLAUDE_CONFIG_DIR                                  -> refused
   and, expected to work: write the checkout, the git dir's objects, /mnt/cloud-folder
```

- **Shown able to fail** (P4): the Feature test runs it twice, once as built (all refused) and
  once after `chmod 644` of a planted token (red, naming the line).
- **When it runs**: in the Feature tests; at the container start for every agent user (a failing
  line is one warning, never fatal); on demand. `key-file-rotate` starts when this is green in this
  devhost for the host and the four backs.
- **Exit codes** follow the linter CLI contract (ADR-0035): 0 all refused, 1 a line readable, 2
  usage, 3 agent users not on.

## 11. What a consumer changes, and what breaks

**Opt-in first.** A new option on the `agents` Feature, `runAs`: `remote-user` (the default;
today's behaviour) or `agent-user` (one user per identity). Every Feature change below is inert
until a consumer sets it, so every slice up to the default flip is a minor.

What a consumer does to turn it on:

1. Set `"runAs": "agent-user"` on the `agents` Feature and rebuild.
2. Make sure the remote user has passwordless `sudo` at start (the base images do), or accept the
   one-line refusal.
3. Give each agent its Claude credential (`task agents:login -- <name>`, or the token of 8.4) and,
   for an agent that pushes, its GitHub token (8.5).
4. Move what agents must not read under the Operator's user, 600, and list it in
   `AGENTS_BOUNDARY_PATHS`. **The office**: its own key file and `secrets.env`. Its board tool runs
   inside an agent session and reads them, so the office takes this step together with
   `openbao-agent-login` (the tool then logs in as its own role), or gives that one file to the one
   agent user that runs the board as a stopgap.
5. **DSNP**: check which agent tasks use `docker` or `sudo` (test U12); those move to the
   Operator's terminal or to CI.
6. Run `task agents:boundary` and read it.

**What breaks, and so needs a major**, when the default becomes `agent-user`:

| Change | Why it breaks | Version |
|---|---|---|
| The default user of every agent changes | files they make are owned by a new uid; `sudo`, `docker` and the Operator's logins vanish from agent sessions; a `!` command loses them too | agents 3.0.0 |
| Claude Code state moves to `users/<user>/` | an unmigrated tool reading `$CLAUDE_CONFIG_DIR/projects` sees an empty folder | claude-code 2.0.0 (already the major that drops `claude-host`) |
| The share-handling tasks refuse by user, not by variable | a script that ran them from an agent session with the variables unset stops | openbao, at its next major |
| `GH_CONFIG_DIR` per user | an agent's `gh` has no login until 8.5 is done | gh, at the flip (minor while opt-in) |

## 12. Slices, in delivery order

Each with its version bump, CHANGELOG entry and `task docs`; the host commits, pushes and opens
them; the Operator merges and releases.

0. **Records** (with the ruling): an ADR "agents run as their own Linux users"; the lexicon gains
   **Agent user** and **The Operator's user** (the remote user, which keeps `sudo`); ADR-0056
   decision 8 gets its "until" date when slice 6 is green.
1. **agents minor: the check first.** `agents boundary` and `task agents:boundary`, run as the
   current user. Red in today's devhost on every line, which is the evidence of section 3 and shows
   the check can fail.
2. **agents minor: the users.** Option `runAs`; group `dcf-work`; users from the list at start
   (6.1), uids by name (6.3), `uid:` key; `agent-env` and the drop-in folder (8.1, 8.2); leases
   owned by the caller; `agents check` shows each agent's user; an agent user's `agents start` is
   refused. Docker scenario: two agents, two uids, the boundary green for a planted token.
3. **claude-code minor.** The drop-in: `users/<user>/`; the credential of 8.4; the one-time move of
   today's state to the default agent (decision 6); the warning of 8.6.
4. **git minor.** `core.sharedRepository=group`; the git dir's `config` kept the Operator's;
   `safe.directory` for worktrees; umask 002 for the Operator's shells. Test: two users commit in
   turn on one checkout.
5. **gh, ssh-agent, cloud-folder, openbao minors.** Their drop-ins; cloud-folder's
   `allow_other` mount for `dcf-work`; openbao's share tasks refuse by user, the backs' and agents'
   AppRole folders (prepares `openbao-agent-login`).
6. **devhost (local) and this devhost's `.devcontainer`.** Back users, the hand-over of 8.3, the
   devhost state folders by group; `runAs: agent-user` here; the briefing shows the boundary line.
   Then the Operator runs `key-file-rotate` (a backlog item for the Operator).
7. **The flip, later**: agents 3.0.0 and claude-code 2.0.0 make `agent-user` the default, after
   the office and DSNP have run it opt-in.

Model sizing: slices 1 to 5 and 7 reach every consumer of those Features: the strongest model.
Slices 0 and 6: Sonnet.

## 13. Unknowns, each as a test

| # | Unknown | The test |
|---|---|---|
| U1 | Do the checkout and `/git-dirs` keep Linux owners, modes and the setgid bit per engine (wslc, docker on WSL, Docker Desktop, a Linux bind)? | on each host type: two users create, edit and rename files in a folder with setgid `dcf-work`; `stat` after a container restart |
| U2 | Does `core.sharedRepository=group` in a git dir shared with Windows leave Windows git working? | set it, then `git status`, `commit`, `gc` from Windows git on the same repository |
| U3 | Does Claude Code accept `CLAUDE_CODE_OAUTH_TOKEN` for `--bg`, its daemon, `attach` and `--remote-control`? Can two users' daemons run at once? | as two agent users with the token only: start a background session each, attach, reach one from the phone |
| U4 | Does `claude attach` under `sudo -n -u` in the Operator's terminal behave (resize, keys, detach)? | attach to a resident from `task dc:shell` and from the launcher |
| U5 | Does `rclone mount --allow-other` work in the container with `user_allow_other`, and does `--default-permissions` with `--gid` hold? | mount; read and write as an agent user; refused as a user outside `dcf-work` |
| U6 | Which user runs a Feature's `postStartCommand`, and can it `useradd` (`sudo -n`) on wslc, docker and the CI images (`debian:latest` has no `sudo`)? | a scenario printing `id` and the result of `useradd` in the hook |
| U7 | Can another uid read the unlock process's standard input or the server's memory? | as an agent user, during `openbao-setup unlock --stdin`: open `/proc/<pid>/fd/0`, `mem`, `environ` |
| U8 | What can an agent do on the loopback listener without a token (ADR-0055)? Does a unix-socket listener for the Operator help? | start and cancel a root-token attempt as an agent user; the same against a server with a `unix` listener owned by the Operator's user |
| U9 | Which git commands the host and cons use write the git dir's `config`? | run the host's usual sequence (branch, worktree add and remove, commit, push, push -u) with `config` read-only; list each failure |
| U10 | Do Claude hooks (`Stop`, `SubagentStop`) run the hand-over `sudo` non-interactively, inside their timeout? | a stub back that records its uid |
| U11 | Collision rate of the name-derived uids | the agent and back names of this collection and both consumers, plus 1,000 random names |
| U12 | What in the office and DSNP agent sessions uses `docker`, `sudo` or the Operator's logins today? | their ledgers and session transcripts searched for `sudo`, `docker`, `gh auth`; one session each run with `runAs: agent-user` |
| U13 | Does the VS Code server, and the Claude Code extension, start anything as the remote user that an agent then drives? | list the extension's processes and their uid with agent users on |

## 14. Decisions for the Operator

1. **One user per identity in the agent list, and one per back** (option B), not one shared agent
   user. *Recommendation: yes; a one-agent list is the shared case.*
2. **Users made at start from the agent list, with uids derived from the name** (and an optional
   `uid:` key), not a Feature option at install time. *Recommendation: yes.*
3. **Environment for an agent: the container's variables minus a deny list** (each Feature's
   secret variables plus the patterns of 8.1), not an allow list. A deny list keeps a consumer's
   own variables working; an allow list is safer and breaks more. *Recommendation: deny list, with
   the boundary check naming every passed variable that matches a pattern.*
4. **Agents get no `docker` group.** In this devhost the tester back and `task test` in an agent
   session then report "skipped"; the Feature tests run in CI (the required `tests` check) and in
   the Operator's terminal. Giving agents `docker` makes them root and the rest of this proposal
   moot where docker-in-docker is on. *Recommendation: no docker for agents.*
5. **The Operator's user keeps passwordless `sudo`.** The setup hooks rely on it (`dcf-persist`),
   and trust runs one way (section 4). The residual (code an agent plants and the Operator runs) is
   section 3.3's, and is not closed by a password on `sudo`. *Recommendation: keep it.*
6. **Today's Claude Code sessions go to the default agent's user** (`host` here) at the one-time
   move, so the host keeps its history; other users start empty. *Recommendation: yes.*
7. **A `claude` started as the Operator's user warns, never blocks.** *Recommendation: warn.*
8. **An agent cannot start another agent** in the first version. *Recommendation: yes; revisit
   when an agent needs to.*
9. **Claude login: one `setup-token` token for all agent users**, if test U3 passes, else one login
   per user. *Recommendation: the token.*
10. **GitHub: a narrow token per agent** (fine-grained or a GitHub App), moving to OpenBao with
    `openbao-agent-login`. *Recommendation: yes; the Operator makes the host's once.*
11. **Opt-in now (`runAs`, minors), default flip later** in agents 3.0.0 and claude-code 2.0.0,
    after the office and DSNP have run it. *Recommendation: yes.*
12. **`key-file-rotate` starts when `agents boundary` is green in this devhost for the host and the
    four backs** (end of slice 6). *Recommendation: yes.*

## 15. For the repository (found while writing)

- **The launcher runs from the checkout.** `task dc:*` on Windows runs `Taskfile.yml` and the
  vendored launcher from the OneDrive checkout, on whatever branch an agent left it, as the
  Windows account that opens the OpenBao key file. No Linux user closes that. Worth its own
  backlog item: the launcher runs from a copy installed per user (as Node.js is cached under
  `%LOCALAPPDATA%`), refreshed only from `main` or by the Operator.
- **The git dir's `config` is the workstation's too** (section 3.3): an agent-written
  `core.fsmonitor` runs on Windows. Slice 4 closes it inside the container; the same write from the
  workstation side (a workstation session) is outside this proposal.
- **ADR-0020's whole `.git-dirs` mount** lets an agent here write any repository's git dir; with
  agent users the `config` rule applies to all of them, but objects and refs stay writable.
  Mounting only the repository's own git dir would narrow it; it reopens ADR-0020's option 2.
- **The share tasks' refusal reads variables** (`openbao-lib.sh`): an agent that unsets
  `CLAUDECODE` passes it today. Slice 5 checks the user instead.
- **The shared folder is unreachable by any other user today** (FUSE without `allow_other`),
  including root; the cloud-folder NOTES could say so.
- **`dcf-persist` hands a folder to "the current user"**: called as an agent user it would try
  `sudo` and fail quietly. Per-user folders are made by `agents` (8.2), not by `dcf-persist`; its
  NOTES should say which user it serves.

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
