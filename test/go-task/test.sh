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

check "go-task:version runs and prints the version" bash -c "task -t /usr/local/share/go-task/includes.d/go-task.yml version | grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+'"

# taskAliases is off by default: no generator, no yq, nothing included, the task says so
check "aliases off: no task-aliases command" bash -c "! command -v task-aliases"
check "aliases off: features.yml includes no alias Taskfile" bash -c "! grep -q task-aliases /usr/local/share/go-task/features.yml"
check "aliases off: go-task:aliases refuses and names the option" bash -c "task -t /usr/local/share/go-task/includes.d/go-task.yml aliases 2>&1 | grep -F taskAliases"

reportResults
