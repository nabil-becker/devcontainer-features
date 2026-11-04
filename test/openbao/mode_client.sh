#!/bin/bash
# Scenario 'mode_client' (see scenarios.json): mode=client given explicitly, the run-time twin
# OPENBAO_SETUP_MODE for a mode the Feature does not have, and that client mode runs no server.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "mode baked as client" grep -q '^MODE=client$' /usr/local/share/openbao-feature/options.env
check "openbao-setup says client" bash -c "openbao-setup | grep -F 'mode client'"
check "an unknown OPENBAO_SETUP_MODE is reported and runs as client" bash -c "OPENBAO_SETUP_MODE=sideways openbao-setup 2>&1 | grep -F \"mode 'sideways' is not known\""
check "the start hook does nothing in client mode (no config, no server)" bash -c "openbao-setup start && [ ! -e \"\$OPENBAO_STATE_DIR/server.hcl\" ] && ! pgrep -x bao"
check "the server-mode tasks say they are for server mode " bash -c "openbao-server unseal </dev/null 2>&1 | grep -F 'this container runs no server'"
check "dcf-secret keeps the client-mode address default (BAO_ADDR stays unset)" bash -c "env -u BAO_ADDR bash -c '. /usr/local/share/openbao-feature/env.sh; [ -z \"\${BAO_ADDR:-}\" ]'"

reportResults
