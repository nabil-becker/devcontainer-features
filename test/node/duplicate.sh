#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "Node.js after repeated installation" node --version
check "npm after repeated installation" npm --version

reportResults
