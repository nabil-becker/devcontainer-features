#!/bin/bash
# Auto-generated scenario: the register-engine Feature alone with its default options on the base
# image; it carries its own copy of sign-packet's library, so no other Feature is needed.
# Run with:
#   devcontainer features test -f register-engine --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the command is installed" register-engine version
check "the command is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/register-engine)\" = root ]"
check "the format is version 2" bash -c 'register-engine version | grep -q "format v2"'
check "its own sign-packet library" test -f /usr/local/lib/register-engine/signpacket/packet.py
check "no sign-packet Feature needed" bash -c '! test -e /usr/local/lib/sign-packet'
check "the Taskfile is in the go-task includes" test -f /usr/local/share/go-task/includes.d/register-engine.yml
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "the types folder is there, root-owned" bash -c 'test "$(stat -c %u /usr/local/lib/register-engine/types.d)" = 0'
check "only the log type without a capability Feature" bash -c 'register-engine types | grep -q "log"'
check "check is ready" register-engine check

reportResults
