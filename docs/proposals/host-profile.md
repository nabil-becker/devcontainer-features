# Proposal: the host is an adapter, described by a host profile

Status: proposed 2026-10-23, for the Operator's review. The five decisions in section 1 were taken by the Operator on 2026-10-23; everything after them is a recommendation. Reasoning for the decision itself: [ADR 0024](../adr/0024-the-host-is-an-adapter-owned-by-devcontainer-cli.md). Backlog: `host-platform-adapters`, `host-profile-contract`.

## 1. Decided (2026-10-23)

1. **The host is a pluggable side**, like a backend, source or sink. Only the devcontainer-cli Feature and its bootstrap (the launcher, run on the host) know about the host; every other Feature is host-blind and adapts inside the container.
2. **`HOST_TYPE`** replaces "which docker path" as the one host choice: `windows-docker-desktop`, `windows-wsl-docker` (Docker Engine in a WSL distro; the devcontainer CLI runs wherever works), `windows-wslc`, `linux`, `macos`. The launcher detects it; it can be overridden.
3. **No process of ours runs in the background on the host.** Nothing on Windows or in a WSL distro outlives a task. Processes inside the devcontainer are fine.
4. **The launcher passes host-specific mounts** with `devcontainer up --mount type=bind,source=..,target=..`, so consuming repos declare none. It also mounts a small **host profile file** at a fixed path that Features read.
5. **The bootstrap lives in `.devcontainer/cli_bootstrap.ignore/`** by default (was `./bootstrap/`), overridable (`BOOTSTRAP_DIR`), and git-ignored: the bootstrap creates `.devcontainer/.gitignore` or appends `cli_bootstrap.ignore/` to it.

Checked with `devcontainer up --help` (CLI 0.89): `--mount` ("type=<bind|volume>,source=..,target=..") exists; `--remote-env` exists but "will be added when executing the user commands", so it reaches `exec` and lifecycle commands, not the container's own environment. The profile therefore travels as a mounted file, not as env.

## 2. The picture

```
 HOST (workstation)                          DEVCONTAINER
 ------------------                          ------------
 task devcontainer:up
   |
   v
 launcher (bootstrap + devcontainer-cli)     /var/lib/devcontainer-features/host/profile.env
   1 detect HOST_TYPE  (or take override)       HOST_TYPE=windows-wsl-docker
   2 pick engine command, host home             HOST_HOME_DIR=...   SSH_AGENT=sock|none
   3 write profile.env (host temp file)               ^
   4 devcontainer up                                  | read by
        --mount .git-dirs -> /git-dirs               |
        --mount profile.env -> .../profile.env   git, gh, claude-code, ssh-agent ...
        --mount ssh socket  -> /ssh-agent.sock       (host-blind: they read the
   5 exit (no daemon left behind)                     profile, never probe the host)
```

## 3. Per HOST_TYPE

Detection is the launcher's, in this order; `HOST_TYPE` in `.devcontainer/.env` or on the command line wins. Evidence column: what the scripts can check today.

| HOST_TYPE | Detected by | Engine command | Host home | Can mount |
|---|---|---|---|---|
| `windows-docker-desktop` | `$IsWindows`; `docker` on PATH and its context is Docker Desktop's (`docker context show`; to confirm) | `docker` | `%USERPROFILE%` | any Windows folder (Docker Desktop shares drives); no Windows named pipe |
| `windows-wsl-docker` | `$IsWindows`; no Docker Desktop context, a WSL distro answers `docker info` (`wsl -e docker info`); or the CLI runs inside the distro (`/proc/version` names Microsoft, `WSL_DISTRO_NAME` set) | `docker` (in the distro) | the distro's `$HOME` for distro paths; `%USERPROFILE%` only through `/mnt/c` | distro paths; Windows paths through `/mnt/c` |
| `windows-wslc` | `$IsWindows`; `wslc.exe` on PATH or `C:\Program Files\WSL\wslc.exe` (as `Resolve-DockerPath` already does) and no `docker` | `wslc` | `%USERPROFILE%` | Windows folders |
| `linux` | `uname -s` is Linux and not WSL | `docker` (or podman, nerdctl) | `$HOME` | any local path, `$SSH_AUTH_SOCK` |
| `macos` | `uname -s` is Darwin | `docker` | `$HOME` | folders shared with Docker Desktop, its ssh socket |

`DEVCONTAINER_DOCKER_PATH` stays as the override of the engine command (podman, a full path); `HOST_TYPE` supplies the default. This fixes `git-dirs-posix-line`: the host home is the launcher's fact (`USERPROFILE` on Windows, `HOME` elsewhere), so no repo writes `${localEnv:USERPROFILE}` or `${localEnv:HOME}` any more.

## 4. What moves into the profile

| Today | Where it lives | In the new shape |
|---|---|---|
| Engine path (`DEVCONTAINER_DOCKER_PATH`) | host-side: `Resolve-DockerPath`, the bash twin | derived from `HOST_TYPE`, override kept; written to the profile only as information |
| `devcontainer:homes` (`~/.devcontainer-homes`) | host-side task, run as `initializeCommand` | the launcher creates the folders itself before `up`; the task stays for VS Code (section 5) |
| `.git-dirs` mount (ADR 0020) | repo's `devcontainer.json` | the launcher adds `--mount source=<host home>/.git-dirs,target=/git-dirs`; repos drop the line; the git wrapper is unchanged |
| Build lock (README, "Builds are serialised host-wide") | host-side: named mutex / flock, held only while `up` runs | unchanged: a lock held by a running task is not a background process |
| Stop check (ADR 0022) | resolved inside the container, run by the host task | unchanged; it is the model of the contract: the host runs, the container decides |

All five are already host-side. The new part is only the profile file and the mounts the launcher adds.

## 5. SSH agent under "no background process"

A relay from a Windows named pipe to a socket needs a process that outlives the task, so it is ruled out. The ssh-agent Feature (slice 4) then offers only what the host already provides:

| HOST_TYPE | Agent in the container | How |
|---|---|---|
| `linux` | yes | launcher mounts `$SSH_AUTH_SOCK` |
| `macos` | yes | Docker Desktop's `/run/host-services/ssh-auth.sock` |
| `windows-wsl-docker` | yes, if the distro's own ssh-agent holds the key | mount the distro's agent socket (the user's agent, not ours) |
| `windows-docker-desktop` | no | the Windows agent is a named pipe |
| `windows-wslc` | no | same |

For the two "no" rows `ssh-agent:check` says why and names two ways around: (a) use a VS Code terminal, whose agent forwarding is VS Code's own; (b) an opt-in signing-only key in a container volume. (b) breaks "the key never enters the container", so it is opt-in and never the default.

Open, not verified: whether a WSL distro socket can be bind-mounted when the CLI runs from Windows (versus from inside the distro); whether Docker Desktop on Windows with the WSL 2 backend exposes `/run/host-services/ssh-auth.sock` to a Windows named pipe agent (reported to work on macOS only).

## 6. The VS Code gap

Opening the repo directly in VS Code (Reopen in Container) bypasses the launcher, so the `--mount` lines and the profile are missing: `.git-dirs` is absent and Features see no profile.

| Option | Cost | Verdict |
|---|---|---|
| A. Document "start through the tasks" | none; VS Code users lose the mounts silently | needs a guard |
| B. The launcher also writes a `devcontainer.json`-side fallback (the same mounts, gitignored include) | a generated file per repo, per host | fragile: `${localEnv}` differs by OS |
| C. A VS Code `initializeCommand` that runs the launcher's profile step | the profile exists, but `initializeCommand` cannot add mounts | partial |

Recommendation: A, plus a check. Features that need the profile say `host profile missing: start through task devcontainer:up` (one line, in `git:setup` and `ssh-agent:check`), so a bypass is loud, not silent. B and C wait for a consumer that needs VS Code to be first-class.

## 7. Slices

| Slice | Content | CI can test without the host | Manual per HOST_TYPE |
|---|---|---|---|
| 1 | `HOST_TYPE` detection, profile file, engine and home derived | detection as a pure function over faked evidence (env, `uname`, stub `wslc.exe`); profile format; PowerShell and bash twins agree | one `up` per type; the profile is readable in the container |
| 2 | Bootstrap moves to `.devcontainer/cli_bootstrap.ignore/`; `.gitignore` handling; Taskfile include `optional: true`; migration of old `./bootstrap` | bootstrap run against a temp repo: creates, appends once, repoints the old include | fresh clone, bootstrap one-liner, first `up` |
| 3 | `.git-dirs` through `--mount`; repos drop the line | the launcher's command line (the arguments it builds) | a worktree and a commit on each type |
| 4 | The ssh-agent Feature and `ssh-agent:check` | the check's messages per profile; Feature test with a faked socket | a real agent on `linux`, `macos`, `windows-wsl-docker`; the "no" messages on the others |

## 8. Open questions for the Operator

1. **Detection order on Windows** when both Docker Desktop and a WSL Docker are present: Docker Desktop first (it is on PATH), unless `HOST_TYPE` says otherwise?
2. **`windows-wsl-docker`: where the CLI runs.** From Windows (paths translated) or inside the distro? Both can work; which does the launcher assume by default?
3. **Existing consumers' timing.** The office and DSNP carry `./bootstrap` and a git-dirs mount line. Migrate both together at slice 2, or leave the old form working until slice 3 ships?
4. **Opt-in signing key** (section 5b): offer it at all, given it breaks the key never entering the container?
5. **Profile contents.** Only `HOST_TYPE` and a few facts (host home, ssh agent kind), or also the engine command? Fewer facts keep Features host-blind.
6. **`BOOTSTRAP_DIR` override**: is a repo-relative path enough, or must it allow a folder outside the checkout?
