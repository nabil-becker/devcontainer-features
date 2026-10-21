#!/usr/bin/env bash
# claude-host: start or resume one Claude Code session by its UUID.
# Installed on PATH by the claude-code Feature; run by `task devcontainer:claude`
# (host side) and `task claude-code:host` (inside). HOST_SESSION names the
# role, not the product: another host product gets its own launcher.
#
# Portable on purpose: no repository paths, no dependencies beyond bash and
# `claude`. Set HOST_SESSION (containerEnv, a .env file, or the shell) to a
# UUID:
#   unset                  -> claude "$@", with a one-line hint
#   set, invalid UUID      -> error, exit 2
#   set, transcript exists -> claude --resume <uuid> "$@"
#   set, no transcript     -> claude --session-id <uuid> "$@"
# CLAUDE_HOST_PRINT_FLAG=1 (any non-empty value) prints the flag pair that
# would be used (--resume <uuid> or --session-id <uuid>) on stdout and exits 0
# without starting claude, so a launcher of its own reuses the decision. With
# HOST_SESSION unset it prints nothing and exits 0; an invalid UUID is still
# exit 2. Messages go to stderr, so stdout carries only the flags.
# Sessions are referred to by UUID; a session's name is only a label, may
# change with /rename and may collide. The transcript is looked up where
# Claude Code keeps it for the current directory:
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<cwd, every non-alphanumeric as ->/<uuid>.jsonl
set -u
sid="${HOST_SESSION:-}"
if [ -z "$sid" ]; then
  echo "claude-host: HOST_SESSION is not set; set it to a UUID to resume one session by its id." >&2
  [ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && exit 0
  exec claude "$@"
fi
if ! [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "claude-host: HOST_SESSION is not a valid UUID; sessions are referred to by UUID, a name is only a label." >&2
  exit 2
fi
slug="$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/$sid.jsonl" ]; then
  [ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--resume $sid"; exit 0; }
  exec claude --resume "$sid" "$@"
fi
[ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--session-id $sid"; exit 0; }
exec claude --session-id "$sid" "$@"
