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

## `dcf-skills.sh`: the skills hand-over the CLI adapters share

The component registry's skills hand-over (ADR-0064, ADR-0074, ADR-0077) was written twice, once in
each CLI adapter that takes resolved skills (`agent-adapter-claude` in claude-code,
`agent-adapter-copilot` in copilot). It is one file now, `src/common/dcf-skills.sh`: the split of an
agent's view into the CLI's personal skills folder (what every agent's view has alike) and the
agent's own folder (read through `--add-dir`), the modes `split`, `shared` and `off`, forget, the
owned-copy marker `.component-registry`, `skills-show`, the `--add-dir` argument and the start line.
What differs per CLI stays in the adapter as settings: `SK_CLI` (the word its lines start with),
`SK_OWN` (`.claude/skills`, `.github/skills`), `sk_home` (`CLAUDE_CONFIG_DIR`, `COPILOT_HOME`) and
three hooks for the CLI's own words (`sk_reload_note`, `sk_handover_clash`, `sk_start_clash`).

Unlike the other two helpers it is neither installed nor a file beside the adapter: an adapter is
installed and tested as one file, so each carries the helper verbatim **inside** it, between a line
`# >>> dcf-skills.sh: ...` and a line `# <<< dcf-skills.sh <<<`. `task common:sync` rewrites what
is between them, and `task common:check` (part of `task lint`) fails when it differs from this file
or the markers are not there once each. A third CLI adapter adds the markers and its settings.
`test/common/unit/dcf_skills_test.sh` runs it alone with a made-up vendor's settings.

## Why copies rather than a dependency

Every Feature that needs `dcf-persist`, `dcf-curl` or `dcf-skills` carries a verbatim copy of
`src/common/dcf-persist.sh`, `src/common/dcf-curl.sh` or `src/common/dcf-skills.sh` (the first
installed, the second sourced, the third inside the adapter script) rather than declaring
`dependsOn` on this Feature: `devcontainer features test` cannot resolve a
`dependsOn` on an OCI reference that has not been published yet, so the
Features could not be tested before the first release, and the official
`devcontainers/features` avoid cross-Feature dependencies for the same
reason. This Feature is the canonical source; `task lint` checks that every
copy is identical to it.
