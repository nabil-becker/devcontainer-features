#!/bin/bash
# Scenario 'with_guard' (see scenarios.json): guard, ingressGuard and guardTimeout set, remoteUser=vscode.
# The options are baked for the command; an egress guard refuses a packet before it is signed.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

mkdir -p /tmp/relay
check "the guard options are baked" bash -c "grep -q '^GUARD=/bin/grep -qv forbidden' /usr/local/lib/packet-relay/options.env && grep -q '^GUARD_TIMEOUT=20' /usr/local/lib/packet-relay/options.env"
check "the command runs with the guards set" packet-relay version
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "the egress guard refuses, nothing is sent" bash -c '
  mkdir -p "$PACKET_RELAY_HOME/members"
  packet-relay key new carol | head -n1 > "$PACKET_RELAY_HOME/members/talk"
  ! packet-relay send --domain talk --as carol --kind note --data "{\"text\": \"forbidden\"}" \
    && ! ls /tmp/relay/talk/carol/packets/* 2>/dev/null'

reportResults
