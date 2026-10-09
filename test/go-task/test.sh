#!/bin/bash
# Auto-generated scenario: the go-task Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f go-task --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "task is on PATH" command -v task
check "task reports a version" bash -c "task --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
check "bash completion installed" test -f /etc/bash_completion.d/task

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/go-task.yml

reportResults
