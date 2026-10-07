#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "Python after repeated installation" python3 --version
check "pip after repeated installation" python3 -m pip --version

reportResults
