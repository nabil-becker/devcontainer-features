
# Microsoft DSC v3 (dsc)

Installs Microsoft Desired State Configuration v3 (https://github.com/PowerShell/DSC) whole into /opt/dsc (dsc discovers its bundled resources from its own directory on PATH) and verifies the release tarball against the sha256 digest GitHub publishes for the asset, or a digest you pin via the sha256 option. The PowerShell adapter resources need pwsh (ghcr.io/devcontainers/features/powershell).

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
| sha256 | Expected sha256 of the release tarball for this platform. When empty, the digest is read from the GitHub Releases API (set GITHUB_TOKEN in the build environment to avoid the unauthenticated rate limit). | string | - |

## Layout

The whole release lands in `/opt/dsc`, which the Feature prepends to `PATH`
(`dsc` also gets a symlink in `/usr/local/bin`). DSC discovers its bundled
resources from that folder, so do not move the binary out on its own.

The `Microsoft.DSC/PowerShell` adapter and the
`Microsoft.DSC.Transitional/PowerShellScript` resource run `pwsh`; add
`ghcr.io/devcontainers/features/powershell` if you use them.

## Verification

DSC releases do not ship a checksums file. GitHub computes a sha256 digest
for every uploaded release asset and returns it from the Releases API; the
Feature reads that digest for the exact tarball it downloads and verifies
against it. The unauthenticated API allows 60 requests per hour per IP; in
busy CI set `GITHUB_TOKEN` in the build environment, or pin the digest
yourself:

```json
"ghcr.io/nabil-becker/devcontainer-features/dsc:1": {
  "version": "3.3.0",
  "sha256": "cf17d1a130b65332ec65380ee9368133101d13d8f40c1a501038920b1e9cd748"
}
```

(`sha256` is per platform: that example is the x86_64 tarball.)


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/dsc/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
