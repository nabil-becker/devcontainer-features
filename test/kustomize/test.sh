#!/bin/bash
# Auto-generated scenario: the kustomize Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f kustomize --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "kustomize is on PATH" command -v kustomize
check "kustomize reports a version" bash -c "kustomize version | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v kustomize)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/kustomize.yml

reportResults
