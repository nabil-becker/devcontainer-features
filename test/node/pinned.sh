#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "requested Node.js version" test "$(node --version)" = "v22.23.3"
check "npm works" npm --version

reportResults
