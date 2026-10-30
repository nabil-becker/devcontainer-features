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
#                cd <folder> && claude --bg --resume <session id> (the same id, its conversation,
#                its saved options) when Claude Code's saved options for it are --name <a name the
#                agent's session has had> <args>, in any order; otherwise
#                ... --resume <session id> --name <session name> <args> (a copy). Woken bare, it
#                may stay idle (no prompt): that is the agent's session, its id printed (1.9.1)
#     attach     claude attach <id> of its newest running session (a terminal is needed); an
#                ended one is attached (restarted) only when wake would wake it bare, else
#                woken as wake does, then attached
#     resume     cd <folder> && claude --resume <session id> <args> of its newest session;
#                refused while that session runs (a second process on one transcript); when
#                the list cannot be read, claude --resume <args> (its own picker), never new
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
# session's short job id and its full session id, and (1.9.0) the name the session was started
# with and the names it had before (up to 5, separated by \037), one line each, in
#   $AGENT_ADAPTER_CLAUDE_STATE/agents.tsv  (default $CLAUDE_CONFIG_DIR/agent-adapter-claude,
#   the claude-code Feature's volume, so it survives a rebuild; folder 700, file 600)
# never in the repository. A recorded session still listed is the agent's whatever its name
# now is: by its job id (which stays across /clear, while the session id changes), else by
# its session id (a wake that continued under a new job id). Otherwise the name and folder
# find it, as before, by any name the agent has had (a changed session-name template does not
# lose it). Clearing a record keeps the names (a line without ids).
state_dir() { printf '%s' "${AGENT_ADAPTER_CLAUDE_STATE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-adapter-claude}"; }
RECORDS="$(state_dir)/agents.tsv"

US=$'\037'
MAX_HIST=5

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
  # the names stay (the session may be found by one of them), the ids go
  if ! { awk -F'\t' -v OFS='\t' -v n="$1" -v f="$2" '$1 == n && $2 == f { if ($5 != "") print $1, $2, "", "", $5, $6; next } { print }' "$RECORDS" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$RECORDS"; }; then
    rm -f "$tmp"
  fi
}

# rec_put <name> <folder> <id> <session id>: replace the agent's record, with its names and
# STARTED_AS when set (never fatal).
rec_put() {
  local d tmp old
  d="$(state_dir)"
  if ! (umask 077 && mkdir -p "$d") 2>/dev/null; then note "$1: could not keep its session record under $d."; return 0; fi
  chmod 700 "$d" 2>/dev/null || true
  tmp="$(umask 077 && mktemp "$d/.agents.XXXXXX" 2>/dev/null)" || { note "$1: could not keep its session record under $d."; return 0; }
  old="$(rec_line "$1" "$2")"
  names_next "$(printf '%s' "$old" | cut -f5)" "$(printf '%s' "$old" | cut -f6)"
  { [ -r "$RECORDS" ] && awk -F'\t' -v n="$1" -v f="$2" '!($1 == n && $2 == f)' "$RECORDS"
    printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
    [ -z "$NCUR" ] || printf '\t%s%s' "$NCUR" "${NHIST:+$'\t'$NHIST}"
    printf '\n'; } > "$tmp"
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
# running, or with a pid whatever its state: a finished session woken bare comes back idle with
# its state still done, 1.9.1), else a running session with a name the agent's session may have
# (cand_names) in its folder that was not listed before. Record it as the agent's and print its
# session id.
wait_running() {
  local before="$1" want="${2:-}" left="${AGENT_ADAPTER_WAIT:-10}" all got
  while :; do
    if all="$(sessions)"; then
      got=''
      [ -n "$want" ] && got="$(printf '%s\n' "$all" | awk -F'\t' -v s="$want" '$2 == s && ($3 == "running" || $7 + 0 > 0)' | head -n 1)"
      [ -n "$got" ] || got="$(printf '%s\n' "$all" | awk -F'\t' -v n="$(cand_names | tr '\n' "$US")" -v f="$FOLDER" -v b="$before" '
        BEGIN { split(b, x, " "); for (k in x) old[x[k]] = 1; m = split(n, nm, "\037") }
        $3 == "running" && $4 == f && !($2 in old) { for (k = 1; k <= m; k++) if (nm[k] != "" && ($1 == nm[k] || index($1, nm[k] " (") == 1)) { print; exit } }')"
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
# its saved options are what start-bg passes for the agent (--name <a name the agent's session
# has had> and its args; 1.9.0: the name may be the session name now, the handle, or one the
# record holds, so a changed session-name template never turns a wake into a copy); when they
# differ (the args changed, or the session was started without them) or cannot be read, it is
# woken with --name <session name> and the args, so the agent never runs without its options.
# Claude Code's own state in state.json is not consulted (1.9.1): after a container restart it
# still says "working" for a session that was idle, since Claude Code's background service
# writes the ended state only when it starts again, and a bare wake of it continues the same
# session (checked on 2.1.308); waking it with flags there started a copy under a new id.
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
# then the args, so the order alone never decides; --remote-control is dropped (see bare_ok).
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

# bare_ok <short id> <args...>: 0 when a bare wake (or claude attach) of that ended session is
# known to bring it back as the agent: its saved options are --name <a name the agent's session has
# had (cand_names)> <args> (in any order), and BARE_NAME is that name. Else 1, with WHY set for the
# note. --remote-control is left out of both sides: Claude Code saves it where it was given (checked
# 1.9.1: `--name n --remote-control --model m`), and turning the remoteControl option on must not
# make the wake of a session started without it a copy (a wake that adds flags is a copy).
bare_ok() {
  local short="$1" saved c want; shift
  BARE_NAME=''
  if ! saved="$(saved_flags "$short")"; then
    WHY="the options Claude Code saved for its session $short cannot be read ($(jobs_dir)/$short/state.json)"; return 1
  fi
  saved="$(printf '%s\n' "$saved" | canon_flags)"
  while IFS= read -r c; do
    WANT_NAME="$c" want="$(want_flags "$@")"
    [ "$saved" = "$want" ] && { BARE_NAME="$c"; break; }
  done < <(cand_names)
  WANT_NAME=''
  [ -n "$BARE_NAME" ] && return 0
  WHY="its session $short keeps other options than the agent's (--name, one of the agent's session names, and its args from the list)"
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
# bare_ok, else with --name <session name> <args> (said on stderr); wait until it runs, record it and
# print its session id (the copy's, when Claude Code started one). When the resume fails because
# the session is gone (session_gone), start the agent fresh as start-bg does and say so; any
# other failure fails.
wake_session() {
  local s="$1" sid short before WHY='' out rc=0 got; shift
  sid="$(col "$s" 2)" short="$(col "$s" 5)"
  before="$(printf '%s\n' "$ALL" | cut -f2 | tr '\n' ' ')"
  stop_done "$s" || exit 1
  if bare_ok "$short" "$@"; then
    STARTED_AS="$BARE_NAME"  # the name it keeps (and the record then holds)
    out="$(cd "$FOLDER" && claude --bg --resume "$sid" </dev/null 2>&1)" || rc=$?
  else
    note "$NAME: $WHY; waking it with the agent's options (--name and its args from the list), which Claude Code may start as a copy under a new id."
    STARTED_AS="$SNAME"
    out="$(cd "$FOLDER" && claude --bg --resume "$sid" --name "$SNAME" "$@" </dev/null 2>&1)" || rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  got=''
  if [ "$rc" -eq 0 ]; then
    got="$(wait_running "$before" "$sid")"
    [ -z "$got" ] || { printf '%s\n' "$got"; return 0; }
    # Claude Code said it woke this very session (its short id), but the list does not show it
    # yet: it is the agent's, idle until a prompt reaches it (1.9.1); never a fresh start
    case "$out" in
      *"woke session $short "* | *"backgrounded · $short "*)
        rec_put "$NAME" "$FOLDER" "$short" "$sid"
        printf '%s\n' "$sid"; return 0 ;;
    esac
  fi
  if session_gone "$sid" "$out"; then
    note "$NAME: session $sid is gone; started fresh."
    STARTED_AS="$SNAME"
    (cd "$FOLDER" && claude --bg --name "$SNAME" "$@" </dev/null >&2) || die 1 "$NAME: session $sid is gone and 'claude --bg' failed."
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
    STARTED_AS="$SNAME"
    if [ -n "$sid" ]; then
      rec_put "$NAME" "$FOLDER" "$sid" "$sid"
      cd "$FOLDER" && exec claude --name "$SNAME" --session-id "$sid" "$@"
    fi
    cd "$FOLDER" && exec claude --name "$SNAME" "$@" ;;
  stop)
    # running sessions, and finished ones whose process is still alive (listed stopped, with a pid)
    run="$(mine | awk -F'\t' '$3 == "running" || ($3 == "stopped" && $7 + 0 > 0)')"
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
