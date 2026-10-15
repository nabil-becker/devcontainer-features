#!/bin/bash
# Auto-generated scenario: the claude-code Feature with default options
# (install=auto, version=stable) on an image without a prior claude, so the
# native binary is installed. Run with:
#   devcontainer features test -f claude-code --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "claude is on PATH" command -v claude
check "claude reports a version" bash -c "claude --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
check "native binary installed" bash -c "[ \"\$(command -v claude)\" = /usr/local/bin/claude ]"
check "binary is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/claude)\" = root ]"
check "autoupdater disabled" bash -c "[ \"\$DISABLE_AUTOUPDATER\" = 1 ]"

check "claude-host on PATH" command -v claude-host
check "claude-host without HOST_SESSION runs claude" bash -c "HOST_SESSION= claude-host --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "claude-host rejects a non-UUID" bash -c 'HOST_SESSION=not-a-uuid claude-host --version; [ "$?" -eq 2 ]'

check "claude-code-setup on PATH" command -v claude-code-setup
check "dcf-persist on PATH" command -v dcf-persist
check "CLAUDE_CONFIG_DIR points at the Feature's state dir" bash -c "[ \"\$CLAUDE_CONFIG_DIR\" = /var/lib/devcontainer-features/claude-code ]"
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
check "setup makes the state dir usable and reports it" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$' && [ -w /var/lib/devcontainer-features/claude-code ]"
check "setup is idempotent" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$'"
# shellcheck disable=SC2016
check "setup honours an overriding CLAUDE_CONFIG_DIR" bash -c 'd=$(mktemp -d)/cfg; CLAUDE_CONFIG_DIR="$d" claude-code-setup | grep -q "^claude-code: $d (image, writable)" && [ -d "$d" ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/claude-code.yml

reportResults
