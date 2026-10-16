# Back: the tester. Sourced by devhost-run-job.
# Uses no model: after a turn, if code under TESTER_PATHS (src tests scripts) changed since
# this job's last run, it runs the test command (TESTER_CMD: `task test` when the root
# Taskfile has a test task, else nothing) and speaks only when the suite is red, or green
# again after being red (a suite the environment cannot run, e.g. no Docker, is `skipped`: one
# quiet notice, no verdict, a previous red kept). Its metrics line carries model "none" and cost 0 (TESTER_MODEL,
# lib.sh). The runner's lock keeps two runs apart (the second exits quietly);
# DEVHOST_JOB_CHILD is set for the suite, so nothing the suite starts can start a back.
# shellcheck shell=bash disable=SC2034,SC2154  # JOB_* are read, ROOT/state/transcript set, by the runner
JOB_NAME=tester
# Any new stretch will do: this job reads no transcript, it looks at the code.
JOB_MIN_CHARS=1
JOB_QUIET_SECS=0
: "${TESTER_PATHS:=src tests scripts}"
: "${TESTER_TIMEOUT:=900}"

# tester_cmd: TESTER_CMD, else `task test` when the root Taskfile lists a test task, else
# nothing (the job then has no suite to run and stays quiet).
tester_cmd() {
  if [ -n "${TESTER_CMD:-}" ]; then printf '%s\n' "$TESTER_CMD"; return 0; fi
  command -v task >/dev/null 2>&1 || return 1
  ( cd "$ROOT" && task --list-all 2>/dev/null | grep -qE '^\* test:' ) || return 1
  echo "task test"
}

# tester_hash: one hash of what the code is now: HEAD, the diff against it and the untracked
# files (git), or a listing of names, sizes and times when this is not a git checkout.
tester_hash() {
  {
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$ROOT" rev-parse HEAD 2>/dev/null
      # shellcheck disable=SC2086
      git -C "$ROOT" diff HEAD -- $TESTER_PATHS 2>/dev/null
      # shellcheck disable=SC2086
      git -C "$ROOT" ls-files -o --exclude-standard -z -- $TESTER_PATHS 2>/dev/null | sort -z | xargs -0 -r cat 2>/dev/null
    else
      # shellcheck disable=SC2086
      ( cd "$ROOT" && find $TESTER_PATHS -type f -not -path '*/__pycache__/*' -printf '%p %s %T@\n' 2>/dev/null | sort )
    fi
  } | sha256sum | cut -d' ' -f1
}

# tester_cannot_run <cmd> <output file>: true when the suite failed because this environment
# cannot run it (no verdict on the code): the Taskfile's precondition stopped it, or the
# command is the default `task test` / `task test:global` and there is no Docker daemon.
# Any other TESTER_CMD is judged by its output alone, so a real failure stays red.
tester_cannot_run() {
  grep -Eqi 'precondition not met|no Docker daemon here' "$2" && return 0
  case "$1" in
    "task test"|"task test:global") ! docker info >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

job_run() {
  local tmp="$2" now prev code first failed cmd last
  [ -n "${DEVHOST_JOB_CHILD:-}" ] && { JOB_STATUS=nothing; return; }
  cmd="$(tester_cmd)" || { JOB_STATUS=nothing; [ -f "$state/no-suite" ] || { log "no test command (set TESTER_CMD or add a test task); quiet"; touch "$state/no-suite"; }; return; }
  now="$(tester_hash)"
  if [ "$now" = "$(cat "$state/code_hash" 2>/dev/null)" ]; then JOB_STATUS=nothing; return; fi
  ( cd "$ROOT" && DEVHOST_JOB_CHILD=1 timeout "$TESTER_TIMEOUT" bash -c "$cmd" ) >"$tmp/suite.out" 2>&1 9>&-
  code=$?
  if [ "$code" = 124 ]; then
    log "suite timed out; no verdict, will run again after the next turn"
    JOB_STATUS=nothing; return
  fi
  prev="$(cat "$state/last_result" 2>/dev/null || echo green)"
  echo "$now" >"$state/code_hash"
  # Skipped is no verdict: last_result says skipped, last_real keeps the last red or green so a
  # red is neither flipped to green by a skip nor announced again, and green-again still fires.
  [ "$prev" = skipped ] && prev="$(cat "$state/last_real" 2>/dev/null || echo green)"
  if [ "$code" != 0 ] && tester_cannot_run "$cmd" "$tmp/suite.out"; then
    local was; was="$(cat "$state/last_result" 2>/dev/null || echo green)"
    echo "$prev" >"$state/last_real"
    echo skipped >"$state/last_result"
    if [ "$was" = skipped ]; then
      JOB_STATUS=nothing
    else
      JOB_STATUS=changed; JOB_NOTICE="tests skipped: \`$cmd\` cannot run here (no Docker daemon); no verdict, quiet until it can."
    fi
    return
  fi
  if [ "$code" = 0 ]; then
    echo green >"$state/last_result"; echo green >"$state/last_real"
    if [ "$prev" = red ]; then
      JOB_STATUS=changed; JOB_NOTICE="tests green again."
    else
      JOB_STATUS=nothing
    fi
    return
  fi
  echo red >"$state/last_result"; echo red >"$state/last_real"
  # pytest-style summaries are read when present; otherwise the last line of output.
  failed="$(grep -Eo '[0-9]+ failed' "$tmp/suite.out" | tail -n1 | cut -d' ' -f1)"
  first="$(sed -n 's/^FAILED \([^ ]*\).*/\1/p; s/^ERROR \([^ ]*\).*/\1/p' "$tmp/suite.out" | head -n1)"
  last="$(grep -v '^[[:space:]]*$' "$tmp/suite.out" | tail -n1 | head -c 200)"
  JOB_STATUS=changed
  JOB_NOTICE="tests red (\`$cmd\` exit $code): ${failed:-?} failed, first: ${first:-${last:-unknown}}"
}
