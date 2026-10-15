#!/usr/bin/env bash
# The backs' runner, on PATH as devhost-run-job. Usage, from a Claude Code hook:
#   devhost-run-job <job>            (the hook's JSON on stdin)
# <job> is a name (scribe, secretary, librarian, tester: jobs/<job>/job.sh under
# DEVHOST_JOBS_DIR, by default /usr/local/share/devhost/jobs) or the path of a job file
# (absolute, or relative to the repository root).
#
# A back keeps one record current from what an inter did, without gating the inter: the
# Stop and SubagentStop hooks run it async, the inter never waits. The runner does the
# shared part: the gate (inside a container only), the job's lock, condensing the part of
# the transcript this job has not read yet, the thresholds, the metrics line, the quiet
# notice. The job file (bash, sourced) supplies:
#   JOB_NAME, JOB_MIN_CHARS, JOB_QUIET_SECS (optional; the model comes from lib.sh)
#   job_run <stretch file> <tmp dir>   sets JOB_STATUS (changed | nothing | pending | error),
#                                      JOB_NOTICE (one line for the inter) and JOB_PENDING
# changed: the notice reaches the inter's next turn as context, without waking it and
# without anything shown to the person. pending: the same, and the stretch is read again
# later. nothing: quiet.
#
# One level only: a Stop hook reads the host session; a SubagentStop hook reads the con's
# own transcript, so a con's job gets its own entry. Read-only lookups
# (DEVHOST_JOB_SKIP_AGENTS) are skipped; their cost still reaches the report from the
# transcripts.
#
# State: $DEVHOST_STATE/<job>/ (offsets, lock, log, pending) and $DEVHOST_STATE/runs.jsonl
# (one metrics line per run); the Feature's volume, never the checkout.
# shellcheck disable=SC2034,SC2329  # JOB_DIR, job_claude and redact are for the sourced job file
set -uo pipefail

[ -n "${DEVHOST_JOB_CHILD:-}" ] && exit 0     # never inside a back's own claude run
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # next to this file
source "$BIN/lib.sh"
hk_in_container || exit 0                     # on a workstation: do nothing, say nothing

job_arg="${1:?usage: devhost-run-job <job>}"

mapfile -t f < <(python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except ValueError: d={}
for k in ("session_id","transcript_path","cwd","hook_event_name","agent_id","agent_transcript_path","agent_type"): print(d.get(k) or "")')
SID="${f[0]:-}"; transcript="${f[1]:-}"; HOOK_CWD="${f[2]:-$PWD}"; EVENT="${f[3]:-Stop}"
ROOT="$(hk_root "$HOOK_CWD")" || exit 0
STATE_ROOT="$(hk_state)"
ENGINEER="$(hk_engineer "$ROOT")"

case "$job_arg" in
  */* | *.sh) job_file="$job_arg"; case "$job_file" in /*) ;; *) job_file="$ROOT/$job_file" ;; esac ;;
  *) job_file="$(hk_jobs_dir)/$job_arg/job.sh" ;;
esac
[ -f "$job_file" ] || { echo "devhost-run-job: no job file at $job_file" >&2; exit 0; }
JOB_DIR="$(cd "$(dirname "$job_file")" && pwd)"
JOB_MIN_CHARS=1500
JOB_QUIET_SECS=120
# shellcheck source=/dev/null
source "$job_file"
QUIET_SECS="${DEVHOST_JOB_QUIET_SECS:-$JOB_QUIET_SECS}"
upper="$(echo "$JOB_NAME" | tr '[:lower:]' '[:upper:]')"
model_var="${upper}_MODEL"; MODEL="${!model_var:-haiku}"

MODE=session; AGENT_TYPE=""
if [ "$EVENT" = "SubagentStop" ]; then
  SID="${f[4]:-}"; transcript="${f[5]:-}"; AGENT_TYPE="${f[6]:-}"; MODE=sub
  [ -n "$SID" ] && [ -f "$transcript" ] || exit 0
  if [ -z "$AGENT_TYPE" ] && [ -f "${transcript%.jsonl}.meta.json" ]; then
    AGENT_TYPE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agentType",""))' "${transcript%.jsonl}.meta.json" 2>/dev/null || true)"
  fi
  for skip in ${DEVHOST_JOB_SKIP_AGENTS:-Explore claude-code-guide statusline-setup}; do
    [ "$AGENT_TYPE" = "$skip" ] && exit 0
  done
else
  [ -n "$SID" ] && [ -f "$transcript" ] || exit 0
fi
state="$STATE_ROOT/$JOB_NAME"
mkdir -p "$state/offsets" 2>/dev/null || { echo "devhost-run-job: cannot write $state (run devhost-setup)" >&2; exit 0; }
log() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$SID" "$*" >>"$state/job.log"; }

exec 9>"$state/lock"
flock -n 9 || exit 0                          # a run of this job is busy; the next turn catches up

offset="$(cat "$state/offsets/$SID" 2>/dev/null || echo 0)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 "$BIN/condense.py" "$transcript" "$offset" "$MODE" >"$TMP/stretch" 2>"$TMP/offset" || { log "condense failed"; exit 0; }
new_offset="$(tail -n1 "$TMP/offset")"
size="$(wc -c <"$TMP/stretch")"
last="$(stat -c %Y "$state/offsets/$SID" 2>/dev/null || echo 0)"
# A finished con is read when it did enough to be a job, and a stake for this job always
# wakes it; a session only when enough is new and the job has not run in the last
# QUIET_SECS (unless a lot is new).
if ! grep -qi "^STAKE for $JOB_NAME" "$TMP/stretch"; then
  if [ "$MODE" = session ]; then
    [ "$size" -lt "$JOB_MIN_CHARS" ] && exit 0
    [ $(( $(date +%s) - last )) -lt "$QUIET_SECS" ] && [ "$size" -lt $(( JOB_MIN_CHARS * 4 )) ] && exit 0
  else
    [ "$size" -lt "${JOB_MIN_CHARS_SUB:-1500}" ] && exit 0
  fi
fi

# For the job: run its model headless, with hooks off, no session saved (its cost is in the
# metrics line, so the transcripts never count it twice) and the child guard set. Prints the
# model's reply; the run's metrics (cost, tokens, turns) stay in $TMP/claude.json.
# shellcheck disable=SC2317  # job_claude and redact are called by the sourced job file
job_claude() {
  DEVHOST_JOB_CHILD=1 timeout 540 claude -p --model "$MODEL" --settings '{"disableAllHooks": true}' \
    --no-session-persistence --output-format json "$@" >"$TMP/claude.json" || return 1
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",""))' "$TMP/claude.json"
}

# The name guard: every name of DEVHOST_REDACT_FILE becomes DEVHOST_REDACT_WITH ("the
# Operator") and every word of DEVHOST_FORBIDDEN_WORDS too, in the files named or on
# stdin. Backs run it on everything they write.
redact() { DEVHOST_ROOT="$ROOT" python3 "$BIN/redact.py" "$@"; }

JOB_STATUS=error; JOB_NOTICE=""; JOB_PENDING=""; JOB_UNDONE=0
started="$(date +%s.%N)"
job_run "$TMP/stretch" "$TMP"
log "status=$JOB_STATUS model=$MODEL size=$size notice=$JOB_NOTICE${JOB_PENDING:+ pending=$JOB_PENDING}"
python3 - "$TMP/claude.json" "$STATE_ROOT/runs.jsonl" "$JOB_NAME" "$MODE" "$SID" "$MODEL" "$size" \
  "$(grep -ci "^STAKE for $JOB_NAME" "$TMP/stretch" || true)" "$JOB_STATUS" "$JOB_UNDONE" "$started" \
  "$ENGINEER" "$AGENT_TYPE" <<'PY' || log "metrics not recorded"
import json, os, sys, time
(path, out, job, mode, sid, model, size, stakes, status, undone, started, engineer, agent_type) = sys.argv[1:14]
m = {}
if os.path.exists(path):
    try:
        m = json.load(open(path, encoding="utf-8"))
    except ValueError:
        m = {}
u = m.get("usage") or {}
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "job": job, "mode": mode,
    "agent_type": agent_type, "sid": sid, "engineer": engineer, "model": model,
    "stretch_chars": int(size), "stakes": int(stakes or 0), "status": status, "undone": int(undone),
    "duration_s": round(time.time() - float(started), 1),
    "cost_usd": round(m.get("total_cost_usd") or 0, 5), "turns": m.get("num_turns") or 0,
    "input_tokens": u.get("input_tokens", 0), "output_tokens": u.get("output_tokens", 0),
    "cache_read_tokens": u.get("cache_read_input_tokens", 0),
    "cache_write_tokens": u.get("cache_creation_input_tokens", 0),
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec) + "\n")
PY

event="$( [ "$MODE" = sub ] && echo SubagentStop || echo Stop )"
case "$JOB_STATUS" in
  changed)
    echo "$new_offset" >"$state/offsets/$SID"
    # Quiet by design: the inter gets the notice as context on its next turn and checks the
    # change before its next commit; the person is not interrupted.
    where="$( [ "$MODE" = sub ] && echo " (con ${AGENT_TYPE:-agent})" )"
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[4],
      "additionalContext": "Back " + sys.argv[1] + sys.argv[2] + " (quiet notice, do not relay unless asked or wrong): " + sys.argv[3]}}))' \
      "$JOB_NAME" "$where" "$JOB_NOTICE${JOB_PENDING:+ Still pending: $JOB_PENDING}" "$event"
    exit 0 ;;
  nothing)
    echo "$new_offset" >"$state/offsets/$SID"; exit 0 ;;
  pending)
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[3],
      "additionalContext": "Back " + sys.argv[1] + " (quiet notice): still pending, not yet done: " + sys.argv[2]}}))' \
      "$JOB_NAME" "${JOB_PENDING:-$JOB_NOTICE}" "$event"
    exit 0 ;;
  *) exit 0 ;;
esac
