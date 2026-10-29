#!/usr/bin/env bash
# Docker-free, offline tests of where bootstrap/bootstrap.sh vendors (slice 2 of the
# host-profile proposal): the default folder .devcontainer/cli_bootstrap.ignore, the
# repo-relative BOOTSTRAP_DIR override and its rejections, the .gitignore handling
# (created, appended once, other lines kept, BOOTSTRAP_GITIGNORE=false), the Taskfile
# template's include (chosen path, optional: true), and the old ./bootstrap form (kept,
# migration note, the one-value include rewrite). The script runs against a temp
# "consuming repo", takes its files from this checkout (--source <dir>, the local
# override of the GitHub URL) and a fake `task` on PATH. The PowerShell twin is covered by
# the Pester tests (BootstrapDir.Tests.ps1). Part of `task lint` (`task test:bootstrap-dir`).
# BOOTSTRAP_SH points the tests at another copy of the script (used to show a test fails
# when the code it covers is broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="${BOOTSTRAP_SH:-$root/bootstrap/bootstrap.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
contains() { # <name> <file or text> <needle>
  local hay="$2"; [ -f "$2" ] && hay="$(cat "$2")"
  case "$hay" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$hay')" ;; esac
}
lacks() { # <name> <file or text> <needle>
  local hay="$2"; [ -f "$2" ] && hay="$(cat "$2")"
  case "$hay" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$hay')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac
}

bin="$T/bin"; mkdir -p "$bin"
printf '#!/bin/sh\necho "fake task $*"\n' > "$bin/task"; chmod +x "$bin/task"

new_repo() { rm -rf "$T/repo"; mkdir -p "$T/repo"; }
# run [VAR=value ...] -- <bootstrap args>: runs the script in the temp repo; output in $out, status in $rc.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out="$(cd "$T/repo" && env -u BOOTSTRAP_DIR -u BOOTSTRAP_GITIGNORE "${envs[@]}" PATH="$bin:$PATH" \
    bash "$script" --source "$root" --no-up "$@" 2>&1)"; rc=$?
}

# --- default folder
new_repo; run --
check 'default: exits 0' 0 "$rc"
check 'default: vendors devcontainer.yml' yes "$([ -f "$T/repo/.devcontainer/cli_bootstrap.ignore/devcontainer.yml" ] && echo yes)"
check 'default: vendors the bash twin, executable' yes "$([ -x "$T/repo/.devcontainer/cli_bootstrap.ignore/host/devcontainer-cli.sh" ] && echo yes)"
check 'default: vendors cloud-folder.yml (task cloud-folder:login on the workstation)' yes "$([ -f "$T/repo/.devcontainer/cli_bootstrap.ignore/cloud-folder.yml" ] && echo yes)"
check 'default: vendors the download helper next to the bash twin' yes "$([ -f "$T/repo/.devcontainer/cli_bootstrap.ignore/host/dcf-curl.sh" ] && echo yes)"
check 'default: no ./bootstrap in the repo' no "$([ -e "$T/repo/bootstrap" ] && echo yes || echo no)"
contains 'default: prints the folder used' "$out" 'folder    .devcontainer/cli_bootstrap.ignore/'
check 'default: .devcontainer/.gitignore ignores the folder' 'cli_bootstrap.ignore/' "$(cat "$T/repo/.devcontainer/.gitignore")"
contains 'default: Taskfile includes the vendored path' "$T/repo/Taskfile.yml" "taskfile: './.devcontainer/cli_bootstrap.ignore/devcontainer.yml'"
contains 'default: the devcontainer include itself is optional' "$(awk '/^  devcontainer:/{f=1;next} /^  [a-z]/{f=0} f' "$T/repo/Taskfile.yml")" 'optional: true'
contains 'default: template comment says run the bootstrap first' "$T/repo/Taskfile.yml" 'run the'
lacks 'default: no unsubstituted placeholder' "$T/repo/Taskfile.yml" 'BOOTSTRAP_DIR'
check 'default: no migration note' no "$(case "$out" in *MIGRATION*) echo yes ;; *) echo no ;; esac)"
if command -v task > /dev/null 2>&1; then
  tl="$(cd "$T/repo" && env -u BOOTSTRAP_DIR task --list-all 2>&1)"
  contains 'default: real task resolves the vendored include' "$tl" 'devcontainer:up'
  tl="$(cd "$T/repo" && env -u BOOTSTRAP_DIR -u RCLONE_CONFIG -u DEVCONTAINER_IN_CONTAINER task --list-all 2>&1)"
  contains 'default: on the workstation task cloud-folder:login is the launcher' "$tl" 'cloud-folder:login'
fi
# the bash twin is found next to the vendored devcontainer.yml (the _BASH_CLI lookup)
snippet="$(grep -F 'f="{{.TASKFILE_DIR}}/host/devcontainer-cli.sh"' "$T/repo/.devcontainer/cli_bootstrap.ignore/devcontainer.yml" | head -1)"
contains 'default: _BASH_CLI looks in host/ next to the vendored file' "$snippet" '{{.TASKFILE_DIR}}/host/devcontainer-cli.sh'

# --- idempotent re-run: no duplicate
run --
check 're-run: .gitignore has the line exactly once' 1 "$(grep -cxF 'cli_bootstrap.ignore/' "$T/repo/.devcontainer/.gitignore")"
contains 're-run: says it is kept' "$out" 'already ignores'
check 're-run: Taskfile kept, not rewritten' 1 "$(grep -c "taskfile: './.devcontainer/cli_bootstrap.ignore/devcontainer.yml'" "$T/repo/Taskfile.yml")"

# --- an unrelated .gitignore line is kept; no trailing newline handled
new_repo; mkdir -p "$T/repo/.devcontainer"; printf '*.log\nsecrets/' > "$T/repo/.devcontainer/.gitignore"
run --
check 'existing: unrelated lines kept, line appended' "*.log
secrets/
cli_bootstrap.ignore/" "$(cat "$T/repo/.devcontainer/.gitignore")"
run --
check 'existing: second run adds nothing' 3 "$(wc -l < "$T/repo/.devcontainer/.gitignore" | tr -d ' ')"

# --- an equivalent existing line counts as present
new_repo; mkdir -p "$T/repo/.devcontainer"; printf '/cli_bootstrap.ignore\n' > "$T/repo/.devcontainer/.gitignore"
run --
check 'equivalent line: nothing appended' '/cli_bootstrap.ignore' "$(cat "$T/repo/.devcontainer/.gitignore")"

# --- BOOTSTRAP_GITIGNORE=false
new_repo; run BOOTSTRAP_GITIGNORE=false --
check 'no gitignore: exits 0' 0 "$rc"
check 'no gitignore: .devcontainer/.gitignore not written' no "$([ -e "$T/repo/.devcontainer/.gitignore" ] && echo yes || echo no)"
contains 'no gitignore: says so' "$out" 'skipped'
new_repo; run -- --no-gitignore
check 'no gitignore: the flag does the same' no "$([ -e "$T/repo/.devcontainer/.gitignore" ] && echo yes || echo no)"

# --- BOOTSTRAP_DIR override
new_repo; run BOOTSTRAP_DIR=tools/dc/ --
check 'override: exits 0' 0 "$rc"
check 'override: vendors into the chosen folder' yes "$([ -f "$T/repo/tools/dc/devcontainer.yml" ] && echo yes)"
check 'override: default folder untouched' no "$([ -e "$T/repo/.devcontainer/cli_bootstrap.ignore" ] && echo yes || echo no)"
contains 'override: prints the folder used' "$out" 'folder    tools/dc/'
contains 'override: Taskfile includes the chosen path' "$T/repo/Taskfile.yml" "taskfile: './tools/dc/devcontainer.yml'"
check 'override outside .devcontainer: root .gitignore gets an anchored line' '/tools/dc/' "$(grep -x '/tools/dc/' "$T/repo/.gitignore")"
check 'override outside .devcontainer: .devcontainer/.gitignore not written' no "$([ -e "$T/repo/.devcontainer/.gitignore" ] && echo yes || echo no)"
contains 'override outside .devcontainer: says which file' "$out" '/tools/dc/ in .gitignore'
new_repo; run -- --bootstrap-dir .devcontainer/vendor
check 'override inside .devcontainer: relative line in .devcontainer/.gitignore' 'vendor/' "$(cat "$T/repo/.devcontainer/.gitignore")"
contains 'override inside .devcontainer: flag works' "$T/repo/Taskfile.yml" "'./.devcontainer/vendor/devcontainer.yml'"

# --- rejections
for bad in /abs/path 'C:\x' ../up a/../../up .. . .devcontainer; do
  new_repo; run "BOOTSTRAP_DIR=$bad" --
  check "reject '$bad': exits 2" 2 "$rc"
  contains "reject '$bad': says BOOTSTRAP_DIR" "$out" 'BOOTSTRAP_DIR'
  check "reject '$bad': nothing written" 0 "$(find "$T/repo" -type f | wc -l | tr -d ' ')"
done

# --- old form: ./bootstrap and an include of ./bootstrap/devcontainer.yml
old_repo() {
  new_repo; mkdir -p "$T/repo/bootstrap/host"
  echo 'old vendored' > "$T/repo/bootstrap/devcontainer.yml"
  printf "version: '3'\n# my comment\nincludes:\n  devcontainer:\n    taskfile: ./bootstrap/devcontainer.yml   # old\n    aliases: [dc]\n  other:\n    taskfile: ./other.yml\ntasks:\n  shutdown:check:\n    cmds: [true]\n" > "$T/repo/Taskfile.yml"
  cp "$T/repo/Taskfile.yml" "$T/old-Taskfile.yml"
}
old_repo
check 'old form: untouched without a re-run' 'old vendored' "$(cat "$T/repo/bootstrap/devcontainer.yml")"
run --
check 'old form re-run: exits 0' 0 "$rc"
contains 'old form re-run: migration note' "$out" 'MIGRATION'
contains 'old form re-run: note says ./bootstrap can be deleted' "$out" './bootstrap/ is unused and can be deleted'
check 'old form re-run: ./bootstrap kept' 'old vendored' "$(cat "$T/repo/bootstrap/devcontainer.yml")"
check 'old form re-run: vendors into the new default' yes "$([ -f "$T/repo/.devcontainer/cli_bootstrap.ignore/devcontainer.yml" ] && echo yes)"
contains 'old form re-run: include repointed' "$T/repo/Taskfile.yml" 'taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml   # old'
check 'old form re-run: the value changed and optional: true was added, nothing else' "$(printf "version: '3'\n# my comment\nincludes:\n  devcontainer:\n    taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml   # old\n    optional: true\n    aliases: [dc]\n  other:\n    taskfile: ./other.yml\ntasks:\n  shutdown:check:\n    cmds: [true]\n")" "$(cat "$T/repo/Taskfile.yml")"
contains 'old form re-run: says it repointed' "$out" 'repointed Taskfile.yml'
contains 'old form re-run: says it added optional: true' "$out" 'added     optional: true'
check 'old form re-run: only the devcontainer include got optional (the other include did not)' 1 "$(grep -c 'optional: true' "$T/repo/Taskfile.yml")"
run --
lacks 'old form second re-run: nothing left to repoint' "$out" 'repointed'
check 'old form second re-run: optional: true still there once' 1 "$(grep -c 'optional: true' "$T/repo/Taskfile.yml")"
# an include that already says optional (before or after the taskfile line) is not given a second one
old_repo; printf "includes:\n  devcontainer:\n    optional: true\n    taskfile: ./bootstrap/devcontainer.yml\n  other:\n    taskfile: ./other.yml\n" > "$T/repo/Taskfile.yml"
run --
check 'old form, optional before taskfile: no second optional' 1 "$(grep -c 'optional' "$T/repo/Taskfile.yml")"
lacks 'old form, optional present: no "added" line' "$out" 'added     optional'
old_repo; printf "includes:\n  devcontainer:\n    taskfile: ./bootstrap/devcontainer.yml\n    optional: false\n  other:\n    taskfile: ./other.yml\n" > "$T/repo/Taskfile.yml"
run --
check 'old form, optional: false kept as the engineer wrote it' 1 "$(grep -c 'optional' "$T/repo/Taskfile.yml")"
# a taskfile line with no trailing newline at the end of the file
old_repo; printf "includes:\n  devcontainer:\n    taskfile: ./bootstrap/devcontainer.yml" > "$T/repo/Taskfile.yml"
run --
check 'old form, last line without newline: optional added on its own line' "$(printf "includes:\n  devcontainer:\n    taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml\n    optional: true")" "$(cat "$T/repo/Taskfile.yml")"
# an include that is not exactly the old path is left alone
old_repo; sed -i 's#\./bootstrap/devcontainer\.yml#./bootstrap/devcontainer.yml.local#' "$T/repo/Taskfile.yml"; cp "$T/repo/Taskfile.yml" "$T/old-Taskfile.yml"
run --
check 'old form, other include: Taskfile untouched' "$(cat "$T/old-Taskfile.yml")" "$(cat "$T/repo/Taskfile.yml")"
# an explicit BOOTSTRAP_DIR is the engineer's choice: no note, no rewrite
old_repo; run BOOTSTRAP_DIR=vendor --
lacks 'old form with BOOTSTRAP_DIR: no migration note' "$out" 'MIGRATION'
check 'old form with BOOTSTRAP_DIR: Taskfile untouched' "$(cat "$T/old-Taskfile.yml")" "$(cat "$T/repo/Taskfile.yml")"

# --- downloads retry a dropped connection (curl: --retry-all-errors covers exit 35 and 56)
new_repo
mkdir -p "$T/cbin"
cat > "$T/cbin/curl" <<'SH'
#!/bin/sh
case "$*" in *--help*) echo "--retry-all-errors"; exit 0 ;; esac
echo "$*" >> "$CURL_LOG"
exit 22
SH
chmod +x "$T/cbin/curl"
CURL_LOG="$T/curl.log"; : > "$CURL_LOG"; export CURL_LOG
(cd "$T/repo" && env -u BOOTSTRAP_DIR PATH="$T/cbin:$bin:$PATH" bash "$script" --source https://example.invalid/x --no-up >/dev/null 2>&1)
contains 'download: --retry 3' "$CURL_LOG" '--retry 3'
contains 'download: --retry-delay 2' "$CURL_LOG" '--retry-delay 2'
contains 'download: --retry-all-errors' "$CURL_LOG" '--retry-all-errors'

echo "bootstrap dir tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
