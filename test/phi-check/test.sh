#!/bin/bash
# Auto-generated scenario: the phi-check Feature alone with default options on the base image, as a
# repo that lists only phi-check:1 gets it. The dependsOn on the official python Feature
# (os-provided, no tools) must bring python3 in. All data is synthetic and assembled here.
# Run with:
#   devcontainer features test -f phi-check --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

# Assembled from parts so this file holds no record-shaped string.
ssn="$(printf '%s-%s-%s' 123 45 6789)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check "phi-check is on PATH" command -v phi-check
check "python3 is on PATH (from dependsOn)" command -v python3
check "phi-check is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/phi-check)\" = root ]"
check "phi-check reports its version" bash -c "phi-check --version | grep -qE '^phi-check [0-9]+\\.[0-9]+\\.[0-9]+\$'"
check "the module is installed" test -f /usr/local/share/phi-check/phi_patterns.py
check "the module imports and finds" bash -c "python3 -I -c \"import sys; sys.path.insert(0, '/usr/local/share/phi-check'); import phi_patterns; assert phi_patterns.find('SSN: $ssn')\""
check "the default exceptions name is baked" grep -qx '.phi-exceptions.txt' /usr/local/share/phi-check/exceptions-default
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/phi-check.yml

echo "nothing to see" > "$work/clean.txt"
printf 'SSN: %s\n' "$ssn" > "$work/dirty.txt"
check "a clean file exits 0" bash -c "phi-check '$work/clean.txt' | grep -qx 'phi-check: clean, 1 file(s)'"
check "a finding exits 1 and names the line and rule" bash -c "! phi-check '$work/dirty.txt' > '$work/out.txt'; grep -qx '$work/dirty.txt:1: PHI tier 1: US Social Security number' '$work/out.txt'"
check "the matched value is never printed" bash -c "! grep -q '$ssn' '$work/out.txt'"
check "bad usage exits 2" bash -c "phi-check --format nope x; [ \$? -eq 2 ]"
check "standard input works" bash -c "echo 'SSN: $ssn' | phi-check --stdin-filename staged.txt - | grep -q '^staged.txt:1:'"

reportResults
