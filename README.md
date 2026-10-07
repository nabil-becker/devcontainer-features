# Dev Container Features

An MIT-licensed monorepo of reusable [Dev Container Features](https://containers.dev/features)
for development containers and GitHub Codespaces.

## Features

| Feature | Description | Documentation |
| --- | --- | --- |
| `node` | Exact Node.js release with bundled npm; amd64 and arm64 | [Node.js](src/node/README.md) |
| `python` | Distribution-managed Python 3, venv, and optional pip | [Python](src/python/README.md) |

The examples target Debian 12+ and Ubuntu 22.04+ (glibc-based images).
Alpine, Windows containers, and end-of-life distributions are not supported.
CI covers Debian 12 and Ubuntu 24.04 on amd64; arm64 requires a matching Docker host.

## Usage

After the initial publication, add these entries to `.devcontainer/devcontainer.json`:

```json
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/node:0.1": {
      "version": "24.21.0"
    },
    "ghcr.io/nabil-becker/devcontainer-features/python:0.1": {
      "installPip": true
    }
  }
}
```

Rebuild the container, then run `node --version`, `npm --version`, and
`python3 --version`. For Python dependencies, use a virtual environment:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install requests
```

Feature tags select the **feature package**, not the language runtime. Each
feature has its own semantic version in `devcontainer-feature.json`. Publishing
creates full-version, minor, major, and `latest` OCI tags; use an exact feature
version (or digest) for reproducibility. Before 1.0, prefer `:0.1` over `:0`.
Node's `version` selects an exact runtime; Python's version follows the base
distribution and its security updates.

## Development and releases

- [Contributing](CONTRIBUTING.md): structure, workflow, and branch protection
- [Testing](test/README.md): local and CI commands
- [Changelog](CHANGELOG.md): release history
- [License](LICENSE): MIT
- [Feature specification](https://containers.dev/implementors/features/)
- [Publishing specification](https://containers.dev/implementors/features-distribution/)

The repository's development container builds the local feature installers, so
it works before the first GHCR publication. Release publishing is manual, restricted to `main`,
and uses `GITHUB_TOKEN`; no personal access token is needed. A maintainer must
run the **Release features** workflow after merging and make both GHCR packages
public in their package settings. Publication is not performed by opening a PR.
