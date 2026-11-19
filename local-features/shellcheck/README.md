# shellcheck (local Feature)

Used by this repository's devcontainer and its CI config (`.devcontainer/devcontainer.json`,
`.devcontainer/ci/devcontainer.json`); not published. Installs shellcheck from its release asset
and verifies it against a SHA-256 pinned in `install.sh` (NFR-3), so the install never calls the
GitHub API, whose unauthenticated rate limit failed the `ghcr.io/devcontainers-extra` Feature on a
shared CI runner.

| Option | Default | |
| --- | --- | --- |
| `version` | `0.11.0` | must have a checksum in `install.sh` |

To bump, add the new version's two checksums to `install.sh` and change `version` in both
devcontainer configs; `task lint:toolchain` fails if the table lacks the pinned version.
