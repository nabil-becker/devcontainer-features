#!/bin/bash
# Scenario 'with_gh' (see scenarios.json): gh (installsAfter target) and copilot together. Both
# state volumes are there and separate, and gh's login variable is not touched by this Feature.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "gh is on PATH" command -v gh
check "copilot is on PATH" command -v copilot
check "two different state dirs" bash -c "[ \"\$GH_CONFIG_DIR\" != \"\$COPILOT_HOME\" ] && [ -d \"\$GH_CONFIG_DIR\" ] && [ -d \"\$COPILOT_HOME\" ]"
check "this Feature sets no GH_TOKEN or GITHUB_TOKEN" bash -c "! grep -q -E 'GH_TOKEN|GITHUB_TOKEN' /usr/local/share/copilot-feature/options.env"
check "setup reports no token (none is set by a Feature)" bash -c "env -u COPILOT_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN copilot-setup | grep -q 'no token in the environment'"

reportResults
