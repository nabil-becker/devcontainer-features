#!/bin/bash
# Auto-generated scenario: the coder-cli Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f coder-cli --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "coder is on PATH" command -v coder
check "coder reports a version" bash -c "coder version | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v coder)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/coder-cli.yml

reportResults
