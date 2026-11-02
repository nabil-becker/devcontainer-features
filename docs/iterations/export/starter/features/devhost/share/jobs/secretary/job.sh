# Back: the secretary. Sourced by devhost-run-job.
# Keeps the backlog ($DEVHOST_BACKLOG, TODO.md) current from the condensed stretch: adds open
# items and decisions for the Operator, ticks finished ones. The model edits the file itself
# (write access to that file only); the backlog guard undoes any run that deletes, rewords
# or reorders a line. Model: SECRETARY_MODEL (lib.sh). Cons' runs are not read: it runs from
# the Stop hook only.
# shellcheck shell=bash disable=SC2034,SC2154  # JOB_* are read, ROOT/state/transcript set, by the runner
JOB_NAME=secretary

job_run() {
  local stretch="$1" tmp="$2" status summary todo guard
  todo="$(hk_backlog "$ROOT")"
  [ -f "$todo" ] || { log "no backlog at ${todo#"$ROOT"/}"; return; }
  cp "$todo" "$tmp/todo.before"
  {
    cat "$JOB_DIR/brief.md"
    printf '\n\nTHE BACKLOG FILE: %s\nTODAY: %s\n\nSTRETCH (%s %s):\n' "${todo#"$ROOT"/}" "$(date -u +%F)" "$MODE" "$SID"; cat "$stretch"
  } >"$tmp/prompt"
  # The Edit rule is absolute (//) so it holds whichever path form the model uses.
  ( cd "$ROOT" && job_claude --allowedTools "Read" "Edit(/$todo)" --disallowedTools "Bash" <"$tmp/prompt" ) \
    >"$tmp/out" 2>"$tmp/err" || { log "claude failed: $(head -c 300 "$tmp/err")"; return; }

  guard=1; hk_guard backlog secretary || guard=""
  if [ -z "$guard" ] || ! "${HK_GUARD[@]}" "$tmp/todo.before" "$todo" >"$tmp/guard"; then
    cp "$tmp/todo.before" "$todo"; JOB_UNDONE=1
    if [ -z "$guard" ]; then
      log "no backlog guard installed (share/python/guards.py); edit undone"
      JOB_STATUS=pending; JOB_NOTICE="the backlog guard is not installed, so the secretary's edit was undone"
    else
      # The guard prints the finding (the line and the rule) first, then the rejected diff.
      log "edit changed existing lines; undone: $(head -n1 "$tmp/guard" | head -c 400)"
      sed -n '2,$p' "$tmp/guard" | head -c 1600 | sed 's/^/    | /' >>"$state/job.log"
      # Handled: an undone stake is not retried every turn; the notice says it was undone.
      JOB_STATUS=pending; JOB_ADVANCE=1
      JOB_NOTICE="a ${todo#"$ROOT"/} edit was undone ($(head -n1 "$tmp/guard" | head -c 300)). To change an existing item, add an amend-<id> item instead"
    fi
    return
  fi
  redact "$todo"
  status="$(sed -n 's/^STATUS: *//p' "$tmp/out" | tail -n1)"
  summary="$(sed -n 's/^SUMMARY: *//p' "$tmp/out" | tail -n1)"; summary="${summary%.}"
  JOB_PENDING="$(sed -n 's/^PENDING: *//p' "$tmp/out" | tail -n1)"
  [ "$JOB_PENDING" = "none" ] && JOB_PENDING=""
  if ! diff -q "$tmp/todo.before" "$todo" >/dev/null; then
    JOB_STATUS=changed; JOB_NOTICE="updated ${todo#"$ROOT"/}: $summary. Read the changes before the next commit."
  elif [ "$status" = "pending" ]; then
    JOB_STATUS=pending; JOB_NOTICE="$summary"
  else
    JOB_STATUS=nothing
  fi
}
