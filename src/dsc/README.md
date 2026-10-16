
# Microsoft DSC v3 (dsc)

Installs Microsoft Desired State Configuration v3 (https://github.com/PowerShell/DSC) whole into /opt/dsc (dsc discovers its bundled resources from its own directory on PATH) and verifies the release tarball against a sha256 digest pinned in the Feature, read from the release page, or set via the sha256 option (the GitHub API is never called). The PowerShell adapter resources need pwsh (ghcr.io/devcontainers/features/powershell).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/dsc:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | DSC release to install (e.g. '3.3.0', with or without a leading 'v'), or 'latest'. | string | latest |
| sha256 | Expected sha256 of the release tarball for this platform. When empty, the digest comes from the Feature's pinned list (digests.txt) or, for other versions, from the release page on github.com. | string | - |

## Layout

The whole release lands in `/opt/dsc`, which the Feature prepends to `PATH`
(`dsc` also gets a symlink in `/usr/local/bin`). DSC discovers its bundled
resources from that folder, so do not move the binary out on its own.

The `Microsoft.DSC/PowerShell` adapter and the
`Microsoft.DSC.Transitional/PowerShellScript` resource run `pwsh`; add
`ghcr.io/devcontainers/features/powershell` if you use them.

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
   versions not pinned.

If none yields a digest the install fails; it never installs unverified.
Pin the digest yourself to skip step 3:

```json
"ghcr.io/nabil-becker/devcontainer-features/dsc:1": {
  "version": "3.3.0",
  "sha256": "cf17d1a130b65332ec65380ee9368133101d13d8f40c1a501038920b1e9cd748"
}
```

(`sha256` is per platform: that example is the x86_64 tarball.)

To add a version to `digests.txt` (maintainers; check the digests against the
release page, then bump the Feature `version`):

```bash
v=3.4.0; for a in x86_64 aarch64; do n=DSC-$v-$a-linux.tar.gz
  d=$(curl -fsSL https://github.com/PowerShell/DSC/releases/expanded_assets/v$v |
    grep -oE "digest for ${n//./\\.}\"[^>]*value=\"sha256:[0-9a-f]{64}" | grep -oE '[0-9a-f]{64}

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/dsc/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
)
  echo "$d  $n"; done
```


---

_Note: This file was auto-generated from the [devcontainer-feature.json](#{RepoUrl}).  Add additional notes to a `NOTES.md`._
