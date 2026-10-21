#!/bin/bash
# Auto-generated scenario: the az Feature alone with default options on the
# base image, as a repo that lists only az:1 gets it. The dependsOn on the
# official azure-cli Feature (installBicep) must bring az and bicep in.
# Run with:
#   devcontainer features test -f az --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "az is on PATH (from dependsOn)" command -v az
check "bicep is on PATH (installBicep in dependsOn)" command -v bicep
check "AZURE_CONFIG_DIR set" bash -c "[ \"\$AZURE_CONFIG_DIR\" = /var/lib/devcontainer-features/az ]"
check "dcf-persist on PATH" command -v dcf-persist
check "az-setup on PATH" command -v az-setup
check "options baked for az-setup" grep -q '^BICEPFROMPATH=true$' /usr/local/share/az-feature/options.env
check "az-setup reports the state dir" bash -c "az-setup | grep -E '^az: /var/lib/devcontainer-features/az \((volume|bind|image), writable\)$'"
check "az-setup reports the version" bash -c "az-setup | grep -E '^az: azure-cli [0-9]+\\.[0-9]+\\.[0-9]+ at '"
check "az-setup sets bicep.use_binary_from_path" bash -c "az-setup | grep -E 'bicep.use_binary_from_path=true .*(set|kept)'"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/az.yml

reportResults
