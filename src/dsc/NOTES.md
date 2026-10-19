## What it installs

The Microsoft DSC v3 release from `github.com/PowerShell/DSC`, installed
whole into `/opt/dsc` (replaced on every install: `install.sh` removes the
folder first). `dsc` also gets a symlink at `/usr/local/bin/dsc`, and the
Feature prepends `/opt/dsc` to `PATH` through `containerEnv`, because DSC
discovers its bundled resource manifests (and the PowerShell adapter) next to
its own binary. Do not move the binary out on its own. `install.sh` downloads
`DSC-<version>-<arch>-linux.tar.gz`, checks it against a sha256 digest
(see Verification), extracts it, and runs `dsc --version` at the end.

- `version` takes a number with or without a leading `v` (`3.3.0`,
  `v3.3.0`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` fails the build.

## Options

- `version` (default `latest`): change it to the DSC version your
  configurations are written against. A value that does not start with an
  `x.y.z` number fails the build. Versions in `digests.txt` (3.3.0 and 3.1.3
  today, both architectures) need no network lookup for their digest.
- `sha256` (default empty): set it to pin the tarball digest yourself, for a
  version that `digests.txt` does not list, or to skip the release-page
  lookup. It is per platform (the x86_64 and aarch64 tarballs differ), so a
  value copied from one architecture fails the check on the other.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/dsc.yml` in the image.

There is no run-time override; the version is fixed at build.

## Verification

DSC releases do not ship a checksums file, but GitHub records a sha256 digest
for every release asset. The Feature never calls the GitHub API (its
unauthenticated limit of 60 requests per hour per IP is exhausted by CI
matrices, and a Feature build receives no `GITHUB_TOKEN`). The tarball is
verified against the first digest found in this order:

1. the `sha256` option;
2. `digests.txt` in the Feature, which pins the linux tarballs of known
   versions (no network lookup at all);
3. the digest shown on the release page
   (`github.com/PowerShell/DSC/releases/expanded_assets/v<version>`), for
   versions not pinned. This step reads the page's HTML, so a change to
   GitHub's markup breaks it; that is why `sha256` exists.

If none yields a digest, or the value is not 64 hex characters, the install
fails; it never installs unverified. Pin the digest yourself to skip step 3:

```json
"ghcr.io/nabil-becker/devcontainer-features/dsc:1": {
  "version": "3.3.0",
  "sha256": "cf17d1a130b65332ec65380ee9368133101d13d8f40c1a501038920b1e9cd748"
}
```

(That example is the x86_64 tarball.)

To add a version to `digests.txt` (maintainers; check the digests against the
release page, then bump the Feature `version`):

```bash
v=3.4.0; for a in x86_64 aarch64; do n=DSC-$v-$a-linux.tar.gz
  d=$(curl -fsSL https://github.com/PowerShell/DSC/releases/expanded_assets/v$v |
    grep -oE "digest for ${n//./\\.}\"[^>]*value=\"sha256:[0-9a-f]{64}" | grep -oE '[0-9a-f]{64}$')
  echo "$d  $n"; done
```

## State

No state: installs a program tree only. No volume, no post-create hook, no
credentials. The one `containerEnv` entry is the `PATH` prefix `/opt/dsc`.
DSC itself holds no state between runs; `dsc config set` changes the
container it runs in (see Tasks).

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/dsc:1": {
    "version": "3.3.0"
  }
}
```

Drop the `version` line to follow the newest release at each image build;
for a version not in `digests.txt` that relies on the release-page lookup.

## Verify it works

```bash
dsc --version
task dsc:version
dsc resource list | head      # the bundled resources are discovered
```

The build log carries `dsc: downloading DSC v<version> (DSC-<version>-<arch>-linux.tar.gz)...`,
`sha256sum`'s `OK` line, then the `dsc --version` output. A wrong digest
stops the build with `sha256sum`'s `FAILED` line; no digest found stops it
with `no digest for <asset> in digests.txt or on the release page`. There is
no post-create line: nothing runs after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed), the official
  `common-utils` and the official `powershell`.
- Pairs with `ghcr.io/devcontainers/features/powershell`: the
  `Microsoft.DSC/PowerShell` adapter and the
  `Microsoft.DSC.Transitional/PowerShellScript` resource run `pwsh`, which
  DSC does not install. Without it those resources fail; the bundled native
  resources do not need it.
- It augments no official Feature and replaces none.
- Independent of `kube-state`: no cluster is contacted.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `dsc:`. `CONFIG` is the path to a DSC v3
configuration document (YAML or JSON), relative to where you run `task`;
extra flags go after `--`.

- `dsc:version`: show the installed version.
- `dsc:resources`: list the discoverable resources.
- `dsc:get`: read the current state described by `CONFIG` (changes nothing).
- `dsc:test`: report whether the system matches `CONFIG` (`inDesiredState`
  per resource; changes nothing).
- `dsc:set`: converge the system to `CONFIG`. This changes the container;
  read `dsc:test` first.

## Limits and troubleshooting

- Linux only, on the two architectures above (no `armv7`); others fail with
  `unsupported architecture`.
- `could not resolve a DSC version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- `no digest for ... Set the sha256 option explicitly`: the version is not in
  `digests.txt` and the release page did not show a digest (network, or
  GitHub's page changed). Set `sha256`.
- `/opt/dsc` is replaced on every install; anything you put there is lost at
  the next rebuild.
- Tested (`test/dsc`): the binary is on PATH, runs and is root-owned (default
  and 3.3.0, non-root user), the Taskfile lands in `includes.d` and is absent
  with `installTaskfile: false`, and the global scenario lists resources and
  runs `dsc:version` through the registry. Not tested: the `sha256` option,
  the release-page fallback on a pinned-by-nobody version (only incidentally,
  when `latest` is newer than `digests.txt`), a failed digest, the PowerShell
  adapter, and the `get`/`test`/`set` tasks.

## Why this one exists

No published Dev Container Feature for DSC v3 is known to this repository,
so there is no alternative to compare.
