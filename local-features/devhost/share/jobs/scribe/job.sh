# Back: the scribe. Sourced by devhost-run-job.
# Writes ledger entries for finished units of work into $DEVHOST_LEDGER_DIR/YYYY-MM.md, from
# the condensed stretch. The model only prints entries; this file fills each entry's Measures
# with the numbers from the transcripts (devhost-costs), passes them through the name guard
# and appends them, so the ledger stays append-only. Model: SCRIBE_MODEL (lib.sh).
#
# With DEVHOST_LEDGER_REGISTER set (the ledger is an agentic-register register), the same entries
# are signed into the register as `work` entries with the scribe's own key (fetched by the runner
# from OpenBao; the job does not run without it), then the stretch's cost (the worker's own
# replies, per model) and the backs' runs since the last time (runs.jsonl) as `run` entries, and
# the register's mirror is brought level (agentic-register mirror; best effort, the next run
# catches up). Nothing is written to the Markdown files then; the ledger is read with devhost-ledger.
# shellcheck shell=bash disable=SC2034,SC2154  # JOB_* are read, ROOT/state/transcript set, by the runner
JOB_NAME=scribe
[ -n "$(hk_ledger_register)" ] && JOB_NEEDS_KEY=1

# scribe_register <entries file> <since> <transcript>...: sign the entries, the stretch's runs and
# the backs' runs into the register; sets JOB_STATUS, JOB_NOTICE, JOB_ADVANCE. Returns 1 when
# no entry was written.
scribe_register() {
  local entries="$1" since="$2"; shift 2
  local reg ids err who="${DEVHOST_SCRIBE_AS:-scribe}" member
  reg="$(hk_ledger_register)"
  err="$TMP/register.err"
  ids="$(DEVHOST_ROOT="$ROOT" python3 "$DEVHOST_SHARE/python/ledger.py" add --as "$who" --key "$JOB_KEY_FILE" "$entries" 2>"$err")"
  if [ -z "$ids" ]; then
    log "register $reg refused the entries: $(tail -n1 "$err" | head -c 300)"
    JOB_STATUS=pending
    JOB_NOTICE="the scribe could not write to the register $reg ($(tail -n1 "$err" | head -c 200)); the stretch is read again on the next run"
    return 1
  fi
  [ -s "$err" ] && log "register $reg: some entries not written: $(tail -n1 "$err" | head -c 300)"
  member="$( [ "$MODE" = sub ] && echo "con ${AGENT_TYPE:-agent}" || echo host )"
  if python3 "$DEVHOST_SHARE/python/session_cost.py" --runs "$@" --main 1 ${since:+--since "$since"} \
       --member "$member" >"$TMP/runs.jsonl" 2>>"$err" && [ -s "$TMP/runs.jsonl" ]; then
    DEVHOST_ROOT="$ROOT" python3 "$DEVHOST_SHARE/python/ledger.py" add-runs --as "$who" --key "$JOB_KEY_FILE" "$TMP/runs.jsonl" \
      >/dev/null 2>>"$err" || log "register $reg: the stretch's runs not written: $(tail -n1 "$err" | head -c 300)"
  fi
  DEVHOST_ROOT="$ROOT" python3 "$DEVHOST_SHARE/python/ledger.py" back-runs --as "$who" --key "$JOB_KEY_FILE" \
    "$STATE_ROOT/runs.jsonl" "$state/runs-cursor" >/dev/null 2>>"$err" \
    || log "register $reg: the backs' runs not all written: $(tail -n1 "$err" | head -c 300)"
  DEVHOST_ROOT="$ROOT" python3 "$DEVHOST_SHARE/python/ledger.py" mirror >>"$state/mirror.log" 2>&1 \
    || log "register $reg: mirror not level ($(tail -n1 "$state/mirror.log" | head -c 200)); the next run tries again"
  JOB_LOGGED_IN="register $reg ($(printf '%s\n' "$ids" | wc -l) entries)"
  return 0
}

job_run() {
  local stretch="$1" tmp="$2" ledger_dir month ledger prev since files main branch session_line measures s
  ledger_dir="$(hk_ledger_dir "$ROOT")"
  [ -n "$(hk_ledger_register)" ] || mkdir -p "$ledger_dir"
  month="$(date -u +%Y-%m)"; ledger="$ledger_dir/$month.md"
  prev="$ledger_dir/$(date -u -d "$month-01 -1 day" +%Y-%m).md"
  branch="$(git -C "$HOOK_CWD" branch --show-current 2>/dev/null || true)"
  since="$(cat "$state/since-$SID" 2>/dev/null || true)"
  if [ "$MODE" = sub ]; then
    session_line="con ${AGENT_TYPE:-agent} ($SID)"
    files=("$transcript"); main=1
  else
    session_line="host ($SID)"
    files=("$transcript"); main=1
    for s in "${transcript%.jsonl}"/subagents/*.jsonl; do [ -f "$s" ] && files+=("$s"); done
  fi
  measures="$(hk_measures "$main" "$since" "${files[@]}")"
  {
    cat "$JOB_DIR/brief.md"
    printf '\n\nTODAY: %s\nSESSION LINE: %s\nENGINEER: %s\nBRANCH: %s\n' "$(date -u +%F)" "$session_line" "$ENGINEER" "${branch:-unknown}"
    printf '\n\nENTRY TEMPLATE:\n'; cat "$JOB_DIR/entry-template.md"
    if [ -n "$(hk_ledger_register)" ]; then
      printf '\n\nLEDGER TAIL (register %s):\n' "$(hk_ledger_register)"
      DEVHOST_ROOT="$ROOT" python3 "$DEVHOST_SHARE/python/ledger.py" tail 8000 2>/dev/null
    else
      printf '\n\nLEDGER TAIL (%s):\n' "${ledger#"$ROOT"/}"
      { cat "$prev" "$ledger" 2>/dev/null; } | tail -c 8000
    fi
    printf '\n\nSTRETCH (%s %s):\n' "$MODE" "$SID"; cat "$stretch"
    # Units held back last run: their start is behind the offset now, so the scribe is told.
    [ -s "$state/pending-$SID" ] && { printf '\n\nSTILL PENDING FROM YOUR LAST RUN:\n'; cat "$state/pending-$SID"; }
  } >"$tmp/prompt"
  ( cd "$tmp" && job_claude <"$tmp/prompt" ) >"$tmp/out" 2>"$tmp/err" || { log "claude failed: $(head -c 300 "$tmp/err")"; return; }

  local status summary entries
  status="$(sed -n 's/^STATUS: *//p' "$tmp/out" | head -n1)"
  summary="$(sed -n 's/^SUMMARY: *//p' "$tmp/out" | head -n1)"; summary="${summary%.}"
  JOB_PENDING="$(sed -n 's/^PENDING: *//p' "$tmp/out" | head -n1)"
  [ "$JOB_PENDING" = "none" ] && JOB_PENDING=""
  # An item carried three runs in a row is dropped (share/python/pending.py keeps the counts
  # beside the file); without the helper the line is kept as printed.
  if [ -f "$DEVHOST_SHARE/python/pending.py" ]; then
    JOB_PENDING="$(python3 "$DEVHOST_SHARE/python/pending.py" "$state/pending-$SID" "$JOB_PENDING" 2>>"$tmp/pending.log")" \
      || JOB_PENDING="$(sed -n 's/^PENDING: *//p' "$tmp/out" | head -n1)"
    [ -s "$tmp/pending.log" ] && log "$(head -c 300 "$tmp/pending.log")"
  fi
  printf '%s' "$JOB_PENDING" >"$state/pending-$SID"
  # The numbers are the script's, never the model's: the stretch's cost goes on its first entry
  # only, so summing the ledger's Measures counts it once; the others point to that entry.
  entries="$(sed -n '/^---$/,$p' "$tmp/out" | sed '1d' \
    | MEASURES="$measures (this stretch; model $MODEL wrote the entry)" python3 -c 'import os,re,sys
t=sys.stdin.read(); m=os.environ["MEASURES"]; n=[0]
def fill(_):
    n[0] += 1
    return "- **Measures:** " + (m if n[0] == 1 else "counted in the first entry of this stretch, above")
t=re.sub(r"^- \*\*Corrects:\*\*[ \t]*none[ \t.,;:!]*\n", "", t, flags=re.M | re.I)  # the guard refuses it
print(re.sub(r"^- \*\*Measures:\*\*.*$", fill, t, flags=re.M), end="")' \
    | redact)"
  case "$status" in
    logged)
      grep -q '^### ' <<<"$entries" || { log "logged without entries"; return; }
      if [ -n "$(hk_ledger_register)" ]; then
        printf '%s\n' "$entries" >"$tmp/entries.md"
        scribe_register "$tmp/entries.md" "$since" "${files[@]}" || return
        date -u +%FT%TZ >"$state/since-$SID"
        JOB_STATUS=changed
        JOB_NOTICE="logged in the $JOB_LOGGED_IN: $summary. Read them with devhost-ledger show; correct a wrong one with a correcting entry."
        return
      fi
      [ -f "$ledger" ] || printf '# Ledger, %s\n' "$month" >"$ledger"
      printf '\n%s\n' "$entries" >>"$ledger"
      date -u +%FT%TZ >"$state/since-$SID"
      JOB_STATUS=changed
      JOB_NOTICE="logged in ${ledger#"$ROOT"/}: $summary. Read the new entries before the next commit; correct a wrong one with a correcting entry." ;;
    # "pending" is an older status for "nothing written, something in progress".
    nothing|pending) JOB_STATUS=nothing ;;
    *) log "unreadable reply: $(head -c 300 "$tmp/out")" ;;
  esac
}
