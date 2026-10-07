#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

venv_dir="$(mktemp -d)"
trap 'rm -rf "$venv_dir"' EXIT
check "Python works without global pip" python3 --version
check "TLS trust store without global pip" python3 -c 'import ssl; assert ssl.create_default_context().cert_store_stats()["x509_ca"] > 0'
check "global pip not installed" bash -c '! python3 -m pip --version'
check "venv still supported" python3 -m venv "$venv_dir"
check "venv has its own pip" "$venv_dir/bin/python" -m pip --version

reportResults
