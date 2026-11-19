#!/bin/bash
# Auto-generated scenario: the packet-relay Feature alone with its default options on the base image;
# it carries its own copy of sign-packet's library, so no other Feature is needed.
# Run with:
#   devcontainer features test -f packet-relay --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the command is installed" packet-relay version
check "the command is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/packet-relay)\" = root ]"
check "its own sign-packet library" test -f /usr/local/lib/packet-relay/signpacket/packet.py
check "no sign-packet Feature needed" bash -c '! test -e /usr/local/lib/sign-packet'
check "the Taskfile is in the go-task includes" test -f /usr/local/share/go-task/includes.d/packet-relay.yml
check "setup is never fatal" packet-relay-setup
check "check is not ready without a shared folder" bash -c '! packet-relay check'

reportResults
