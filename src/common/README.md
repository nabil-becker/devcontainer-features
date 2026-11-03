
# Common helpers (devcontainer-features) (common)

Shared helpers used by this collection's Features: dcf-persist (installed, also for a repo's own post-create scripts), which makes a tool's state directory (a named volume or a bind mount) usable by the remote user and reports what backs it; and dcf-curl.sh, the download helper every installer sources so each download retries every error.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/common:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |

## How it fits

```text
  Features' post-create hooks  --call-->  dcf-persist <dir>
  a repo's own post-create scripts ----->   (hands a volume or bind mount
  every installer  --source-->  dcf-curl.sh   to the remote user, reports
                                              volume | bind | image)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Nothing of its own | helpers only; the directories it prepares belong to the calling Feature | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [windows-workstation-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/windows-workstation-devhost.md)

## What `dcf-persist` does

`dcf-persist [--label <name>] <dir>...` is the one helper behind every
`<id>-setup` post-create hook of this collection. For each directory it
creates it (with `sudo` when the parent is not writable), hands it to the
current user when its top level is owned by someone else (named volumes and
bind mounts arrive owned by root or by the host's uid), and prints one line:
label, path, what backs it, and whether it is writable. The backing is one
of:

- `volume` - a named volume: survives rebuilds, deleted by a container-engine
  storage reset or a move to another engine;
- `bind` - a folder from the host disk: survives all of that;
- `image` - the container filesystem: gone at the next rebuild.

It is never fatal (exit 0 always): a problem is reported and the rest of
post-create goes on. The same thing as a task:
`task common:persist DIR=<dir> [LABEL=<name>]`.

## How Features use it

An augmentation Feature declares the directory variable in `containerEnv`
and a named volume as its default backing, then calls the helper from its
`<id>-setup` hook, which the Feature's `postCreateCommand` runs as the
remote user:

```json
"containerEnv": {
  "<VAR>": "/var/lib/devcontainer-features/<id>"
},
"mounts": [
  {
    "source": "<id>-<what>-${devcontainerId}",
    "target": "/var/lib/devcontainer-features/<id>",
    "type": "volume"
  }
],
"postCreateCommand": "<id>-setup"
```

```bash
dcf-persist --label <id> "$<VAR>"
```

A repo that wants the state on the host disk overrides the volume with a bind
mount on the same target in its `devcontainer.json`; mounts are applied in
order and the last source for a target wins:

```json
"mounts": [
  "source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/<id>,target=/var/lib/devcontainer-features/<id>,type=bind"
]
```

A repo's own post-create scripts can call `dcf-persist` the same way for
their own directories once this Feature is installed.

## `dcf-curl`: every download retries

`dcf-curl.sh` is sourced by every installer that downloads (and by
`devcontainer-cli.sh`), never installed. It defines `dcf_curl`, which is
`curl` with `--retry 3 --retry-delay 2 --retry-connrefused` added and, on
curl 7.71+, `--retry-all-errors`:

```bash
# shellcheck source=src/<id>/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"
dcf_curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
```

Plain `--retry` retries a timeout or an HTTP 5xx, not a TLS reset in
mid-handshake (curl exit 35) or a connection cut mid-transfer (exit 56); both
failed CI builds. An older curl keeps plain `--retry`. The caller's own flags
(`-f`, `-s`, `-S`, `-L`, `-o`, `-w`) pass through unchanged, and so does the
checksum check that follows. A retried download to stdout (no `-o`) can
repeat the bytes of the cut attempt, so a binary is always fetched with
`-o` and checked. `task common:curl-check` (part of `task lint`) fails on a
`curl` or `wget` call in a Feature script that does not go through
`dcf_curl`; a justified exception carries `dcf-curl: allow <reason>` on the
same line.

## Why copies rather than a dependency

Every Feature that needs `dcf-persist` or `dcf-curl` carries a verbatim copy of
`src/common/dcf-persist.sh` or `src/common/dcf-curl.sh` (the first installed, the second
sourced) rather than declaring
`dependsOn` on this Feature: `devcontainer features test` cannot resolve a
`dependsOn` on an OCI reference that has not been published yet, so the
Features could not be tested before the first release, and the official
`devcontainers/features` avoid cross-Feature dependencies for the same
reason. This Feature is the canonical source; `task lint` checks that every
copy is identical to it.

## Changes

### [1.0.4] - 2026-11-03

#### Changed

- The README now has a "How it fits" section with a small diagram of how the Feature sits in a devcontainer, a table of the data it keeps and the storage tier of each, and "Used in" links to the reference architectures that use it. Documentation only: the Feature itself is unchanged. Nothing to do.

### [1.0.3] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

### [1.0.2] - 2026-10-28

#### Fixed

- Build-time downloads retry on transient network errors, so a flaky connection no longer fails the container build outright. Rebuild the container to pick it up. No change to options or tasks; nothing to do. ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/common/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/common/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
