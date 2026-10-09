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
