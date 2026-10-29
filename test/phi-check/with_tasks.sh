#!/bin/bash
# Scenario 'with_tasks' (see scenarios.json): go-task and phi-check, remoteUser=vscode. The Feature's
# tasks run as the non-root user through the registry, in the folder task was started from.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

ssn="$(printf '%s-%s-%s' 123 45 6789)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
registry=/usr/local/share/go-task/features.yml

echo "nothing to see" > "$work/clean.txt"
printf 'SSN: %s\n' "$ssn" > "$work/dirty.txt"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && phi-check --version >/dev/null'
check "phi-check:version runs" task -t "$registry" phi-check:version
check "phi-check:check passes a clean file" bash -c "cd '$work' && task -t $registry phi-check:check FILE=clean.txt | grep -q 'phi-check: clean'"
check "phi-check:check fails a dirty file" bash -c "cd '$work' && ! task -t $registry phi-check:check FILE=dirty.txt >/dev/null 2>&1"
check "phi-check:check passes options after --" bash -c "cd '$work' && task -t $registry phi-check:check FILE=dirty.txt -- --format json 2>/dev/null | grep -q '\"clean\": false'"
check "phi-check:check needs FILE" bash -c "cd '$work' && ! task -t $registry phi-check:check >/dev/null 2>&1"

reportResults
