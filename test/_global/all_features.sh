#!/bin/bash
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "task" task --version
check "claude" claude --version
check "devcontainer" devcontainer --version

reportResults
