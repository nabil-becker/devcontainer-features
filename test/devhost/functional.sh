# Functional run of the backs' runner, shared by test.sh and the scenarios (sourced after
# dev-container-features-test-lib, so `check` exists). Ported from the original's test
# fakes: a fake repository under mktemp, a stub `claude` first on PATH that records its
# arguments and prints a canned scribe reply, a fake transcript, a container marker the
# tests control. Never a real model, never the real state volume.
# shellcheck shell=bash

devhost_functional() {
  local tmp root state marker month ledger payload out
  tmp="$(mktemp -d)"
  root="$tmp/repo"; state="$tmp/state"; marker="$tmp/marker"
  mkdir -p "$root/.claude" "$root/docs/ledger" "$root/.devhost" "$tmp/bin"
  echo '{}' > "$root/.claude/settings.json"
  printf '# To do\n\n## Now\n\n- [ ] **TD-01 First** (host). Added 2026-10-14.\n\n## Next\n\n## Decisions for the Operator\n' > "$root/TODO.md"
  printf '# Lexicon\n\n## Records\n\n- **Entry**: one ledger record.\n' > "$root/LEXICON.md"
  printf '# names to redact, one per line\nZebulonica\n' > "$root/.devhost/redact-names.txt"
  touch "$marker"

  # The stub: records argv and the prompt, prints the canned reply as claude's JSON output.
  cat > "$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$FAKE_DIR"/prompt-*.txt 2>/dev/null | wc -l)
printf '%s\n' "$@" > "$FAKE_DIR/args-$n.txt"
cat > "$FAKE_DIR/prompt-$n.txt"
python3 -c 'import json,os; print(json.dumps({"result": open(os.environ["FAKE_DIR"] + "/answer").read(), "total_cost_usd": 0.0012, "num_turns": 2, "usage": {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 5}}))'
STUB
  chmod 0755 "$tmp/bin/claude"
  cat > "$tmp/answer" <<'ANSWER'
STATUS: logged
SUMMARY: Thing built
PENDING: none
---
### 2026-10-14 Thing built

- **Session:** host (s1)
- **Asked:** build the thing for Zebulonica
- **Friction:** none
- **Measures:** MEASURES
ANSWER

  # A transcript: a few user/assistant records and one stake line, long enough to pass the
  # scribe's 1500-character threshold.
  python3 - "$tmp/s1.jsonl" <<'PY'
import json, sys
recs = [
    {"type": "user", "message": {"role": "user", "content": "please build the thing " * 60}},
    {"type": "assistant", "timestamp": "2026-10-14T10:00:00Z", "message": {"role": "assistant", "model": "claude-haiku-4-5", "id": "m1",
        "content": [{"type": "text", "text": "built it " * 300}],
        "usage": {"input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}},
    {"type": "user", "message": {"role": "user", "content": "Stake for the scribe: the build needs an entry."}},
    {"type": "assistant", "timestamp": "2026-10-14T10:01:00Z", "message": {"role": "assistant", "model": "claude-haiku-4-5",
        "content": [{"type": "text", "text": "noted"}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY
  month="$(date -u +%Y-%m)"; ledger="$root/docs/ledger/$month.md"

  run_job() { # <job> <session id> [VAR=value ...] -> stdout of the runner (offsets are per session)
    local job="$1" sid="$2"; shift 2
    local payload
    payload="$(printf '{"session_id": "%s", "transcript_path": "%s", "cwd": "%s", "hook_event_name": "Stop"}' "$sid" "$tmp/s1.jsonl" "$root")"
    (cd "$root" && env -u DEVHOST_ROOT -u CLAUDE_PROJECT_DIR -u DEVHOST_JOB_CHILD \
      PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp" DEVHOST_STATE="$state" DEVHOST_CONTAINER_MARKERS="$marker" \
      DEVHOST_ENGINEER=tester DEVHOST_JOB_QUIET_SECS=0 "$@" devhost-run-job "$job" <<<"$payload")
  }
  calls() { find "$tmp" -maxdepth 1 -name 'args-*.txt' | wc -l | tr -d ' '; }

  # 1. A first run: the stub is called, an entry lands in the ledger, state is written, the
  #    stdout is the quiet notice.
  out="$(run_job scribe s1)"; rc=$?
  check "scribe run exits 0" test "$rc" -eq 0
  check "scribe called claude once" test "$(calls)" = 1
  check "claude ran headless with hooks off and no session" bash -c "grep -q -- '--no-session-persistence' '$tmp/args-0.txt' && grep -q disableAllHooks '$tmp/args-0.txt' && grep -qx haiku '$tmp/args-0.txt'"
  check "the stake reached the top of the prompt" grep -q '^STAKE for scribe (from engineer): the build needs an entry' "$tmp/prompt-0.txt"
  check "the prompt carries the session line and the engineer" bash -c "grep -q '^SESSION LINE: host (s1)' '$tmp/prompt-0.txt' && grep -q '^ENGINEER: tester' '$tmp/prompt-0.txt'"
  check "ledger file created with its heading" bash -c "head -n1 '$ledger' | grep -qx '# Ledger, $month'"
  check "ledger gained the entry" grep -q '^### 2026-10-14 Thing built' "$ledger"
  check "Measures filled by the job, not the model" bash -c "grep -q '^- \*\*Measures:\*\* ' '$ledger' && ! grep -q 'MEASURES' '$ledger'"
  check "the name guard replaced the name" bash -c "grep -q 'build the thing for the Operator' '$ledger' && ! grep -qi zebulonica '$ledger'"
  check "offset file written" test -s "$state/scribe/offsets/s1"
  check "job.log written" test -s "$state/scribe/job.log"
  check "runs.jsonl has one scribe line" bash -c "[ \"\$(wc -l < '$state/runs.jsonl')\" = 1 ] && grep -q '\"job\": \"scribe\"' '$state/runs.jsonl' && grep -q '\"status\": \"changed\"' '$state/runs.jsonl'"
  check "stdout is the quiet notice JSON" bash -c "printf '%s' '$out' | python3 -c 'import json,sys; d=json.load(sys.stdin)[\"hookSpecificOutput\"]; assert d[\"hookEventName\"]==\"Stop\"; assert d[\"additionalContext\"].startswith(\"Back scribe (quiet notice\"); assert \"docs/ledger/$month.md\" in d[\"additionalContext\"]'"

  # 2. The same transcript again: nothing new behind the offset, no call, no output.
  out="$(run_job scribe s1)"; rc=$?
  check "second run exits 0" test "$rc" -eq 0
  check "second run calls nothing and says nothing" bash -c "[ '$(calls)' = 1 ] && [ -z '$out' ]"
  check "ledger unchanged by the second run" bash -c "[ \"\$(grep -c '^### ' '$ledger')\" = 1 ]"

  # 3. Outside a container (marker absent): exit 0, no call, nothing written.
  rm -f "$marker"
  echo "more " >> "$tmp/s1.jsonl"
  out="$(run_job scribe s1)"; rc=$?
  check "workstation run exits 0" test "$rc" -eq 0
  check "workstation run calls nothing and says nothing" bash -c "[ '$(calls)' = 1 ] && [ -z '$out' ]"
  touch "$marker"

  # 4. Inside a back's own run (child guard): nothing.
  out="$(run_job scribe s1 DEVHOST_JOB_CHILD=1)"
  check "child guard stops a nested run" bash -c "[ '$(calls)' = 1 ] && [ -z '$out' ]"

  # 5. The tester with a red suite: no model, a notice; green after red: a recovery notice.
  mkdir -p "$root/src"; echo 'x = 1' > "$root/src/a.py"
  out="$(run_job tester t1 TESTER_CMD="echo 'FAILED tests/test_x.py::test_it - assert'; echo '1 failed, 4 passed in 0.5s'; exit 1")"
  check "tester red leaves a notice" bash -c "printf '%s' '$out' | grep -q 'tests red' && printf '%s' '$out' | grep -q 'first: tests/test_x.py::test_it'"
  check "tester metrics line has no model" bash -c "tail -n1 '$state/runs.jsonl' | grep -q '\"job\": \"tester\"' && tail -n1 '$state/runs.jsonl' | grep -q '\"model\": \"none\"'"
  echo 'x = 2' > "$root/src/a.py"
  out="$(run_job tester t2 TESTER_CMD="echo '5 passed'")"
  check "tester green again leaves a recovery notice" bash -c "printf '%s' '$out' | grep -q 'tests green again'"
  out="$(run_job tester t3 TESTER_CMD="echo '5 passed'")"
  check "tester is quiet without a code change" test -z "$out"
  check "tester never called claude" test "$(calls)" = 1

  rm -rf "$tmp"
}
