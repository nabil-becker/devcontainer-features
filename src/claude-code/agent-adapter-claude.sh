#!/usr/bin/env bash
# agent-adapter-claude: the Claude Code adapter of the agents Feature's contract
# (docs/proposals/agents.md, section 5). Installed on PATH by the claude-code Feature; the
# agents Feature calls it, nothing else does.
#
#   agent-adapter-claude <verb> <name> <folder> [--extras] [-- claude args...]
#     (<name> is the agent's handle. The session's own name is $AGENT_SESSION_NAME when the caller
#     sets it and it is not empty, else the handle: "session name" below; claude-code 1.9.0)
#     start-bg   cd <folder> && claude --bg --name <session name> <args>; prints the new session's id
#     wake       the agent's newest stopped or failed session, by its full id:
#                cd <folder> && claude --bg --resume <session id> (its conversation, the same id on 2.1.308,
#                its saved options), always bare: a flag given with --resume starts a copy that
#                loses the conversation (1.9.3). When Claude Code's saved options lack one the
#                agent wants (--name a name the agent's session has had, or its args) or hold
#                another value for it, one line says so; extra saved options (a --model Claude Code
#                took from the room's settings) are no difference. Woken bare, it may stay idle
#                (no prompt): that is the agent's session, its id printed (1.9.1). Never woken:
#                a session with no transcript (never prompted) or whose job failed with
#                "source session <id> not found"; the agent starts fresh instead. A wake is
#                confirmed for AGENT_ADAPTER_SETTLE seconds (default 5): one that crashes with
#                "not found" is never recorded, the agent starts fresh. A wake that comes back
#                under a new id continuing the same conversation records that id, keeps the old
#                one as superseded, and stops the old one if it still has a process (1.9.4)
#     attach     claude attach <id> of its newest running session (a terminal is needed); an
#                ended one is woken bare as wake does (recorded, the old id superseded when it
#                comes back under a new one), then the session that runs is attached (1.9.6)
#   Every start, wake and attach adds one quiet line to trace.log beside agents.tsv (1.9.6, see trace).
#     resume     cd <folder> && claude --resume <session id> <args> of its newest own conversation
#                (1.9.5): its recorded session, its listed interactive sessions and the ended ones
#                only on disk (an interactive session leaves the list when it ends), newest by
#                transcript; never a background session that is not its recorded one. Refused
#                while one of them runs (a second process on one transcript); when the list
#                cannot be read, claude --resume <args> (its own picker), never new
#     new        cd <folder> && claude --name <session name> <args>
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
# folder and its name is one the agent's session has had (the handle, the session name now, the
# name the record holds and the names it held before: a changed template never orphans a
# session; or "<name> (2)", how Claude Code numbers a collision), read from
# `claude agents --json --all`. attach, stop and logs then take the
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

# pid_live <pid>: 0 when that process runs here and is Claude Code's: $AGENT_ADAPTER_CLAUDE_PROC
# (default /proc) has it, and its command line, when it can be read, names claude. A pid listed
# for a session left before a container restart is not (1.9.6): read as running, such a session
# (a blocked one in the report) was never woken, and attaching to it let Claude Code start a copy.
pid_live() {
  local r="${AGENT_ADAPTER_CLAUDE_PROC:-/proc}" c
  [ -d "$r/$1" ] || return 1
  c="$(tr '\0' ' ' < "$r/$1/cmdline" 2>/dev/null)" || return 0
  case "$c" in '' | *claude*) return 0 ;; esac
  return 1
}

# sessions: one line per session, newest first:
#   name sessionId state cwd shortid kind pid startedAt activity   (tab-separated)
# activity: busy (mid-turn: status busy, or a background state of working), idle (status idle
# or waiting, a state of blocked or done with a live process, or not running), unknown (running,
# and neither says).
# state: running (a pid, whatever its state: a session that finished its turn (done) keeps its
# process until it is stopped and waits for a prompt, so it is up, 1.9.2; or a background state
# that says so, but not blocked without a pid), failed, stopped.
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
      idle:* | waiting:* | *:blocked | *:done) act=idle ;;
      *) act=unknown ;;
    esac
    if [ "${pid:-0}" -gt 0 ] && pid_live "$pid"; then st=running  # a live process: up, even when its turn is done (idle)
    elif [ "${pid:-0}" -gt 0 ]; then
      # (1.9.6) a pid listed whose process is not here (gone with a container restart, or the
      # number taken by another program): ended, whatever state it was left in (blocked too)
      pid=0
      case "${st,,}" in fail* | error* | crash*) st=failed ;; *) st=stopped ;; esac
    else
      case "${st,,}" in
        running | idle | busy | working | waiting | starting) st=running ;;
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
# session's short job id and its full session id, and (1.9.0) the name the session was started
# with and the names it had before (up to 5, separated by \037), one line each, in
#   $AGENT_ADAPTER_CLAUDE_STATE/agents.tsv  (default $CLAUDE_CONFIG_DIR/agent-adapter-claude,
#   the claude-code Feature's volume, so it survives a rebuild; folder 700, file 600)
# never in the repository. A recorded session still listed is the agent's whatever its name
# now is: by its job id (which stays across /clear, while the session id changes), else by
# its session id (a wake that continued under a new job id). Otherwise the name and folder
# find it, as before, by any name the agent has had (a changed session-name template does not
# lose it). Clearing a record keeps the names (a line without ids).
# (1.9.4) A seventh field holds the sessions the agent left in a wake (it came back under a new id,
# crashed, or was gone; up to MAX_EARLIER, separated by \037, newest first): each is superseded,
# never woken or attached as the agent again, and `list` prints it, while it has no process, as
# "<name> (superseded)", which is no name of the agent's, so it is never counted as another copy.
state_dir() { printf '%s' "${AGENT_ADAPTER_CLAUDE_STATE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-adapter-claude}"; }
RECORDS="$(state_dir)/agents.tsv"

US=$'\037'
MAX_HIST=5
MAX_EARLIER=10

# rec_line <name> <folder>: the agent's record line (the last one), empty when none.
rec_line() {
  [ -r "$RECORDS" ] || return 0
  awk -F'\t' -v n="$1" -v f="$2" '$1 == n && $2 == f { l = $0 } END { if (l != "") print l }' "$RECORDS"
}

# rec_get <name> <folder>: RID and RSID of the agent's record, RCUR the name its session was
# started with and RHIST the names before it (empty when none).
rec_get() {
  RID='' RSID='' RCUR='' RHIST=''
  local line
  line="$(rec_line "$1" "$2")"
  [ -n "$line" ] || return 0
  RID="$(printf '%s' "$line" | cut -f3)" RSID="$(printf '%s' "$line" | cut -f4)"
  RCUR="$(printf '%s' "$line" | cut -f5)" RHIST="$(printf '%s' "$line" | cut -f6)"
}

# names_next <current> <history>: NCUR and NHIST once STARTED_AS (when set) is the session's name:
# the name before it goes to the front of the history (no duplicates, at most MAX_HIST).
names_next() {
  local cur="$1" hist="$2" new="${STARTED_AS:-}" h n=0
  NCUR="$cur" NHIST="$hist"
  [ -n "$new" ] && [ "$new" != "$cur" ] || return 0
  NCUR="$new" NHIST=''
  while IFS= read -r h; do
    { [ -n "$h" ] && [ "$h" != "$new" ]; } || continue
    case "$US$NHIST$US" in *"$US$h$US"*) continue ;; esac
    [ "$n" -lt "$MAX_HIST" ] || break
    NHIST="${NHIST:+$NHIST$US}$h" n=$((n + 1))
  done <<< "$cur"$'\n'"${hist//$US/$'\n'}"
}

# cand_names: the names the agent's session may have, one per line: the session name now, the
# handle, the name its record holds and the names before it (RCUR and RHIST, set by rec_get).
cand_names() {
  { printf '%s\n' "$SNAME" "$NAME" "${RCUR:-}"; printf '%s\n' "${RHIST:-}" | tr "$US" '\n'; } | awk 'NF && !seen[$0]++'
}

# rec_del <name> <folder>: clear the agent's record, keeping its names (never fatal).
rec_del() {
  [ -e "$RECORDS" ] || return 0
  local tmp
  tmp="$(umask 077 && mktemp "$(state_dir)/.agents.XXXXXX" 2>/dev/null)" || return 0
  # the names stay (the session may be found by one of them), and the superseded sessions; the ids go
  if ! { awk -F'\t' -v OFS='\t' -v n="$1" -v f="$2" '$1 == n && $2 == f { if ($7 != "") print $1, $2, "", "", $5, $6, $7; else if ($5 != "") print $1, $2, "", "", $5, $6; next } { print }' "$RECORDS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RECORDS"; }; then
    rm -f "$tmp"
  fi
}

# rec_put <name> <folder> <id> <session id> [<session ids left>...]: replace the agent's record,
# with its names and STARTED_AS when set, and the sessions it left (1.9.4: superseded, see above;
# the session it now is never among them) (never fatal).
rec_put() {
  local d tmp old earlier e x n=0
  d="$(state_dir)"
  if ! (umask 077 && mkdir -p "$d") 2>/dev/null; then note "$1: could not keep its session record under $d."; return 0; fi
  chmod 700 "$d" 2>/dev/null || true
  tmp="$(umask 077 && mktemp "$d/.agents.XXXXXX" 2>/dev/null)" || { note "$1: could not keep its session record under $d."; return 0; }
  old="$(rec_line "$1" "$2")"
  names_next "$(printf '%s' "$old" | cut -f5)" "$(printf '%s' "$old" | cut -f6)"
  earlier=''
  while IFS= read -r e; do
    { [ -n "$e" ] && [ "$e" != "$4" ]; } || continue
    case "$US$earlier$US" in *"$US$e$US"*) continue ;; esac
    [ "$n" -lt "$MAX_EARLIER" ] || break
    earlier="${earlier:+$earlier$US}$e" n=$((n + 1))
  done < <(for x in "${@:5}"; do printf '%s\n' "$x"; done; printf '%s\n' "$old" | cut -f7 | tr "$US" '\n')
  { [ -r "$RECORDS" ] && awk -F'\t' -v n="$1" -v f="$2" '!($1 == n && $2 == f)' "$RECORDS"
    printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
    if [ -n "$earlier" ]; then printf '\t%s\t%s\t%s' "$NCUR" "$NHIST" "$earlier"
    elif [ -n "$NCUR" ]; then printf '\t%s%s' "$NCUR" "${NHIST:+$'\t'$NHIST}"; fi
    printf '\n'; } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORDS" || { rm -f "$tmp"; note "$1: could not keep its session record under $d."; }
}

# trace <outcome> [<old session id>] [<new session id>]: one line in $AGENT_ADAPTER_CLAUDE_STATE/
# trace.log (beside agents.tsv; the last TRACE_KEEP lines, default 500) on how an agent came back:
#   <UTC time> <verb> <agent> <folder> <old id or -> <new id or -> <outcome>   (tab-separated)
# the verb the agents Feature called (start-bg, wake, attach), and the outcome: same (woken under
# its own id), continues (a new id continuing it; the old one superseded), new-id (a new id, not
# known to continue it; the old one superseded), fresh (started fresh; the old one superseded),
# started, said-woken, unconfirmed (not recorded), attached; a "; options lack ..." suffix when the
# session that runs lacks the agent's options. Quiet (never on the terminal), never fatal (1.9.6).
trace() {
  local d f n keep="${TRACE_KEEP:-500}"
  d="$(state_dir)" f="$(state_dir)/trace.log"
  (umask 077 && mkdir -p "$d") 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${verb:-?}" "$NAME" "$FOLDER" "${2:--}" "${3:--}" "${1//$'\n'/ }" >> "$f" 2>/dev/null || return 0
  chmod 600 "$f" 2>/dev/null || true
  n="$(wc -l < "$f" 2>/dev/null)" || return 0
  if [ "${n:-0}" -gt $((keep * 2)) ]; then tail -n "$keep" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null; rm -f "$f.tmp"; fi
  return 0
}

# apply_records: the session lines on stdin with every recorded session given its agent's
# name and folder (by job id, else session id), so a retitled session still reads as the agent,
# and an R in a tenth column; a session the agent left (1.9.4) without a process reads as
# "<agent> (superseded)" in the agent's folder, with an S (one with a process is left as it is:
# it is a live copy, and counts as one).
apply_records() {
  if [ -r "$RECORDS" ]; then
    awk -F'\t' -v OFS='\t' 'NR == FNR { if ($3 != "") byid[$3] = $1 "\t" $2; if ($4 != "") bysid[$4] = $1 "\t" $2
        if ($7 != "") { k = split($7, e, "\037"); for (j = 1; j <= k; j++) if (e[j] != "") sup[e[j]] = $1 "\t" $2 }
        next }
      { r = ($5 in byid) ? byid[$5] : (($2 in bysid) ? bysid[$2] : "")
        if (r != "") { split(r, p, "\t"); $1 = p[1]; $4 = p[2]; print $0 "\tR"; next }
        if (($2 in sup) && $3 != "running") { split(sup[$2], p, "\t"); $1 = p[1] " (superseded)"; $4 = p[2]; print $0 "\tS"; next }
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
  # resume reads an ended recorded session from its transcript (1.9.5): nothing to say there
  [ -n "${REC_QUIET:-}" ] || note "$NAME: its recorded session (${RID:-$RSID}) is no longer listed; finding it by name and folder."
}

# name_is_mine <listed name>: one of CANDS (cand_names), or one of them with Claude Code's
# collision number ("<name> (2)").
name_is_mine() {
  local c
  while IFS= read -r c; do
    case "$1" in
      "$c") return 0 ;;
      "$c ("*")") [[ "$1" =~ \([0-9]+\)$ ]] && return 0 ;;
    esac
  done <<< "$CANDS"
  return 1
}

# mine [state]: the agent's sessions, optionally one state: its recorded session first (by id,
# whatever its name now is), then those in its folder with a name it has had (cand_names;
# "<name> (2)" too), newest first. Callers take a running one before an ended one: a live session always wins.
mine() {
  local want="${1:-}" nm rest st fo sid first='' others=''
  if [ -z "${ALL+x}" ]; then ALL="$(sessions | apply_records)" || return 1; fi
  [ -n "${REC_SID+x}" ] || resolve_record
  CANDS="$(cand_names)"
  while IFS=$'\t' read -r nm rest; do
    [ -n "$nm" ] || continue
    sid="$(printf '%s' "$rest" | cut -f1)" st="$(printf '%s' "$rest" | cut -f2)" fo="$(printf '%s' "$rest" | cut -f3)"
    [ -z "$want" ] || [ "$st" = "$want" ] || continue
    if [ -n "$REC_SID" ] && [ "$sid" = "$REC_SID" ]; then first="$nm"$'\t'"$rest"; continue; fi
    [ "$fo" = "$FOLDER" ] || continue
    name_is_mine "$nm" || continue
    others="$others$nm"$'\t'"$rest"$'\n'
  done <<< "$ALL"
  [ -z "$first" ] || printf '%s\n' "$first"
  printf '%s' "$others"
}
col() { printf '%s\n' "$1" | head -n 1 | cut -f"$2"; }

# wait_running <ids before> [<session id>]: after a --bg start or wake, wait (AGENT_ADAPTER_WAIT
# seconds, default 10) until the session runs: the given session id with a live process (listed
# running: a finished session woken bare comes back idle with a pid and its state still done,
# which is listed running, 1.9.2), else a running session with a name the agent's session may have
# (cand_names) in its folder that was not listed before. Record it as the agent's and print its
# session id.
wait_running() {
  local before="$1" want="${2:-}" left="${AGENT_ADAPTER_WAIT:-10}" all got
  while :; do
    if all="$(sessions)"; then
      got=''
      [ -n "$want" ] && got="$(printf '%s\n' "$all" | awk -F'\t' -v s="$want" '$2 == s && $3 == "running"' | head -n 1)"
      [ -n "$got" ] || got="$(printf '%s\n' "$all" | awk -F'\t' -v n="$(cand_names | tr '\n' "$US")" -v f="$FOLDER" -v b="$before" '
        BEGIN { split(b, x, " "); for (k in x) old[x[k]] = 1; m = split(n, nm, "\037") }
        $3 == "running" && $4 == f && !($2 in old) { for (k = 1; k <= m; k++) if (nm[k] != "" && ($1 == nm[k] || index($1, nm[k] " (") == 1)) { print; exit } }')"
      if [ -n "$got" ]; then
        rec_put "$NAME" "$FOLDER" "$(col "$got" 5)" "$(col "$got" 2)" ${LEFT[@]+"${LEFT[@]}"}
        WR_SID="$(col "$got" 2)"; col "$got" 2; return 0
      fi
    else
      note "$NAME: started, but its session list cannot be read to confirm and record it."; return 0
    fi
    [ "$left" -le 0 ] && { note "$NAME: started, but not in 'claude agents' yet; not recorded."; return 0; }
    sleep 1; left=$((left - 1))
  done
}
ids_now() { sessions 2>/dev/null | cut -f2 | tr '\n' ' '; }
LEFT=()  # the sessions a wake leaves (1.9.4): wait_running records them as superseded

# ------------------------------------------------------------ saved options ----
# Claude Code keeps the options a background session was started with (its "saved options",
# the respawnFlags in $CLAUDE_CONFIG_DIR/jobs/<short id>/state.json) and puts them back when the
# session is woken bare (`claude --bg --resume <session id>`, or `claude attach <id>` of an ended
# one): `note: woke session <id> with its saved options (--name, --agent, --settings, --model)`.
# Any flag given with --bg --resume makes Claude Code start a copy under a new id instead
# (`the flags you passed started a copy as <id>`; 2.1.308), and a copy loses the conversation.
# So an existing session is always woken bare (1.9.3). The saved options are only compared with
# what start-bg passes for the agent (--name <a name the agent's session has had> and its args;
# 1.9.0: the name may be the session name now, the handle, or one the record holds, so a changed
# session-name template never turns a wake into a copy): every wanted option present with the same
# value is the agent's as wanted; an extra saved option is no difference (1.9.3: Claude Code saves
# a --model it took from the room's .claude/settings.json, which made every such wake a copy);
# a wanted option that is missing or has another value is said in one line and applies at the
# agent's next fresh start. Claude Code's own state in state.json is not consulted (1.9.1): after
# a container restart it still says "working" for a session that was idle, since Claude Code's
# background service writes the ended state only when it starts again, and a bare wake of it
# continues the same session (checked on 2.1.308).
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

# canon_flags: the options on stdin (one per line) in one order, so two lists that differ only in
# order compare equal: --name, --settings <path>, --agent <name>, --model <m>, whichever are present
# (a repeated one keeps its last value, as Claude Code does: two --settings, the last wins), then
# every other option in the order given. Claude Code 2.1.308 saves the options in the order they
# were given (checked 1.9.1; 1.8.7 took it for a fixed order), and start-bg gives --name first,
# then the args, so the order alone never decides; --remote-control is dropped (see bare_check).
canon_flags() {
  awk '{ t[NR] = $0 }
    END {
      for (k = 1; k <= NR; k++) {
        a = t[k]
        if (a == "--remote-control") continue
        if ((a == "--name" || a == "--settings" || a == "--agent" || a == "--model") && k < NR) { v[a] = t[k + 1]; h[a] = 1; k++; continue }
        r[++n] = a
      }
      split("--name --settings --agent --model", o, " ")
      for (j = 1; j <= 4; j++) if (h[o[j]]) { print o[j]; print v[o[j]] }
      for (j = 1; j <= n; j++) print r[j]
    }'
}

# want_flags <args...>: what start-bg passes for the agent (--name <WANT_NAME, else the session
# name> <args>; a --name in the args wins), encoded as saved_flags prints it (JSON string escapes,
# as Claude Code writes them) and put in canon_flags' order.
want_flags() {
  local a
  for a in --name "${WANT_NAME:-$SNAME}" "$@"; do
    a="${a//\\/\\\\}"; a="${a//\"/\\\"}"; a="${a//$'\n'/\\n}"; a="${a//$'\t'/\\t}"; a="${a//$'\r'/\\r}"
    printf '%s\n' "$a"
  done | canon_flags
}

# units: canon_flags' output on stdin as one option per line: --name, --settings, --agent and
# --model with their value (tab-joined), any other option with the value that follows it when that
# does not start with a dash, else alone.
units() {
  awk '{ t[NR] = $0 }
    END {
      for (k = 1; k <= NR; k++) {
        a = t[k]
        if (k < NR && (a == "--name" || a == "--settings" || a == "--agent" || a == "--model" || (a ~ /^--/ && t[k + 1] !~ /^-/))) { print a "\t" t[k + 1]; k++ }
        else print a
      }
    }'
}

# bare_check <short id> <args...>: what to say about a bare wake (or claude attach) of that ended
# session, which always happens (1.9.3). BARE_NAME is the name the session keeps, empty when that
# is not known; WHY is empty when the saved options hold everything the agent wants (--name one of
# the agent's session names, each of its args with the same value; extra saved options and their
# order do not matter), else says what is missing or differs, or that they cannot be read.
# --remote-control is left out of both sides: Claude Code saves it where it was given (checked
# 1.9.1: `--name n --remote-control --model m`), and turning the remoteControl option on must
# not matter to a wake.
bare_check() {
  local short="$1" saved c want sn miss; shift
  BARE_NAME='' WHY=''
  if ! saved="$(saved_flags "$short")"; then
    WHY="the options Claude Code saved for its session $short cannot be read ($(jobs_dir)/$short/state.json), so whether they are the agent's is not known"; return 0
  fi
  saved="$(printf '%s\n' "$saved" | canon_flags)"
  sn="$(printf '%s\n' "$saved" | awk '$0 == "--name" { getline; print; exit }')"
  sn="${sn//\\\"/\"}"; sn="${sn//\\\\/\\}"
  saved="$(printf '%s\n' "$saved" | units)"
  # the name it keeps is the one saved; the options wanted are compared under it when it is one
  # of the agent's names, else under the session name now (which then shows as the difference)
  c="$SNAME"
  while IFS= read -r want; do [ "$want" = "$sn" ] && { c="$want"; break; }; done < <(cand_names)
  WANT_NAME="$c" want="$(want_flags "$@" | units)"
  WANT_NAME=''
  BARE_NAME="$sn"
  miss="$(printf '%s\n' "$want" | grep -Fxv -f <(printf '%s\n' "$saved") | tr '\t' ' ' | sed 's/\\"/"/g; s/\\\\/\\/g' | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')" || true
  [ -z "$miss" ] && return 0
  WHY="Claude Code's saved options for its session $short lack or differ in: $miss"
  return 0
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

# ------------------------------------------------------ wakes that crash or fork ----
# (1.9.4) Reported on Claude Code 2.1.314: a session that was never prompted has no transcript,
# and waking it crashes (`bg settled <short> (crashed): source session <id> not found` in
# $CLAUDE_CONFIG_DIR/daemon.log, the job failed with that detail), sometimes under a new short id
# that is briefly listed running; and a session that resumes fine may come back under a new id
# (the same conversation), the old one left listed beside it. On 2.1.308 (checked) a session that
# was never prompted has no transcript either, but a bare wake of it continues the same id. So: a
# session with no transcript, or whose job failed with "not found", is never woken (the agent
# starts fresh: there is no conversation to lose); every wake is confirmed for AGENT_ADAPTER_SETTLE
# seconds; and a new id that continues the conversation is recorded as the agent's session.
config_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# transcript_state <session id>: 0 Claude Code keeps a transcript of it
# ($CLAUDE_CONFIG_DIR/projects/<folder>/<session id>.jsonl, in any folder), 1 it keeps none,
# 2 not known (no projects folder: then the wake goes ahead, as before 1.9.4).
transcript_state() {
  local p f
  p="$(config_dir)/projects"
  [ -n "$1" ] && [ -d "$p" ] || return 2
  for f in "$p"/*/"$1".jsonl; do [ -s "$f" ] && return 0; done
  return 1
}

# job_field <short id> <key>: a string field of that job's state.json; returns 1 when unreadable.
job_field() {
  local f; f="$(jobs_dir)/$1/state.json"
  [ -n "$1" ] && [ -r "$f" ] || return 1
  tr -d '\n\r' < "$f" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# job_not_found <short id>: 0 when that job failed because its source session was not found (a
# crashed wake: the session it would continue does not exist; waking it again crashes again).
job_not_found() {
  local f; f="$(jobs_dir)/$1/state.json"
  [ -n "$1" ] && [ -r "$f" ] || return 1
  tr -d '\n\r' < "$f" | grep -q 'source session [^"]* not found'
}

daemon_log() { printf '%s' "${AGENT_ADAPTER_CLAUDE_DAEMON_LOG:-$(config_dir)/daemon.log}"; }
log_size() { local f; f="$(daemon_log)"; if [ -r "$f" ]; then wc -c < "$f" | tr -d ' '; else echo 0; fi; }

# crashed <session id> <daemon.log size before> <claude output> [<short id woken>]: 0 when the wake
# of that session failed with "not found": in what claude printed, the woken job's state.json, any
# job's state.json naming this session, or daemon.log since the wake.
crashed() {
  local sid="$1" off="$2" out="$3" ws="${4:-}" lg size
  case "$out" in *"source session $sid not found"*) return 0 ;; esac
  [ -n "$ws" ] && job_not_found "$ws" && return 0
  session_gone "$sid" "" && return 0
  lg="$(daemon_log)"
  if [ -r "$lg" ]; then
    size="$(log_size)"; [ "$size" -ge "$off" ] 2>/dev/null || off=0
    tail -c +"$((off + 1))" "$lg" 2>/dev/null | grep -qF "source session $sid not found" && return 0
  fi
  return 1
}

# fork_of <session line> <old session id> <old short id> <claude output>: 0 when that session is
# not the old one but continues its conversation: its job resumes the old session id
# (resumeSessionId in its state.json, or (1.9.6) the old id anywhere in it, such as a forked
# respawn's `--fork-session --resume <old id>`), or Claude Code said it woke the old session and named this
# one (`woke session <old short>` with `backgrounded · <new short>`), or its transcript names the
# old session. A copy Claude Code says it started (`started a copy as <id>`) never is.
fork_of() {
  local nsid nshort t
  nsid="$(col "$1" 2)" nshort="$(col "$1" 5)"
  [ -n "$nsid" ] && [ "$nsid" != "$2" ] || return 1
  case "$4" in *"started a copy as $nshort"*) return 1 ;; esac
  [ "$(job_field "$nshort" resumeSessionId)" = "$2" ] && return 0
  [ -r "$(jobs_dir)/$nshort/state.json" ] && grep -qF "\"$2\"" "$(jobs_dir)/$nshort/state.json" && return 0
  case "$4" in *"woke session $3 "*) case "$4" in *"backgrounded · $nshort "*) return 0 ;; esac ;; esac
  for t in "$(config_dir)/projects"/*/"$nsid".jsonl; do
    [ -r "$t" ] && grep -qF "$2" "$t" && return 0
  done
  return 1
}

# scan_wake <session id> <short id> <ids before> <claude output>: one read of the list after a
# wake. SCAN is the list; SELF that session's line when it runs; FORK a session new since the wake,
# in the folder, that continues its conversation (fork_of); NEWRUN a new running session with a
# name the agent's session may have (the 1.9.1 fallback). Returns 1 when the list cannot be read.
scan_wake() {
  local l
  SELF='' FORK='' NEWRUN=''
  SCAN="$(sessions)" || return 1
  SELF="$(printf '%s\n' "$SCAN" | awk -F'\t' -v s="$1" '$2 == s && $3 == "running"' | head -n 1)"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case " $3 " in *" $(col "$l" 2) "*) continue ;; esac
    [ "$(col "$l" 4)" = "$FOLDER" ] || continue
    if fork_of "$l" "$1" "$2" "$4"; then FORK="$l"; break; fi
  done <<< "$SCAN"
  NEWRUN="$(printf '%s\n' "$SCAN" | awk -F'\t' -v n="$(cand_names | tr '\n' "$US")" -v f="$FOLDER" -v b="$3" '
    BEGIN { split(b, x, " "); for (k in x) old[x[k]] = 1; m = split(n, nm, "\037") }
    $3 == "running" && $4 == f && !($2 in old) { for (k = 1; k <= m; k++) if (nm[k] != "" && ($1 == nm[k] || index($1, nm[k] " (") == 1)) { print; exit } }')"
  return 0
}

# start_fresh <why> <ids before> [<session ids left>...]: start the agent fresh as start-bg does
# (a new session, with the agent's flags, WARGS), say why, record it with the sessions it left
# (superseded) and print its id.
start_fresh() {
  local why="$1" before="$2"; shift 2
  LEFT=("$@")
  note "$NAME: $why; started fresh."
  STARTED_AS="$SNAME"
  (cd "$FOLDER" && claude --bg --name "$SNAME" ${WARGS[@]+"${WARGS[@]}"} </dev/null >&2) || die 1 "$NAME: $why, and 'claude --bg' failed."
  WR_SID=''
  wait_running "$before"
  trace "fresh: $why" "${1:-}" "$WR_SID"
}

# wake_session <session line> <args...>: wake that ended session (stopped or failed, so without a
# process: one with a process is listed running and never reaches here, so a resume never starts
# a copy of it, 1.9.2) in the background, always bare (1.9.3: a flag makes Claude Code start a copy
# that loses the conversation), and say on stderr when its saved options lack or differ from what
# the agent wants; confirm it, record it and print its session id. The agent starts fresh (as
# start-bg does, a new session, said on stderr) instead when the session is gone: its job failed
# with "not found" or it has no transcript (never woken, 1.9.4), or the wake fails or crashes with
# "not found" within AGENT_ADAPTER_SETTLE seconds (the crashed attempt never recorded, 1.9.4). A
# wake that comes back under a new id continuing the conversation records the new id, keeps the
# old one as superseded and stops it if it still has a process (1.9.4). Any other failure fails.
wake_session() {
  local s="$1" sid short before WHY='' out rc=0 off k cand csid cshort chosen st kind; shift
  WARGS=("$@")
  sid="$(col "$s" 2)" short="$(col "$s" 5)"
  before="$(printf '%s\n' "$ALL" | cut -f2 | tr '\n' ' ')"
  if job_not_found "$short" || session_gone "$sid" ""; then
    start_fresh "session $sid is gone (Claude Code did not find it when it was woken before), so it is not woken again" "$before" "$sid"; return 0
  fi
  transcript_state "$sid"; rc=$?
  if [ "$rc" -eq 1 ]; then
    start_fresh "session $sid has no transcript (it was never prompted, so there is no conversation to keep; waking it crashes on Claude Code 2.1.314), so it is not woken" "$before" "$sid"; return 0
  fi
  rc=0
  bare_check "$short" "$@"
  [ -z "$WHY" ] || note "$NAME: $WHY; woken as it is (the same conversation), so what differs applies at the agent's next fresh start (agents reset, or the session gone)."
  STARTED_AS="$BARE_NAME"  # the name it keeps (and the record then holds)
  off="$(log_size)"
  out="$(cd "$FOLDER" && claude --bg --resume "$sid" </dev/null 2>&1)" || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  if [ "$rc" -ne 0 ]; then
    if crashed "$sid" "$off" "$out"; then start_fresh "session $sid is gone" "$before" "$sid"; return 0; fi
    die 1 "$NAME: 'claude --bg --resume' failed."
  fi
  # what came back: within AGENT_ADAPTER_WAIT seconds, its own session running, a new one that
  # continues it, or a new running one by the agent's name
  SCAN='' SELF='' FORK='' NEWRUN=''
  k="${AGENT_ADAPTER_WAIT:-10}"; case "$k" in '' | *[!0-9]*) k=10 ;; esac
  while :; do
    scan_wake "$sid" "$short" "$before" "$out" || break
    [ -z "$SELF$FORK$NEWRUN" ] || break
    [ "$k" -le 0 ] && break
    sleep 1; k=$((k - 1))
  done
  # then confirm it for AGENT_ADAPTER_SETTLE seconds: no "not found" crash (a new id may show up
  # meanwhile, so the list is read again each second)
  k="${AGENT_ADAPTER_SETTLE:-5}"; case "$k" in '' | *[!0-9]*) k=5 ;; esac
  while :; do
    cand="${FORK:-${SELF:-$NEWRUN}}"
    csid="$(col "$cand" 2)" cshort="$(col "$cand" 5)"
    if crashed "$sid" "$off" "$out" "$cshort"; then
      [ "$csid" != "$sid" ] || csid=''
      start_fresh "session $sid is gone${csid:+ (its wake crashed as $csid, which is not recorded)}" "$before" "$sid" ${csid:+"$csid"}
      return 0
    fi
    [ "$k" -le 0 ] && break
    sleep 1; k=$((k - 1))
    local pf="$FORK" ps="$SELF" pn="$NEWRUN"
    scan_wake "$sid" "$short" "$before" "$out" || { FORK="$pf" SELF="$ps" NEWRUN="$pn"; continue; }
    [ -n "$FORK" ] || FORK="$pf"
  done
  cand="${FORK:-${SELF:-$NEWRUN}}"
  if [ -n "$cand" ]; then
    # alive: still listed, and not failed since
    chosen="$(printf '%s\n' "$SCAN" | awk -F'\t' -v s="$(col "$cand" 2)" '$2 == s' | head -n 1)"
    st="$(col "$chosen" 3)"
    if [ "$st" = failed ]; then
      die 1 "$NAME: woken, but session $(col "$cand" 2) failed within ${AGENT_ADAPTER_SETTLE:-5}s (not a missing session; its conversation is kept, not recorded): claude logs $(col "$cand" 5)."
    fi
  fi
  if [ -n "$FORK" ]; then
    csid="$(col "$FORK" 2)" cshort="$(col "$FORK" 5)"
    rec_put "$NAME" "$FOLDER" "$cshort" "$csid" "$sid"
    note "$NAME: woken; Claude Code continues its conversation under a new id, $csid (was $sid)."
    opts_of_new "$cshort"
    # the old one: stopped by its id if it still has a process, else left (superseded)
    s="$(printf '%s\n' "$SCAN" | awk -F'\t' -v x="$sid" '$2 == x' | head -n 1)"
    if [ "$(col "$s" 3)" = running ]; then
      kind="$(col "$s" 6)"
      if [ "$kind" = interactive ]; then
        note "$NAME: its old session $sid is held by a terminal (pid $(col "$s" 7)); end it there."
      elif claude stop "$(col "$s" 5)" </dev/null >/dev/null 2>&1; then
        note "$NAME: stopped its old session $sid by its id (it still had a process; its conversation goes on as $csid)."
      else
        note "$NAME: 'claude stop $(col "$s" 5)' of its old session $sid failed; it runs beside $csid."
      fi
    fi
    trace "continues$OPTS_NOTE" "$sid" "$csid"
    printf '%s\n' "$csid"; return 0
  fi
  if [ -n "$cand" ]; then
    csid="$(col "$cand" 2)" cshort="$(col "$cand" 5)"
    if [ "$csid" = "$sid" ]; then
      rec_put "$NAME" "$FOLDER" "$cshort" "$csid"
      trace same "$sid" "$csid"
    else
      # (1.9.6) a new running session by the agent's name in place of the one woken, not known to
      # continue it: it is the agent now, and the one woken is left (superseded), never woken again
      rec_put "$NAME" "$FOLDER" "$cshort" "$csid" "$sid"
      note "$NAME: woken, but Claude Code runs it as a new session, $csid (was $sid; whether it continues the conversation is not known); the old one is left."
      opts_of_new "$cshort"
      trace "new-id$OPTS_NOTE" "$sid" "$csid"
    fi
    printf '%s\n' "$csid"; return 0
  fi
  # Claude Code said it woke this very session (its short id), but the list does not show it
  # yet: it is the agent's, idle until a prompt reaches it (1.9.1); never a fresh start
  case "$out" in
    *"woke session $short "* | *"backgrounded · $short "*)
      rec_put "$NAME" "$FOLDER" "$short" "$sid"
      trace said-woken "$sid" "$sid"
      printf '%s\n' "$sid"; return 0 ;;
  esac
  if [ -z "$SCAN" ]; then note "$NAME: started, but its session list cannot be read to confirm and record it."
  else note "$NAME: started, but not in 'claude agents' yet; not recorded."; fi
  trace unconfirmed "$sid"
  return 0
}

# opts_of_new <short id>: after a wake came back under a new id, say when the options Claude Code
# keeps for it lack or differ from the agent's (the report: a forked respawn kept only --model, so
# the host lost its --agent and --settings); OPTS_NOTE is that for the trace, else empty (1.9.6).
OPTS_NOTE=''
opts_of_new() {
  local short="$1" sn
  OPTS_NOTE=''
  sn="$SNAME"
  bare_check "$short" ${WARGS[@]+"${WARGS[@]}"}
  SNAME="$sn"
  [ -n "$WHY" ] || return 0
  note "$NAME: $WHY; it runs without them until the agent's next fresh start (task agents -- $NAME --new starts one, a new conversation)."
  OPTS_NOTE="; options lack: ${WHY#*lack or differ in: }"
}

# ------------------------------------------------------------------ resume ----
# (1.9.5) `claude agents --json --all` lists an interactive session only while it runs: one ended
# with /exit is gone from it, its transcript kept at $CLAUDE_CONFIG_DIR/projects/<folder slug>/
# <session id>.jsonl, which names the session ("agentName" and "customTitle" lines). The list may
# still hold a background session of the same name and folder (a resident run left it), which is
# not the on-demand agent's conversation. So resume weighs, by the identity rule (name and folder,
# the recorded session first): its recorded session (listed, or ended with a transcript); its
# listed sessions that are interactive (or of no known kind) and not a background job's; and the
# ended sessions only on disk in the folder's transcript folder whose transcript was made in the
# folder (cwd), whose last title is a name the agent's session has had, and that no job of
# $CLAUDE_CONFIG_DIR/jobs names (a background session's). A running one wins (and is refused);
# else the newest by its transcript's time (a listed one without a transcript by its start).
project_dir() { printf '%s/projects/%s' "$(config_dir)" "$(printf '%s' "$FOLDER" | sed 's/[^A-Za-z0-9]/-/g')"; }
transcript_of() { # transcript_of <session id>: its transcript's path (any folder), 1 when none
  local f
  [ -n "$1" ] || return 1
  for f in "$(config_dir)/projects"/*/"$1".jsonl; do [ -s "$f" ] && { printf '%s' "$f"; return 0; }; done
  return 1
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || echo 0; }
job_sids() { # the session ids the background jobs hold, one per line
  local f
  for f in "$(jobs_dir)"/*/state.json; do
    [ -r "$f" ] && tr -d '\n\r' < "$f" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  done
  return 0
}

# resume_candidates: the agent's conversations, one per line: time<TAB>session id<TAB>state<TAB>pid
resume_candidates() {
  local l sid st kind pid started f t nm d seen=' ' jobs listed
  CANDS="$(cand_names)"
  jobs="$(job_sids)"
  listed=" $(printf '%s\n' "$ALL" | cut -f2 | tr '\n' ' ')"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    sid="$(col "$l" 2)" st="$(col "$l" 3)" kind="$(col "$l" 6)" pid="$(col "$l" 7)" started="$(col "$l" 8)"
    if [ "$sid" != "$RSID" ] && [ "$sid" != "${REC_SID:-}" ]; then
      case "$kind" in interactive | unknown) ;; *) continue ;; esac
      ! printf '%s\n' "$jobs" | grep -qxF -- "$sid" || continue
    fi
    if f="$(transcript_of "$sid")"; then t="$(mtime_of "$f")"; else t=$(( ${started:-0} / 1000 )); fi
    printf '%s\t%s\t%s\t%s\n' "$t" "$sid" "$st" "${pid:-0}"; seen="$seen$sid "
  done < <(mine)
  # the recorded session, ended and gone from the list
  if [ -n "$RSID" ] && [[ "$listed" != *" $RSID "* ]] && f="$(transcript_of "$RSID")"; then
    printf '%s\t%s\tstopped\t0\n' "$(mtime_of "$f")" "$RSID"; seen="$seen$RSID "
  fi
  # the ended sessions only on disk
  d="$(project_dir)"
  [ -d "$d" ] || return 0
  while IFS=$'\t' read -r f nm; do
    [ -n "$f" ] || continue
    sid="$(basename "$f" .jsonl)"
    [[ "$seen$listed" != *" $sid "* ]] || continue
    ! printf '%s\n' "$jobs" | grep -qxF -- "$sid" || continue
    name_is_mine "$nm" || continue
    grep -qF -- "\"cwd\":\"$FOLDER\"" "$f" || continue
    printf '%s\t%s\tstopped\t0\n' "$(mtime_of "$f")" "$sid"; seen="$seen$sid "
  done < <(grep -o -H -E '"(agentName|customTitle)":"([^"\\]|\\.)*"' "$d"/*.jsonl 2>/dev/null | awk '
    { if (!match($0, /:"(agentName|customTitle)":"/)) next
      f = substr($0, 1, RSTART - 1); v = substr($0, RSTART + RLENGTH); v = substr(v, 1, length(v) - 1)
      gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
      if (!(f in last)) o[++n] = f
      last[f] = v }
    END { for (k = 1; k <= n; k++) print o[k] "\t" last[o[k]] }')
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
# The session's name (1.9.0): what the caller renders into AGENT_SESSION_NAME (the agents Feature,
# from its template), else the handle, as before. Nothing is checked about it here but that it
# can be one line: the caller renders and checks the template. A name only applies when a
# session starts; a running session is never renamed.
SNAME="$NAME"
case "${AGENT_SESSION_NAME-}" in
  '' | *[![:space:]]*) ;;
  *) AGENT_SESSION_NAME='' ;;
esac
if [ -n "${AGENT_SESSION_NAME-}" ]; then
  case "$AGENT_SESSION_NAME" in
    *$'\n'* | *$'\r'* | *$'\t'*) note "$NAME: AGENT_SESSION_NAME has a line break or a tab; using the handle as the session name." ;;
    *) SNAME="$AGENT_SESSION_NAME" ;;
  esac
fi
STARTED_AS=''  # set only where a session is started under SNAME (or a wake keeps the name it saved)
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
# Remote Control (the remoteControl option, 1.8.8): on, every session the adapter starts or wakes
# gets --remote-control unless the agent's args have it. --no-remote-control in the args is this
# adapter's own opt-out for one agent (Claude Code has no off flag); it is always removed.
remote_control_on() {
  local v="${AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL:-}"
  [ -n "$v" ] || { v="$(cat "${AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL_FILE:-/usr/local/share/claude-code/remote-control}" 2>/dev/null)" || v=''; }
  case "${v,,}" in 1 | true | yes | on) return 0 ;; *) return 1 ;; esac
}
rc_args=() rc_out=0 rc_has=0
for a in "$@"; do
  case "$a" in
    --no-remote-control) rc_out=1 ;;
    --remote-control | --remote-control=*) rc_has=1; rc_args+=("$a") ;;
    *) rc_args+=("$a") ;;
  esac
done
if [ "$rc_out" -eq 0 ] && [ "$rc_has" -eq 0 ]; then
  case "$verb" in start-bg | wake | attach | new) remote_control_on && rc_args+=(--remote-control) ;; esac
fi
set -- "${rc_args[@]}"

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
    REC_QUIET=1
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
    STARTED_AS="$SNAME"
    (cd "$FOLDER" && claude --bg --name "$SNAME" "$@" </dev/null >&2) || die 1 "$NAME: 'claude --bg' failed (a folder never trusted fails with 'Workspace not trusted': run claude there once and accept)."
    WR_SID=''
    wait_running "$before"
    trace started "" "$WR_SID" ;;
  wake)
    got="$(mine)"
    s="$(printf '%s\n' "$got" | awk -F'\t' '$3 == "stopped" || $3 == "failed"' | head -n 1)"
    if [ -z "$s" ]; then
      [ -z "$(mine running)" ] || die 1 "$NAME: its session in $FOLDER is running (a finished one with a live process too); nothing to wake. task agents -- $NAME attaches to it."
      die 1 "$NAME: no stopped session to wake in $FOLDER."
    fi
    wake_session "$s" "$@" ;;
  attach)
    run="$(mine running)"
    if [ -z "$run" ]; then
      s="$(mine | head -n 1)"
      [ -n "$s" ] || die 1 "$NAME: no session in $FOLDER to attach to."
      # (1.9.6) an ended session is woken first, as `wake` does (bare, confirmed, a new id recorded
      # with the old one superseded), and the session that then runs is attached: `claude attach`
      # of an ended session lets Claude Code restart it on its own, which may be a copy under a new
      # id that nothing records (the report: the host came back as a copy with only --model)
      woke="$(wake_session "$s" "$@")" || exit $?
      woke="$(printf '%s\n' "$woke" | awk 'NF { l = $0 } END { print l }')"
      [ -n "$woke" ] || die 1 "$NAME: woken, but its session is not listed yet, so there is nothing to attach to; try again in a moment."
      short="$(sessions 2>/dev/null | awk -F'\t' -v s="$woke" '$2 == s { print $5; exit }')"
      [ -n "$short" ] || { [ "$woke" = "$(col "$s" 2)" ] && short="$(col "$s" 5)"; }
      [ -n "$short" ] || die 1 "$NAME: woken as $woke, but it is not listed yet, so there is nothing to attach to; try again in a moment."
      trace attached "" "$woke"
      exec claude attach "$short"
    fi
    extras_note "$run"
    if [ "$(col "$run" 6)" = interactive ]; then
      tty="$(ps -o tty= -p "$(col "$run" 7)" 2>/dev/null | tr -d '[:space:]')"
      die 1 "$NAME: its session $(col "$run" 2) (pid $(col "$run" 7)) is held by a terminal${tty:+ ($tty)}; switch to that terminal (or Remote Control). claude attach does not reach an interactive session."
    fi
    trace attached "" "$(col "$run" 2)"
    exec claude attach "$(col "$run" 5)" ;;
  resume)
    # its newest own conversation (1.9.5, see resume_candidates); a running one is refused
    cands="$(resume_candidates)"
    s="$(printf '%s\n' "$cands" | awk -F'\t' '$3 == "running"' | head -n 1)"
    if [ -n "$s" ]; then
      die 1 "$NAME: its latest session $(col "$s" 2) is running (pid $(col "$s" 4)); resuming it here would be a second copy. Switch to it, or stop it first."
    fi
    s="$(printf '%s\n' "$cands" | awk NF | sort -s -t $'\t' -k1,1nr | head -n 1)"
    [ -n "$s" ] || die 1 "$NAME: no earlier conversation in $FOLDER to resume; task agents -- $NAME starts one."
    cd "$FOLDER" && exec claude --resume "$(col "$s" 2)" "$@" ;;
  new)
    # a session id chosen here, so the new conversation is recorded before it starts
    sid=''
    case " $* " in *" --session-id "* | *" --session-id="*) ;; *)
      sid="$(tr -d '\n' < /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)" ;; esac
    STARTED_AS="$SNAME"
    if [ -n "$sid" ]; then
      rec_put "$NAME" "$FOLDER" "$sid" "$sid"
      cd "$FOLDER" && exec claude --name "$SNAME" --session-id "$sid" "$@"
    fi
    cd "$FOLDER" && exec claude --name "$SNAME" "$@" ;;
  stop)
    # running sessions, which include a finished one whose process is still alive (1.9.2)
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
