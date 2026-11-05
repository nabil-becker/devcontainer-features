
# SSH agent (ssh-agent)

Makes an SSH agent available to every process in the devcontainer (SSH_AUTH_SOCK=/var/lib/devcontainer-features/ssh-agent/agent.sock, also for `devcontainer exec`) so git commits can be signed with an SSH key: the devcontainer-cli launcher bind-mounts the host's agent socket onto that path where the host type has one (linux, macos, a WSL distro), the private key never entering the container; a post-start hook (ssh-agent-setup) checks it on every start and says plainly what a host type without one can do; the opt-in key mode (option mode: key) starts an agent inside the container and loads keys from its own volume instead, which breaks the no-key rule for whoever turns it on. With the openbao Feature, key:load NAME=ssh/<key> fetches a key from OpenBao and pipes it into the agent (ssh-add -t, memory only, never a file) for no longer than the login, key:lock drops it, and key:rotate rotates OpenBao records, keeping .devcontainer/allowed_signers; the key volume's tasks are deprecated (removed in 2.0). Plus the Feature Taskfile (check, keys, key tasks including key:rotate, key:retire and key:age, git:signing, git:verify).

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
| passphraseTimeout | Key mode: seconds `task ssh-agent:setup` (and the key tasks) wait for the passphrase of a protected key typed at ssh-add's own prompt. On the timeout, with no terminal to ask on, or with 0 (never prompt), they print one warning (the key is not loaded; task ssh-agent:setup loads it later) and go on with exit 0. The start hook itself never asks: it skips a protected key with that warning. Override per container with SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT in containerEnv. | string | 120 |
| mode | Which agent the container uses. `auto` (default) follows what the launcher found for the host (DCF_HOST_SSH_AGENT): the host's socket where the host type has one, otherwise nothing (with a plain explanation). `socket` pins the host's agent socket verdict, `none` pins no agent, whatever the launcher found. `key` starts an agent inside the container on the fixed socket and loads the private keys found in the ssh-agent-key volume, unless the launcher really mounted a host socket (a mounted socket wins and the start hook says so); this puts a private key in the container, which breaks the default rule that the key never enters it, so use it only where the host type cannot forward its agent (windows-docker, windows-wslc). Set it per machine with "mode": "${localEnv:SSH_AGENT_MODE:auto}" in devcontainer.json and SSH_AGENT_MODE=key in .devcontainer/.env, then rebuild. An empty or unknown value is treated as auto with one warning. Override per container with SSH_AGENT_SETUP_MODE in containerEnv. | string | auto |
| keyMode | Deprecated (removed in 2.0; use mode: key). With mode auto, keyMode: true means mode: key. Ignored when mode is socket, key or none. Still overridable per container with SSH_AGENT_SETUP_KEY_MODE in containerEnv, which is deprecated the same way. | boolean | false |

## How it fits

```text
  host SSH agent socket --bind mount (devcontainer-cli launcher)-->
        /var/lib/devcontainer-features/ssh-agent/agent.sock = SSH_AUTH_SOCK
  git commit -S, ssh  --> the agent; the private key never enters the container
  Windows engines: none; opt-in key mode keeps keys in a volume
  git Feature: signing config
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Private keys | none in the default mode; only in the opt-in key mode, in a named volume at `/var/lib/devcontainer-features/ssh-agent-key` | 4 working set |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [windows-workstation-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/windows-workstation-devhost.md), [secrets-with-openbao](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/secrets-with-openbao.md)

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
`.devcontainer/.env`, where `"mode": "${localEnv:SSH_AGENT_MODE:auto}"` also reads it) sets `DCF_HOST_SSH_AGENT=key` and suppresses the socket mount.

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
- `mode` (default `auto`; 1.5.0): which agent the container uses, the one setting to touch.
  - `auto`: follow what the launcher found (`DCF_HOST_SSH_AGENT`): the host's socket where the host
    type has one, otherwise nothing, with the plain explanation. The deprecated `keyMode: true`
    still turns this into `key`.
  - `socket`: pin the host-socket verdict whatever the launcher said (a socket that is not there is
    reported as not reachable, with the fix).
  - `key`: the opt-in, temporary key mode below. It applies when no host agent socket is mounted
    (`none` or unknown); a mounted socket wins and the hook says so.
  - `none`: pin no agent: the hook explains the ways round and starts nothing.
  An empty or unknown value is `auto`, with one warning (`${localEnv:SSH_AGENT_MODE:auto}` can
  produce odd values). Override without a rebuild with `SSH_AGENT_SETUP_MODE` in `containerEnv`.
  Per machine, write `"mode": "${localEnv:SSH_AGENT_MODE:auto}"` in `devcontainer.json` and
  `SSH_AGENT_MODE=key` in `.devcontainer/.env` on the workstation, then rebuild. The launcher reads
  the same `SSH_AGENT_MODE=key` and then suppresses the socket mount (it stays the launcher's
  internal signal, `DCF_HOST_SSH_AGENT`).
- `keyMode` (default `false`): **deprecated, removed in 2.0**; with `mode: auto` it means `mode: key`,
  and it is ignored when `mode` is `socket`, `key` or `none`. Its override
  `SSH_AGENT_SETUP_KEY_MODE` is deprecated the same way. The start hook prints one deprecation line
  while either is on.
- `passphraseTimeout` (default `"120"`): key mode, seconds the explicit tasks wait for the passphrase of a
  protected key at ssh-add's prompt in `task ssh-agent:setup` and the key tasks before it warns and goes on; `0` never prompts. The start hook itself never asks.
  Override without a rebuild with `SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT` in `containerEnv`
  (a repository can map it from the launcher's environment with `${localEnv:...}`).

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1": {}
}
```

On `windows-docker` or `windows-wslc`, add `"mode": "key"` only if you accept the trade-off
below.

## Keys from OpenBao (1.4.0)

With the `openbao` Feature (1.3.0 or later) in the container, OpenBao keeps the private keys and
this Feature only uses them (ADR 0048):

```sh
task openbao:login -- -method=userpass username=operator   # once per sitting (server mode unsealed)
task ssh-agent:key:load NAME=ssh/<key> [MINUTES=60]       # the key into the agent, memory only
task ssh-agent:key:lock NAME=ssh/<key>                    # out again, sooner than its lifetime
```

- **No file.** `key:load` runs `dcf-secret get ssh/<key> --field private_key | ssh-add -t <life> -`:
  the key passes on a pipe into the agent and is never written anywhere. Only its public key is
  noted (in `$XDG_RUNTIME_DIR` or `/tmp`, `ssh-agent-feature-<uid>/`), so `key:lock` works while
  OpenBao is sealed.
- **No longer than the login.** The lifetime is what the OpenBao token has left (`dcf-secret
  ttl`), at most 480 minutes; `MINUTES` shortens it, and a longer one is cut to the login with a
  line saying so. With under a minute left it refuses with exit 12 (log in again).
- **Whose agent.** Key mode: the container's own agent (started if none runs). Socket mode: the
  workstation's agent, and the task says so (`loaded ssh/<key> into the workstation's agent until
  HH:MM`); keys the workstation already holds stay the workstation's. With neither, it refuses with
  the verdict of `check`.
- **OpenBao's answers come through**: exit 10 unreachable, 11 sealed (the Operator runs `task
  openbao:unseal`), 12 no or expired login, 13 not allowed, 14 no such key; nothing is loaded. There
  is no fallback to the key volume. Without the `openbao` Feature it says to add it.
- **The start hook never fetches from OpenBao**: it never waits and never asks.

Names are OpenBao's: `ssh/<key>` for signing keys, `register/<principal>` for the register's.
`task openbao:ssh:new` makes one, `task openbao:ssh:import FROM=ssh-agent` moves the key volume's
keys in (below), and from the workstation `task devcontainer:openbao-ssh-import FILE=<key>` streams one in.

## Loading keys

- **Socket mode** (linux, macos, windows-wsl-docker): the agent is the host's, so load keys on
  the host with the host's `ssh-add`. `task devcontainer:ssh-add -- ~/.ssh/id_ed25519` runs it
  (no arguments lists with `-l`); it is a one-shot command that exits. Inside the container
  `task ssh-agent:keys` shows what the agent holds.
- **Key mode** (opt-in; **its key volume is deprecated and goes in 2.0**, every task below that uses
  it prints one line naming its replacement): from the host, `task devcontainer:ssh-key-import FILE=<private key on the
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
  For a protected key you want in the agent only for a sitting, `task ssh-agent:key:unlock
  NAME=<file> [MINUTES=15]` loads that one key with a lifetime (`ssh-add -t`), asks for its
  passphrase on the terminal (same prompt and `passphraseTimeout` as above), and says the clock
  time it drops out; MINUTES is a positive whole number, at most 480 (8 hours). `task
  ssh-agent:key:lock NAME=<file>` takes it out sooner and leaves it in the volume (it is the same
  unload `key:remove` does without `DELETE=1`). Both are key mode only.

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

**On OpenBao records** (`NAME=ssh/<key>`; optional when OpenBao holds exactly one active key and
key mode is off), `task ssh-agent:key:rotate` keeps the four steps below and their order, with the
records' lifecycle in the `openbao` Feature: (1) `openbao:ssh:new` makes `ssh/<new>` and it is
loaded from OpenBao; (2) the `gh` Feature's `gh:ssh-key:add` registers it as a signing key (else
`gh` directly, else the public key is printed and the rotation stops, to resume with
`NEW=ssh/<new>`); (3) git is pointed at it and `git:verify` runs, and it gets a line in
`.devcontainer/allowed_signers` valid after now (the file is made if missing); (4) only then
`openbao:ssh:retire` destroys the old record's private key, its line gets valid-before now (added
first if it had none), and it is unloaded. The host commits `.devcontainer/allowed_signers`. `--plan`
and `REVOKE=1` work as below.

On the key volume (deprecated, key mode), `task ssh-agent:key:rotate` replaces a signing key in four steps and stops at the first failure,
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
   **registered at GitHub**; `REVOKE=1` also removes it there (`gh ssh-key delete <id> --yes`, the id
   found by matching the public key). GitHub's documentation says a commit verified once stays
   verified in its repository's network even if the key is later removed, so `REVOKE=1` loses only
   the badge of commits GitHub had not yet verified.

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

**Old signatures keep verifying locally.** From 1.4.0 the record is `.devcontainer/allowed_signers`
in the repository (one line per key, `namespaces="git"` with valid-after / valid-before; public
keys only, reviewed in pull requests), which `openbao:ssh:import FROM=ssh-agent` fills from the
history file and `key:rotate` keeps. Where the repository has that file, `git:signing` adds the
signing key to it if missing and sets `gpg.ssh.allowedSignersFile` in the repository's config to
the relative path `.devcontainer/allowed_signers`: git reads a relative path from the top of the
work tree, from any subfolder and with `git -C` (tested), and so does Windows git on the same
repository config. `ALLOWED_SIGNERS=<file>` names another file. A repository without the file
gets none from `git:signing`. Before 1.4.0, point git at the history file:

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
mounted into every container. Then Windows git reads the same `user.signingkey key::<public key>`,
signs through the Windows agent, which does not hold that key, and every commit on the host fails.
**Where the git dir is shared with a Windows host, use `SCOPE=global`.** The default is therefore
`global` when the `git` Feature's volume is present (`GIT_CONFIG_GLOBAL` under
`/var/lib/devcontainer-features/`) or the host is Windows (`DCF_HOST_TYPE` `windows-*`), else
`repo`, and the task says which it used. `task ssh-agent:git:verify` signs a throwaway message through the agent with
`ssh-keygen -Y sign` and verifies it against a temporary `allowed_signers` file, printing `ok` or
why not, without committing. To check signatures with `git log --show-signature`, also set
`gpg.ssh.allowedSignersFile`; adding the public key to GitHub as a signing key marks the commits
verified there, with the condition in the next section.

## Signing and GitHub

GitHub shows **Verified** only when the commit's **committer email is a verified email of the account
that registered the signing key**. A repository whose agents commit as an address no account can
claim (an `.invalid` address, to keep personal emails out of history) gets `verified: false` with
`reason: no_user` on every agent commit, although the signature is good. That is expected, not a
fault of this Feature: the signatures still check locally with `gpg.ssh.allowedSignersFile` and
`git log --show-signature`, and a squash merge (or a merge queue's commit) made on GitHub is signed
by GitHub itself and shows Verified. To get the badge on the agent commits, commit with an email
the key's account has verified.

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

`task ssh-agent:version`, `check`, `setup`, `keys`, `key:load`, `key:lock`, `key:rotate`,
`git:signing`, `git:verify`; deprecated with the key volume (gone in 2.0): `key:add`, `key:new`,
`key:unlock`, `key:remove DELETE=1`, `key:retire`, `key:age`, `key:load` with no `NAME` (all in
`ssh-agent`; the host side has `devcontainer:ssh-add`, `devcontainer:openbao-ssh-import` and the
deprecated `devcontainer:ssh-key-import`). The records' own tasks are the `openbao` Feature's
(`openbao:ssh:new`, `put`, `import`, `retire`, `age`) and GitHub's step is the `gh` Feature's
(`gh:ssh-key:add`).

## Limits and troubleshooting

- **A socket is mounted at `up`.** Start the host agent (and add a key) before `task
  devcontainer:up`, or restart the container afterwards: a socket that did not exist then is not
  mounted. `check` says "not reachable" with that hint.
- **Opened straight in VS Code** (no launcher): no mount and `DCF_HOST_SSH_AGENT` is empty; use VS
  Code's own forwarding in its terminals, or start through the tasks.
- `windows-wsl-docker` driven from Windows, and Docker Desktop's socket on Windows, are not
  forwarded (unverified, see `host-profile-unverified-checks` in the repository's backlog).
- **A passphrase-protected key (key mode) at start.** The start hook never asks for a passphrase: it
  loads the keys that have none, skips each protected key with one warning
  (`<key> has a passphrase and the start hook never asks for one ... Load it: run task
  ssh-agent:setup from a terminal in the container`), starts the agent and exits 0. Why: the devcontainer
  CLI runs every Feature's start hook together and waits for all of them, so a hook that waits at
  ssh-add's prompt holds the whole start (a consumer's start on `windows-wslc` stopped after about 13
  minutes, 775 s, when WSL's exec connection timed out; the remaining start hooks were skipped, so no
  agent ran, and the failure was reported on another Feature's hook). From a terminal,
  `task ssh-agent:setup` (and `key:load`, `key:add`, `key:new`, `key:rotate`) shows ssh-add's own prompt,
  `Enter passphrase for <key>:`, and waits up to `passphraseTimeout` seconds (default 120;
  `SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT` in `containerEnv` overrides it, `0` never prompts). A wrong
  passphrase is asked again (ssh-add's own three tries). When the time runs out, the passphrase is
  skipped or there is no terminal, it prints the same single warning and goes on with exit 0. The passphrase
  is typed at ssh-add's prompt and never read, logged or passed by this script.
- **Start hook and `key:unlock`.** A protected key is skipped at start, so `task ssh-agent:key:unlock`
  is the way to use it: it is not reloaded by the hook, and a key loaded with a lifetime is gone from
  the agent when the lifetime ends (or at the next container start) and stays gone until unlocked again.
  A key without a passphrase unlocked this way is reloaded, without a limit, by the next start hook.
- The key volume is a named volume: a container-engine storage reset deletes it (the key is on your
  host anyway; re-import it).

## Best practices

- **Prefer socket mode; use key mode only where the host has no agent to forward, with a dedicated signing key.** In socket mode the private key never enters the container; key mode puts it in the key volume, readable by every process in the container (see "The opt-in key mode, temporary").

## Anti-patterns

### Don't prompt for a passphrase in the start hook

- **Don't:** run `ssh-add`, or anything that reads the terminal, in a start hook, and don't put a passphrase-protected key where the hook loads it expecting a prompt.
- **Why:** 2026-10-30, "Start hook no longer waits on ssh-add; passphrase prompt gets a bounded wait and a warning". The hook prompted on `/dev/tty`, the devcontainer CLI waits for every Feature's start hook, and one start hung about 775 s until WSL's exec connection dropped; the error named another Feature's hook (2026-10-30, "Consumer diagnostics read; copy cause and start hang settled").
- **Instead:** let the hook load only keys without a passphrase (it skips protected ones with one warning and exits 0), and load a protected key from a terminal with `task ssh-agent:setup` or `task ssh-agent:key:unlock` (which waits up to `passphraseTimeout`).
- **Caught by:** the pty cases in `passphrase_test.sh`, run by `task test:ssh-agent-unit` (the hook never asks, skips a protected key, exits 0).

### Don't use `key:unlock` for a key that has no passphrase

- **Don't:** unlock an unprotected key with `task ssh-agent:key:unlock MINUTES=<n>` and expect it to drop out after the lifetime.
- **Why:** 2026-11-03, "ssh-agent 1.3.0 adds timed key unlock and key lock": the start hook loads every key without a passphrase, with no lifetime, so the next container start puts it back for good.
- **Instead:** use timed unlock for protected keys only (they are skipped at start and so stay out until unlocked again); to take an unprotected key out, `task ssh-agent:key:remove NAME=<file>`.
- **Caught by:** nothing yet (the "Limits" section says so; a guard in `key:unlock` for an unprotected key is not on the backlog).

## Why it exists

VS Code forwards the host agent only into its own terminals, and the devcontainer CLI does not
forward it at all, so signing from `devcontainer exec` or a `claude` session failed. No Feature of
this collection or of `devcontainers/features` forwards the agent for the CLI; this one does it with
the launcher's mount instead of a process on the host, and is honest where a host type cannot.

## Version and upgrade

`1.4.0`: keys from OpenBao (`key:load` / `key:lock NAME=ssh/<key>`, `key:rotate` on OpenBao
records, `.devcontainer/allowed_signers`), and the key volume's tasks deprecated: they keep working
and print one line each. **Nothing breaks**; a consumer pinned to `:1` sees the deprecation lines.
To move off key mode's volume, once per container:

| Step | Who | What |
|---|---|---|
| 1 | maintainer | add `openbao` with `"mode": "server"` (or a `BAO_ADDR` of your server) to `devcontainer.json`, rebuild |
| 2 | the Operator, in a plain terminal | `task openbao:init` (once), `task openbao:unseal`, `task openbao:login` |
| 3 | the Operator | `task openbao:ssh:import FROM=ssh-agent`; the host commits `.devcontainer/allowed_signers` |
| 4 | everyone | `key:unlock NAME=<file>` becomes `key:load NAME=ssh/<file> [MINUTES=]` |

In 2.0 the key volume, its mount and the deprecated tasks go, and `mode: key` becomes `localAgent` (and `keyMode` goes)
(an in-container agent with keys in memory only); removing a mount does not delete the volume, so
import first and remove the old volume with the engine's own command.

`1.2.0`: the start hook no longer hangs on a passphrase-protected key in key mode: it never asks, it
skips the key with one warning and exits 0. `task ssh-agent:setup` (and the key tasks) ask at ssh-add's
prompt for up to the new option `passphraseTimeout` (default 120 seconds); on the timeout, with no
terminal or with `0`, they warn once (the key is not loaded, how to load it) and go on with exit 0.
Before, ssh-add asked on the controlling terminal with no limit, so the start waited until something
else gave up. Nothing in the key volume changes on upgrade.

`1.1.1`: `git:verify` no longer ends with `tmp: unbound variable` after `ok` and removes its
temporary folder; `git:signing` defaults to `SCOPE=global` on a Windows host (`DCF_HOST_TYPE`
`windows-*`) even without the `git` Feature's volume, and with `SCOPE=repo` says to use `global`
where the git dir is shared with Windows. Nothing in the key volume or git config changes on upgrade.

`1.1.0`: dedicated-key guidance and warnings (default names, keys that also open something on the
host), `key:new`'s default name `<repo>-<container>-sign`, `key:rotate`, `key:retire`, `key:age`
and the age warning in `check` (`SSH_KEY_MAX_AGE_DAYS`); `devcontainer-cli` 1.10.0 adds the host-side
warnings to `devcontainer:ssh-key-import`. Nothing in the key volume changes except two additions
(`<name>.meta` sidecars and `allowed_signers.history`), neither of which is loaded as a key.

`1.0.0`: the first release. The container side is `ssh-agent-setup`; the host side lives in
`devcontainer-cli` 1.8.0 or later (the socket mount, `SSH_AGENT_MODE`, `devcontainer:ssh-add`,
`devcontainer:ssh-key-import`). Pin the Feature with `:1`; an upgrade changes nothing in the key
volume, and a rebuild re-runs the hook.

## Changes

### [1.5.0] - 2026-11-05

#### Added

- **A `mode` option** (`auto`, `socket`, `key`, `none`; default `auto`) is the one setting for which agent the container uses. `auto` behaves exactly as before: it follows what the launcher found for the host. `key` starts the agent inside the container and loads the keys of the key volume (what `keyMode: true` meant; a host socket the launcher really mounted still wins, and the start hook says so). `socket` and `none` pin those two outcomes whatever the launcher found. To choose per machine, write `"mode": "${localEnv:SSH_AGENT_MODE:auto}"` in `devcontainer.json` and `SSH_AGENT_MODE=key` in `.devcontainer/.env` on the workstation, then rebuild. An empty or unknown value counts as `auto` with one warning. `SSH_AGENT_SETUP_MODE` in `containerEnv` overrides it without a rebuild.

#### Changed

- The messages that told you how to turn key mode on now name this way (the `mode` line plus `SSH_AGENT_MODE=key` in `.devcontainer/.env`, then rebuild).

#### Deprecated

- **`keyMode` and the `SSH_AGENT_SETUP_KEY_MODE` override** (removed in 2.0): they still work, `keyMode: true` meaning `mode: key` while `mode` is `auto`, and the start hook prints one deprecation line while either is on. **You do not have to act now**; move to `mode` when convenient.

### [1.4.0] - 2026-11-04

#### Added

- **`task ssh-agent:key:load NAME=ssh/<key> [MINUTES=]` loads a key from OpenBao** (the openbao Feature 1.3.0, unsealed, after `task openbao:login`): the key is piped into `ssh-add -t <life> -`, so it is in agent memory only and never in a file, for as long as your OpenBao login has left (at most 8 hours; `MINUTES` shortens it), and it says when it drops out. In socket mode it loads into the workstation's agent and says so. `task ssh-agent:key:lock NAME=ssh/<key>` takes it out, also while OpenBao is sealed. OpenBao's own exit codes come through (11 sealed, 12 log in, 14 no such key).
- **`task ssh-agent:key:rotate NAME=ssh/<key>` rotates on OpenBao records**: the same four steps and order (a new record, registered at GitHub as a signing key through the gh Feature's `gh:ssh-key:add`, git pointed at it and verified, only then the old record retired), and `.devcontainer/allowed_signers` keeps both keys with valid-after and valid-before stamps, so old commits still verify. The host commits the file.
- `task ssh-agent:git:signing` adds the key to `.devcontainer/allowed_signers` and sets `gpg.ssh.allowedSignersFile` in the repository's config to that relative path, but only where the repository has the file (or `ALLOWED_SIGNERS=<file>` names one). git reads it from the top of the work tree, from any folder.

#### Deprecated

- **The key volume and its tasks**: `key:new`, `key:add`, `key:unlock`, `key:retire`, `key:age`, `key:remove DELETE=1`, `key:load` with no `NAME`, `key:lock` and `key:rotate` of a volume key, and the old workstation import (`devcontainer:ssh-key-import`) still work as before and print one line naming what replaces them; the start hook says so once in key mode when the volume holds keys. They are removed in ssh-agent 2.0, where `keyMode` becomes `localAgent`. **Nothing breaks now**; to move, add the openbao Feature and run `task openbao:ssh:import FROM=ssh-agent` once, then `key:unlock NAME=<file>` becomes `key:load NAME=ssh/<file>`. A setup in socket mode that never used key mode changes nothing.

### [1.3.2] - 2026-11-03

#### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Where the Feature has them, its best practices and anti-patterns are in the README too. Documentation only: the Feature itself is unchanged. Nothing to do.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/ssh-agent/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/ssh-agent/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
