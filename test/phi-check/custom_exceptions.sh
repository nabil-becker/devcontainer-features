#!/bin/bash
# Scenario 'custom_exceptions' (see scenarios.json): exceptions=fixtures/phi-ok.txt, remoteUser=vscode.
# The option is the default exceptions file; PHI_CHECK_EXCEPTIONS overrides it; --no-exceptions ignores it.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

ssn="$(printf '%s-%s-%s' 123 45 6789)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/fixtures"
printf 'SSN: %s\n' "$ssn" > "$work/fixtures/synthetic.txt"
printf 'SSN: %s\n' "$ssn" > "$work/other.txt"
echo "fixtures/synthetic.txt 2026-10-29 synthetic fixture" > "$work/fixtures/phi-ok.txt"

check "option baked" grep -qx 'fixtures/phi-ok.txt' /usr/local/share/phi-check/exceptions-default
check "the default exceptions file skips its listed path" bash -c "cd '$work' && phi-check fixtures/synthetic.txt | grep -q 'skipped fixtures/synthetic.txt'"
check "an unlisted path is still refused" bash -c "cd '$work' && ! phi-check other.txt >/dev/null"
check "--no-exceptions ignores the file" bash -c "cd '$work' && ! phi-check --no-exceptions fixtures/synthetic.txt >/dev/null"
check "--cwd resolves the file" bash -c "phi-check --cwd '$work' fixtures/synthetic.txt | grep -q 'clean'"
check "env override wins over the option" bash -c "cd '$work' && ! PHI_CHECK_EXCEPTIONS=missing.txt phi-check fixtures/synthetic.txt >/dev/null"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && phi-check --version >/dev/null'

reportResults
