#!/bin/bash
# Scenario 'autostart_off' (see scenarios.json): autostart false: the container starts with nothing running;
# infra up starts it by hand, and down stops it.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the option as installed" grep -q '^FACILITATOR_AUTOSTART=false$' /opt/facilitator/lib/options.env
check "nothing started at container start" bash -c '! facilitator infra status >/dev/null'
check "infra up by hand" facilitator infra up
check "check is ready" facilitator check
check "infra down" facilitator infra down

reportResults
