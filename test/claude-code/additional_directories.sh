#!/bin/bash
# Scenario 'additional_directories' (see scenarios.json): the additionalDirectories option is
# written as a managed-settings drop-in, ~ expanded to the remote user's home, a space kept,
# readable by the remote user, and Claude Code reads its managed settings without an error.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

f=/etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json
check "the drop-in is there" test -f "$f"
check "the drop-in holds the folders, ~ expanded, a space kept" bash -c "[ \"\$(cat $f)\" = '{\"permissions\":{\"additionalDirectories\":[\"/workspaces/shared\",\"/home/vscode/notes\",\"/mnt/One Drive\"]}}' ]"
check "the drop-in is readable by the remote user" test -r "$f"
check "the user's own settings are not written" bash -c "[ ! -e \"\$CLAUDE_CONFIG_DIR/settings.json\" ] || ! grep -q additionalDirectories \"\$CLAUDE_CONFIG_DIR/settings.json\""
check "claude starts with the managed settings (--version)" bash -c "DISABLE_AUTOUPDATER=1 claude --version"

reportResults
