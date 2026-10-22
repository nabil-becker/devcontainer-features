#!/usr/bin/env bash
# Docker-free tests of the shutdown-check contract (bootstrap/SHUTDOWN.md):
#   1. the default resolution snippet in bootstrap/devcontainer.yml
#      (_SHUTDOWN_CHECK_DEFAULT), extracted from there and run with fake
#      `task` and `devhost-shutdown-check` commands on a PATH that holds nothing else;
#   2. the starter bootstrap/shutdown-check.sh in temp git repositories;
#   3. the bash twin's `stop` (src/devcontainer-cli/devcontainer-cli.sh) with a
#      stub engine and CLI: a check that exits 127 gets its own message, a
#      refusing check refuses, FORCE skips it, prepshutdown stops nothing.
# Part of `task lint` (`task test:shutdown`). Needs bash, git, base64.
#
# DEVCONTAINER_YML, STARTER and CLI_SH point the tests at other copies of the
# three files (used to show a test fails when the code it covers is broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$here/../.."
yml="${DEVCONTAINER_YML:-$repo/bootstrap/devcontainer.yml}"
starter="${STARTER:-$repo/bootstrap/shutdown-check.sh}"
cli_sh="${CLI_SH:-$repo/src/devcontainer-cli/devcontainer-cli.sh}"
command -v git >/dev/null || { echo "shutdown_resolution_test: no git on PATH" >&2; exit 1; }
bash_bin="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

# --- 1. The resolution snippet ---------------------------------------------
snippet="$(sed -n "s/^  _SHUTDOWN_CHECK_DEFAULT: '\(.*\)'\$/\1/p" "$yml")"
[ -n "$snippet" ] || { echo "FAIL - no _SHUTDOWN_CHECK_DEFAULT in $yml"; exit 1; }
case "$snippet" in *\'*) check 'snippet has no single quote' no yes ;; *) check 'snippet has no single quote' no no ;; esac

# run_snippet <task mode: knows|unknown|refuses|none> <devhost check: yes|refuses|no>
# Prints "<exit code>|<what ran>". Fakes record their name; PATH holds only them.
run_snippet() {
  local d="$T/bin.$$.$RANDOM" out rc
  mkdir -p "$d"
  # shellcheck disable=SC2016  # the fakes' own $1 and $*, not ours
  case "$1" in
    knows | refuses)
      cat > "$d/task" <<EOF
#!/bin/sh
if [ "\$1" = --summary ]; then [ "\$2" = shutdown:check ]; exit \$?; fi
echo "task \$*"
$([ "$1" = refuses ] && echo 'exit 3' || echo 'exit 0')
EOF
      ;;
    unknown) printf '#!/bin/sh\nif [ "$1" = --summary ]; then exit 200; fi\necho "task $*"\n' > "$d/task" ;;
  esac
  case "$2" in
    yes) printf '#!/bin/sh\necho devhost-shutdown-check\n' > "$d/devhost-shutdown-check" ;;
    refuses) printf '#!/bin/sh\necho devhost-shutdown-check\nexit 4\n' > "$d/devhost-shutdown-check" ;;
  esac
  chmod +x "$d"/* 2>/dev/null
  out="$(PATH="$d" "$bash_bin" -c "$snippet" 2>&1)"; rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

check 'task knows shutdown:check: it runs, devhost check not' '0|task shutdown:check' "$(run_snippet knows yes)"
check 'refusing shutdown:check refuses with its code' '3|task shutdown:check' "$(run_snippet refuses yes)"
check 'task without shutdown:check: devhost check runs' '0|devhost-shutdown-check' "$(run_snippet unknown yes)"
check 'refusing devhost check refuses with its code' '4|devhost-shutdown-check' "$(run_snippet unknown refuses)"
check 'no task, devhost check: it runs' '0|devhost-shutdown-check' "$(run_snippet none yes)"
check 'task without shutdown:check, no devhost check: stops' '0|no shutdown check defined; stopping' "$(run_snippet unknown no)"
check 'neither: stops' '0|no shutdown check defined; stopping' "$(run_snippet none no)"

# --- 2. The starter script ---------------------------------------------------
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

new_repo() { # <name>: a repo with one commit; prints its path
  local r="$T/$1"
  mkdir -p "$r"
  (cd "$r" && git init -q && echo a > a && git add a && git commit -q -m one)
  printf '%s' "$r"
}
run_starter() { (cd "$1" && sh "$starter" >"$T/starter.out" 2>&1; echo $?); }

r="$(new_repo clean)"
check 'starter: clean repo -> 0' 0 "$(run_starter "$r")"
echo b > "$r/b"
check 'starter: uncommitted work is reported, not refused' 0 "$(run_starter "$r")"
grep -q 'uncommitted' "$T/starter.out"; check 'starter: ...and said so' 0 "$?"

r="$(new_repo stash)"
echo changed > "$r/a"; (cd "$r" && git stash -q)
check 'starter: a stash left behind -> non-zero' 1 "$(run_starter "$r")"

r="$(new_repo merge)"
(cd "$r" && git rev-parse HEAD > "$(git rev-parse --git-path MERGE_HEAD)")
check 'starter: MERGE_HEAD -> non-zero' 1 "$(run_starter "$r")"

r="$(new_repo lock)"
(cd "$r" && : > "$(git rev-parse --git-path index.lock)")
check 'starter: index.lock -> non-zero' 1 "$(run_starter "$r")"

r="$(new_repo rebase)"
(cd "$r" && mkdir -p "$(git rev-parse --git-path rebase-merge)")
check 'starter: rebase in progress -> non-zero' 1 "$(run_starter "$r")"

r="$(new_repo sepdir)"
(cd "$r" && git init -q --separate-git-dir "$T/sepdir.git" . >/dev/null 2>&1; : > "$(git rev-parse --git-path CHERRY_PICK_HEAD)")
check 'starter: CHERRY_PICK_HEAD in a git dir outside the workspace -> non-zero' 1 "$(run_starter "$r")"

mkdir -p "$T/nogit"
check 'starter: not a git work tree -> 0' 0 "$(run_starter "$T/nogit")"

# --- 3. The bash twin's stop -------------------------------------------------
# Stub docker (ps lists one container; stop records) and stub devcontainer (an
# exec exits $STUB_RC and records its command); the twin finds both on PATH.
stub="$T/stub"; mkdir -p "$stub" "$T/ws"
cat > "$stub/docker" <<'EOF'
#!/bin/sh
case "$1" in ps) echo abc123 ;; stop) echo "docker $*" >> "$STUB_LOG" ;; esac
EOF
cat > "$stub/devcontainer" <<'EOF'
#!/bin/sh
echo "devcontainer $*" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"/*
export STUB_LOG="$T/stub.log"
check_b64="$(printf '%s' 'my-check' | base64 | tr -d '\n')"
run_stop() { # <sub> <rc> [--force]; prints "<exit>|<stderr last line>|<log lines>"
  local sub="$1" rc="$2"; shift 2
  : > "$STUB_LOG"
  local err code
  err="$(PATH="$stub:$PATH" STUB_RC="$rc" bash "$cli_sh" run "$sub" --workspace-folder "$T/ws" --cmd-b64 "$check_b64" "$@" 2>&1 >/dev/null)"; code=$?
  printf '%s|%s|%s' "$code" "$(printf '%s' "$err" | tail -n 1)" "$(tr '\n' ';' < "$STUB_LOG")"
}
msg127='Not stopping: the shutdown check (my-check) is not installed in the container (exit 127). Define it, unset STOP_CHECK to use the default resolution, or run again with FORCE=1.'
out="$(run_stop stop 127)"
check 'bash stop: exit 127 -> the not-installed message, exit 127, no stop' "127|$msg127|" "${out%%|devcontainer*}|"
case "$out" in *'docker stop'*) check 'bash stop: 127 does not stop' no yes ;; *) check 'bash stop: 127 does not stop' no no ;; esac
out="$(run_stop stop 1)"
case "$out" in 1\|Not\ stopping:\ the\ shutdown\ check\ \(my-check\)\ found*) check 'bash stop: refusing check -> generic refusal, its code' ok ok ;; *) check 'bash stop: refusing check -> generic refusal, its code' ok "$out" ;; esac
out="$(run_stop stop 0)"
case "$out" in 0\|*'docker stop abc123'*) check 'bash stop: passing check -> stops' ok ok ;; *) check 'bash stop: passing check -> stops' ok "$out" ;; esac
out="$(run_stop stop 1 --force)"
case "$out" in 0\|*'docker stop abc123'*) case "$out" in *'devcontainer exec'*) check 'bash stop: FORCE runs no check' ok ran ;; *) check 'bash stop: FORCE runs no check' ok ok ;; esac ;; *) check 'bash stop: FORCE runs no check' ok "$out" ;; esac
out="$(run_stop prepshutdown 0)"
case "$out" in 0\|*'devcontainer exec'*) case "$out" in *'docker stop'*) check 'bash prepshutdown: runs the check, stops nothing' ok stopped ;; *) check 'bash prepshutdown: runs the check, stops nothing' ok ok ;; esac ;; *) check 'bash prepshutdown: runs the check, stops nothing' ok "$out" ;; esac
out="$(run_stop prepshutdown 5)"
case "$out" in 5\|*) case "$out" in *'docker stop'*) check 'bash prepshutdown: refusing check -> its code' 5 stopped ;; *) check 'bash prepshutdown: refusing check -> its code' 5 5 ;; esac ;; *) check 'bash prepshutdown: refusing check -> its code' 5 "$out" ;; esac

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
