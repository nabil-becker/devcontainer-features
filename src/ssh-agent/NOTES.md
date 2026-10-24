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
  key; the private key is never printed; NAME defaults to `<repo>-<container>-sign`). `task ssh-agent:key:load` (re)loads every key of the
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

## Dedicated keys

Key mode puts a private key in a volume, so the key must be worth losing: small blast radius,
easy rotation.

- **Never import a personal key** that also opens GitHub, servers or other repositories. The
  host task `devcontainer:ssh-key-import` and the Feature warn (never block) when the file has a
  default name (`id_ed25519`, `id_ecdsa`, `id_rsa`, `id_dsa`, `id_ed25519_sk`, `id_ecdsa_sk`), or
  when its public key is also in the host's `~/.ssh/authorized_keys` or the same as another
  `~/.ssh/*.pub`. They print fingerprints, never key material. The public half is read from
  `FILE.pub`, or derived with `ssh-keygen -y` only when the key has no passphrase (a protected key
  is never prompted for; the check is skipped).
- **One key per purpose and per container**, named `<repo>-<container>-sign` (what `key:new`
  makes by default: the repository's name, the container's short host name, lower-cased to
  `[a-z0-9-]`). A leak then costs one container's signatures, not an identity.
- **Register it only as a signing key** at GitHub (Settings > SSH and GPG keys > New SSH key, key
  type Signing Key), never as an authentication key: a signing-only key cannot log in to anything.
- **Retire it** when the container goes away or on suspicion (below): `task ssh-agent:key:retire`.
- **The Operator's anchor key stays on the host**: the one that proves who you are is not imported
  into any container. A dedicated key is the thing you rotate; the anchor is what you use to
  register and remove dedicated keys.

## Rotating and retiring

`task ssh-agent:key:rotate` replaces a signing key in four steps and stops at the first failure,
removing nothing of the old key until the new one is proven:

1. Make the new key (`NEW`, default the old name without a date suffix plus `-YYYYMMDD`) in the
   key volume and load it; the old key stays loaded.
2. If `gh` is installed and logged in, register the public key as a **signing** key
   (`gh ssh-key add --type signing`). Otherwise print the public key and the manual step and
   **stop with exit 1**. The login needs the `admin:ssh_signing_key` scope (`gh auth refresh -s
   admin:ssh_signing_key`; the `gh` Feature keeps the login in its volume).
3. Point git at the new key (`SCOPE=global|repo`, as `git:signing`) and run `git:verify`; it must
   pass. On a failure git's settings are put back as they were. A repo-level `user.signingkey` that
   still names another key also stops the rotation.
4. Only then retire the old key: unload it from the agent, append its public key, dated, to
   `allowed_signers.history` in the key volume, delete its private key. By default the old key stays
   **registered at GitHub**, so its old commits keep their verified badge; `REVOKE=1` also removes it
   there (`gh ssh-key delete <id> --yes`, the id found by matching the public key), after which old
   commits show unverified at GitHub.

`task ssh-agent:key:rotate -- --plan` prints the steps and the keys involved and changes nothing.
`NAME=<old key>` is optional when the volume holds exactly one key. `EMPTY_PASSPHRASE=1` skips the
passphrase prompt (the task is interactive otherwise).

**Resuming.** If step 2 stopped because `gh` is missing, register the printed public key by hand
(signing key), then run `task ssh-agent:key:rotate NAME=<old> NEW=<new name>` with the name the
message gave. A `NEW` that already exists resumes: it is loaded if need be, registration is taken
on your word when `gh` is unavailable (and checked or done through `gh` when it is available),
and steps 3 and 4 run. A rotation that stopped later (verify, say) resumes the same way.

`task ssh-agent:key:retire NAME=<key> [REVOKE=1]` is step 4 alone (also with `-- --plan`), for a
key that needs no replacement. `task ssh-agent:key:age` lists each key with its creation date
(recorded in a `<name>.meta` sidecar when `key:new` or an import creates it; the file's date for
older ones), its age and fingerprint, and `task ssh-agent:check` warns when a key is older than
`SSH_KEY_MAX_AGE_DAYS` (default 365): "older than N days; task ssh-agent:key:rotate".

**Old signatures keep verifying locally.** Point git at the history file:

```sh
git config --global gpg.ssh.allowedSignersFile /var/lib/devcontainer-features/ssh-agent-key/allowed_signers.history
```

Each line is `* namespaces="git",valid-before="YYYYMMDD" <key>`: the key is trusted for commits
made before the day it was retired. Add the current key's line too if you want new commits to
verify locally. The history file holds public keys only; it lives in the key volume and goes with
it.

**Keys in the host's agent (socket mode)** are outside this Feature's reach, and `ssh-agent:check`
prints the same steps for them: make a new dedicated key on the host and add it
(`task devcontainer:ssh-add -- <new key>`); register it at GitHub as a signing key; point git at it
(`task ssh-agent:git:signing KEY=<its .pub>`) and run `task ssh-agent:git:verify`; only then remove
the old key from the host agent (`ssh-add -d`) and, if you want its commits unverified, from GitHub.

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
- Nothing here prints key material, and nothing generates a key unless you run `key:new` or `key:rotate`.

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
`key:rotate`, `key:retire`, `key:age`, `git:signing`, `git:verify` (all in `ssh-agent`; the host side has `devcontainer:ssh-add` and
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

`1.1.0`: dedicated-key guidance and warnings (default names, keys that also open something on the
host), `key:new`'s default name `<repo>-<container>-sign`, `key:rotate`, `key:retire`, `key:age`
and the age warning in `check` (`SSH_KEY_MAX_AGE_DAYS`); `devcontainer-cli` 1.10.0 adds the host-side
warnings to `devcontainer:ssh-key-import`. Nothing in the key volume changes except two additions
(`<name>.meta` sidecars and `allowed_signers.history`), neither of which is loaded as a key.

`1.0.0`: the first release. The container side is `ssh-agent-setup`; the host side lives in
`devcontainer-cli` 1.8.0 or later (the socket mount, `SSH_AGENT_MODE`, `devcontainer:ssh-add`,
`devcontainer:ssh-key-import`). Pin the Feature with `:1`; an upgrade changes nothing in the key
volume, and a rebuild re-runs the hook.
