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
# A live session in the folder wins over the pinned id. /clear gives a session a
# new id, so the pinned id's transcript is stale while the folder's live session
# carries on; resuming the pinned id would run a second copy of one agent. Before
# resuming, claude-host reads `claude agents --json` (fields sessionId and cwd,
# one entry per live session) and looks for live sessions whose cwd is this folder:
#   none live              -> the rules above (resume if transcript, else create)
#   the pinned id is live  -> resume it
#   one other is live      -> resume that one, say so, warn that the pinned id is
#                             stale; CLAUDE_HOST_UPDATE_PIN=1 also rewrites the
#                             HOST_SESSION... line holding the old id in
#                             .devcontainer/.env (found upwards from here, or
#                             CLAUDE_HOST_ENV_FILE; CLAUDE_HOST_PIN_VAR=<name> names
#                             the variable; never created, never any other line;
#                             also done under CLAUDE_HOST_PRINT_FLAG)
#   two or more, none pinned -> start nothing, list the ids on stderr, exit 1
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

# live_in_dir: the ids of the live sessions whose cwd is this folder, one per line.
# Returns 1 when `claude agents --json` cannot be read. No jq or python needed:
# the JSON is flattened and cut into one entry per object, and sessionId and cwd
# are picked out of each (fields as seen in Claude Code 2.1.308: sessionId, cwd).
# Same parser as claude-fleet; keep them in step.
live_in_dir() {
  local out entry id cwd
  out="$(timeout 30 claude agents --json 2>/dev/null)" || return 1  # timeout: coreutils
  out="$(printf '%s' "$out" | tr -d '\n\r')"
  case "$out" in '['*) ;; *) return 1 ;; esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    id="$(printf '%s' "$entry" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    cwd="$(printf '%s' "$entry" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\\\/\\/g')"
    [ -n "$id" ] && [ -n "$cwd" ] || continue
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    [ "$cwd" = "$here" ] && printf '%s\n' "$id"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g')
  return 0
}

# update_pin <old> <new>: rewrite the HOST_SESSION... line that holds <old>.
update_pin() {
  local old="$1" new="$2" f d name re tmp n
  f="${CLAUDE_HOST_ENV_FILE:-}"
  if [ -z "$f" ]; then
    d="$here"
    while :; do
      [ -f "$d/.devcontainer/.env" ] && { f="$d/.devcontainer/.env"; break; }
      [ "$d" = / ] && break
      d="$(dirname "$d")"
    done
  fi
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "claude-host: CLAUDE_HOST_UPDATE_PIN: no .devcontainer/.env found; nothing updated." >&2
    return 0
  fi
  name="${CLAUDE_HOST_PIN_VAR:-HOST_SESSION[A-Za-z0-9_]*}"
  re="^[[:space:]]*(export[[:space:]]+)?${name}=[\"']?${old}"
  n="$(grep -Eic "$re" "$f")"
  if [ "$n" -ne 1 ]; then
    echo "claude-host: CLAUDE_HOST_UPDATE_PIN: $n lines of $f hold $old (need exactly one); nothing updated." >&2
    return 0
  fi
  tmp="$(mktemp)" || return 0
  sed "s/\(^[[:space:]]*\(export[[:space:]]\+\)\{0,1\}${name}=[\"']\{0,1\}\)${old}/\1${new}/I" "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
  echo "claude-host: updated $f: $old -> $new." >&2
}

use="$sid"
if [ "${CLAUDE_HOST_LIVE_CHECK:-1}" != 0 ]; then
  if live="$(live_in_dir)"; then
    if [ -n "$live" ]; then
      lc_sid="${sid,,}"
      if printf '%s\n' "${live,,}" | grep -qxF "$lc_sid"; then
        echo "claude-host: session $sid is live in this folder; resuming it." >&2
        use="$sid" live_resume=1
      elif [ "$(printf '%s\n' "$live" | wc -l)" -eq 1 ]; then
        echo "claude-host: session $live is live in this folder; resuming it, not the pinned $sid (a /clear gives a session a new id). The pin (HOST_SESSION... in .devcontainer/.env) is stale; CLAUDE_HOST_UPDATE_PIN=1 updates it." >&2
        use="$live" live_resume=1
        [ -n "${CLAUDE_HOST_UPDATE_PIN:-}" ] && update_pin "$sid" "$live"
      else
        {
          echo "claude-host: several live sessions in this folder and none is the pinned $sid; starting nothing. Live ids:"
          printf '%s\n' "$live" | sed 's/^/  /'
          echo "claude-host: attach one with claude --resume <id>, or set HOST_SESSION to one of them."
        } >&2
        exit 1
      fi
    fi
  else
    echo "claude-host: 'claude agents --json' is unavailable (older Claude Code?); not checking for a live session." >&2
  fi
fi
if [ -n "${live_resume:-}" ] || [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/$use.jsonl" ]; then
  [ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--resume $use"; exit 0; }
  exec claude --resume "$use" "$@"
fi
[ -n "${CLAUDE_HOST_PRINT_FLAG:-}" ] && { echo "--session-id $use"; exit 0; }
exec claude --session-id "$use" "$@"
