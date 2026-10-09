# Contributing

Thanks for helping! This repository is a collection of [Dev Container
Features](https://containers.dev/implementors/features/) listed in the public
[containers.dev index](https://containers.dev/collections), so changes here
reach anyone who references them. The rules below keep that safe.

- **Questions / ideas:** open an [issue](https://github.com/nabil-becker/devcontainer-features/issues).
- **Bugs:** use the bug report template.
- **Security issues:** never in the issue tracker - see [SECURITY.md](SECURITY.md).

## Ground rules for Features

Every Feature in `src/<id>/` must:

1. Follow the [Feature specification](https://containers.dev/implementors/features/)
   and the [feature-starter](https://github.com/devcontainers/feature-starter)
   layout: `devcontainer-feature.json`, `install.sh`, `NOTES.md` (the README
   is generated on release - do not edit `src/<id>/README.md` by hand).
2. **Verify what it downloads.** Release artifacts are checked against the
   publisher's checksum file (or a pinned sha256). No piping unverified
   content into a shell.
3. **Pin by default, allow override.** A `version` option with a sensible
   default; `latest` resolved at build time is acceptable only when a
   checksum still protects the download.
4. **Be idempotent and root-safe.** `install.sh` runs as root under
   `set -euo pipefail`, must succeed when run twice, must not rely on a
   specific `remoteUser`, and cleans up apt lists and temp files.
5. **Not touch PATH with private toolchains.** Anything installed only to
   support the Feature (e.g. the Node.js behind `devcontainer-cli`) lives
   under `/opt/<feature>` and is reached through a wrapper.
6. **Have tests.** `test/<id>/test.sh` for the defaults plus `scenarios.json`
   covering every option. CI runs them on Debian and Ubuntu.
7. **Bump `version`** in `devcontainer-feature.json` per
   [semver](https://semver.org/) in the same PR as the change.

## Workflow

1. Fork, branch from `main`.
2. Make the change; run `task lint` and, on Linux/macOS or inside the
   workbench devcontainer, `task test FEATURE=<id>`.
3. Open a pull request using the template. CI (`validate`, `lint`, `tests`)
   must pass and a code owner must approve; `main` only accepts squash
   merges through pull requests.
4. A maintainer runs the release workflow, which publishes to
   `ghcr.io/nabil-becker/devcontainer-features/<id>` and regenerates docs.

## Proposing a new Feature

Open a "New Feature proposal" issue first. We accept Features that install
one well-defined tool from a trustworthy, checksummed source and that do not
already exist in [devcontainers/features](https://github.com/devcontainers/features).

## Code style

- Shell: bash, `shellcheck`-clean, 2-space indent, `set -euo pipefail`.
- PowerShell: PowerShell 7, `PSScriptAnalyzer`-clean, comment-based help.
- Host-side tooling ships in two flavours that must stay in step:
  `taskfiles/devcontainer/*.ps*1` + `bootstrap.ps1` (Windows, primary) and
  `taskfiles/devcontainer/devcontainer-cli.sh` + `bootstrap.sh`
  (Linux/macOS). A behaviour or setting added to one goes into the other in
  the same PR, with the same `DEVCONTAINER_*` variable name.
- Keep comments to the *why*; the code says the *what*.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
