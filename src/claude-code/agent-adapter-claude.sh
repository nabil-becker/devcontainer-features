#!/usr/bin/env bash
# agent-adapter-claude: the Claude Code adapter of the agents Feature's contract
# (docs/proposals/agents.md, section 5). Installed on PATH by the claude-code Feature; the
# agents Feature calls it, nothing else does.
#
#   agent-adapter-claude <verb> <name> <folder> [--extras] [-- claude args...]
#     start-bg   cd <folder> && claude --bg --name <name> <args>; prints the new session's id
#     wake       the agent's newest stopped or failed session, by its full id:
#                cd <folder> && claude --bg --resume <session id> (the same id, its conversation,
#                its saved options) when Claude Code's saved options for it are --name <name>
#                <args> and its own state.json says it ended; otherwise ... --resume <session id>
#                --name <name> <args> (a copy)
#     attach     claude attach <id> of its newest running session (a terminal is needed); an
#                ended one is attached (restarted) only when wake would wake it bare, else
#                woken as wake does, then attached
#     resume     cd <folder> && claude --resume <session id> <args> of its newest session;
#                refused while that session runs (a second process on one transcript); when
#                the list cannot be read, claude --resume <args> (its own picker), never new
#     new        cd <folder> && claude --name <name> <args>
#     stop       claude stop <id> of its newest running session; --extras: every other one
#     logs       claude logs <id> of its newest session
#     hint       how to find and resume the agent by hand (when the list cannot be read)
#     record     record the agent's running session as the agent's (or clear its record)
#   agent-adapter-claude session-busy <id>     exit 0 when that session is mid-turn, 1 when not, 3 unknown
#   agent-adapter-claude session-stop <id>     claude stop that session (the list's id)
#   agent-adapter-claude session-remove <id>   claude rm that ended session (never a running one)
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
# with -c or --resume <name>, which start copies; Claude Code puts its saved options back,
# and a flag given with --bg --resume starts a copy instead, so flags go with it only when the
# saved options are not the agent's ("saved options" below). The JSON is read with sed (no jq or
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
#   name sessionId state cwd shortid kind pid startedAt activity   (tab-separated)
# activity: busy (mid-turn: status busy, or a background state of working), idle (status idle
# or waiting, a state of blocked, or not running), unknown (running, and neither says).
# state: running (a pid, or a background state that says so), failed, stopped.
# The first read after a Claude Code update may be slow (its daemon restarts), so a read that
# timed out or printed nothing is tried once more after AGENT_ADAPTER_CLAUDE_PAUSE seconds
# (default 3) with three times the time-out (AGENT_ADAPTER_CLAUDE_TIMEOUT, default 30); a quick
# error with a message is not. When it fails, the reason is said on stderr and it returns 1.
sessions() {
  local out entry name sid id cwd pid kind st bst pst act started LIST='' REASON='' AGAIN=0 t="${AGENT_ADAPTER_CLAUDE_TIMEOUT:-30}"
  case "$t" in '' | *[!0-9]*) t=30 ;; esac
  command -v claude >/dev/null 2>&1 || { note "the session list could not be read: claude is not installed (not on PATH)."; return 1; }
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
    bst="$(field "$entry" state)" pst="$(field "$entry" status)"
    st="$bst"; [ -n "$st" ] || st="$pst"
    case "${pst,,}:${bst,,}" in
      busy:* | *:working) act=busy ;;
      idle:* | waiting:* | *:blocked) act=idle ;;
      *) act=unknown ;;
    esac
    if [ "${pid:-0}" -gt 0 ] && [ "${bst,,}" = "done" ]; then st=stopped  # finished, process alive: wake stops it first
    elif [ "${pid:-0}" -gt 0 ]; then st=running
    else
      case "${st,,}" in
        running | idle | busy | working | waiting | blocked | starting) st=running ;;
        fail* | error* | crash*) st=failed ;;
        *) st=stopped ;;
      esac
    fi
    cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "${cwd%/}")"
    [ "$st" = running ] || act=idle
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${name//$'\t'/ }" "$sid" "$st" "$cwd" "${id:-$sid}" "${kind:-unknown}" "${pid:-0}" "${started:-0}" "$act"
  done < <(printf '%s' "$out" | sed 's/}[[:space:]]*,[[:space:]]*{/}\n{/g') | sort -t $'\t' -k8,8nr
}

# ------------------------------------------------------------------ records ----
# Claude Code may retitle a background session after a prompt (the name given with --name
# does not always stay), so the name alone does not find the agent again. The adapter records
# which session is the agent's when it starts, wakes or opens one: agent name, folder, the
# session's short job id and its full session id, one line each, in
#   $AGENT_ADAPTER_CLAUDE_STATE/agents.tsv  (default $CLAUDE_CONFIG_DIR/agent-adapter-claude,
#   the claude-code Feature's volume, so it survives a rebuild; folder 700, file 600)
# never in the repository. A recorded session still listed is the agent's whatever its name
# now is: by its job id (which stays across /clear, while the session id changes), else by
# its session id (a wake that continued under a new job id). Otherwise the name and folder
# find it, as before.
state_dir() { printf '%s' "${AGENT_ADAPTER_CLAUDE_STATE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-adapter-claude}"; }
RECORDS="$(state_dir)/agents.tsv"

# rec_get <name> <folder>: RID and RSID of the agent's record (empty when none).
rec_get() {
  RID='' RSID=''
  [ -r "$RECORDS" ] || return 0
  local line
  line="$(awk -F'\t' -v n="$1" -v f="$2" '$1 == n && $2 == f { l = $0 } END { if (l != "") print l }' "$RECORDS")"
  [ -n "$line" ] || return 0
  RID="$(printf '%s' "$line" | cut -f3)" RSID="$(printf '%s' "$line" | cut -f4)"
}

# rec_del <name> <folder>: remove the agent's record (never fatal).
rec_del() {
  [ -e "$RECORDS" ] || return 0
  local tmp
  tmp="$(umask 077 && mktemp "$(state_dir)/.agents.XXXXXX" 2>/dev/null)" || return 0
  if ! { awk -F'\t' -v n="$1" -v f="$2" '!($1 == n && $2 == f)' "$RECORDS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RECORDS"; }; then
    rm -f "$tmp"
  fi
}

# rec_put <name> <folder> <id> <session id>: replace the agent's record (never fatal).
rec_put() {
  local d tmp
  d="$(state_dir)"
  if ! (umask 077 && mkdir -p "$d") 2>/dev/null; then note "$1: could not keep its session record under $d."; return 0; fi
  chmod 700 "$d" 2>/dev/null || true
  tmp="$(umask 077 && mktemp "$d/.agents.XXXXXX" 2>/dev/null)" || { note "$1: could not keep its session record under $d."; return 0; }
  { [ -r "$RECORDS" ] && awk -F'\t' -v n="$1" -v f="$2" '!($1 == n && $2 == f)' "$RECORDS"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORDS" || { rm -f "$tmp"; note "$1: could not keep its session record under $d."; }
}

# apply_records: the session lines on stdin with every recorded session given its agent's
# name and folder (by job id, else session id), so a retitled session still reads as the agent,
# and an R in a tenth column.
apply_records() {
  if [ -r "$RECORDS" ]; then
    awk -F'\t' -v OFS='\t' 'NR == FNR { if ($3 != "") byid[$3] = $1 "\t" $2; if ($4 != "") bysid[$4] = $1 "\t" $2; next }
      { r = ($5 in byid) ? byid[$5] : (($2 in bysid) ? bysid[$2] : "")
        if (r != "") { split(r, p, "\t"); $1 = p[1]; $4 = p[2]; print $0 "\tR"; next }
        print }' "$RECORDS" -
  else
    cat
  fi
}

# resolve_record: for the agent (NAME in FOLDER), REC_SID is its recorded session's id in ALL
# (empty when it has no record or the session is gone); says on stderr how a changed or missing
# session was resolved, and keeps the record current.
resolve_record() {
  local line id sid
  REC_SID=''
  rec_get "$NAME" "$FOLDER"
  [ -n "$RID$RSID" ] || return 0
  line="$(printf '%s\n' "$ALL" | awk -F'\t' -v i="$RID" 'i != "" && $5 == i' | head -n 1)"
  if [ -n "$line" ]; then
    sid="$(col "$line" 2)"
    if [ "$sid" != "$RSID" ]; then
      note "$NAME: its session $RID now holds session id $sid (was $RSID, a /clear starts a new one); following the job id."
      rec_put "$NAME" "$FOLDER" "$RID" "$sid"
    fi
    REC_SID="$sid"; return 0
  fi
  line="$(printf '%s\n' "$ALL" | awk -F'\t' -v s="$RSID" 's != "" && $2 == s' | head -n 1)"
  if [ -n "$line" ]; then
    id="$(col "$line" 5)"
    note "$NAME: its session $RSID now runs as job $id (was $RID); following the session id."
    rec_put "$NAME" "$FOLDER" "$id" "$RSID"
    REC_SID="$RSID"; return 0
  fi
  note "$NAME: its recorded session (${RID:-$RSID}) is no longer listed; finding it by name and folder."
}

# mine [state]: the agent's sessions, optionally one state: its recorded session first (by id,
# whatever its name now is), then those with its name ("<name> (2)" too) in its folder, newest
# first. Callers take a running one before an ended one: a live session always wins.
mine() {
  local want="${1:-}" nm rest st fo sid first='' others=''
  if [ -z "${ALL+x}" ]; then ALL="$(sessions | apply_records)" || return 1; fi
  [ -n "${REC_SID+x}" ] || resolve_record
  while IFS=$'\t' read -r nm rest; do
    [ -n "$nm" ] || continue
    sid="$(printf '%s' "$rest" | cut -f1)" st="$(printf '%s' "$rest" | cut -f2)" fo="$(printf '%s' "$rest" | cut -f3)"
    [ -z "$want" ] || [ "$st" = "$want" ] || continue
    if [ -n "$REC_SID" ] && [ "$sid" = "$REC_SID" ]; then first="$nm"$'\t'"$rest"; continue; fi
    [ "$fo" = "$FOLDER" ] || continue
    case "$nm" in "$NAME") ;; "$NAME ("*")") [[ "$nm" =~ \([0-9]+\)$ ]] || continue ;; *) continue ;; esac
    others="$others$nm"$'\t'"$rest"$'\n'
  done <<< "$ALL"
  [ -z "$first" ] || printf '%s\n' "$first"
  printf '%s' "$others"
}
col() { printf '%s\n' "$1" | head -n 1 | cut -f"$2"; }

# wait_running <ids before> [<session id>]: after a --bg start or wake, wait (AGENT_ADAPTER_WAIT
# seconds, default 10) until the session runs: the given session id, else a running session
# with the agent's name in its folder that was not listed before. Record it as the agent's and
# print its session id.
wait_running() {
  local before="$1" want="${2:-}" left="${AGENT_ADAPTER_WAIT:-10}" all got
  while :; do
    if all="$(sessions)"; then
      got=''
      [ -n "$want" ] && got="$(printf '%s\n' "$all" | awk -F'\t' -v s="$want" '$2 == s && $3 == "running"' | head -n 1)"
      [ -n "$got" ] || got="$(printf '%s\n' "$all" | awk -F'\t' -v n="$NAME" -v f="$FOLDER" -v b="$before" '
        BEGIN { split(b, x, " "); for (k in x) old[x[k]] = 1 }
        $3 == "running" && $4 == f && ($1 == n || index($1, n " (") == 1) && !($2 in old)' | head -n 1)"
      if [ -n "$got" ]; then
        rec_put "$NAME" "$FOLDER" "$(col "$got" 5)" "$(col "$got" 2)"
        col "$got" 2; return 0
      fi
    else
      note "$NAME: started, but its session list cannot be read to confirm and record it."; return 0
    fi
    [ "$left" -le 0 ] && { note "$NAME: started, but not in 'claude agents' yet; not recorded."; return 0; }
    sleep 1; left=$((left - 1))
  done
}
ids_now() { sessions 2>/dev/null | cut -f2 | tr '\n' ' '; }

# ------------------------------------------------------------ saved options ----
# Claude Code keeps the options a background session was started with (its "saved options",
# the respawnFlags in $CLAUDE_CONFIG_DIR/jobs/<short id>/state.json) and puts them back when the
# session is woken bare (`claude --bg --resume <session id>`, or `claude attach <id>` of an ended
# one): `note: woke session <id> with its saved options (--name, --agent, --settings, --model)`.
# Any flag given with --bg --resume makes Claude Code start a copy under a new id instead
# (`the flags you passed started a copy as <id>`; 2.1.308). So a session is woken bare only when
# its saved options are exactly what start-bg passes for the agent (--name <name> and its args);
# when they differ (the args changed, or the session was started without them) or cannot be read,
# it is woken with --name <name> and the args, so the agent never runs without its options. The
# same when Claude Code's own state for it (state.json "state") is not an ended one although the
# list shows it ended: after a rebuild a bare wake of it starts a copy without any options.
jobs_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"; }

# saved_flags <short id>: the session's saved options, one JSON string per line as the file holds
# it (still escaped); returns 1 when they cannot be read.
saved_flags() {
  local f; f="$(jobs_dir)/$1/state.json"
  [ -n "$1" ] && [ -r "$f" ] || return 1
  awk 'BEGIN { RS = "\001" } { s = s $0 } END {
    i = index(s, "\"respawnFlags\""); if (!i) exit 1
    s = substr(s, i + 14)
    if (!match(s, /^[ \t\r\n]*:[ \t\r\n]*\[/)) exit 1
    s = substr(s, RLENGTH + 1); n = length(s); tok = ""; ins = 0; esc = 0
    for (k = 1; k <= n; k++) {
      c = substr(s, k, 1)
      if (ins) {
        if (esc) { tok = tok c; esc = 0 } else if (c == "\\") { tok = tok c; esc = 1 }
        else if (c == "\"") { print tok; tok = ""; ins = 0 } else tok = tok c
        continue
      }
      if (c == "\"") { ins = 1; continue }
      if (c == "]") exit 0
      if (c ~ /[ \t\r\n,]/) continue
      exit 1
    }
    exit 1 }' "$f"
}

# want_flags <args...>: what start-bg passes for the agent (--name <name> <args>), as Claude
# Code saves it (2.1.308, checked): in a fixed order, --name, --settings <path>, --agent <name>,
# --model <m>, whichever are present, whatever order the list gave them in; a repeated flag keeps
# the last value (two --settings: the last wins). Any other arg is assumed saved too (not
# checked), after those four in the order given, so an unknown flag compares strictly. Encoded
# as saved_flags prints it (JSON string escapes, as Claude Code writes them).
want_flags() {
  local a v_name="$NAME" v_settings='' v_agent='' v_model='' rest=() out=()
  local h_settings='' h_agent='' h_model=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) [ $# -ge 2 ] && { v_name="$2"; shift 2; continue; } ;;
      --settings) [ $# -ge 2 ] && { v_settings="$2"; h_settings=1; shift 2; continue; } ;;
      --agent) [ $# -ge 2 ] && { v_agent="$2"; h_agent=1; shift 2; continue; } ;;
      --model) [ $# -ge 2 ] && { v_model="$2"; h_model=1; shift 2; continue; } ;;
    esac
    rest+=("$1"); shift
  done
  out=(--name "$v_name")
  [ -z "$h_settings" ] || out+=(--settings "$v_settings")
  [ -z "$h_agent" ] || out+=(--agent "$v_agent")
  [ -z "$h_model" ] || out+=(--model "$v_model")
  out+=("${rest[@]}")
  for a in "${out[@]}"; do
    a="${a//\\/\\\\}"; a="${a//\"/\\\"}"; a="${a//$'\n'/\\n}"; a="${a//$'\t'/\\t}"; a="${a//$'\r'/\\r}"
    printf '%s\n' "$a"
  done
}

# saved_state <short id>: the session's own state in its state.json (the top-level "state":
# running, starting, working, stopped, done, failed, ... as Claude Code 2.1.308 writes it);
# returns 1 when it cannot be read.
saved_state() {
  local f v; f="$(jobs_dir)/$1/state.json"
  [ -n "$1" ] && [ -r "$f" ] || return 1
  v="$(tr -d '\n\r' < "$f" | sed -n 's/^[[:space:]]*{[[:space:]]*"state"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')"
  [ -n "$v" ] || v="$(tr -d '\n\r' < "$f" | grep -o '"state"[[:space:]]*:[[:space:]]*"[^"\\]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# bare_ok <short id> <args...>: 0 when a bare wake (or claude attach) of that ended session is
# known to bring it back as the agent: its saved options are --name <name> <args>, and Claude
# Code's own state for it is an ended one. A state that still says running (or starting, or
# anything else; after a rebuild the volume keeps the last one) would make Claude Code take it
# for a live session and start a copy without any options. Else 1, with WHY set for the note.
bare_ok() {
  local short="$1" saved st; shift
  if ! saved="$(saved_flags "$short")"; then
    WHY="the options Claude Code saved for its session $short cannot be read ($(jobs_dir)/$short/state.json)"; return 1
  fi
  if [ "$saved" != "$(want_flags "$@")" ]; then
    WHY="its session $short keeps other options than the agent's (--name and its args from the list)"; return 1
  fi
  st="$(saved_state "$short")" || st=''
  case "${st,,}" in
    stopped | done | failed | error* | crash* | exited | killed) return 0 ;;
  esac
  WHY="its session $short is ended in the list but Claude Code's own state for it says '${st:-(none)}' (after a rebuild a bare wake would start a copy without its options)"
  return 1
}

# session_gone <session id> <claude output>: 0 when the resume failed because the session is gone:
# what claude printed, or the state.json detail of any job (the failed resume may run under a new
# short id), says `source session <id> not found` for this session. Any other failure returns 1.
session_gone() {
  local f
  case "$2" in *"source session $1 not found"* | *"source session "*" not found"*) return 0 ;; esac
  [ -n "$1" ] || return 1
  for f in "$(jobs_dir)"/*/state.json; do
    [ -r "$f" ] || continue
    tr -d '\n\r' < "$f" | grep -qF "source session $1 not found" && return 0
  done
  return 1
}

# stop_done <session line>: a session whose state is done may still have a live process (a pid in
# the list); resuming that starts a copy with empty saved options ("already running"; 2.1.308). So
# when the line carries a pid, `claude stop <short id>` that one session (never another), then wait
# (AGENT_ADAPTER_WAIT seconds, default 10) until the list shows it without a pid. Fails when it
# does not stop.
stop_done() {
  local pid short sid left="${AGENT_ADAPTER_WAIT:-10}" all
  pid="$(col "$1" 7)" short="$(col "$1" 5)" sid="$(col "$1" 2)"
  [ "${pid:-0}" -gt 0 ] 2>/dev/null || return 0
  note "$NAME: session $sid is finished but its process (pid $pid) is alive; stopping it before the wake."
  claude stop "$short" </dev/null >/dev/null || { note "$NAME: 'claude stop $short' failed."; return 1; }
  while :; do
    all="$(sessions 2>/dev/null)" && [ -z "$(printf '%s\n' "$all" | awk -F'\t' -v s="$sid" '$2 == s && $7 > 0')" ] && return 0
    [ "$left" -le 0 ] && { note "$NAME: session $sid still has a process after 'claude stop'; not waking it (that would start a copy)."; return 1; }
    sleep 1; left=$((left - 1))
  done
}

# wake_session <session line> <args...>: wake that ended session in the background, bare when
# bare_ok, else with --name <name> <args> (said on stderr); wait until it runs, record it and
# print its session id (the copy's, when Claude Code started one). When the resume fails because
# the session is gone (session_gone), start the agent fresh as start-bg does and say so; any
# other failure fails.
wake_session() {
  local s="$1" sid short before WHY='' out rc=0 got; shift
  sid="$(col "$s" 2)" short="$(col "$s" 5)"
  before="$(printf '%s\n' "$ALL" | cut -f2 | tr '\n' ' ')"
  stop_done "$s" || exit 1
  if bare_ok "$short" "$@"; then
    out="$(cd "$FOLDER" && claude --bg --resume "$sid" </dev/null 2>&1)" || rc=$?
  else
    note "$NAME: $WHY; waking it with the agent's options (--name and its args from the list), which Claude Code may start as a copy under a new id."
    out="$(cd "$FOLDER" && claude --bg --resume "$sid" --name "$NAME" "$@" </dev/null 2>&1)" || rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  got=''
  if [ "$rc" -eq 0 ]; then
    got="$(wait_running "$before" "$sid")"
    [ -z "$got" ] || { printf '%s\n' "$got"; return 0; }
  fi
  if session_gone "$sid" "$out"; then
    note "$NAME: session $sid is gone; started fresh."
    (cd "$FOLDER" && claude --bg --name "$NAME" "$@" </dev/null >&2) || die 1 "$NAME: session $sid is gone and 'claude --bg' failed."
    wait_running "$before"; return 0
  fi
  [ "$rc" -eq 0 ] || die 1 "$NAME: 'claude --bg --resume' failed."
  return 0
}

extras_note() { # extras_note <running lines>
  local n; n="$(printf '%s\n' "$1" | grep -c .)"
  [ "$n" -gt 1 ] && note "$NAME: $n running sessions; using the newest ($(col "$1" 2)). task agents:stop -- $NAME --extras stops the others."
  return 0
}

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  supports) printf '%s\n' start-bg wake attach resume new list stop logs hint record session-busy session-stop session-remove supports; exit 0 ;;
  list)
    # newest first, an agent's recorded session before the others (it is the one the agent is)
    ALL="$(sessions)" || exit 1
    ALL="$(printf '%s\n' "$ALL" | apply_records)"
    printf '%s\n' "$ALL" | awk -F'\t' 'NF && $10 == "R" { print $1 "\t" $2 "\t" $3 "\t" $4 }'
    printf '%s\n' "$ALL" | awk -F'\t' 'NF && $10 != "R" { print $1 "\t" $2 "\t" $3 "\t" $4 }'
    exit 0 ;;
  session-busy)
    # exit 0: that session is mid-turn now; 1: it is not (idle, waiting for input, or ended);
    # 3: Claude Code does not say (the caller treats it as not busy, with a note)
    [ $# -ge 1 ] || die 2 "$verb needs the session id from list"
    ALL="$(sessions)" || exit 1
    s="$(printf '%s\n' "$ALL" | awk -F'\t' -v w="$1" '$2 == w || $5 == w' | head -n 1)"
    [ -n "$s" ] || die 1 "no session $1 in 'claude agents --json --all'."
    case "$(col "$s" 9)" in
      busy) echo "$1: mid-turn"; exit 0 ;;
      idle) echo "$1: not mid-turn"; exit 1 ;;
      *) echo "$1: Claude Code does not say whether it is mid-turn"; exit 3 ;;
    esac ;;
  session-stop | session-remove)
    # by the id `list` printed (the full session id), whatever agent it belongs to
    [ $# -ge 1 ] || die 2 "$verb needs the session id from list"
    want="$1"
    ALL="$(sessions)" || exit 1
    s="$(printf '%s\n' "$ALL" | awk -F'\t' -v w="$want" '$2 == w || $5 == w' | head -n 1)"
    [ -n "$s" ] || die 1 "no session $want in 'claude agents --json --all'."
    if [ "$verb" = session-stop ]; then
      [ "$(col "$s" 3)" = running ] || { echo "$want: not running"; exit 0; }
      [ "$(col "$s" 6)" = interactive ] && die 1 "$want: held by a terminal (pid $(col "$s" 7)); end it there."
      claude stop "$(col "$s" 5)" </dev/null >/dev/null || die 1 "'claude stop $(col "$s" 5)' failed."
      echo "$want: stopped (its conversation is kept)"
    else
      [ "$(col "$s" 3)" = running ] && die 1 "$want: running; stop it first."
      # claude rm keeps the transcript and a worktree with unpushed work, and says so
      # its own "removed <id>" line is dropped: the line below says it once
      rmout="$(claude rm "$(col "$s" 5)" </dev/null 2>&1)" || { printf '%s\n' "$rmout" >&2; die 1 "'claude rm $(col "$s" 5)' failed."; }
      [ -z "$rmout" ] || printf '%s\n' "$rmout" | grep -v '^removed ' >&2 || true
      echo "$want: removed from the session list"
    fi
    exit 0 ;;
  start-bg | wake | attach | resume | new | stop | logs | hint | record) ;;
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
  record)
    # record the session the agent is now: its running one (recorded first), else none
    ALL="$(sessions)" || exit 1
    ALL="$(printf '%s\n' "$ALL" | apply_records)"; resolve_record
    run="$(mine running | head -n 1)"
    if [ -n "$run" ]; then
      rec_put "$NAME" "$FOLDER" "$(col "$run" 5)" "$(col "$run" 2)"
      echo "$NAME: recorded $(col "$run" 2)"
    else
      rec_del "$NAME" "$FOLDER"
      echo "$NAME: no running session; its record is cleared (the next start or wake records one)"
    fi
    exit 0 ;;
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
if [ -n "${ALL+x}" ]; then ALL="$(printf '%s\n' "$ALL" | apply_records)"; resolve_record; fi

case "$verb" in
  start-bg)
    before=''
    if ALL="$(sessions 2>/dev/null)"; then
      before="$(printf '%s\n' "$ALL" | cut -f2 | tr '\n' ' ')"
      ALL="$(printf '%s\n' "$ALL" | apply_records)"
      resolve_record
      run="$(mine running)"
      if [ -n "$REC_SID" ] && [ "$(col "$run" 2)" = "$REC_SID" ]; then
        die 1 "$NAME: its recorded session $REC_SID runs ($(col "$run" 1)); not starting a second one."
      fi
    fi
    (cd "$FOLDER" && claude --bg --name "$NAME" "$@" </dev/null >&2) || die 1 "$NAME: 'claude --bg' failed (a folder never trusted fails with 'Workspace not trusted': run claude there once and accept)."
    wait_running "$before" ;;
  wake)
    got="$(mine)"
    s="$(printf '%s\n' "$got" | awk -F'\t' '$3 == "stopped" || $3 == "failed"' | head -n 1)"
    [ -n "$s" ] || die 1 "$NAME: no stopped session to wake in $FOLDER."
    wake_session "$s" "$@" ;;
  attach)
    run="$(mine running)"
    if [ -z "$run" ]; then
      s="$(mine | head -n 1)"
      [ -n "$s" ] || die 1 "$NAME: no session in $FOLDER to attach to."
      # attaching to a stopped or failed session restarts it with its saved options, so that is
      # done only when they are the agent's; otherwise it is woken with them first, then attached
      if bare_ok "$(col "$s" 5)" "$@"; then
        exec claude attach "$(col "$s" 5)"
      fi
      sid="$(wake_session "$s" "$@")" || exit 1
      [ -n "$sid" ] || die 1 "$NAME: woken in the background, but not listed as running yet; attach again in a moment (task agents -- $NAME)."
      rec_get "$NAME" "$FOLDER"
      [ "$RSID" = "$sid" ] && [ -n "$RID" ] || die 1 "$NAME: woken in the background ($sid), but its id to attach to is not known; attach again in a moment (task agents -- $NAME)."
      exec claude attach "$RID"
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
    # a session id chosen here, so the new conversation is recorded before it starts
    sid=''
    case " $* " in *" --session-id "* | *" --session-id="*) ;; *)
      sid="$(tr -d '\n' < /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)" ;; esac
    if [ -n "$sid" ]; then
      rec_put "$NAME" "$FOLDER" "$sid" "$sid"
      cd "$FOLDER" && exec claude --name "$NAME" --session-id "$sid" "$@"
    fi
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
