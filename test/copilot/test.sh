#!/bin/bash
# Auto-generated scenario: the copilot Feature with default options on an image with nothing else,
# so the official ghcr.io/devcontainers/features/copilot-cli (its dependsOn) installs the CLI and
# this Feature adds its pieces. Needs no Copilot login and no network after the build. Run with:
#   devcontainer features test -f copilot --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "copilot is on PATH (from the dependsOn)" command -v copilot
check "copilot reports a version" bash -c "copilot --version | grep -E 'Copilot CLI [0-9]+\.[0-9]+\.[0-9]+'"
check "copilot is the pinned 1.0.114" bash -c "copilot --version | grep -q '1\.0\.114'"
check "Copilot self-update is off" bash -c "[ \"\$COPILOT_AUTO_UPDATE\" = false ]"
check "the binary is the official Feature's, root-owned" bash -c "[ \"\$(stat -c %U \"\$(readlink -f \"\$(command -v copilot)\")\")\" = root ]"
check "this Feature installed no binary of its own" bash -c "[ \"\$(type -ap copilot | wc -l)\" = 1 ]"
check "COPILOT_HOME points at the Feature's state dir" bash -c "[ \"\$COPILOT_HOME\" = /var/lib/devcontainer-features/copilot ]"

check "agent-adapter-copilot on PATH" command -v agent-adapter-copilot
check "agent-adapter-copilot is root-owned" bash -c "[ \"\$(stat -c %U \"\$(command -v agent-adapter-copilot)\")\" = root ]"
check "agent-adapter-copilot supports run-once" bash -c "agent-adapter-copilot supports | grep -qx run-once"
check "agent-adapter-copilot start-bg exits 3" bash -c "agent-adapter-copilot start-bg x /tmp; [ \$? -eq 3 ]"
check "no participant component without participants" bash -c "! test -e /usr/local/lib/dcf-participant"

check "copilot-setup on PATH" command -v copilot-setup
check "dcf-persist on PATH" command -v dcf-persist
check "setup makes the state dir usable and reports it" bash -c "copilot-setup | grep -Eq '^copilot: /var/lib/devcontainer-features/copilot \((volume|bind|image), writable\)\$' && [ -w /var/lib/devcontainer-features/copilot ]"
check "the state dir is not writable by group or other (Copilot refuses one that is)" bash -c "[ -z \"\$(find \$COPILOT_HOME -maxdepth 0 -perm /022)\" ]"
check "setup is idempotent" bash -c "copilot-setup >/dev/null && copilot-setup | grep -Eq '^copilot: /var/lib/devcontainer-features/copilot \((volume|bind|image), writable\)\$'"
check "setup says where the login comes from, with no token value" bash -c "t=\$(COPILOT_GITHUB_TOKEN=ghp_secretvalue copilot-setup); printf '%s' \"\$t\" | grep -q 'COPILOT_GITHUB_TOKEN' && ! printf '%s' \"\$t\" | grep -q secretvalue"
check "setup without a token says how to log in" bash -c "env -u COPILOT_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN copilot-setup | grep -q 'copilot login'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "setup honours an overriding COPILOT_HOME" bash -c 'd=$(mktemp -d)/cfg; COPILOT_HOME="$d" copilot-setup | grep -q "^copilot: $d (image, writable)" && [ -d "$d" ]'

check "with no attach option nothing is registered" bash -c "! copilot mcp list | grep -q facilitator"
# The real CLI registers an MCP entry with no login (a fake facilitator names the command): the
# adapter's mcp-attach, run twice, leaves one entry and no token in it.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "mcp-attach with no facilitator installed registers nothing and says so" bash -c 'out=$(agent-adapter-copilot mcp-attach facilitator); [ $? -eq 0 ] && printf "%s" "$out" | grep -q "no entry to register" && ! copilot mcp list | grep -q facilitator'
# shellcheck disable=SC2016
check "mcp-attach through the real copilot mcp add (twice, no login)" bash -c '
  t=$(mktemp -d); mkdir -p "$t/bin" "$t/home"; chmod 700 "$t/home"
  printf "#!/bin/sh\nexit 0\n" > "$t/bin/facilitator"; chmod +x "$t/bin/facilitator"
  export PATH="$t/bin:$PATH" COPILOT_HOME="$t/home"
  agent-adapter-copilot mcp-attach facilitator >/dev/null && agent-adapter-copilot mcp-attach facilitator >/dev/null || exit 1
  [ "$(copilot mcp list | grep -c "^  facilitator ")" = 1 ] || exit 1
  grep -q FACILITATOR_HANDLE "$t/home/mcp-config.json" && ! grep -qE "FACILITATOR_TOKEN=|\"env\"" "$t/home/mcp-config.json" || exit 1
  [ "$(stat -c %a "$t/home/mcp-config.json")" = 600 ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/copilot.yml

reportResults
