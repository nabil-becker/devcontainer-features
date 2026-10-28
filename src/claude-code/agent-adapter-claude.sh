#!/usr/bin/env bash
# agent-adapter-claude: the Claude Code adapter of the agents Feature's contract
# (docs/proposals/agents.md, section 5). Installed on PATH by the claude-code Feature; the
# agents Feature calls it, nothing else does.
#
#   agent-adapter-claude <verb> <name> <folder> [--extras] [-- claude args...]
#     start-bg   cd <folder> && claude --bg --name <name> <args>; prints the new session's id
#     wake       the agent's newest stopped or failed session, by its full id:
#                cd <folder> && claude --bg --resume <session id> (the same id, its conversation)
#     attach     claude attach <id> of its newest running session (a terminal is needed)
#     resume     cd <folder> && claude --resume <session id> <args> of its newest session;
#                refused while that session runs (a second process on one transcript); when
#                the list cannot be read, claude --resume <args> (its own picker), never new
#     new        cd <folder> && claude --name <name> <args>
#     stop       claude stop <id> of its newest running session; --extras: every other one
#     logs       claude logs <id> of its newest session
#     hint       how to find and resume the agent by hand (when the list cannot be read)
#   agent-adapter-claude list       name<TAB>session id<TAB>state<TAB>folder, newest first
#   agent-adapter-claude supports   the verbs above, one per line
# Exit: 0 done, 1 failed, 2 bad use, 3 not supported.
#
# Identity by name and folder, action by id: a session is the agent's when its cwd is the
# folder and its name is the agent's name (or "<name> (2)", how Claude Code numbers a
# collision), read from `claude agents --json --all`. attach, stop and logs then take the
# session's short id (the "id" field; the full sessionId when there is none), never the
# name: `claude attach host` would match part of a name ("host-review" too) and only while
# the session runs. A stopped session is woken by its full id with --bg --resume, never
# with -c or --resume <name>, which start copies. The JSON is read with sed (no jq or
# python in the Feature), as claude-host does; entries are flat objects.
set -u

die() { local rc="$1"; shift; printf 'agent-adapter-claude: %s\n' "$*" >&2; exit "$rc"; }
note() { printf 'agent-adapter-claude: %s\n' "$*" >&2; }

field() { # field <entry> <key>: a string value
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\\\]\|\\\\.\)*\)\".*/\1/p" | sed 's/\\\(.\)/\1/g'
}
number() { # number <entry> <key>
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
}

# json_array: from stdin, the JSON array `claude agents --json` prints, even when other lines
# come before or after it (a notice while the daemon restarts after an update): from the first
# line that starts with `[` followed by `{`, `]` or nothing, through that line when it also
# ends with `]` (all on one line), else through the first line that is only `]` (pretty-
# printed) or ends with `}]` (one entry per line). Entries are flat objects, so no line inside
# the array ends that way. Returns 1 when there is no such array.
json_array() {
  awk '
    !on && /^[[:space:]]*\[[[:space:]]*(\{|\]|$)/ { on = 1; print; if ($0 ~ /\][[:space:]]*$/) { done = 1; exit } ; next }
    on { print; if ($0 ~ /^[[:space:]]*\][[:space:]]*$/ || $0 ~ /\}[[:space:]]*\][[:space:]]*$/) { done = 1; exit } }
    END { exit done ? 0 : 1 }'
}

# read_agents <timeout>: `claude agents --json --all` within <timeout> seconds, and plain
# `--json` only when this Claude Code refuses --all as unknown (an older one; any other failure
# of --all is not a reason to read a list without the stopped sessions). LIST holds the array,
# else REASON says why: the exit code or the time-out, and the first line it printed as it is
# (cut short), and AGAIN is 1 when asking again may help (a time-out, or nothing printed; a
# quick error with a message will not change). The output goes to files, not a pipe, so a
# process that keeps it open cannot hang the read.
read_agents() {
  local t="$1" d rc first a
  AGAIN=0
  d="$(mktemp -d 2>/dev/null)" || { REASON='no temporary folder for its output'; return 1; }
  for a in --all ''; do
    timeout "$t" claude agents --json ${a:+"$a"} >"$d/out" 2>"$d/err" </dev/null; rc=$?
    if [ "$rc" -eq 0 ] && LIST="$(json_array < "$d/out")"; then rm -rf "$d"; return 0; fi
    first="$(cat "$d/err" "$d/out" 2>/dev/null | tr -d '\r' | grep -m 1 '[^[:space:]]' | cut -c1-160)"
    case "$rc" in
      0) REASON="'claude agents --json${a:+ $a}' printed no JSON list" ;;
      124 | 137) REASON="'claude agents --json${a:+ $a}' timed out after ${t}s" ;;
      *) REASON="'claude agents --json${a:+ $a}' exited $rc" ;;
    esac
    REASON="$REASON${first:+: $first}"
    case "$rc" in 124 | 137) AGAIN=1 ;; *) [ -n "$first" ] || AGAIN=1 ;; esac
    case "$first" in
      *[Uu]nknown\ option*)
        REASON="$REASON. A wrapper or alias in front of claude may be rewriting its arguments: claude here is $(command -v claude 2>/dev/null || echo '(not found)')" ;;
    esac
    if [ -z "$a" ] || [ "$rc" -eq 0 ] || ! grep -qi "unknown option.*--all" "$d/err" "$d/out" 2>/dev/null; then break; fi
  done
  rm -rf "$d"
  return 1
}

# sessions: one line per session, newest first:
#   name sessionId state cwd shortid kind pid startedAt   (tab-separated)
# state: running (a pid, or a background state that says so), failed, stopped.
# The first read after a Claude Code update may be slow (its daemon restarts), so a read that
# timed out or printed nothing is tried once more after AGENT_ADAPTER_CLAUDE_PAUSE seconds
# (default 3) with three times the time-out (AGENT_ADAPTER_CLAUDE_TIMEOUT, default 30); a quick
# error with a message is not. When it fails, the reason is said on stderr and it returns 1.
sessions() {
  local out entry name sid id cwd pid kind st started LIST='' REASON='' AGAIN=0 t="${AGENT_ADAPTER_CLAUDE_TIMEOUT:-30}"
  case "$t" in '' | *[!0-9]*) t=30 ;; esac
  if ! read_agents "$t"; then
    local ok=''
    if [ "$AGAIN" = 1 ]; then
      sleep "${AGENT_ADAPTER_CLAUDE_PAUSE:-3}"
      read_agents $((t * 3)) && ok=1
    fi
    [ -n "$ok" ] || { note "the session list could not be read: $REASON."; return 1; }
  fi
  out="$(printf '%s' "$LIST" | tr -d '\n\r')"
  while IFS= read -r entry || [ -n "$entry" ]; do
    sid="$(field "$entry" sessionId)"
    [ -n "$sid" ] || continue
    name="$(field "$entry" name)" id="$(field "$entry" id)" cwd="$(field "$entry" cwd)"
    kind="$(field "$entry" kind)" pid="$(number "$entry" pid)" started="$(number "$entry" startedAt)"
    st="$(field "$entry" state)"; [ -n "$st" ] || st="$(field "$entry" status)"
    if [ "${pid:-0}" -gt 0 ]; then st=running
    else
      case "${st,,}" in
        running | idle | busy | working | waiting | starting) st=running ;;
        fail* | error* | crash*) st=failed ;;
        *) st=stopped ;;
      esac
    fi
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name//$'\t'/ }" "$sid" "$st" "$cwd" "${id:-$sid}" "${kind:-unknown}" "${pid:-0}" "${started:-0}"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g') | sort -t $'\t' -k8,8nr
}

# mine [state]: the agent's sessions (NAME in FOLDER), newest first, optionally one state.
mine() {
  local want="${1:-}" nm rest st fo
  [ -n "${ALL+x}" ] || ALL="$(sessions)" || return 1
  while IFS=$'\t' read -r nm rest; do
    [ -n "$nm" ] || continue
    st="$(printf '%s' "$rest" | cut -f2)" fo="$(printf '%s' "$rest" | cut -f3)"
    [ "$fo" = "$FOLDER" ] || continue
    case "$nm" in "$NAME") ;; "$NAME ("*")") [[ "$nm" =~ \([0-9]+\)$ ]] || continue ;; *) continue ;; esac
    [ -z "$want" ] || [ "$st" = "$want" ] || continue
    printf '%s\t%s\n' "$nm" "$rest"
  done <<< "$ALL"
}
col() { printf '%s\n' "$1" | head -n 1 | cut -f"$2"; }

# wait_running: after a --bg start, wait (AGENT_ADAPTER_WAIT seconds, default 10) until the
# session is in the list, and print its session id.
wait_running() {
  local left="${AGENT_ADAPTER_WAIT:-10}" got
  while :; do
    unset ALL
    got="$(mine running)" || { note "$NAME: started, but its session list cannot be read to confirm it."; return 0; }
    [ -n "$got" ] && { col "$got" 2; return 0; }
    [ "$left" -le 0 ] && { note "$NAME: started, but not in 'claude agents' yet."; return 0; }
    sleep 1; left=$((left - 1))
  done
}

extras_note() { # extras_note <running lines>
  local n; n="$(printf '%s\n' "$1" | grep -c .)"
  [ "$n" -gt 1 ] && note "$NAME: $n running sessions; using the newest ($(col "$1" 2)). task agents:stop -- $NAME --extras stops the others."
  return 0
}

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  supports) printf '%s\n' start-bg wake attach resume new list stop logs hint supports; exit 0 ;;
  list)
    ALL="$(sessions)" || exit 1
    printf '%s\n' "$ALL" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 }'
    exit 0 ;;
  start-bg | wake | attach | resume | new | stop | logs | hint) ;;
  '') die 2 "usage: agent-adapter-claude <verb> <name> <folder> [-- claude args]" ;;
  *) die 3 "'$verb' is not supported" ;;
esac
[ $# -ge 2 ] || die 2 "$verb needs <name> <folder>"
NAME="$1" FOLDER="$2"; shift 2
extras=''
while [ $# -gt 0 ]; do
  case "$1" in
    --extras) extras=1 ;;
    --) shift; break ;;
    *) die 2 "unknown flag '$1' (claude arguments go after --)" ;;
  esac
  shift
done
given="$FOLDER"
FOLDER="$(cd "$FOLDER" 2>/dev/null && pwd -P)" || die 1 "folder '$given' does not exist"
case "$verb" in
  start-bg | new) ;;
  hint)
    # how to find the agent's conversation by hand when its sessions cannot be listed
    echo "see whether $NAME runs: claude agents (its view lists the background sessions; attach from there)"
    echo "resume its conversation by hand, if it does not run: cd '$FOLDER' && claude --resume (pick '$NAME')"
    exit 0 ;;
  resume)
    if ! ALL="$(sessions)"; then
      # never a fresh session in its place: Claude Code's own picker, where the person chooses
      note "$NAME: its latest session cannot be found, so Claude Code's own picker opens instead: pick '$NAME' (and not one that runs elsewhere, which would be a second copy)."
      cd "$FOLDER" && exec claude --resume "$@"
      exit 1
    fi ;;
  *) ALL="$(sessions)" || exit 1 ;;
esac

case "$verb" in
  start-bg)
    (cd "$FOLDER" && claude --bg --name "$NAME" "$@" </dev/null >&2) || die 1 "$NAME: 'claude --bg' failed (a folder never trusted fails with 'Workspace not trusted': run claude there once and accept)."
    wait_running ;;
  wake)
    got="$(mine)"
    s="$(printf '%s\n' "$got" | awk -F'\t' '$3 == "stopped" || $3 == "failed"' | head -n 1)"
    [ -n "$s" ] || die 1 "$NAME: no stopped session to wake in $FOLDER."
    (cd "$FOLDER" && claude --bg --resume "$(col "$s" 2)" </dev/null >&2) || die 1 "$NAME: 'claude --bg --resume' failed."
    wait_running ;;
  attach)
    run="$(mine running)"
    if [ -z "$run" ]; then
      s="$(mine | head -n 1)"
      [ -n "$s" ] || die 1 "$NAME: no session in $FOLDER to attach to."
      # attaching to a stopped or failed session restarts it from its saved conversation
      exec claude attach "$(col "$s" 5)"
    fi
    extras_note "$run"
    if [ "$(col "$run" 6)" = interactive ]; then
      tty="$(ps -o tty= -p "$(col "$run" 7)" 2>/dev/null | tr -d '[:space:]')"
      die 1 "$NAME: its session $(col "$run" 2) (pid $(col "$run" 7)) is held by a terminal${tty:+ ($tty)}; switch to that terminal (or Remote Control). claude attach does not reach an interactive session."
    fi
    exec claude attach "$(col "$run" 5)" ;;
  resume)
    s="$(mine | head -n 1)"
    [ -n "$s" ] || die 1 "$NAME: no earlier conversation in $FOLDER to resume; task agents -- $NAME starts one."
    if [ "$(col "$s" 3)" = running ]; then
      die 1 "$NAME: its latest session $(col "$s" 2) is running (pid $(col "$s" 7)); resuming it here would be a second copy. Switch to it, or stop it first."
    fi
    cd "$FOLDER" && exec claude --resume "$(col "$s" 2)" "$@" ;;
  new)
    cd "$FOLDER" && exec claude --name "$NAME" "$@" ;;
  stop)
    run="$(mine running)"
    [ -n "$run" ] || { echo "$NAME: not running"; exit 0; }
    if [ -n "$extras" ]; then targets="$(printf '%s\n' "$run" | tail -n +2)"
    else targets="$(printf '%s\n' "$run" | head -n 1)"; extras_note "$run"; fi
    [ -n "$targets" ] || { echo "$NAME: no extra sessions"; exit 0; }
    rc=0
    while IFS=$'\t' read -r _ sid _ _ short kind pid _; do
      if [ "$kind" = interactive ]; then
        note "$NAME: session $sid (pid $pid) is held by a terminal; end it there."; rc=1; continue
      fi
      if claude stop "$short" </dev/null >/dev/null; then echo "$NAME: stopped $sid (its conversation is kept)"
      else note "$NAME: 'claude stop $short' failed."; rc=1; fi
    done <<< "$targets"
    exit "$rc" ;;
  logs)
    s="$(mine running | head -n 1)"; [ -n "$s" ] || s="$(mine | head -n 1)"
    [ -n "$s" ] || die 1 "$NAME: no session in $FOLDER."
    [ "$(col "$s" 6)" = interactive ] && die 1 "$NAME: its session is interactive; claude logs reads background sessions only."
    exec claude logs "$(col "$s" 5)" ;;
esac
