#!/usr/bin/env bash
# claude-fleet: several Claude Code sessions in one terminal, never a second copy
# of one. Installed on PATH by the claude-code Feature next to claude-host; run by
# `task devcontainer:claude:fleet` (host side, through the container) and usable
# directly inside it. Bash, like claude-host: the Feature installs no jq or
# python, so the `claude agents --json` list is read with sed.
#
#   claude-fleet [--plan] [--no-view] [--no-wait] [--stop-duplicates]
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
# A variable's value comes from the .env files FIRST (the root .env, then
# .devcontainer/.env, as Task's dotenv reads them: the first file with a line for the
# variable wins; found upwards from the current directory, or CLAUDE_HOST_ENV_FILE), and
# from the environment only when no .env has a line for that variable: inside a session the environment keeps
# the id the session started with, which after a /clear or a fork is stale, while
# the claude-host-pin hook keeps .env current.
#
# Before reconciling, claude-fleet waits for the list to be stable: after a rebuild
# the Claude daemon restores background sessions from the Feature's volume, and
# starting sessions in that window races the restore and makes duplicates. It reads
# `claude agents --json` until two reads FLEET_SETTLE_INTERVAL seconds apart (default
# 3) give the same set of live ids, up to FLEET_SETTLE_TIMEOUT seconds (default 30;
# then it reconciles anyway, with a note). --no-wait skips it.
#
# Per session, against `claude agents --json` (fields pid, sessionId and cwd; an entry without a pid is an ended session and never counts):
#   variable unset              -> say so, skip
#   its id is live, or a live session works in its dir (/clear gives a session a
#   new id in the same dir, so the id alone would start a duplicate)
#                               -> running, not started
#   more than one live session matches (by id or by folder)
#                               -> duplicates, reported with each session's id, pid,
#                                  age and whether a transcript exists; the kept one
#                                  is the id in .env if live, else the newest. Only
#                                  --stop-duplicates stops the extras, with `claude
#                                  stop <id>` (the conversation stays, `claude attach
#                                  <id>` resumes it); it never deletes a session, which
#                                  can take its worktree with it. It re-reads the list
#                                  to confirm they are gone, and never restarts one.
#   otherwise                   -> (two lines of one folder start one session, the first) cd <dir> && HOST_SESSION=<id> claude-host --bg <args>
# then `exec claude agents` to look at them all. --plan prints what it would do
# and starts nothing (and stops nothing), not even the view; --no-view starts the
# missing ones and leaves the view out. When the list cannot be read, nothing is started (exit 1):
# guessing would start copies. Exit 1 also when a start fails, a dir is missing
# or an id is not a UUID; the other sessions are still handled.
set -u

plan='' view=1 wait=1 stopdup=''
for a in "$@"; do
  case "$a" in
    --plan) plan=1 ;;
    --no-view) view='' ;;
    --no-wait) wait='' ;;
    --stop-duplicates) stopdup=1 ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "claude-fleet: unknown argument '$a' (--plan, --no-view, --no-wait, --stop-duplicates)" >&2; exit 2 ;;
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

# live: "id<TAB>cwd<TAB>pid<TAB>startedAt" per live session (one with a pid) (cwd resolved); returns 1 when the list
# cannot be read. Same parser as claude-host; keep them in step.
live() {
  local out entry id cwd pid started
  out="$(timeout 30 claude agents --json 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '\n\r')"
  case "$out" in '['*) ;; *) return 1 ;; esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    id="$(printf '%s' "$entry" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    cwd="$(printf '%s' "$entry" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | sed 's/\\\\/\\/g')"
    pid="$(printf '%s' "$entry" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    started="$(printf '%s' "$entry" | sed -n 's/.*"startedAt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    # live = has a pid: the list also holds ended sessions, without one
    [ -n "$id" ] && [ -n "$cwd" ] && [ "${pid:-0}" -gt 0 ] || continue
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    printf '%s\t%s\t%s\t%s\n' "$id" "$cwd" "$pid" "${started:-0}"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g')
}

# the .env files in Task's dotenv order (the first file defining a variable wins): the root .env,
# then .devcontainer/.env, the root being the nearest folder at or above here holding .devcontainer;
# CLAUDE_HOST_ENV_FILE overrides. Same lookup as claude-host and claude-host-pin.
envfiles=()
if [ -n "${CLAUDE_HOST_ENV_FILE:-}" ]; then
  envfiles=("$CLAUDE_HOST_ENV_FILE")
else
  d="$here"
  while :; do
    if [ -d "$d/.devcontainer" ]; then
      for f in "$d/.env" "$d/.devcontainer/.env"; do [ -f "$f" ] && envfiles+=("$f"); done
      break
    fi
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
fi

# value_of <variable>: the first .env file with a line for it (last assignment in that file wins),
# the environment only when no file has one. Why: inside a session the environment keeps the id
# the session started with, stale after a /clear or a fork; .env is kept current by the pin hook.
value_of() {
  local v='' f found=''
  for f in "${envfiles[@]}"; do
    [ -f "$f" ] && grep -q "^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=" "$f" && { found="$f"; break; }
  done
  if [ -n "$found" ]; then
    v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=[[:space:]]*//p" "$found" | tail -n 1 | tr -d '\r' |
      sed "s/^[\"']//; s/[\"'][[:space:]]*\$//; s/[[:space:]]\{1,\}#.*\$//; s/[[:space:]]*\$//")"
  else
    v="${!1:-}"
  fi
  printf '%s' "$v"
}

# age <startedAt in ms>: "5m", "3h", "2d".
age() {
  local s=$(( $(date +%s) - ${1:-0} / 1000 ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 120 ]; then echo "${s}s"; elif [ "$s" -lt 7200 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# settle: wait until two reads FLEET_SETTLE_INTERVAL apart give the same set of live ids.
settle() {
  local interval="${FLEET_SETTLE_INTERVAL:-3}" timeout="${FLEET_SETTLE_TIMEOUT:-30}" start="$SECONDS" prev cur
  prev="$(live)" || return 0   # unreadable: the read below says so
  prev="$(printf '%s\n' "$prev" | cut -f1 | sort)"
  echo "waiting for restored sessions…"
  while :; do
    sleep "$interval"
    cur="$(live)" || return 0
    cur="$(printf '%s\n' "$cur" | cut -f1 | sort)"
    [ "$cur" = "$prev" ] && return 0
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "claude-fleet: the session list was still changing after ${timeout}s; reconciling anyway."
      return 0
    fi
    prev="$cur"
  done
}
[ -n "$wait" ] && settle

if ! list="$(live)"; then
  echo "claude-fleet: 'claude agents --json' is unavailable (older Claude Code?); starting nothing, since that could start a second copy of a running session." >&2
  exit 1
fi

# slug of a folder as Claude Code names its project directory
slug_of() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
stopped=' '   # ids already stopped (two lines may share a folder)
to_stop=''

# duplicates <name> <id> <dir label> <target>: when more than one live session matches this agent
# (its id, or its folder), report them all, mark the kept one, and stop the extras with
# --stop-duplicates (claude stop; never a delete). Returns 0 when there are no duplicates.
duplicates() {
  local name="$1" id="$2" dir="$3" target="$4" group n keep sid scwd pid st role tr
  group="$(printf '%s\n' "$list" | awk -F'\t' -v d="$target" -v id="${id,,}" '$3 > 0 && (tolower($1) == id || $2 == d) && !seen[$1]++')"
  n=0; [ -n "$group" ] && n="$(printf '%s\n' "$group" | wc -l)"
  [ "$n" -ge 2 ] || return 0
  keep="$(printf '%s\n' "$group" | awk -F'\t' -v id="${id,,}" 'tolower($1) == id { print $1; exit }')"
  [ -n "$keep" ] || keep="$(printf '%s\n' "$group" | sort -t"$(printf '\t')" -k4,4nr | head -n 1 | cut -f1)"
  echo "$name: duplicates: $n live sessions for this agent (id $id, folder ${dir:-.}); keeping $keep:"
  while IFS=$'\t' read -r sid scwd pid st; do
    role=extra; [ "$sid" = "$keep" ] && role=keep
    tr=no; [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(slug_of "$scwd")/$sid.jsonl" ] && tr=yes
    printf '  %-5s %s pid %s age %s transcript %s\n' "$role" "$sid" "$pid" "$(age "$st")" "$tr"
    if [ "$role" = extra ]; then
      case "$stopped" in *" $sid "*) ;; *) to_stop="$to_stop $sid"; stopped="$stopped$sid " ;; esac
    fi
  done <<< "$group"
  if [ -z "$stopdup" ]; then
    echo "$name: nothing stopped; claude-fleet --stop-duplicates stops the extras with 'claude stop <id>' (never rm; 'claude attach <id>' resumes one)."
  elif [ -n "$plan" ]; then
    echo "$name: would stop the extras with 'claude stop <id>'."
  fi
  return 0
}

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
    echo "$name: skipped, $var is not set (environment, .env or .devcontainer/.env)"; continue
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
    duplicates "$name" "$id" "$dir" "$target"
    continue
  fi
  if [ "$n_dir" -ge 1 ]; then
    echo "$name: running (live in $dir as $(printf '%s' "$in_dir" | tr '\n' ' '), not as $id; $var is stale, claude-host with CLAUDE_HOST_UPDATE_PIN=1 updates it)"
    duplicates "$name" "$id" "$dir" "$target"
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

if [ -n "$stopdup" ] && [ -z "$plan" ] && [ -n "${to_stop# }" ]; then
  for sid in $to_stop; do
    if claude stop "$sid" </dev/null; then echo "claude-fleet: stopped extra session $sid"
    else echo "claude-fleet: 'claude stop $sid' failed" >&2; rc=1; fi
  done
  interval="${FLEET_SETTLE_INTERVAL:-3}" left=''
  for _ in 1 2 3 4 5; do
    now="$(live)" || { left=" the list could not be re-read"; break; }
    left=''
    for sid in $to_stop; do printf '%s\n' "$now" | cut -f1 | grep -qixF "$sid" && left="$left $sid"; done
    [ -z "$left" ] && break
    sleep "$interval"
  done
  if [ -z "$left" ]; then echo "claude-fleet: re-read the list: the stopped extras are gone (${to_stop# })."
  else echo "claude-fleet: still live after claude stop:${left} (or the list could not be re-read)." >&2; rc=1; fi
fi

[ -n "$plan" ] && { echo "claude-fleet: plan only, nothing started."; exit "$rc"; }
if [ -n "$view" ]; then
  [ "$rc" -ne 0 ] && echo "claude-fleet: some sessions had problems (see above)." >&2
  exec claude agents
fi
exit "$rc"
