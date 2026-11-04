
# GitHub CLI (gh) (gh)

GitHub CLI (https://cli.github.com) as a member of this collection's ecosystem: keeps a gh already in the image (e.g. from the official ghcr.io/devcontainers/features/github-cli, which is augmented instead of replaced) or installs the sha256-verified release binary at /usr/local/bin/gh (version pinnable); owns the login state as a named volume at GH_CONFIG_DIR=/var/lib/devcontainer-features/gh so `gh auth login` survives rebuilds; and adds a post-create hook (gh-setup) that makes that directory usable by the remote user, configures git to take GitHub credentials from gh, and reports whether a login is present. Plus the Feature Taskfile, with gh:ssh-key:add to register a public key as a signing key.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/gh:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| install | How the gh binary gets there. 'auto': keep a gh already in the image (official Feature, base image) and only add the ecosystem pieces, else install the verified release binary. 'native': always install the verified release binary at /usr/local/bin/gh. 'none': never install the binary, only the pieces. | string | auto |
| version | GitHub CLI release to install (e.g. '2.80.0', with or without a leading 'v'), or 'latest'. Ignored when an existing gh is kept (install=auto) or install=none. | string | latest |
| gitCredentialHelper | At post-create, configure git (global config) to take credentials for https://github.com from gh (`!gh auth git-credential`), so git push/pull use the gh login. Override per container with GH_SETUP_GIT_CREDENTIAL_HELPER in containerEnv. | boolean | true |

## How it fits

```text
  go-task registry --> gh:login, gh:status
  gh CLI --login--> GitHub
    |   `--credential helper--> git (shared global config with the git Feature)
    v
  volume: GH_CONFIG_DIR  (token, settings)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Login (token and settings) | named volume at `GH_CONFIG_DIR` (`/var/lib/devcontainer-features/gh`) | 4 working set |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [agentic-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/agentic-devhost.md), [windows-workstation-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/windows-workstation-devhost.md), [secrets-with-openbao](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/secrets-with-openbao.md)

## Augment, don't duplicate

With the default `install: auto` this Feature keeps a `gh` that is already
in the image and adds only the ecosystem pieces around it, so it composes
with the official Feature:

```json
"features": {
  "ghcr.io/devcontainers/features/github-cli:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/gh:1": {}
}
```

`installsAfter` orders this one after the official Feature. On its own, or
with `install: native`, it installs the release binary from
`github.com/cli/cli` instead: `gh_<version>_linux_<arch>.tar.gz` is checked
against the publisher's `gh_<version>_checksums.txt` with `sha256sum -c`
before `bin/gh` goes to `/usr/local/bin/gh`; `latest` is resolved through
the `releases/latest` redirect (no API call, no token), and `version` pins
a release. `install: none` adds only the pieces.

What the Feature adds in every mode:

- `GH_CONFIG_DIR=/var/lib/devcontainer-features/gh` in `containerEnv` and a
  named volume (`gh-config-${devcontainerId}`) on that path, so the token
  from `gh auth login` survives rebuilds (see below).
- A `postCreateCommand` (`gh-setup`, also `task gh:setup`) that runs
  `dcf-persist` on `GH_CONFIG_DIR` (creates it, hands it to the remote user,
  prints `gh: <dir> (volume|bind|image, writable)`), configures the git
  credential helper for `https://github.com` and reports whether a login is
  present (by the exit code of `gh auth status`; the hook never prints the
  account) and the next step (`gh auth login`) when it is not.
- `dcf-persist` on PATH, the helper every `<id>-setup` hook of this
  collection shares.

## git credentials from gh

With `gitCredentialHelper: true` (the default) `gh-setup` sets, in the
global git config, `credential.https://github.com.helper` to `''` followed
by `!gh auth git-credential` - the first entry clears whatever the image
configured for github.com, the second makes git use the gh login for
`push`/`pull`. It is idempotent (an already matching helper list is reported
as kept) and creates the folder of `GIT_CONFIG_GLOBAL` first when that is
set (the git Feature's volume, or wherever the repo points the variable).
`GH_SETUP_GIT_CREDENTIAL_HELPER=false` in
`containerEnv` switches it off without a rebuild; `gitCredentialHelper:
false` leaves git alone from the start.

## Keeping the login across rebuilds

`gh` keeps its token and settings in `GH_CONFIG_DIR`. The Feature sets that
to `/var/lib/devcontainer-features/gh` and mounts a named volume there, so
nothing is needed for the login to survive a rebuild. A named volume is
deleted by a container-engine storage reset or a move to another engine;
for a folder on the host disk, bind-mount the same target in the repo's
`devcontainer.json` (`initializeCommand` creates the folder first, since a
bind mount with a missing source fails; array form, since a string goes
through `cmd /c` on Windows):

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "gh"],
"mounts": [
  "source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/gh,target=/var/lib/devcontainer-features/gh,type=bind"
]
```

A repo's `mounts` entry on the same target wins over the Feature's volume.
Alternatively point `GH_CONFIG_DIR` in the repo's `containerEnv` at any
other mounted path; `gh-setup` follows the variable.

## Registering a signing key

`task gh:ssh-key:add` registers a public key at GitHub as a **signing** key (`gh ssh-key add
--type signing`), never an authentication key: a signing-only key logs in to nothing if it leaks.
The key comes from `FILE=<.pub>`, from OpenBao with `KEY=ssh/<name>` (the `openbao` Feature's
`dcf-secret`, field `public_key`), or on stdin; `TITLE=` defaults to the record's name or the key's
comment. A key already registered as a signing key is left alone (exit 0); a private key is
refused. The login needs the `admin:ssh_signing_key` scope: `gh auth refresh -s
admin:ssh_signing_key`. The `ssh-agent` Feature's `key:rotate` calls it (as `gh-ssh-key-add`) for
its GitHub step.

## Pairs with

- `ghcr.io/devcontainers/features/github-cli` for the apt-installed gh.
- This collection's `git` Feature: both write the same global git config,
  and `gh-setup` creates the `GIT_CONFIG_GLOBAL` folder if `git-setup` has
  not yet.
- `task gh:login` / `task gh:status` from a root Taskfile that includes the
  go-task registry.

## Changes

### [1.1.0] - 2026-11-04

#### Added

- `task gh:ssh-key:add` registers a public key at GitHub as a **signing** key (never an authentication key): `FILE=<.pub>`, `KEY=ssh/<name>` to read it from OpenBao (the openbao Feature), or the key on stdin; a key already registered as a signing key is left alone, and a private key is refused. Your gh login needs the `admin:ssh_signing_key` scope (`gh auth refresh -s admin:ssh_signing_key`). ssh-agent 1.4.0's `key:rotate` uses it. Nothing to do otherwise.

### [1.0.4] - 2026-11-03

#### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Documentation only: the Feature itself is unchanged. Nothing to do.

### [1.0.3] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/gh/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/gh/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
