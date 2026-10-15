#!/bin/bash
# Scenario 'bicep_off' (see scenarios.json): bicepFromPath=false with the
# official azure-cli Feature (bicep installed), remoteUser=vscode. az-setup
# leaves the bicep setting alone.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "option baked" grep -q '^BICEPFROMPATH=false$' /usr/local/share/az-feature/options.env
check "bicep is on PATH" command -v bicep
check "az-setup reports the setting as not configured" bash -c "az-setup | grep -qF 'bicep.use_binary_from_path not configured'"
check "bicep.use_binary_from_path is unset" bash -c "! az config get bicep.use_binary_from_path --only-show-errors >/dev/null 2>&1"
check "env override turns it on without a rebuild" bash -c "AZ_SETUP_BICEP_FROM_PATH=true az-setup | grep -qF 'bicep.use_binary_from_path=true' && [ \"\$(az config get bicep.use_binary_from_path --query value -o tsv --only-show-errors)\" = true ]"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && az version --only-show-errors >/dev/null'

reportResults
