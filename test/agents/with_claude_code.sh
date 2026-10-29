#!/bin/bash
# Scenario 'with_claude_code' (see scenarios.json): the claude-code Feature's adapter is found on
# PATH, so a cli: claude entry has an adapter (no claude binary: install none).
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "agent-adapter-claude on PATH" command -v agent-adapter-claude
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "a claude agent is listed (no claude binary: state error, says why)" bash -c '
  t=$(mktemp -d); mkdir -p "$t/.devcontainer"
  printf "agents:\n  - name: host\n    cli: claude\n    kind: on-demand\n    args: [--remote-control]\n" > "$t/.devcontainer/agents.yml"
  cd "$t" && out=$(agents list 2>&1); printf "%s\n" "$out"; printf "%s\n" "$out" | grep -qE "^host +on-demand +stateful +claude +error" && printf "%s\n" "$out" | grep -q "claude is not installed"'

reportResults
