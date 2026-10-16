#!/bin/bash
# Auto-generated scenario: the az Feature alone with default options on the
# base image. There is no az here by design (this Feature installs none; its
# install.sh warns instead of failing), so this checks only the pieces. The
# 'azure_cli' scenario covers the real thing with the official Feature.
# Run with:
#   devcontainer features test -f az --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "az present or absent is reported" bash -c "command -v az || echo 'az absent (expected without the azure-cli Feature)'"
check "AZURE_CONFIG_DIR set" bash -c "[ \"\$AZURE_CONFIG_DIR\" = /var/lib/devcontainer-features/az ]"
check "dcf-persist on PATH" command -v dcf-persist
check "az-setup on PATH" command -v az-setup
check "options baked for az-setup" grep -q '^BICEPFROMPATH=true$' /usr/local/share/az-feature/options.env
check "az-setup reports the state dir" bash -c "az-setup | grep -E '^az: /var/lib/devcontainer-features/az \((volume|bind|image), writable\)$'"
check "az-setup exits 0 without az" bash -c "az-setup >/dev/null 2>&1"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/az.yml

reportResults
