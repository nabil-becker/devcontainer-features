#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

venv_dir="$(mktemp -d)"
trap 'rm -rf "$venv_dir"' EXIT
check "Python 3 available" python3 --version
check "pip available" python3 -m pip --version
check "standard library modules" python3 -c 'import ssl, sqlite3, bz2, lzma, ctypes'
check "TLS trust store" python3 -c 'import ssl; assert ssl.create_default_context().cert_store_stats()["x509_ca"] > 0'
check "create virtual environment" python3 -m venv "$venv_dir"
check "virtual environment pip" "$venv_dir/bin/python" -m pip --version
check "virtual environment is isolated" "$venv_dir/bin/python" -c 'import sys; assert sys.prefix != sys.base_prefix'

reportResults
