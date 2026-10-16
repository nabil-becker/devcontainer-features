# Back: the librarian. Sourced by devhost-run-job.
# Keeps the lexicon ($DEVHOST_LEXICON) and the ADRs ($DEVHOST_ADR_DIR) current from the
# condensed stretch. The model edits the files itself, with write access limited to those
# paths; the docs guard undoes a run that removes or changes a lexicon line or rewrites an
# existing ADR beyond its Status line. Model: LIBRARIAN_MODEL (lib.sh). Runs from Stop and
# from SubagentStop (a con's job).
# shellcheck shell=bash disable=SC2034,SC2154  # JOB_* are read, ROOT/state/transcript set, by the runner
JOB_NAME=librarian
# Woken less often than the scribe (a review found a third of its runs had nothing to do):
# a longer stretch and ten minutes between runs; a stake for it always wakes it.
JOB_MIN_CHARS=8000
JOB_QUIET_SECS=600
# A con's stretch (SubagentStop) needs more than the 1500 default. First review, 31 runs:
# session stretches of 8847 to 10517 chars changed something, but 'nothing' runs spanned
# 8859 to 19552, so size cannot tell sessions apart and 8000 stays. For cons the one
# 'changed' run was 8426 chars; 13 of the 17 'nothing' runs (and 2 'pending') were 5995 to
# 8250. 8000 skips most of those with a margin below the one changed run (8426), since a
# skipped con stretch is never offered again. Re-check after the next review.
JOB_MIN_CHARS_SUB=8000

job_run() {
  local stretch="$1" tmp="$2" status summary changed lexicon adr_dir guard
  lexicon="$(hk_lexicon "$ROOT")"
  adr_dir="$(hk_adr_dir "$ROOT")"
  mkdir -p "$adr_dir"
  # The snapshot the guard compares against: the lexicon under its own name and the ADRs
  # under adr/ (the layout share/python/guards.py reads).
  local snap_lex; snap_lex="$tmp/snap/$(basename "$lexicon")"
  mkdir -p "$tmp/snap/adr"
  [ -f "$lexicon" ] && cp -p "$lexicon" "$snap_lex"
  cp -p "$adr_dir"/*.md "$tmp/snap/adr/" 2>/dev/null
  touch "$tmp/snap/.mark"
  {
    cat "$JOB_DIR/brief.md"
    printf '\n\nTHE LEXICON FILE: %s\nTHE ADR FOLDER: %s\nTODAY: %s\nEXISTING FILES IN THE ADR FOLDER:\n%s\n' \
      "${lexicon#"$ROOT"/}" "${adr_dir#"$ROOT"/}" "$(date -u +%F)" "$(find "$adr_dir" -maxdepth 1 -type f -printf '%f
' | sort)"
    printf '\n\nSTRETCH (%s %s):\n' "$MODE" "$SID"; cat "$stretch"
  } >"$tmp/prompt"
  # Edit rules cover every file-writing tool (Write included); absolute (//) so they hold
  # whichever path form the model uses.
  ( cd "$ROOT" && job_claude --allowedTools "Read" "Glob" "Grep" \
      "Edit(/$lexicon)" "Edit(/$adr_dir/**)" --disallowedTools "Bash" <"$tmp/prompt" ) \
    >"$tmp/out" 2>"$tmp/err" || { log "claude failed: $(head -c 300 "$tmp/err")"; return; }

  guard=1; hk_guard docs librarian || guard=""
  if [ -z "$guard" ] || ! DEVHOST_ROOT="$ROOT" "${HK_GUARD[@]}" "$tmp/snap" "$ROOT" >"$tmp/guard"; then
    [ -f "$snap_lex" ] && cp -p "$snap_lex" "$lexicon"
    cp -p "$tmp/snap/adr/"*.md "$adr_dir/" 2>/dev/null
    JOB_UNDONE=1
    if [ -z "$guard" ]; then
      log "no docs guard installed (share/python/guards.py); edits undone"
      JOB_NOTICE="(the docs guard is not installed, so the librarian's edits to existing files were undone) "
    else
      log "an edit removed or changed protected lines; undone ($(head -c 200 "$tmp/guard"))"
      JOB_NOTICE="(an edit that changed an existing lexicon line or ADR was undone) "
    fi
  fi
  # shellcheck disable=SC2046
  redact "$lexicon" $(find "$adr_dir" -type f -newer "$tmp/snap/.mark")
  status="$(sed -n 's/^STATUS: *//p' "$tmp/out" | tail -n1)"
  summary="$(sed -n 's/^SUMMARY: *//p' "$tmp/out" | tail -n1)"; summary="${summary%.}"
  JOB_PENDING="$(sed -n 's/^PENDING: *//p' "$tmp/out" | tail -n1)"
  [ "$JOB_PENDING" = "none" ] && JOB_PENDING=""
  changed="$( { [ -f "$snap_lex" ] && ! cmp -s "$snap_lex" "$lexicon" && echo "${lexicon#"$ROOT"/}";
    cd "$ROOT" && find "${adr_dir#"$ROOT"/}" -type f -newer "$tmp/snap/.mark" | sort; } | paste -sd, -)"
  if [ -n "$changed" ]; then
    JOB_STATUS=changed
    JOB_NOTICE="${JOB_NOTICE}updated $changed: $summary. Read the changes before the next commit."
  elif [ "$status" = "pending" ] || [ "$JOB_UNDONE" = 1 ]; then
    JOB_STATUS=pending; JOB_NOTICE="${JOB_NOTICE}$summary"
  else
    JOB_STATUS=nothing
  fi
}
