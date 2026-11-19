#!/bin/bash
# Scenario 'two_parties' (see scenarios.json): go-task and packet-relay with root=/tmp/relay,
# remoteUser=vscode. Two parties in one container exchange a packet and its acknowledgement, through
# the tasks, as the non-root user.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
mkdir -p /tmp/relay
check "runs as non-root" bash -c "[ \"\$(id -u)\" != 0 ]"
check "the home is the remote user's" test -w "$PACKET_RELAY_HOME"
check "packet-relay:version runs" bash -c "task -t $registry packet-relay:version | grep -q '^packet-relay '"
check "check is ready with the folder there" packet-relay check
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "a packet sent, taken and acknowledged" bash -c '
  set -e
  mkdir -p "$PACKET_RELAY_HOME/members"
  { packet-relay key new alice | head -n1; packet-relay key new bob | head -n1; } > "$PACKET_RELAY_HOME/members/talk"
  packet-relay send --domain talk --as alice --kind note --data "{\"text\": \"hello\"}"
  packet-relay sync --domain talk --as bob
  ls "$PACKET_RELAY_HOME"/talk/bob/inbox/alice/* >/dev/null
  packet-relay sync --domain talk --as alice'

reportResults
