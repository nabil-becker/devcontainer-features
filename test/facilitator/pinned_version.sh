#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): bundleVersion 0.3.0, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "runs as non-root" bash -c "[ \"\$(id -u)\" != 0 ]"
check "the bundle 0.3.0" bash -c 'facilitator version --json | grep -q "\"bundle\": \"0.3.0 linux-"'
check "the bundle's manifest" grep -q '"version": "0.3.0"' /opt/facilitator/MANIFEST.json
check "dirctl v1.9.1 exactly" bash -c 'facilitator version --json | grep -q "\"dirctl\": \"1.9.1\""'
check "slimctl 3.4.6 exactly" bash -c 'facilitator version --json | grep -q "\"slimctl\": \"3.4.6\""'
check "the state volume is the user's" test -w "$FACILITATOR_HOME"
check "the facilitator's key was made at setup" test -f "$FACILITATOR_HOME/keys/facilitator.pub"
check "autostart ran infra up as the user" bash -c 'facilitator infra status'
check "check is ready" facilitator check
check "infra down" facilitator infra down

reportResults
