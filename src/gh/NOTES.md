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

## Pairs with

- `ghcr.io/devcontainers/features/github-cli` for the apt-installed gh.
- This collection's `git` Feature: both write the same global git config,
  and `gh-setup` creates the `GIT_CONFIG_GLOBAL` folder if `git-setup` has
  not yet.
- `task gh:login` / `task gh:status` from a root Taskfile that includes the
  go-task registry.
