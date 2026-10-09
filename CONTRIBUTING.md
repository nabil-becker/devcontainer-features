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

1. Fork, branch from `main`, and run `task repo:setup` once in the clone
   (see "Sign your work" below).
2. Make the change; run `task lint` and, on Linux/macOS or inside the
   workbench devcontainer, `task test FEATURE=<id>`.
3. Open a pull request using the template. CI (`validate`, `lint`, `tests`,
   `DCO`) must pass and a code owner must approve; `main` only accepts
   squash merges through pull requests.
4. A maintainer runs the release workflow, which publishes to
   `ghcr.io/nabil-becker/devcontainer-features/<id>` and regenerates docs.

## Sign your work (DCO)

Every commit must carry a `Signed-off-by: Your Name <you@example.com>`
trailer. By adding it you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/):
that you wrote the change or otherwise have the right to submit it under
this project's MIT license. The `DCO` check on each pull request enforces
it; no CLA, no separate signing.

You should not have to think about it:

- `task repo:setup` activates the tracked [`.gitconfig`](.gitconfig) for
  your clone (`git config --local include.path ../.gitconfig`). That turns
  on the repo hook `.githooks/prepare-commit-msg`, which adds the trailer to
  every commit automatically, and defines `git cs` as `commit -s`. Only
  this clone's `.git/config` is touched, never your global git config.
- VS Code's Source Control view signs off too
  ([`.vscode/settings.json`](.vscode/settings.json) sets `git.alwaysSignOff`).
- Edits made in the GitHub web editor are signed off by the repository
  setting.

Forgot one? `git commit --amend -s` (or `git rebase --signoff main` for a
whole branch) and force-push your branch.

## AI-assisted contributions

This project is maintained with AI assistance (Claude Code co-authors
commits), and AI-assisted contributions are welcome under the same terms as
any other:

- **You are the author.** You must understand, test and be able to explain
  every line you submit, and your sign-off certifies you have the right to
  contribute it. "The model wrote it" is not an answer in review.
- **Say so.** Add a `Co-Authored-By:` trailer or a sentence in the PR when a
  model produced a substantial part of the change.
- **Quality bar is unchanged.** Unsolicited bulk or low-effort generated
  pull requests, issues or reviews will be closed without discussion.
- **Security reports need a reproduction.** A model's guess that something
  might be vulnerable is not a report; see [SECURITY.md](SECURITY.md).

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
