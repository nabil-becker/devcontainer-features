#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "Node.js default version" test "$(node --version)" = "v24.21.0"
check "npm available" npm --version
check "Node.js executes JavaScript" node -e 'if (2 + 2 !== 4) process.exit(1)'
check "global modules readable" test -r /usr/local/share/devcontainer-node/current/lib/node_modules/npm/package.json

reportResults
