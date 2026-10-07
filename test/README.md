# Testing

Tests use Bash and the official Dev Container CLI's
`dev-container-features-test-lib` (`check` and `reportResults`), not BATS.
The CLI supplies this library inside test containers; do not run assertion
scripts directly on your host.

## Prerequisites

- Docker Engine running with Linux containers and permission to use it
- Node.js 20+ and npm
- Bash and ShellCheck (provided on the CI runner)
- Network access to base-image registries, apt repositories, and nodejs.org

Install the same CLI version used in CI:

```sh
npm install --global @devcontainers/cli@0.89.0
```

Run commands from the repository root. For a focused default-option test:

```sh
devcontainer features test --project-folder . --features node \
  --base-image debian:12 --skip-scenarios --skip-duplicated
```

Run a feature's defaults, option scenarios, and repeated-installation tests:

```sh
devcontainer features test --project-folder . --features python \
  --base-image ubuntu:24.04
```

Run the CI matrix and combined non-root scenario:

```sh
for image in debian:12 ubuntu:24.04; do
  for feature in node python; do
    devcontainer features test --project-folder . --features "$feature" \
      --base-image "$image"
  done
done
devcontainer features test --project-folder . --global-scenarios-only
```

Scenarios use the image and user defined in their JSON, not the CLI's
`--base-image`. Run arm64 tests on an arm64 Docker host when changing the Node
architecture path. CI currently runs amd64 only.

Static checks and packaging:

```sh
for script in src/*/install.sh test/*/*.sh; do bash -n "$script"; done
shellcheck --exclude=SC1091 src/*/install.sh test/*/*.sh
devcontainer features package ./src --output-folder /tmp/devcontainer-feature-packages
```

`SC1091` is excluded because the test library and `/etc/os-release` are supplied
by the container, not this repository. CI syntax-checks every shell script.
The packaging command validates feature metadata and creates OCI-ready archives
without publishing. Test containers/images consume disk; use Docker's normal
cleanup commands after testing, taking care not to remove unrelated containers.

## Adding tests

Place default assertions in `test/<id>/test.sh`, repeat-install assertions in
`duplicate.sh`, and option configurations in `scenarios.json` with a matching
`<scenario>.sh`. Use `test/_global` for cross-feature tests. Tests must return
nonzero on failures; always finish with `reportResults`. Include smoke tests
for installed tools, requested options, and non-root access.
