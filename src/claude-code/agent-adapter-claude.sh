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
#                refused while that session runs (a second process on one transcript)
#     new        cd <folder> && claude --name <name> <args>
#     stop       claude stop <id> of its newest running session; --extras: every other one
#     logs       claude logs <id> of its newest session
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

# sessions: one line per session, newest first:
#   name sessionId state cwd shortid kind pid startedAt   (tab-separated)
# state: running (a pid, or a background state that says so), failed, stopped.
sessions() {
  local out entry name sid id cwd pid kind st started
  out="$(timeout 30 claude agents --json --all 2>/dev/null)" ||
    out="$(timeout 30 claude agents --json 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '\n\r')"
  case "$out" in '['*) ;; *) return 1 ;; esac
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
    got="$(mine running)"
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
  supports) printf '%s\n' start-bg wake attach resume new list stop logs supports; exit 0 ;;
  list)
    ALL="$(sessions)" || die 1 "'claude agents --json' could not be read."
    printf '%s\n' "$ALL" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 }'
    exit 0 ;;
  start-bg | wake | attach | resume | new | stop | logs) ;;
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
  *) ALL="$(sessions)" || die 1 "'claude agents --json' could not be read (Claude Code 2.1.290 or later is needed)." ;;
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
