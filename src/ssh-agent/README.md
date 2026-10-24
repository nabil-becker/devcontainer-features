
# SSH agent (ssh-agent)

Makes an SSH agent available to every process in the devcontainer (SSH_AUTH_SOCK=/var/lib/devcontainer-features/ssh-agent/agent.sock, also for `devcontainer exec`) so git commits can be signed with an SSH key: the devcontainer-cli launcher bind-mounts the host's agent socket onto that path where the host type has one (linux, macos, a WSL distro), the private key never entering the container; a post-start hook (ssh-agent-setup) checks it on every start and says plainly what a host type without one can do; the opt-in keyMode starts an agent inside the container and loads keys from its own volume instead, which breaks the no-key rule for whoever turns it on. Plus the Feature Taskfile (check, keys, key tasks, git:signing, git:verify).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| keyMode | Opt-in, temporary: when no host agent socket is forwarded, start an ssh-agent inside the container on the fixed socket and load the private keys found in the ssh-agent-key volume. This puts a private key in the container, which breaks the default rule that the key never enters it; use it only where the host type cannot forward its agent (windows-docker, windows-wslc). Override per container with SSH_AGENT_SETUP_KEY_MODE in containerEnv, or per start with SSH_AGENT_MODE=key on the launcher. | boolean | false |

## What it gives you

Every process in the container, `devcontainer exec` and `claude` sessions included, sees
`SSH_AUTH_SOCK=/var/lib/devcontainer-features/ssh-agent/agent.sock` (`containerEnv`, a fixed
path). Behind that path is an SSH agent, so `git commit -S` and `ssh` can sign and
authenticate without a private key in the container. Opening the repository in a VS Code
terminal works without this Feature (VS Code forwards the agent itself); the gap it closes is
the sessions that do not go through VS Code (`devcontainer exec`, `task devcontainer:claude`).

It installs no binary of its own: `ssh-add`, `ssh-keygen` and `ssh-agent` come from the base
image, or, when one is missing, from the distribution's `openssh-client` package through apt
(there is no other download, so there is nothing to checksum). It adds `ssh-agent-setup` (the
`postStartCommand`, also behind `task ssh-agent:setup`), `dcf-persist` and the Feature Taskfile.

## Which host gets what

The Feature is host-blind; the launcher (the `devcontainer-cli` Feature and its bootstrap)
bind-mounts the host's agent socket onto the fixed path when the host type has one, and passes
`DCF_HOST_SSH_AGENT` (`socket`, `none` or `key`) and `DCF_HOST_TYPE` through the repository's
`containerEnv`. `ssh-agent-setup` reads them on every start and says what it found.

| `DCF_HOST_TYPE` | Agent | What is mounted |
| --- | --- | --- |
| `linux` | `socket` | the launcher's `$SSH_AUTH_SOCK`, when set and a socket |
| `macos` | `socket` | Docker Desktop's `/run/host-services/ssh-auth.sock` |
| `windows-wsl-docker` | `socket` when the launcher runs inside the distro and the distro's own agent has a socket; `none` when it runs from Windows | the distro's `$SSH_AUTH_SOCK` |
| `windows-docker`, `windows-wslc` | `none` | nothing |

Why the Windows engines get none: the Windows OpenSSH agent listens on a named pipe, not a unix
socket, and a container cannot mount a pipe. Bridging it needs a relay process that outlives
the command that started the container, and this collection decided that no process of ours
runs in the background on the host. So on those host types, and in a distro the launcher is not
inside, `ssh-agent-setup` says so plainly (naming the host type) and offers the two ways round:
a VS Code terminal (VS Code's own forwarding), or the opt-in key mode below. A start that did
not go through the launcher (`DCF_HOST_SSH_AGENT` empty) reports `host unknown: start through
task devcontainer:up` and probes the fixed path anyway.

`SSH_AGENT_MODE=key` on the launcher (`task devcontainer:up SSH_AGENT_MODE=key`, or in
`.devcontainer/.env`) sets `DCF_HOST_SSH_AGENT=key` and suppresses the socket mount.

## The layout, and why there is no volume on the socket's folder

- `/var/lib/devcontainer-features/ssh-agent/` is a plain folder in the image (mode 1777), **not
  a volume**: the launcher bind-mounts a socket file onto `agent.sock` in it, and a volume over
  the folder would hide the mount. In key mode the in-container agent binds the same path.
- `/var/lib/devcontainer-features/ssh-agent-key/` is a named volume
  (`ssh-agent-key-${devcontainerId}`), the only state: keys you put there for the key mode. It
  is a sibling folder rather than `/var/lib/devcontainer-features/ssh-agent`, which NFR-1 would
  suggest, for exactly that reason.

## Options

- `installTaskfile` (default `true`): install the Taskfile into the go-task registry.
- `keyMode` (default `false`): the opt-in, temporary key mode below. It applies when no host agent
  socket is mounted (`none` or unknown); a mounted socket wins and the hook says so. Override
  without a rebuild with `SSH_AGENT_SETUP_KEY_MODE=true|false` in `containerEnv`, or per start
  with `SSH_AGENT_MODE=key` on the launcher.

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1": {}
}
```

On `windows-docker` or `windows-wslc`, add `"keyMode": true` only if you accept the trade-off
below.

## Loading keys

- **Socket mode** (linux, macos, windows-wsl-docker): the agent is the host's, so load keys on
  the host with the host's `ssh-add`. `task devcontainer:ssh-add -- ~/.ssh/id_ed25519` runs it
  (no arguments lists with `-l`); it is a one-shot command that exits. Inside the container
  `task ssh-agent:keys` shows what the agent holds.
- **Key mode** (opt-in): from the host, `task devcontainer:ssh-key-import FILE=<private key on the
  host>` streams the key into the running container through `devcontainer exec` on stdin (never
  as an argument, never into a log or process list) into the key volume with mode 0600, its `.pub`
  beside it when there is one, and loads it. It refuses when the container is not running, when
  key mode is off there, or when FILE is missing, and prints the fingerprint, never the key.
  Inside the container the same job is `task ssh-agent:key:add FILE=<path>`, or
  `task ssh-agent:key:new` to generate a dedicated ed25519 signing key (no passphrase prompt only
  with `EMPTY_PASSPHRASE=1`; the public key is printed so you can add it to GitHub as a signing
  key; the private key is never printed). `task ssh-agent:key:load` (re)loads every key of the
  volume, which is also what the start hook does; a key readable by group or others is refused
  with a message.

## The opt-in key mode, temporary

Key mode starts an `ssh-agent` inside the container on the fixed path (a live one is reused, a
stale socket removed) and loads the private keys it finds in the key volume. It exists because
the Windows engines have no other answer yet. **It breaks the rule this Feature otherwise keeps:
the private key enters the container, for whoever opts in.** Use a dedicated signing key, not your
login key; it is offered as temporary, until a Windows answer that needs no host process exists.
The agent lives only as long as the container runs, and the hook restarts it and reloads the keys at
every start. Remove a key with `task ssh-agent:key:remove NAME=<file> DELETE=1`.

## Signing git commits

`task ssh-agent:git:signing` sets `gpg.format ssh`, `user.signingkey key::<public key>`,
`commit.gpgsign true` and `tag.gpgsign true`, taking the public key from `ssh-add -L`, so it works
with a host agent too (the private key is never needed). With exactly one key in the agent it
uses that; with several, pass `KEY=<fingerprint or path of a .pub file>`. By hand:

```sh
git config --global gpg.format ssh
git config --global user.signingkey "key::$(ssh-add -L | head -n 1 | cut -d' ' -f1,2)"
git config --global commit.gpgsign true
```

`SCOPE=global` writes the container's own git config (`GIT_CONFIG_GLOBAL`, the `git` Feature's
volume); `SCOPE=repo` writes the current repository's config, which in this collection can be
**shared with the Windows host**, because a checkout's git dir may live under `.git-dirs` and be
mounted into every container. The default is therefore `global` when the `git` Feature's volume is
present (`GIT_CONFIG_GLOBAL` under `/var/lib/devcontainer-features/`), else `repo`, and the task
says which it used. `task ssh-agent:git:verify` signs a throwaway message through the agent with
`ssh-keygen -Y sign` and verifies it against a temporary `allowed_signers` file, printing `ok` or
why not, without committing. To check signatures with `git log --show-signature`, also set
`gpg.ssh.allowedSignersFile`; adding the public key to GitHub as a signing key marks the commits
verified there.

## Security notes

- **Socket mode:** the private key never enters the container. While the host agent runs, any
  process in the container can ask it to sign (and to authenticate over SSH) with any key it holds,
  just as any process on the host can: do not forward an agent that holds keys you would not let
  the container's tools use, and prefer keys the agent confirms (`ssh-add -c`).
- **Key mode:** the key is in the container's volume, readable by the remote user, and the agent
  signs for any process in the container. See above; use a dedicated signing key.
- Nothing here prints key material, and nothing generates a key unless you run `key:new`.

## Check it works

```sh
task ssh-agent:check     # ssh-agent: the host's agent reachable at <socket>, 1 key(s) loaded
task ssh-agent:keys      # fingerprints and comments
task ssh-agent:git:verify
```

`check` prints one of: an agent reachable with N keys, reachable with no keys, or not reachable
and why (from `DCF_HOST_TYPE` and `DCF_HOST_SSH_AGENT`); it exits 1 when none answers. If this
shell carries another forwarded agent (VS Code's `SSH_AUTH_SOCK`), the Feature stands down: it
manages only the fixed path and says so.

## Pairs with

`devcontainer-cli` (the launcher that mounts the socket and sets `DCF_HOST_*`; its bootstrap's
`devcontainer.json` template maps them with `containerEnv`), `git` (signing config; its volume is the
default `SCOPE=global` target) and `go-task` (for the tasks). It needs nothing else; `installsAfter`
orders it behind `go-task` and `common-utils`.

## Tasks

`task ssh-agent:version`, `check`, `setup`, `keys`, `key:load`, `key:add`, `key:new`, `key:remove`,
`git:signing`, `git:verify` (all in `ssh-agent`; the host side has `devcontainer:ssh-add` and
`devcontainer:ssh-key-import`).

## Limits and troubleshooting

- **A socket is mounted at `up`.** Start the host agent (and add a key) before `task
  devcontainer:up`, or restart the container afterwards: a socket that did not exist then is not
  mounted. `check` says "not reachable" with that hint.
- **Opened straight in VS Code** (no launcher): no mount and `DCF_HOST_SSH_AGENT` is empty; use VS
  Code's own forwarding in its terminals, or start through the tasks.
- `windows-wsl-docker` driven from Windows, and Docker Desktop's socket on Windows, are not
  forwarded (unverified, see `host-profile-unverified-checks` in the repository's backlog).
- A passphrase-protected key cannot be loaded by the start hook (no terminal); run
  `task ssh-agent:setup` from a terminal.
- The key volume is a named volume: a container-engine storage reset deletes it (the key is on your
  host anyway; re-import it).

## Why it exists

VS Code forwards the host agent only into its own terminals, and the devcontainer CLI does not
forward it at all, so signing from `devcontainer exec` or a `claude` session failed. No Feature of
this collection or of `devcontainers/features` forwards the agent for the CLI; this one does it with
the launcher's mount instead of a process on the host, and is honest where a host type cannot.

## Version and upgrade

`1.0.0`: the first release. The container side is `ssh-agent-setup`; the host side lives in
`devcontainer-cli` 1.8.0 or later (the socket mount, `SSH_AGENT_MODE`, `devcontainer:ssh-add`,
`devcontainer:ssh-key-import`). Pin the Feature with `:1`; an upgrade changes nothing in the key
volume, and a rebuild re-runs the hook.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/ssh-agent/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
