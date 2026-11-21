#!/bin/bash
# Scenario 'leaf' (see scenarios.json): mode leaf installs the thin client only. The bundle without slimctl, no
# daemon started at container start, infra up and node run refused, check ready without the Directory, SLIM or
# the ssh-agent, and the MCP server answering initialize over stdio.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the mode as installed" grep -q '^FACILITATOR_MODE=leaf$' /opt/facilitator/lib/options.env
check "the command and its own Python" facilitator version
check "no SLIM node in a leaf" bash -c '! command -v slimctl && ! test -e /opt/facilitator/bin/slimctl'
check "no daemon was started" bash -c '! pgrep -f "[d]aemon start" && ! pgrep -f "[s]lim start"'
check "infra up is refused" bash -c '! facilitator infra up && facilitator infra up 2>&1 | grep -q "mode leaf"'
check "node run is refused" bash -c '! facilitator node run && facilitator node run 2>&1 | grep -q "mode leaf runs no node"'
check "check is ready, as a leaf" bash -c 'facilitator check && facilitator check | grep -q "mode .*leaf"'
check "the thin client answers initialize" bash -c 'printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}" | timeout 20 facilitator mcp --as nobody 2>/dev/null | grep -q "\"serverInfo\""'

reportResults
