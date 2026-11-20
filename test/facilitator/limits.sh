#!/bin/bash
# Scenario 'limits' (see scenarios.json): the limit options are installed as the variables the command reads,
# a variable of the same name wins (NFR-6), and dirOnlineCheck puts the OASF schema server in the Directory's
# config.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

o=/opt/facilitator/lib/options.env
check "hopLimit" grep -q '^FACILITATOR_HOP_LIMIT=3$' "$o"
check "messageBudget" grep -q '^FACILITATOR_MESSAGE_BUDGET=12$' "$o"
check "rateLimit" grep -q '^FACILITATOR_RATE_LIMIT=5$' "$o"
check "receiveWaitSeconds" grep -q '^FACILITATOR_RECEIVE_WAIT_SECONDS=60$' "$o"
check "staleSeconds" grep -q '^FACILITATOR_STALE_SECONDS=120$' "$o"
check "facilitatorBudget" grep -q '^FACILITATOR_BUDGET=4$' "$o"
check "dirOnlineCheck" grep -q '^FACILITATOR_DIR_ONLINE_CHECK=true$' "$o"
check "infra up" facilitator infra up
check "the online schema check is in the Directory's config" grep -q 'schema.oasf.outshift.com' "$FACILITATOR_HOME/dir/daemon.config.yaml"
check "infra down" facilitator infra down

reportResults
