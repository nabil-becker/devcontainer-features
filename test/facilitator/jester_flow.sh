#!/bin/bash
# Scenario 'jester_flow' (see scenarios.json): the integration test on the real Directory and SLIM, in the
# container: two fake agents through facilitator mcp, the human's "@jester tell @domain-expert-one a joke",
# the five messages routed by the rules (every mention delivered) over SLIM, verify on the chain (integration/jester_flow.py; it uses
# its own state folder and ports, and stops what it started).
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

here="$(cd "$(dirname "$0")" && pwd)"
check "the jester flow end to end, verified" /opt/facilitator/python/bin/python3 -I "$here/integration/jester_flow.py"

reportResults
