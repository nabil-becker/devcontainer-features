#!/bin/bash
# Auto-generated scenario: the kubeconform Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f kubeconform --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "kubeconform is on PATH" command -v kubeconform
check "kubeconform reports a version" bash -c "kubeconform -v | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v kubeconform)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/kubeconform.yml

reportResults
