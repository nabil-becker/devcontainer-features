#!/bin/bash
# Scenario 'deprecated_versions' (see scenarios.json): dirVersion 1.9.1 and slimVersion latest, deprecated in
# 0.3.0 in favour of bundleVersion, still accepted (the bundle carries those versions), with a one-line notice
# from version and check on stderr (CONTRIBUTING's deprecation rule).
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "recorded as deprecated" grep -q '^FACILITATOR_DEPRECATED=dirVersion slimVersion$' /opt/facilitator/lib/options.env
check "version says so on stderr" bash -c 'facilitator version 2>&1 >/dev/null | grep -q "dirVersion is deprecated: use bundleVersion"'
check "check says so on stderr" bash -c 'facilitator check 2>&1 >/dev/null | grep -q "slimVersion is deprecated: use bundleVersion"'
check "dirctl 1.9.1 all the same" bash -c 'facilitator version --json 2>/dev/null | grep -q "\"dirctl\": \"1.9.1\""'
check "check is ready" facilitator check
check "infra down" facilitator infra down

reportResults
