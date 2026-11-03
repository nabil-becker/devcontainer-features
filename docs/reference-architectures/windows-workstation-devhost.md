# Windows workstation devhost

The shape every consuming repository gets on a Windows workstation: a checkout in a synced folder,
its git dir outside it, a devcontainer started from PowerShell with nothing installed but Task and a
container engine, and the Features that give the container its git, its logins, its signing and its
shared folder.

## Who it is for, and when to use it

Use it when an engineer or a consumer's maintainer works on a Windows machine, keeps the checkout in
OneDrive (or another synced folder) and wants sessions, tests and builds to run in a container without
Node.js, git hooks or CLIs installed on the workstation. It is how this repository's own devhost is
assembled (see [`.devcontainer/devcontainer.json`](../../.devcontainer/devcontainer.json)), and what
[`bootstrap/`](../../bootstrap) writes as a starter.

Not for: a Linux or macOS workstation (the same shape holds, with a bash twin of every host script, and
`${localEnv:HOME}` or `${localEnv:DCF_HOST_HOME}` in place of `USERPROFILE`), or a cluster or a cloud
workspace, which has no host folder: there the `cloud-folder` Feature runs in `sync` mode and nothing here
about the launcher applies. The agent side (a host session, backs, a ledger) is the
[agentic devhost](agentic-devhost.md); the secrets side is [secrets with OpenBao](secrets-with-openbao.md).

## Diagram

```text
 WINDOWS WORKSTATION (host)                                    CONTAINER ENGINE
 +----------------------------------------------+              docker | wslc.exe | WSL distro
 | PowerShell 7, Task, an engine CLI            |                  |
 |                                              |  task dc:up      |
 |  checkout   OneDrive\...\myrepo              |  task dc:exec    v
 |  launcher   .devcontainer\cli_bootstrap.ignore\ ------> devcontainer CLI (portable Node.js,
 |  git dirs   %USERPROFILE%\.git-dirs          |          cached in %LOCALAPPDATA%, off PATH)
 |  settings   .devcontainer\.env (git-ignored) |                  |
 |  sync       OneDrive client, its folder      |                  |  one-shot commands only:
 +--+----------+----------+-------------------+                  |  no process of ours stays
    |          |          |                                        |  on the host (ADR 0024, 0026)
    |          |          +-- DCF_HOST_CLOUD_FOLDER --bind-->-+    |
    |          +-- whole .git-dirs folder --bind-->-+         |    |
    +-- checkout (workspace mount) ---->-----+      |         |    |
                                              v      v         v    v
 +-----------------------------------------------------------------------------------------+
 | DEVCONTAINER  (Linux, remote user vscode)                                               |
 |                                                                                         |
 |  /workspaces/myrepo        the checkout          /git-dirs        every git dir         |
 |  /mnt/cloud-folder-host    the host folder  -->  /mnt/cloud-folder  (link, tier 2)      |
 |                                                                                         |
 |  go-task          task <id>:*  registry     common      dcf-persist, dcf-curl           |
 |  devcontainer-cli devcontainer, nested up   git         wrapper maps .git -> /git-dirs  |
 |  gh               login, git credentials    ssh-agent   SSH_AUTH_SOCK, signing          |
 |  cloud-folder     host | mount | sync       claude-code claude, agent adapter           |
 |                                                                                         |
 |  volumes (tier 4)  git-config  gh-config  ssh-agent-key  cloud-folder  claude-code-config|
 +-----------------------------------------------------------------------------------------+
        |                    |                     |                       |
        v                    v                     v                       v
    GitHub (git, gh)    SSH agent (socket    OneDrive / SharePoint     Anthropic
                        host types only)     (rclone, sync or mount)   (Claude Code)
```

## `devcontainer.json`

The Features of this architecture, with the lines the launcher needs. `task devcontainer:up` adds the
`.git-dirs` mount and the SSH agent socket itself, so the file declares neither.

```jsonc
{
  "name": "${localWorkspaceFolderBasename}",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {},
    // Shares the engine's daemon; docker-in-docker instead if the container must run
    // `devcontainer features test` or a nested `devcontainer up`.
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/common:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/devcontainer-cli:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/git:1": {
      "hooksPath": ".githooks"
    },
    "ghcr.io/nabil-becker/devcontainer-features/gh:1": {},
    // Windows engines (windows-docker, windows-wslc) have no agent socket to mount: signing then needs
    // a VS Code terminal, or "keyMode": true, which keeps a dedicated signing key in the container.
    "ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1": {},
    // host: the launcher mounts the folder DCF_HOST_CLOUD_FOLDER names. Without a synced folder on
    // this machine use "mode": "mount" (needs DCF_HOST_FUSE=1, not on wslc) or "sync", with
    // remoteType, driveType, siteUrl and remotePath for the remote.
    "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": {
      "mode": "host",
      "mountPoint": "/mnt/cloud-folder"
    },
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {}
  },
  // What the launcher found, passed on to the Features (empty when VS Code opens the folder directly).
  "containerEnv": {
    "DCF_HOST_TYPE": "${localEnv:DCF_HOST_TYPE}",
    "DCF_HOST_HOME": "${localEnv:DCF_HOST_HOME}",
    "DCF_HOST_SSH_AGENT": "${localEnv:DCF_HOST_SSH_AGENT}",
    "DCF_HOST_CLOUD_FOLDER": "${localEnv:DCF_HOST_CLOUD_FOLDER}",
    "DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}",
    "DCF_HOST_FUSE": "${localEnv:DCF_HOST_FUSE}"
  },
  // FUSE on request, per machine (DCF_HOST_FUSE=1 in .devcontainer/.env); a harmless label otherwise.
  "runArgs": [
    "${localEnv:DCF_HOST_FUSE_DEVICE:--label=dcf.fuse.device=off}",
    "${localEnv:DCF_HOST_FUSE_CAP:--label=dcf.fuse.cap=off}",
    "${localEnv:DCF_HOST_FUSE_SECURITY:--label=dcf.fuse.security=off}"
  ],
  // Array form: a string goes through cmd /c on Windows. Creates %USERPROFILE%\.git-dirs when missing.
  "initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo"],
  "remoteUser": "vscode"
}
```

Also in the repository: a root `Taskfile.yml` that includes the vendored `devcontainer.yml` (alias `dc:`,
`optional: true`) and the go-task registry (`/usr/local/share/go-task/features.yml`, `flatten: true`), and a
git-ignored `.devcontainer/.env` for the settings of this machine. The bootstrap one-liner writes all of it.

`common` is listed because a repository's own post-create scripts may call `dcf-persist` and `dcf-curl`; every
other Feature carries its own copy, so none of them needs it. `claude-code` alone starts a session with the
deprecated `task devcontainer:claude` (removed in claude-code 2.0); the one verb that replaces it,
`task devcontainer:agent`, needs the `agents` Feature, which the [agentic devhost](agentic-devhost.md) adds.

## Data and its storage tier

The tiers are those of [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md):
1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only). The test: if losing the
machine would lose it, it is in the wrong tier.

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| Code, ADRs, records | the checkout, and its git dir under `%USERPROFILE%\.git-dirs` | 1 | kept (host disk) | kept once pushed; a commit never pushed is lost |
| Shared documents that must not be in git (recordings, raw material) | `/mnt/cloud-folder`: the OneDrive folder (`host`), or an rclone `mount` or `sync` of the remote | 2 | kept (host), or fetched again (`sync`) | kept in the cloud |
| The signed-in rclone remote (token, config), its sync state and VFS cache | volume `cloud-folder-${devcontainerId}` at `/var/lib/devcontainer-features/cloud-folder` | 4 | kept | `task cloud-folder:login` again |
| Claude Code login, settings, session transcripts, agent records | volume `claude-code-config-${devcontainerId}` at `CLAUDE_CONFIG_DIR` | 4 | kept | login again; transcripts cannot be fetched again, so decide if they matter (see below) |
| `gh` login | volume `gh-config-${devcontainerId}` at `GH_CONFIG_DIR` | 4 | kept | `gh auth login` |
| git identity and credential helper | volume `git-config-${devcontainerId}` at `GIT_CONFIG_GLOBAL` | 4 | kept; `safe.directory` is rewritten at post-create | `git-setup` rewrites most; identity again |
| A dedicated signing key (key mode only) | volume `ssh-agent-key-${devcontainerId}` | 4 | kept | the key must also be on the host; import it again |
| Host agent keys (socket mode) | the host's agent; never in the container | the workstation's own | not touched | not touched |
| The launcher, portable Node.js and the devcontainer CLI | `.devcontainer/cli_bootstrap.ignore/` (git-ignored), `%LOCALAPPDATA%\devcontainer-features` | caches | not touched | the bootstrap one-liner restores them |
| Settings of this machine | `.devcontainer/.env` (git-ignored; `HOST_TYPE_PRIORITY`, `DCF_HOST_FUSE`, `DCF_HOST_CLOUD_FOLDER`, `SSH_AGENT_MODE`) | per machine, rebuilt from `.devcontainer/.env.example` | not touched | written again by hand |
| The personal folder of the person | never mounted by a Feature | 3 | not touched | theirs |

A repository that wants a tier 4 folder to survive an engine reset bind-mounts it from the host disk
(`task devcontainer:homes` creates the folder, the repository's mount wins over the Feature's volume). That
protects against the engine, not against losing the machine, and ADR 0045 does not name it: it is a tier 4 folder
on a more durable disk. Whether session transcripts need a better home is open.

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| PowerShell 7, Task and one engine (`docker`, `wslc.exe` or a WSL distro's docker): the only installs | every tool a project needs: each is a Feature |
| the launcher, vendored into `.devcontainer/cli_bootstrap.ignore/`: `task dc:up`, `rebuild`, `exec`, `stop`, `host`, `homes`, `ssh-key-import`, `cloud-folder-login` | `devcontainer` (the same CLI, for nested builds and `features test`) and `task <id>:*` from the go-task registry |
| host type detection (`HOST_TYPE`), the `DCF_HOST_*` variables, the host mounts (`.git-dirs` at `/git-dirs`, the agent socket, the cloud folder) | the git wrapper that maps a `.git` pointer onto `/git-dirs`; the Features read `DCF_HOST_*` and never probe the host |
| the OneDrive client keeping the shared folder (`host` mode) | rclone for `sync` and `mount` mode; `cloud-folder:status` |
| the shutdown check run before a stop (`task dc:stop`), the build lock across repositories | sessions, tests, builds, git, `gh`, Claude Code, signing |
| one-shot commands only: no background process of ours (ADR 0024, ADR 0026) | start hooks (`ssh-agent-setup`, `cloud-folder-setup`) that never wait and exit 0 |

## Best practices

- **Start through the tasks, not by reopening the folder in VS Code.** The launcher sets `DCF_HOST_*`, adds the
  mounts and waits for the engine; VS Code skips it and every `${localEnv:DCF_HOST_*}` is empty. Run
  `task dc:host` first: it prints the host type, the engine, the variables and the mounts without starting
  anything.
- **Let the launcher mount `.git-dirs`.** One identical folder at `/git-dirs` for every repository (ADR 0020);
  delete a hand-written per-repository mount and `GIT_DIR`/`GIT_WORK_TREE`. Keep the line only if you also open
  the folder straight in VS Code, and then spell it `${localEnv:USERPROFILE}`.
- **Map `DCF_HOST_*` in `containerEnv`** exactly as the bootstrap's template does; the Features are host-blind
  and read only those variables.
- **Keep the settings of a machine in `.devcontainer/.env`**, not in `devcontainer.json`: the host type
  priority, the FUSE grant, the cloud folder path, the SSH agent mode differ per machine.
- **Pin what must match CI.** `version` on the CLI Features, and `task devcontainer:lock` after a change, with the
  lock file committed.
- **After a rebuild, list what the new container lost before working**: the `gh` login, the `claude` login, an
  unlocked key, the rclone sign-in. Ledger entry 2026-10-31 "gh login restored on fresh container; git HTTPS
  credentials set" is the case: the push failed until `gh auth setup-git` ran.
- **Put `task cloud-folder:status` in the start-up check and `cloud-folder-setup shutdown-check` in `shutdown:check`**,
  so a stop waits for a sync and a missing folder is not written into.
- **Use a dedicated signing key** per purpose and container, registered at GitHub as a signing key only. Never
  import a login key into key mode.
- **Apply the tiers to every new store**: say which tier it is in, and if it cannot be rebuilt, move it up.
- **Stop with `task dc:stop`**, which runs the shutdown check (unpushed commits, running syncs) before the container
  stops.

## Anti-patterns

### W1. A wait in a start hook

- **Don't:** run `ssh-add`, read a prompt, or leave a wait without a timeout or a non-zero exit in any Feature's
  start hook.
- **Why:** 2026-10-30 "Start hook no longer waits on ssh-add; passphrase prompt gets a bounded wait and a warning":
  the hook prompted on `/dev/tty`, the devcontainer CLI waits for every start hook together, so the start hung
  about 775 s until WSL's exec connection dropped, and the error named another Feature. 2026-10-30 "cloud-folder
  1.3.1 makes the post-start run never fatal": an unbounded mount wait and a closed pipe (exit 141) did the same.
- **Instead:** bound every wait (`DCF_CLOUD_FOLDER_START_BUDGET`, `passphraseTimeout`), always exit 0 from a start
  hook, print one warning that names the task to run.
- **Caught by:** `test:ssh-agent-unit` (a pty case) and `test:cloud-folder-unit` for those two Features; nothing
  yet for another Feature's hook or for your own (a lint that scans hooks for an unbounded `read`, `ssh-add` or
  `sleep`).

### W2. `GIT_DIR` and `GIT_WORK_TREE` in `containerEnv`

- **Don't:** point every process at the main checkout's git dir with two environment variables, and bind-mount one
  git dir per repository.
- **Why:** 2026-10-16 "Diagnose git config corruption from wrapper bypass": a test ran the real git in a scratch
  folder with the two variables set, which wrote `core.worktree` and `core.filemode` into the git dir shared with
  Windows and broke the host checkout. ADR 0020 closes the gap: one mount, mapped per call.
- **Instead:** the launcher's `/git-dirs` mount and the `git` Feature's wrapper, which scopes the mapping to the main
  checkout and drops it in worktrees and nested repositories.
- **Caught by:** the wrapper itself, and `test:git-unit`, which compares the git dir's `config` byte for byte before
  and after `git-setup` and a run of wrapper calls.

### W3. A store on the shared folder you have not probed

- **Don't:** put a database, a register or anything that needs hard links, in-place writes or rename guarantees on
  `/mnt/cloud-folder`, in `mount` mode in particular.
- **Why:** 2026-11-03 "Ledger and register storage location answered; shared-folder mirror blocked by hard links":
  the design assumed a mirror that rclone FUSE cannot take. The architecture review of 2026-10-31 had flagged
  read-only modes and conflict names.
- **Instead:** the folder holds documents and copies written once under a new name; a live store stays in a volume
  and is backed up to the folder. Before choosing a store run `ln`, `mv` and `chmod` on the target, and use `sync`
  mode where `mount` is wrong.
- **Caught by:** nothing yet (backlog item `register-store-no-hardlink`).

### W4. Two rclone versions, or a sign-in port left open

- **Don't:** install a different rclone on the workstation than the one the Feature pins, or leave the sign-in
  callback port open.
- **Why:** 2026-10-29 "Question answered: personal OneDrive mount for this repository": the pasted token was
  rejected because the versions differed. 2026-10-29 "Question answered: can the rclone callback port be dynamic":
  the app registration allows only `localhost:53682`.
- **Instead:** `task cloud-folder:login` from the workstation: the launcher relays the browser into the container,
  opens `53682` only while signing in, and uses the Feature's pinned, verified rclone.
- **Caught by:** `test:cloud-folder-login` (the default pin equals the Feature's; the listener closes after
  success, failure and timeout).

### W5. A launcher variable the repository does not pass on

- **Don't:** use a Feature that reads `DCF_HOST_*` without the `containerEnv` line that maps it.
- **Why:** 2026-10-30 "devcontainer-cli 1.16.2 launcher passes DCF_HOST_MACHINE": the machine name reaches the
  container only through one `containerEnv` line (the `agents` Feature shows the word `container` for `{machine}`
  when it is unset); 2026-10-29 "cloud-folder:login built as one command" needed a root Taskfile include as well.
- **Instead:** copy the bootstrap's template lines and re-run the bootstrap after a launcher change; the launcher
  prints the exact line when one is missing.
- **Caught by:** the launcher hint tests in `test:bootstrap`; the changelog's "must you act" line of each Feature
  (ADR 0047) is the long-term home.

### W6. Reading an engine failure as a repository failure

- **Don't:** run `devcontainer up` by hand, or take "Command failed: docker ps" for a fault in the repository or the
  last release.
- **Why:** 2026-11-02 "Docker ps failures in two stacks traced to the engine, not a race" and 2026-11-03 "Docker
  Desktop build error explained: mount path fault, not the repository": a 12-minute build succeeded and the engine's
  backend failed at container create.
- **Instead:** `task dc:up`, which waits (bounded) for the engine, prints the engine's own error and how to start it;
  restart the engine, then retry.
- **Caught by:** `test:engine-wait` (wall-clock based, flaky: `flaky-test-sweep`); nothing yet for naming Docker
  Desktop's backend (`launcher-docker-backend-message`).

### W7. Two builds at once on `wslc`, or the build lock turned off

- **Don't:** set `DEVCONTAINER_BUILD_LOCK=0`, or build two repositories at once on an engine without BuildKit build
  contexts.
- **Why:** issue #154 "devcontainer-cli launcher: the build lock names no holder and queues in no order": an `up`
  waited behind unrelated no-cache builds with no clue why. The lock exists because, without BuildKit build contexts
  (`wslc`), every repository's build tags the same temporary image, so two at once overwrite each other and the first
  fails with `"/tmp/build-features/..." not found`. 2026-11-03 "Build lock names its holder and is skipped with
  BuildKit build contexts (#154)".
- **Instead:** leave the lock on; it names who holds it and is skipped where `buildx` is 0.8.0 or later.
- **Caught by:** `test:build-lock`.

### W8. A wrapper around `claude` that adds `--add-dir`

- **Don't:** replace `/usr/local/bin/claude` with a script that puts `--add-dir <folder>` before the arguments.
- **Why:** 2026-10-28 "Claude Code agents --json failure traced to the office claude wrapper": the variadic
  `--add-dir` swallowed the subcommand, `claude agents --json` failed, and the failure looked like a Claude Code bug.
- **Instead:** the `claude-code` option `additionalDirectories`, written to a managed-settings drop-in.
- **Caught by:** `test:claude-unit` guards the option; nothing yet stops a consumer's own wrapper.

### W9. A timed unlock that the next start undoes

- **Don't:** unlock a key that has no passphrase with a lifetime and expect the lifetime to hold across a start.
- **Why:** 2026-11-03 "ssh-agent 1.3.0 adds timed key unlock and key lock": the start hook loads an unprotected key
  again, without a limit, at the next container start.
- **Instead:** use `key:unlock MINUTES=` for a passphrase-protected key (the start hook skips those); say so in the
  notes.
- **Caught by:** the NOTES only; the start-hook reload item is open.

### W10. A login key in key mode

- **Don't:** import a key that also opens GitHub, servers or other repositories into the container's key volume.
- **Why:** key mode breaks "the private key never enters the container" for whoever opts in; ADR 0046 and ADR 0048
  both keep the operator's own key off it.
- **Instead:** a dedicated signing key per purpose and container (`task ssh-agent:key:new`), registered as a
  signing key only, rotated with `key:rotate`.
- **Caught by:** `devcontainer:ssh-key-import` warns, never blocks, on a default key name or a public key that also
  opens the host (`test:ssh-key-import`).
