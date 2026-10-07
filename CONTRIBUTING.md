# Contributing

Bug reports, documentation improvements, and pull requests are welcome.
Search existing issues first. Include the base image, architecture, feature
options, and a minimal reproduction; do not include credentials or private data.
Be respectful and constructive in discussions.

## Development workflow

1. Fork the repository and create a focused branch from `main`.
2. Open the repository in its development container, or install Docker, Bash,
   ShellCheck, Node.js 20+, and `@devcontainers/cli@0.89.0` locally.
3. Make the smallest complete change and run the checks in [test/README.md](test/README.md).
4. Update the affected feature README and changelog. Bump the affected feature's
   semantic version for a release; runtime versions and feature versions differ.
5. Submit a PR describing the behavior, tests run, and compatibility impact.

The development container mounts the host Docker socket. It grants host-level
Docker access: only open trusted code in it. On Windows/macOS, use Docker Desktop
with Linux containers. CI uses GitHub-hosted Ubuntu runners.
The checked-in feature lockfile pins the Docker helper feature; review lockfile
updates when changing development dependencies.

## Adding or modifying a feature

- Put self-contained files in `src/<id>/`: `devcontainer-feature.json`,
  executable `install.sh`, and `README.md`. Keep `id` equal to the directory name.
- Follow the [official schema](https://github.com/devcontainers/spec/blob/main/schemas/devContainerFeature.schema.json).
  Supply a name, description, semantic version, license/documentation links,
  and clearly described options. Options are passed as uppercase environment
  variables (for example, `installPip` becomes `INSTALLPIP`).
- Installers run as root at image build time. Validate inputs before downloads
  or mutations, fail on errors, use HTTPS and integrity checks for artifacts,
  avoid evaluating user input, and clean temporary files.
- Document supported distributions and architectures. Preserve system runtimes,
  avoid user-specific shell startup requirements, and ensure non-root users can
  run installed tools. Repeated installation must succeed.
- Keep packages minimal. Never embed credentials or disable TLS verification.
  Do not bypass Python's externally managed environment protection.
- Add `test/<id>/test.sh`, option scenarios with matching shell scripts, and
  `duplicate.sh` for repeat installation. Add a combined non-root scenario to
  `test/_global` where appropriate.
- Add the feature to the root README and CI matrix. Test default options,
  non-default options, supported images, and interactions with other features.
  For architecture-specific changes, test on that architecture before release.

## Releases

Feature versions are independent, starting at `0.1.0`. Maintainers review and
merge passing PRs, update metadata versions and the changelog, then dispatch
**Release features** on `main`. The workflow reruns tests before publishing the
collection to `ghcr.io/nabil-becker/devcontainer-features`. It does not modify
source files, generate documentation PRs, or create Git tags. OCI tags come from
each feature's metadata version; increment that version for changed packages.
Treat published versions as immutable.

The workflow needs Actions enabled and `packages: write` for `GITHUB_TOKEN`.
After the first release, set package visibility to public and verify anonymous
pulls. Existing packages may need this repository granted Actions access in
their package settings.

## Protecting main (repository administrator)

Branch protection cannot be enabled by committing a workflow. In **Settings →
Rules → Rulesets**, create an active branch ruleset targeting `main`:

- Require pull requests and at least one approval; dismiss stale approvals.
- Require status checks: `Static checks`, `Feature (node, debian:12)`,
  `Feature (node, ubuntu:24.04)`, `Feature (python, debian:12)`,
  `Feature (python, ubuntu:24.04)`, and `Combined non-root`.
- Require the branch to be up to date and conversations to be resolved.
- Block force pushes and deletions; do not grant routine bypass permissions.

Run CI once so the check names are selectable. These settings require
repository administration rights and must be applied separately. For a
single-maintainer repository, an approval requirement also requires a second
reviewer; choose that policy deliberately rather than silently bypassing it.
