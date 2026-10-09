#!/bin/bash
# Auto-generated scenario: the velero Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f velero --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "velero is on PATH" command -v velero
check "velero reports a version" bash -c "velero version --client-only | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v velero)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/velero.yml

reportResults
