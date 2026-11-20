#!/usr/bin/env bash
# claude-code-setup: the claude-code Feature's postCreateCommand, run as the
# remote user from the workspace folder after every create/rebuild; also
# behind `task claude-code:setup`. Idempotent, never fatal: a problem is
# reported, not allowed to abort the rest of post-create.
#
# Makes the Claude Code state directory usable: CLAUDE_CONFIG_DIR (the
# Feature's named volume at /var/lib/devcontainer-features/claude-code, a
# repo's bind mount over it, or ~/.claude when unset) exists and belongs to
# the remote user. Mounts arrive owned by root or by the host's uid, and
# Claude Code then cannot write its credentials, settings or transcripts
# there. dcf-persist (shared by every Feature of this collection) does the
# create/chown and reports path, backing and writability.
set -u

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dcf-persist --label claude-code "$dir"
# The personal skills folder (1.12.0): created now, even empty, so a session started later watches
# it and picks up skills the component registry hands over mid-session (agent-adapter-claude
# skills); a skills folder that did not exist when a session started needs /reload-skills.
[ -d "$dir" ] && { [ -d "$dir/skills" ] || (umask 077 && mkdir -p "$dir/skills") 2>/dev/null || echo "claude-code-setup: could not create $dir/skills"; }
if [ -s "$dir/.credentials.json" ] || [ -s "$dir/.claude.json" ]; then echo "claude-code-setup: login present"; else echo "claude-code-setup: no login yet (run claude and sign in once; it persists in $dir)"; fi
if [ -n "${HOST_SESSION:-}" ]; then echo "claude-code-setup: HOST_SESSION set (claude-host resumes it)"; fi
exit 0
