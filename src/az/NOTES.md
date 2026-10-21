## az comes with it (dependsOn)

The Feature brings the Azure CLI in itself, through `dependsOn` on the
official Feature, which installs it from Microsoft's signed apt repository:

```json
"dependsOn": {
  "ghcr.io/devcontainers/features/azure-cli:1": { "installBicep": true }
}
```

So listing only `ghcr.io/nabil-becker/devcontainer-features/az:1` gives an
image with `az` and `bicep`, installed before this Feature. `dependsOn`
installs the dependency; `installsAfter` (what this Feature used before
1.1.0) only orders it, and is dropped when the repo does not list it, which
left such images with no `az`. `installBicep: true` is passed because
`bicepFromPath` (default true) wires up a `bicep` on PATH.

### When the repo lists azure-cli too

The devcontainer CLI counts two entries as one Feature only when both the
id and the options are equal; otherwise it installs both.

- Listed with the same options (`"installBicep": true`, nothing else): one
  install, nothing to do. Listing it is not needed any more.
- Listed with other options (a pinned `version`, `extensions`, no bicep):
  the official Feature is installed **twice**, once with each set of
  options. Both runs install the apt package; which run comes last, and
  so which `version` ends up installed, is not fixed by the spec. If you
  need a pinned az version, say so on this collection's backlog rather than
  relying on the order.

When `az` is absent at image build anyway (a tool that does not resolve
`dependsOn`), `install.sh` prints a loud warning and still installs the
hook, `dcf-persist` and the Taskfile rather than failing; `az-setup`
repeats the warning at post-create.

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
  "source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/az,target=/var/lib/devcontainer-features/az,type=bind"
]
```

A repo's `mounts` entry on the same target wins over the Feature's volume.
Alternatively point `AZURE_CONFIG_DIR` in the repo's `containerEnv` at any
other mounted path; `az-setup` follows the variable.

## Pairs with

- `ghcr.io/devcontainers/features/azure-cli`, pulled in through
  `dependsOn` (with `installBicep`), for az itself and the bicep binary this
  Feature wires up.
- `task az:login` / `task az:account` from a root Taskfile that includes
  the go-task registry.
