#!/usr/bin/env bash
# claude-code-post-start: the claude-code Feature's postStartCommand, run at every container start.
# With participants: true (claude-code 1.10.0) it makes every resident agent of the agent list run
# in the background (`agents up --post-start`, the participant component's start hook, which never
# fails), as the agents Feature's own postStartCommand did. It does nothing when participants is
# false, and nothing when the deprecated agents Feature is also installed, since that Feature's
# own hook runs the same command and one run is enough. Never fatal.
set -u

share="${CLAUDE_CODE_SHARE_DIR:-/usr/local/share/claude-code}"
agents_share="${AGENTS_SHARE_DIR:-/usr/local/share/agents-feature}"
[ -f "$share/participants" ] || exit 0
[ ! -f "$agents_share/version" ] || exit 0
command -v agents >/dev/null 2>&1 || { echo "claude-code-post-start: participants is on but the agents command is missing; rebuild" >&2; exit 0; }
agents up --post-start || true
exit 0
