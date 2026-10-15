
# Azure CLI (az) setup (az)

Augments the Azure CLI that ghcr.io/devcontainers/features/azure-cli installs (this Feature installs no az itself; add that one before it): owns the login state as a named volume at AZURE_CONFIG_DIR=/var/lib/devcontainer-features/az so `az login` survives rebuilds, and adds a post-create hook (az-setup) that makes that directory usable by the remote user, tells az to use a bicep binary found on PATH (so `az bicep` does not download its own), and reports the az version and whether a login is present. Plus the Feature Taskfile.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/az:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| bicepFromPath | At post-create, when a bicep binary is on PATH (the azure-cli Feature's installBicep puts one there), set `az config set bicep.use_binary_from_path=true` so `az bicep` and `az deployment` use it instead of asking to install their own copy. Override per container with AZ_SETUP_BICEP_FROM_PATH in containerEnv. | boolean | true |

## Augmentation only: bring the official Feature

This Feature installs no `az`. Microsoft ships the Azure CLI through its
signed apt repository, which is exactly what
`ghcr.io/devcontainers/features/azure-cli` installs, and there is no better
verified source to re-implement here. List that Feature first; `installsAfter`
orders this one behind it:

```json
"features": {
  "ghcr.io/devcontainers/features/azure-cli:1": {
    "installBicep": true
  },
  "ghcr.io/nabil-becker/devcontainer-features/az:1": {}
}
```

When `az` is absent at image build, `install.sh` prints a loud warning
(`az not found; add ghcr.io/devcontainers/features/azure-cli:1 before this
Feature`) and still installs the hook, `dcf-persist` and the Taskfile
rather than failing: the auto-generated test of `devcontainer features
test` installs every Feature alone on a bare image, and an image that gets
az from a later layer should not break. `az-setup` repeats the warning at
post-create.

What the Feature adds:

- `AZURE_CONFIG_DIR=/var/lib/devcontainer-features/az` in `containerEnv`
  and a named volume (`az-config-${devcontainerId}`) on that path, so the
  tokens from `az login` survive rebuilds (see below).
- A `postCreateCommand` (`az-setup`, also `task az:setup`) that runs
  `dcf-persist` on `AZURE_CONFIG_DIR` (creates it, hands it to the remote
  user, prints `az: <dir> (volume|bind|image, writable)`), applies the bicep
  setting and reports the azure-cli version, whether a login is present (by
  the exit code of `az account show`; the hook never prints the account)
  and the next step (`az login --use-device-code`) when it is not.
- `dcf-persist` on PATH, the helper every `<id>-setup` hook of this
  collection shares.

## bicep from PATH

The azure-cli Feature's `installBicep: true` puts a `bicep` binary on PATH,
but `az bicep build` / `az deployment ... --template-file x.bicep` still
offer to download their own copy into `AZURE_CONFIG_DIR/bin` unless
`bicep.use_binary_from_path` is set. With `bicepFromPath: true` (the
default) `az-setup` runs `az config set bicep.use_binary_from_path=true
--only-show-errors` when a `bicep` is on PATH (reported as kept once set;
left alone when there is no bicep). `AZ_SETUP_BICEP_FROM_PATH=false` in
`containerEnv` switches it off without a rebuild; `bicepFromPath: false`
leaves the setting alone from the start. The setting lives in
`AZURE_CONFIG_DIR/config`, so it persists with the login.

## Keeping the login across rebuilds

`az` keeps tokens, the subscription list and its config in
`AZURE_CONFIG_DIR`. The Feature sets that to
`/var/lib/devcontainer-features/az` and mounts a named volume there, so
nothing is needed for the login to survive a rebuild. A named volume is
deleted by a container-engine storage reset or a move to another engine;
for a folder on the host disk, bind-mount the same target in the repo's
`devcontainer.json` (`initializeCommand` creates the folder first, since a
bind mount with a missing source fails; array form, since a string goes
through `cmd /c` on Windows):

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "az"],
"mounts": [
  "source=${localEnv:USERPROFILE}${localEnv:HOME}/.devcontainer-homes/myrepo/az,target=/var/lib/devcontainer-features/az,type=bind"
]
```

A repo's `mounts` entry on the same target wins over the Feature's volume.
Alternatively point `AZURE_CONFIG_DIR` in the repo's `containerEnv` at any
other mounted path; `az-setup` follows the variable.

## Pairs with

- `ghcr.io/devcontainers/features/azure-cli` (required) for az itself and,
  with `installBicep`, the bicep binary this Feature wires up.
- `task az:login` / `task az:account` from a root Taskfile that includes
  the go-task registry.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/az/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
