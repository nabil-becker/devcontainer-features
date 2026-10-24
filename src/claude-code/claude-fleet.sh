#!/usr/bin/env bash
# claude-fleet: several Claude Code sessions in one terminal, never a second copy
# of one. Installed on PATH by the claude-code Feature next to claude-host; run by
# `task devcontainer:claude:fleet` (host side, through the container) and usable
# directly inside it. Bash, like claude-host: the Feature installs no jq or
# python, so the `claude agents --json` list is read with sed.
#
#   claude-fleet [--plan] [--no-view]
#
# SESSIONS (environment, or SESSIONS_B64 holding it base64-encoded, which is how
# the bootstrap task passes it): one line per session,
#   name|session-variable|dir|extra claude args
# name is a label, session-variable the name of the variable holding the
# session's UUID (HOST_SESSION_SOLIS, say), dir the folder the session works in
# (relative to the current directory), the extra args are split on whitespace
# (no quoting) and handed to claude-host after --bg. Blank lines and lines
# starting with # are skipped.
#
# A variable's value comes from the environment, else from .devcontainer/.env
# (found upwards from the current directory, or CLAUDE_HOST_ENV_FILE): inside
# the container only HOST_SESSION is in the environment.
#
# Per session, against `claude agents --json` (fields pid, sessionId and cwd; an entry without a pid is an ended session and never counts):
#   variable unset              -> say so, skip
#   its id is live, or a live session works in its dir (/clear gives a session a
#   new id in the same dir, so the id alone would start a duplicate)
#                               -> running, not started; two or more live in the
#                                  dir are reported
#   otherwise                   -> (two lines of one folder start one session, the first) cd <dir> && HOST_SESSION=<id> claude-host --bg <args>
# then `exec claude agents` to look at them all. --plan prints what it would do
# and starts nothing, not even the view; --no-view starts the missing ones and
# leaves the view out. When the list cannot be read, nothing is started (exit 1):
# guessing would start copies. Exit 1 also when a start fails, a dir is missing
# or an id is not a UUID; the other sessions are still handled.
set -u

plan='' view=1
for a in "$@"; do
  case "$a" in
    --plan) plan=1 ;;
    --no-view) view='' ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "claude-fleet: unknown argument '$a' (--plan, --no-view)" >&2; exit 2 ;;
  esac
done

sessions="${SESSIONS:-}"
if [ -z "$sessions" ] && [ -n "${SESSIONS_B64:-}" ]; then
  sessions="$(printf '%s' "$SESSIONS_B64" | base64 -d 2>/dev/null)" || { echo "claude-fleet: SESSIONS_B64 is not base64." >&2; exit 2; }
fi
if [ -z "$sessions" ]; then
  echo "claude-fleet: SESSIONS is empty; set it to lines of name|session-variable|dir|extra claude args." >&2
  exit 2
fi

here="$(pwd -P)"

# live: "id<TAB>cwd" per live session (one with a pid) (cwd resolved); returns 1 when the list
# cannot be read. Same parser as claude-host; keep them in step.
live() {
  local out entry id cwd pid
  out="$(timeout 30 claude agents --json 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '\n\r')"
  case "$out" in '['*) ;; *) return 1 ;; esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    id="$(printf '%s' "$entry" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    cwd="$(printf '%s' "$entry" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\\\/\\/g')"
    pid="$(printf '%s' "$entry" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    # live = has a pid: the list also holds ended sessions, without one
    [ -n "$id" ] && [ -n "$cwd" ] && [ "${pid:-0}" -gt 0 ] || continue
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    printf '%s\t%s\n' "$id" "$cwd"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g')
}

envfile="${CLAUDE_HOST_ENV_FILE:-}"
if [ -z "$envfile" ]; then
  d="$here"
  while :; do
    [ -f "$d/.devcontainer/.env" ] && { envfile="$d/.devcontainer/.env"; break; }
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
fi

# value_of <variable>: environment first, then the .env file (last assignment wins).
value_of() {
  local v="${!1:-}"
  if [ -z "$v" ] && [ -n "$envfile" ] && [ -f "$envfile" ]; then
    v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=[[:space:]]*//p" "$envfile" | tail -n 1 | tr -d '\r' |
      sed "s/^[\"']//; s/[\"'][[:space:]]*\$//; s/[[:space:]]\{1,\}#.*\$//; s/[[:space:]]*\$//")"
  fi
  printf '%s' "$v"
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

if ! list="$(live)"; then
  echo "claude-fleet: 'claude agents --json' is unavailable (older Claude Code?); starting nothing, since that could start a second copy of a running session." >&2
  exit 1
fi

rc=0
uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
while IFS='|' read -r name var dir args || [ -n "${name:-}" ]; do
  name="$(trim "${name:-}")" var="$(trim "${var:-}")" dir="$(trim "${dir:-}")" args="$(trim "${args:-}")"
  case "$name" in '' | '#'*) continue ;; esac
  if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "$name: skipped, '$var' is not a variable name" >&2; rc=1; continue
  fi
  id="$(value_of "$var")"
  if [ -z "$id" ]; then
    echo "$name: skipped, $var is not set (environment or .devcontainer/.env)"; continue
  fi
  if ! [[ "$id" =~ $uuid ]]; then
    echo "$name: skipped, $var is not a UUID" >&2; rc=1; continue
  fi
  target="$here"
  case "$dir" in '' | .) ;; /*) target="$dir" ;; *) target="$here/$dir" ;; esac
  if ! target="$(cd "$target" 2>/dev/null && pwd -P)"; then
    echo "$name: skipped, folder '$dir' does not exist" >&2; rc=1; continue
  fi
  in_dir="$(printf '%s\n' "$list" | awk -F'\t' -v d="$target" '$2 == d { print $1 }')"
  n_dir=0; [ -n "$in_dir" ] && n_dir="$(printf '%s\n' "$in_dir" | wc -l)"
  if printf '%s\n' "$list" | cut -f1 | grep -qixF "$id"; then
    echo "$name: running ($id)"
    [ "$n_dir" -ge 2 ] && echo "$name: note: $n_dir live sessions work in $dir: $(printf '%s' "$in_dir" | tr '\n' ' ')"
    continue
  fi
  if [ "$n_dir" -ge 1 ]; then
    echo "$name: running (live in $dir as $(printf '%s' "$in_dir" | tr '\n' ' '), not as $id; $var is stale, claude-host with CLAUDE_HOST_UPDATE_PIN=1 updates it)"
    [ "$n_dir" -ge 2 ] && echo "$name: note: $n_dir live sessions work in $dir; attach one of them yourself"
    continue
  fi
  if [ -n "$plan" ]; then
    echo "$name: would start: cd $target && HOST_SESSION=$id claude-host --bg $args"
    list="$(printf '%s\n%s\t%s' "$list" "$id" "$target")"
    continue
  fi
  echo "$name: starting ($id in $target)"
  read -ra extra <<< "$args"
  # claude-host's own live check is off: this loop has just made it.
  if ! (cd "$target" && HOST_SESSION="$id" CLAUDE_HOST_LIVE_CHECK=0 claude-host --bg "${extra[@]}"); then
    echo "$name: start failed" >&2; rc=1
  else
    # the list was read once: a later line for the same folder now finds this one
    list="$(printf '%s\n%s\t%s' "$list" "$id" "$target")"
  fi
done <<< "$sessions"

[ -n "$plan" ] && { echo "claude-fleet: plan only, nothing started."; exit "$rc"; }
if [ -n "$view" ]; then
  [ "$rc" -ne 0 ] && echo "claude-fleet: some sessions had problems (see above)." >&2
  exec claude agents
fi
exit "$rc"
