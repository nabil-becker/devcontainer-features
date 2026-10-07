#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

venv_dir="$(mktemp -d)"
trap 'rm -rf "$venv_dir"' EXIT
check "runs as non-root" test "$(id -u)" -ne 0
check "Node.js available to non-root" node --version
check "npm available to non-root" npm --version
check "Python available to non-root" python3 --version
check "non-root can create a venv" python3 -m venv "$venv_dir"
check "non-root venv pip" "$venv_dir/bin/python" -m pip --version

reportResults
