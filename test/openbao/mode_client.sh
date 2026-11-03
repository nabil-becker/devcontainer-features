#!/bin/bash
# Scenario 'mode_client' (see scenarios.json): mode=client given explicitly, and the run-time twin
# OPENBAO_SETUP_MODE for a mode this version does not have.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "mode baked as client" grep -q '^MODE=client$' /usr/local/share/openbao-feature/options.env
check "openbao-setup says client" bash -c "openbao-setup | grep -F 'mode client'"
check "OPENBAO_SETUP_MODE=server is reported and runs as client" bash -c "OPENBAO_SETUP_MODE=server openbao-setup 2>&1 | grep -F \"mode 'server' is not available\""

reportResults
