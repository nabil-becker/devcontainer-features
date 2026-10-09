#!/bin/bash
# Auto-generated scenario: devcontainer-cli with default options. Run with:
#   devcontainer features test -f devcontainer-cli --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "devcontainer on PATH" command -v devcontainer
check "devcontainer runs" bash -c "devcontainer --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
check "private node present" test -x /opt/devcontainer-cli/node/bin/node
check "node not on PATH" bash -c "! command -v node"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/devcontainer-cli.yml

reportResults
