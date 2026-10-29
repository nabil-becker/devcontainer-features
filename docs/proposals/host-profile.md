# Proposal: the host is a host type, described by DCF_HOST_* variables

Status: decided 2026-10-23 by the Operator (the build is not started). Reasoning: [ADR 0024](../adr/0024-the-host-is-an-adapter-owned-by-devcontainer-cli.md). Backlog: `host-platform-adapters`, `host-profile-contract`.

## 1. Decided (2026-10-23)

1. **The host is a pluggable side**: the host type is the only thing that differs between workstations. Only the devcontainer-cli Feature and its bootstrap (the launcher, run on the host) know about the host; every other Feature is host-blind and adapts inside the container.
2. **`HOST_TYPE`** is the one host choice, with five ids: `windows-docker` (a docker engine reached from Windows: Docker Desktop or any docker.exe), `windows-wsl-docker` (Docker Engine in a WSL distro), `windows-wslc`, `linux`, `macos`. It defaults to `auto`; an explicit `HOST_TYPE=<id>` skips detection. `HOST_TYPE_PRIORITY` is an ordered, comma-separated list (an organisation sets its own, for example in `.devcontainer/.env`); `auto` takes the first type in it whose detection passes.
3. **No process of ours runs in the background on the host.** Processes inside the devcontainer are fine.
4. **No profile file.** The launcher sets the standard `DCF_HOST_*` variables in its own environment before it runs the devcontainer CLI; how they reach the container is the repository's decision, and the bootstrap's `devcontainer.json` template maps them with `containerEnv` (`${localEnv}` is substituted in a repository's own `devcontainer.json`, unlike in a Feature's, ADR 0020). Host-specific **mounts** come from the launcher's `devcontainer up --mount`, so repositories declare none.
5. **The bootstrap** lives in `.devcontainer/cli_bootstrap.ignore/` (repo-relative only; was `./bootstrap/`). `BOOTSTRAP_DIR` overrides it. It is git-ignored: the bootstrap creates `.devcontainer/.gitignore` or appends `cli_bootstrap.ignore/`; `BOOTSTRAP_GITIGNORE=false` skips that. A fresh clone lacks it, so the root Taskfile include becomes `optional: true` and the first step on a new machine is the bootstrap one-liner.
6. **Existing consumers migrate when they decide.** Our commitment: the old form (`./bootstrap`, the per-repo git-dirs mount line) keeps working, and a migration note ships (re-run the bootstrap, remove `./bootstrap`, repoint the include; the bootstrap may repoint it when it finds the old one).
7. **The opt-in signing-only key is offered**, documented as temporary until a Windows answer without a host process exists, and as breaking "the key never enters the container" for whoever opts in.

Checked with `devcontainer up --help` (CLI 0.89): `--mount` (type=<bind|volume>,source=..,target=..) exists; `--remote-env` exists but only applies "when executing the user commands", not to the container's environment. That is why the variables go through `containerEnv`.

## 2. The picture

```
 HOST                                         DEVCONTAINER
 ----                                         ------------
 task devcontainer:up
   |
   v
 launcher (bootstrap + devcontainer-cli)
   1 HOST_TYPE=auto -> first type in HOST_TYPE_PRIORITY that passes
   2 export DCF_HOST_TYPE, DCF_HOST_HOME, DCF_HOST_SSH_AGENT
   3 devcontainer up --mount .git-dirs --mount ssh socket
          |                         |
          | ${localEnv:DCF_HOST_*}  | mounts
          v                         v
   repo devcontainer.json       /git-dirs, /ssh-agent.sock
     containerEnv: DCF_HOST_*          |
          +-------------+--------------+
                        v
        git, gh, claude-code, ssh-agent ...
        read DCF_HOST_*; unset = sensible default
   4 launcher exits (nothing left running)
```

## 3. Per HOST_TYPE

| HOST_TYPE | Detected by (checkable in the scripts) | Engine command | `DCF_HOST_HOME` | Can mount |
|---|---|---|---|---|
| `windows-docker` | `$IsWindows`; `docker` on PATH answers `docker info` | `docker` | `%USERPROFILE%` | Windows folders; no named pipe |
| `windows-wsl-docker` | `$IsWindows` and `wsl -e docker info` answers; or the CLI runs inside the distro (`WSL_DISTRO_NAME` set, `/proc/version` names Microsoft) | `docker` in the distro | the distro's `$HOME` (Windows folders only via `/mnt/c`) | distro paths, `/mnt/c` |
| `windows-wslc` | `$IsWindows`; `wslc.exe` on PATH or `C:\Program Files\WSL\wslc.exe` (as `Resolve-DockerPath` does) | `wslc` | `%USERPROFILE%` | Windows folders |
| `linux` | `uname -s` Linux, not WSL | `docker` (or podman, nerdctl) | `$HOME` | local paths, `$SSH_AUTH_SOCK` |
| `macos` | `uname -s` Darwin | `docker` | `$HOME` | folders shared with Docker Desktop, its ssh socket |

Default `HOST_TYPE_PRIORITY`, per OS the launcher runs on:

| Launcher runs on | Default priority |
|---|---|
| Windows | `windows-docker,windows-wsl-docker,windows-wslc` |
| inside a WSL distro | `windows-wsl-docker` |
| Linux | `linux` |
| macOS | `macos` |

An organisation that wants Docker in WSL first on Windows writes `HOST_TYPE_PRIORITY=windows-wsl-docker,windows-docker,windows-wslc`. `DEVCONTAINER_DOCKER_PATH` stays as the override of the engine command (podman, a full path). `DCF_HOST_HOME` fixes `git-dirs-posix-line`: no repository writes `${localEnv:USERPROFILE}` or `${localEnv:HOME}` any more.

## 4. What the launcher takes over

| Today | In the new shape |
|---|---|
| Engine path (`DEVCONTAINER_DOCKER_PATH`), host-side | derived from `HOST_TYPE`, override kept |
| `devcontainer:homes`, host-side | the launcher creates the folders before `up`; the task stays for VS Code |
| `.git-dirs` mount (ADR 0020), in each repo | `--mount source=$DCF_HOST_HOME/.git-dirs,target=/git-dirs`; the old line keeps working |
| Build lock (README), host-side, held only while `up` runs | unchanged; a lock held by a running task is not a background process |
| Stop check (ADR 0022), resolved in the container | unchanged |

## 5. SSH agent under "no background process"

A relay from a Windows named pipe to a socket needs a process that outlives the task, so it is ruled out. `DCF_HOST_SSH_AGENT` is `socket`, `none` or `key`.

| HOST_TYPE | Agent | How |
|---|---|---|
| `linux` | `socket` | launcher mounts `$SSH_AUTH_SOCK` |
| `macos` | `socket` | Docker Desktop's `/run/host-services/ssh-auth.sock` |
| `windows-wsl-docker` | `socket` if the distro's own ssh-agent holds the key (the user's agent, not ours), else `none` | mount that socket |
| `windows-docker`, `windows-wslc` | `none` | the Windows agent is a named pipe |

For `none`, `ssh-agent:check` says why and names two ways around: a VS Code terminal (its agent forwarding is VS Code's own), or the opt-in signing-only key in a container volume (`DCF_HOST_SSH_AGENT=key`). The key option is temporary, until a Windows answer without a host process exists, and for those who opt in it breaks "the key never enters the container".

## 6. The VS Code gap

Opening the repository directly in VS Code bypasses the launcher: `DCF_HOST_*` expand to empty strings and the `--mount` lines are missing. Options:

| Option | Verdict |
|---|---|
| A. Document "start through the tasks"; Features treat unset `DCF_HOST_*` as "unknown host" and say so | recommended |
| B. The launcher also writes a gitignored fallback include | fragile, `${localEnv}` differs by OS |
| C. A VS Code `initializeCommand` running the launcher's detection | cannot add mounts: partial |

Recommendation A: with `DCF_HOST_TYPE` unset or `.git-dirs` not mounted, `git:setup` and `ssh-agent:check` print one line (`host unknown: start through task devcontainer:up`) and carry on with defaults, so a bypass is loud, never fatal.

## 7. Slices

| Slice | Content | CI without the host | Manual per HOST_TYPE |
|---|---|---|---|
| 1 | `HOST_TYPE`, `HOST_TYPE_PRIORITY`, detection, `DCF_HOST_*`, engine and home; template `containerEnv` | detection as a pure function over faked evidence (env, `uname`, stub `wslc.exe`); priority order; PowerShell and bash twins agree | one `up` per type; `DCF_HOST_*` visible in the container |
| 2 | Bootstrap move, `BOOTSTRAP_DIR`, `BOOTSTRAP_GITIGNORE`, `optional: true`, migration note | bootstrap against a temp repo: creates, appends once, skips with the flag; the old form still works | fresh clone, one-liner, first `up` |
| 3 | `.git-dirs` through `--mount` | the argument list the launcher builds | a worktree and a commit per type |
| 4 | ssh-agent Feature, `ssh-agent:check`, opt-in key | check messages per `DCF_HOST_*`; Feature test with a faked socket | a real agent on `linux`, `macos`, `windows-wsl-docker`; the `none` messages elsewhere |

## 8. Still open (unverified facts, not decisions)

1. Whether a WSL distro's agent socket can be bind-mounted when the CLI runs from Windows rather than from inside the distro.
2. Whether Docker Desktop on Windows can expose `/run/host-services/ssh-auth.sock` (reported on macOS only).
3. The `docker context` evidence that tells Docker Desktop from another docker.exe; `windows-docker` does not need it, but the check message might.
