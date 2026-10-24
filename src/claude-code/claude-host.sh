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
#
# A live session in the folder is never started a second time. `claude --resume
# <id>` on a session that is still running opens a second process on the same
# transcript, and /clear gives a session a new id, so the pinned id may not even be
# the running one. Before starting, claude-host reads `claude agents --json`
# (fields pid, sessionId, cwd; an entry without a pid, or with pid null or 0, is a
# session that ended and never counts as live) and looks for live sessions whose
# cwd is this folder:
#   none live              -> the rules above (resume if transcript, else create)
#   one or more live       -> start nothing, print each running id and pid and how
#                             to attach (`claude agents`, select it), exit 1; with
#                             CLAUDE_HOST_PRINT_FLAG print nothing and exit 1 too.
#                             When the pinned id is not among them it says the pin
#                             is stale; CLAUDE_HOST_UPDATE_PIN=1 then also rewrites
#                             the HOST_SESSION... line holding the old id in
#                             .devcontainer/.env (claude-host-pin --replace; the
#                             SessionStart hook claude-host-pin keeps it current)
#   CLAUDE_HOST_ALLOW_SECOND=1 -> start anyway by the rules above
# `claude agents --json` missing or failing (older Claude Code): one-line note and
# the rules above. CLAUDE_HOST_LIVE_CHECK=0 skips the check (claude-fleet does, it
# has made the same check already).
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
here="$(pwd -P)"
slug="$(printf '%s' "$here" | sed 's/[^A-Za-z0-9]/-/g')"

# live_in_dir: "id pid" of each live session whose cwd is this folder, one per
# line. Returns 1 when `claude agents --json` cannot be read. No jq or python
# needed: the JSON is flattened and cut into one entry per object, and sessionId,
# cwd and pid are picked out of each (fields as seen in Claude Code 2.1.308). Live =
# has a pid: the list also holds ended sessions, without one. Same parser as
# claude-fleet; keep them in step.
live_in_dir() {
  local out entry id cwd pid
  out="$(timeout 30 claude agents --json 2>/dev/null)" || return 1  # timeout: coreutils
  out="$(printf '%s' "$out" | tr -d '\n\r')"
  case "$out" in '['*) ;; *) return 1 ;; esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    id="$(printf '%s' "$entry" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    cwd="$(printf '%s' "$entry" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\\\/\\/g')"
    pid="$(printf '%s' "$entry" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    [ -n "$id" ] && [ -n "$cwd" ] && [ "${pid:-0}" -gt 0 ] || continue
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    [ "$cwd" = "$here" ] && printf '%s %s\n' "$id" "$pid"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g')
  return 0
}

pin_tool() { # claude-host-pin: on PATH, else beside this script
  command -v claude-host-pin 2>/dev/null || { [ -x "$(dirname "$0")/claude-host-pin" ] && echo "$(dirname "$0")/claude-host-pin"; }
}

if [ "${CLAUDE_HOST_LIVE_CHECK:-1}" != 0 ]; then
  if live="$(live_in_dir)"; then
    if [ -n "$live" ] && [ -z "${CLAUDE_HOST_ALLOW_SECOND:-}" ]; then
      {
        echo "claude-host: a session is already running in this folder; starting nothing (a second process on one transcript would be a second copy):"
        printf '%s\n' "$live" | while read -r lid lpid; do echo "  session $lid (pid $lpid)"; done
        echo "claude-host: attach with 'claude agents' and select it. CLAUDE_HOST_ALLOW_SECOND=1 starts one anyway."
        if ! printf '%s\n' "${live,,}" | cut -d' ' -f1 | grep -qxF "${sid,,}"; then
          echo "claude-host: the pinned $sid (HOST_SESSION... in .devcontainer/.env) is stale: it is not a running session (a /clear gives a session a new id). CLAUDE_HOST_UPDATE_PIN=1 claude-host updates it with the running id when exactly one runs; the claude-host-pin SessionStart hook keeps it current."
        fi
      } >&2
      if [ -n "${CLAUDE_HOST_UPDATE_PIN:-}" ] && [ "$(printf '%s\n' "$live" | wc -l)" -eq 1 ] \
        && [ "${live%% *}" != "${sid,,}" ] && pin="$(pin_tool)"; then
        "$pin" --replace "$sid" "${live%% *}"
      fi
      exit 1
    fi
    [ -n "$live" ] && echo "claude-host: CLAUDE_HOST_ALLOW_SECOND is set; starting although a session is running in this folder." >&2
  else
    echo "claude-host: 'claude agents --json' is unavailable (older Claude Code?); not checking for a live session." >&2
  fi
fi
use="$sid"
if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/$use.jsonl" ]; then
  [ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--resume $use"; exit 0; }
  exec claude --resume "$use" "$@"
fi
[ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--session-id $use"; exit 0; }
exec claude --session-id "$use" "$@"
