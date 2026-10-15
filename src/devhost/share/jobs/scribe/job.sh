# Back: the scribe. Sourced by devhost-run-job.
# Writes ledger entries for finished units of work into $DEVHOST_LEDGER_DIR/YYYY-MM.md, from
# the condensed stretch. The model only prints entries; this file fills each entry's Measures
# with the numbers from the transcripts (devhost-costs), passes them through the name guard
# and appends them, so the ledger stays append-only. Model: SCRIBE_MODEL (lib.sh).
# shellcheck shell=bash disable=SC2034,SC2154  # JOB_* are read, ROOT/state/transcript set, by the runner
JOB_NAME=scribe

job_run() {
  local stretch="$1" tmp="$2" ledger_dir month ledger prev since files main branch session_line measures s
  ledger_dir="$(hk_ledger_dir "$ROOT")"
  mkdir -p "$ledger_dir"
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
    printf '\n\nLEDGER TAIL (%s):\n' "${ledger#"$ROOT"/}"
    { cat "$prev" "$ledger" 2>/dev/null; } | tail -c 8000
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
  printf '%s' "$JOB_PENDING" >"$state/pending-$SID"
  # The numbers are the script's, never the model's: every Measures line gets this stretch's.
  entries="$(sed -n '/^---$/,$p' "$tmp/out" | sed '1d' \
    | MEASURES="$measures (this stretch; model $MODEL wrote the entry)" python3 -c 'import os,re,sys
t=sys.stdin.read(); m=os.environ["MEASURES"]
print(re.sub(r"^- \*\*Measures:\*\*.*$", lambda _: "- **Measures:** " + m, t, flags=re.M), end="")' \
    | redact)"
  case "$status" in
    logged)
      grep -q '^### ' <<<"$entries" || { log "logged without entries"; return; }
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
