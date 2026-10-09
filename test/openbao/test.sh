#!/bin/bash
# Auto-generated scenario: the openbao Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f openbao --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "bao is on PATH" command -v bao
check "bao reports a version" bash -c "bao version | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v bao)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/openbao.yml

reportResults
