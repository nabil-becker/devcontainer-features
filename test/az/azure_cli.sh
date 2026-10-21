#!/bin/bash
# Scenario 'azure_cli' (see scenarios.json): the repo also lists the
# official ghcr.io/devcontainers/features/azure-cli with the same options
# as this Feature's dependsOn (installBicep), so the CLI counts it once;
# remoteUser=vscode. The checks the default
# options need a real az for.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "az is on PATH" command -v az
check "bicep is on PATH" command -v bicep
check "AZURE_CONFIG_DIR set" bash -c "[ \"\$AZURE_CONFIG_DIR\" = /var/lib/devcontainer-features/az ]"
check "dcf-persist on PATH" command -v dcf-persist
check "az-setup on PATH" command -v az-setup
check "az-setup reports the state dir" bash -c "az-setup | grep -E '^az: /var/lib/devcontainer-features/az \((volume|bind|image), writable\)$'"
check "az-setup reports the version and login state" bash -c "az-setup | grep -E '^az: azure-cli [0-9]+\.[0-9]+\.[0-9]+ at ' && az-setup | grep -E '^az: (logged in|no login yet)'"
check "az-setup sets bicep.use_binary_from_path" bash -c "az-setup | grep -E 'bicep.use_binary_from_path=true .*(set|kept)' && [ \"\$(az config get bicep.use_binary_from_path --query value -o tsv --only-show-errors)\" = true ]"
check "second run keeps it" bash -c "az-setup | grep -F 'bicep.use_binary_from_path=true' | grep -qF 'kept'"
check "setting lives in AZURE_CONFIG_DIR" grep -q 'use_binary_from_path' /var/lib/devcontainer-features/az/config
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "az runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && az version --only-show-errors >/dev/null'
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/az.yml

reportResults
