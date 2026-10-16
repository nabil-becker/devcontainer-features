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
    grep -oE "digest for ${n//./\\.}\"[^>]*value=\"sha256:[0-9a-f]{64}" | grep -oE '[0-9a-f]{64}$')
  echo "$d  $n"; done
```
