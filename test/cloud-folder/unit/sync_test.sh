#!/usr/bin/env bash
# Docker-free tests of cloud-folder-setup's sync mode (src/cloud-folder/cloud-folder-setup.sh)
# with a fake rclone on PATH: it records every call's arguments, answers `version`, `lsjson
# --stat` and `config update` (rclone's non-interactive config protocol), and plays bisync
# between two temp folders (the remote is an alias remote pointing at one of them), with a
# chosen delay, exit code and log line. The real rclone runs in the Docker scenarios
# (test/cloud-folder/sync_local.sh). Covered: auto choosing sync once a remote is signed in;
# login (a pasted token read from stdin and written only into the config, mode 600; a wrong
# paste refused; siteUrl required for sharepoint; one drive taken, several listed and chosen;
# client credentials from a secret file); the first sync a --resync with the flags that matter
# (--max-lock, --max-delete 50, --resilient, --recover, the workdir in the volume); later syncs
# without it; a new folder (the marker gone) resynced; a failure and bisync's delete guard
# reported and failing the status; exit 7; status and --json; the files changed since the last
# sync; a second sync refused while one runs; the shutdown check refusing a running sync and
# pending changes, waiting for a sync to end, and passing in host mode; the timer started once
# (a second start leaves it), syncing on its own, off with syncInterval 0, stopped cleanly, and
# stopping a running sync gracefully; the token never in a process's arguments, the logs, the
# record or any output; the Feature Taskfile passing -- --resync and WAIT. Part of `task lint`
# (`task test:cloud-folder-unit`). SETUP_SH points the tests at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/cloud-folder/cloud-folder-setup.sh}"
taskfile="$here/../../../src/cloud-folder/taskfile.yml"

T="$(mktemp -d)"
cleanup() {
  local p
  for p in "$T"/state/run/*.pid; do [ -f "$p" ] && kill -TERM "$(cat "$p")" 2>/dev/null; done
  pkill -f "$T/bin/rclone" 2>/dev/null
  sleep 0.3
  chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
hasnt() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}
yesno() { if "$@"; then echo yes; else echo no; fi; }

SECRET='SECRETTOKENMARKER-7f3a'
CSECRET='CLIENTSECRETMARKER-91c2'
state="$T/state"
mp="$T/cloud folder"
remote_dir="$T/remote"
mkdir -p "$T/bin" "$remote_dir/sub"
mount_table() { echo '22 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw' > "$T/mountinfo"; }
mount_table

# The fake rclone. FAKE_SLEEP seconds inside bisync (TERM ends it with 143; INT is what bisync's
# graceful shutdown listens for, but a background job of a script starts with INT ignored, so the
# setup script follows it with TERM), FAKE_RC its exit code, FAKE_ERROR a log line,
# FAKE_DRIVES the number of drives `config update` offers, FAKE_UNREACHABLE=1 fails lsjson.
cat > "$T/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
printf '%s\n' "$*" >> "$FAKE_CALLS.all"
case "$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  lsjson) [ "${FAKE_UNREACHABLE:-}" = 1 ] && { echo 'NOTICE: Failed to lsjson: directory not found' >&2; exit 3; }; echo '{}'; exit 0 ;;
  config)
    case " $* " in
      *' --continue '*) printf '{\n\t"State": "",\n\t"Option": null,\n\t"Error": "",\n\t"Result": ""\n}\n'; exit 0 ;;
    esac
    if [ "${FAKE_DRIVES:-1}" -gt 1 ]; then
      printf '{\n\t"State": "driveid_final",\n\t"Option": {\n\t\t"Name": "config_driveid",\n\t\t"Examples": [\n'
      for i in $(seq 1 "$FAKE_DRIVES"); do printf '\t\t\t{\n\t\t\t\t"Value": "drive-%s",\n\t\t\t\t"Help": "Library %s (documentLibrary)"\n\t\t\t},\n' "$i" "$i"; done
      printf '\t\t]\n\t},\n\t"Error": "",\n\t"Result": ""\n}\n'
    else
      printf '{\n\t"State": "driveid_final_end",\n\t"Option": {\n\t\t"Name": "config_drive_ok",\n\t\t"Default": true\n\t},\n\t"Error": "",\n\t"Result": ""\n}\n'
    fi
    exit 0 ;;
  bisync)
    p1="$2"; p2="$3"; shift 3
    resync=no workdir='' log=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --resync) resync=yes ;;
        --workdir) workdir="$2"; shift ;;
        --log-file) log="$2"; shift ;;
      esac
      shift
    done
    base="$(sed -n 's/^remote = //p' "$RCLONE_CONFIG" | head -n 1)"
    src="$base/${p1#cloud-folder:}"
    echo $$ > "$FAKE_PIDFILE"
    trap 'echo "NOTICE: terminated" >> "$log"; exit 143' TERM
    if [ -n "${FAKE_SLEEP:-}" ]; then
      i=0; while [ "$i" -lt "$((FAKE_SLEEP * 10))" ]; do sleep 0.1; i=$((i + 1)); done
    fi
    if [ "$resync" = no ] && [ ! -f "$workdir/listing" ]; then
      echo '2026/10/27 10:00:00 ERROR : Bisync critical error: cannot find prior Path1 or Path2 listings' >> "$log"; exit 7
    fi
    if [ -n "${FAKE_RC:-}" ] && [ "$FAKE_RC" != 0 ]; then
      echo "2026/10/27 10:00:00 ERROR : ${FAKE_ERROR:-something failed}" >> "$log"; exit "$FAKE_RC"
    fi
    cp -a -u "$src"/. "$p2"/ 2>/dev/null
    (cd "$p2" && for f in * ; do [ -e "$f" ] && cp -a -u "$f" "$src"/; done)
    : > "$workdir/listing"
    echo '2026/10/27 10:00:00 INFO  : Bisync successful' >> "$log"
    exit 0 ;;
esac
echo "fake rclone: unexpected call: $*" >&2
exit 2
FAKE
chmod +x "$T/bin/rclone"
export FAKE_CALLS="$T/calls" FAKE_PIDFILE="$T/fake.pid"
: > "$FAKE_CALLS"

ALL_OUT="$T/all-output"
: > "$ALL_OUT"
# run [VAR=value ...] -- <script args>: out = stdout+stderr, rc = exit status. Clean environment.
# Every output is kept, to check at the end that no secret was ever printed.
base_env() {
  env -i PATH="$T/bin:$PATH" HOME="$T" FAKE_CALLS="$FAKE_CALLS" FAKE_PIDFILE="$FAKE_PIDFILE" \
    DCF_CLOUD_FOLDER_STATE_DIR="$state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" DCF_CLOUD_FOLDER_HOST_MOUNT="$mp" \
    CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_REMOTE_PATH=sub CLOUD_FOLDER_SITE_URL=https://example.invalid/sites/team \
    CLOUD_FOLDER_SYNC_INTERVAL=0 DCF_CLOUD_FOLDER_GRACE=1 DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" "$@"
}
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out="$(base_env "${envs[@]}" bash "$setup_sh" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
}
field() { python3 -c 'import json, sys; v = json.loads(sys.stdin.read())[sys.argv[1]]; print(json.dumps(v) if not isinstance(v, str) else v)' "$1" <<<"$out"; }
last_call() { grep "^$1" "$FAKE_CALLS" | tail -n 1; }
alias_conf() { # a remote the fake plays as an alias of $remote_dir, with a token line to guard
  umask 077
  printf '[cloud-folder]\ntype = alias\nremote = %s\ntoken = {"access_token":"%s"}\n' "$remote_dir" "$SECRET" > "$state/rclone.conf"
}

# --- no remote yet
run -- status
check 'no remote, auto: status exits 1' 1 "$rc"
has 'no remote, auto: no source, and says how to sign in' 'task cloud-folder:login' "$out"
run CLOUD_FOLDER_MODE=sync -- status
check 'mode sync, no remote: exit 1' 1 "$rc"
has 'mode sync, no remote: not-configured' 'not usable (not-configured)' "$out"
run CLOUD_FOLDER_MODE=sync -- sync
check 'sync with no remote: exit 3' 3 "$rc"
run CLOUD_FOLDER_MODE=sync -- start
check 'start with no remote: exit 0' 0 "$rc"
has 'start with no remote: says login starts it' 'no remote is configured yet' "$out"

# --- login: a pasted token
run CLOUD_FOLDER_SITE_URL= -- login
check 'login, sharepoint without siteUrl: exit 2' 2 "$rc"
has 'and says siteUrl is needed' 'needs siteUrl' "$out"
out="$(printf 'not a token\n' | base_env bash "$setup_sh" login 2>&1)"; rc=$?; printf '%s\n' "$out" >> "$ALL_OUT"
check 'login, a wrong paste: exit 1' 1 "$rc"
has 'and nothing changed' 'nothing changed' "$out"
check 'no config written' no "$(yesno test -e "$state/rclone.conf")"
: > "$FAKE_CALLS"
token="{\"access_token\":\"$SECRET\",\"token_type\":\"Bearer\",\"refresh_token\":\"r-$SECRET\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
out="$(printf '%s\n' "$token" | base_env bash "$setup_sh" login 2>&1)"; rc=$?; printf '%s\n' "$out" >> "$ALL_OUT"
check 'login with a token: exit 0' 0 "$rc"
has 'login tells the person to run rclone authorize with the same version' 'rclone authorize "onedrive"' "$out"
has 'login names the rclone version' 'rclone v1.75.2' "$out"
has 'login says where the remote went' "written to $state/rclone.conf (mode 600, token)" "$out"
check 'the config holds the token' yes "$(yesno grep -qF "$SECRET" "$state/rclone.conf")"
check 'the config is mode 600' 600 "$(stat -c %a "$state/rclone.conf")"
check 'the config has type onedrive' yes "$(yesno grep -qx 'type = onedrive' "$state/rclone.conf")"
check 'the config has the drive type' yes "$(yesno grep -qx 'drive_type = documentLibrary' "$state/rclone.conf")"
has 'the drive lookup asks rclone with the site URL and keeps the token' 'config update cloud-folder config_refresh_token=false config_type=url config_site_url=https://example.invalid/sites/team --non-interactive' "$(cat "$FAKE_CALLS")"
has 'and confirms the drive' '--continue --state driveid_final_end --result true' "$(cat "$FAKE_CALLS")"
hasnt 'the token is never in an rclone command line' "$SECRET" "$(cat "$FAKE_CALLS")"
has 'syncInterval 0: login starts no timer' 'timer: off' "$out"
run CLOUD_FOLDER_REMOTE_TYPE=onedrive -- version
check 'version: exit 0' 0 "$rc"
has 'version names rclone' 'rclone: rclone v1.75.2' "$out"

# --- login: several drives, other remotes kept
printf '[other]\ntype = local\n' >> "$state/rclone.conf"
: > "$FAKE_CALLS"
out="$(printf '%s\n' "$token" | base_env FAKE_DRIVES=3 bash "$setup_sh" login 2>&1)"; rc=$?; printf '%s\n' "$out" >> "$ALL_OUT"
check 'several drives, no choice possible: exit 1' 1 "$rc"
has 'lists them' '2) Library 2 (documentLibrary) [drive-2]' "$out"
has 'and says how to choose' 'set CLOUD_FOLDER_DRIVE_ID' "$out"
out="$(printf '%s\n' "$token" | base_env FAKE_DRIVES=3 CLOUD_FOLDER_DRIVE_CHOICE=2 bash "$setup_sh" login 2>&1)"; rc=$?; printf '%s\n' "$out" >> "$ALL_OUT"
check 'several drives, choice 2: exit 0' 0 "$rc"
has 'the chosen drive goes back to rclone' '--continue --state driveid_final --result drive-2' "$(cat "$FAKE_CALLS")"
check 'one [cloud-folder] section after logging in twice' 1 "$(grep -c '^\[cloud-folder\]' "$state/rclone.conf")"
check 'another remote in the config is kept' yes "$(yesno grep -qx '\[other\]' "$state/rclone.conf")"
: > "$FAKE_CALLS"
out="$(printf '%s\n' "$token" | base_env CLOUD_FOLDER_DRIVE_ID=b!fixed bash "$setup_sh" login 2>&1)"; rc=$?; printf '%s\n' "$out" >> "$ALL_OUT"
check 'CLOUD_FOLDER_DRIVE_ID: exit 0' 0 "$rc"
check 'CLOUD_FOLDER_DRIVE_ID: written' yes "$(yesno grep -qx 'drive_id = b!fixed' "$state/rclone.conf")"
check 'CLOUD_FOLDER_DRIVE_ID: no lookup' '' "$(grep '^config' "$FAKE_CALLS")"

# --- login: client credentials from a secret file (the cluster case)
printf '%s\n' "$CSECRET" > "$T/client-secret"
: > "$FAKE_CALLS"
run CLOUD_FOLDER_CLIENT_ID=app-id CLOUD_FOLDER_TENANT=tenant-id CLOUD_FOLDER_CLIENT_SECRET_FILE="$T/client-secret" -- login
check 'client credentials: exit 0' 0 "$rc"
check 'client credentials: the secret is in the config' yes "$(yesno grep -qx "client_secret = $CSECRET" "$state/rclone.conf")"
check 'client credentials: the flag is set' yes "$(yesno grep -qx 'client_credentials = true' "$state/rclone.conf")"
check 'client credentials: no token left from before' no "$(yesno grep -q '^token' "$state/rclone.conf")"
hasnt 'client credentials: no refresh_token answer' 'config_refresh_token' "$(cat "$FAKE_CALLS")"
hasnt 'client credentials: the secret is never on a command line' "$CSECRET" "$(cat "$FAKE_CALLS")"
run CLOUD_FOLDER_CLIENT_ID=app-id -- login
check 'client credentials without a tenant: exit 2' 2 "$rc"

# --- sync: an alias remote the fake plays between two folders
alias_conf
echo from-remote > "$remote_dir/sub/remote.txt"
run -- status
check 'auto with a remote: never synced, exit 1' 1 "$rc"
has 'auto chose sync' 'mode sync (auto: nothing is mounted at' "$out"
has 'never synced' 'not usable (never-synced)' "$out"
has 'the remote answers' 'reachable' "$out"
: > "$FAKE_CALLS"
run -- sync
check 'first sync: exit 0' 0 "$rc"
has 'first sync: says it is a resync' '(--resync: first sync of' "$out"
call="$(last_call bisync)"
has 'first sync: --resync' '--resync' "$call"
has 'first sync: path 1 the remote, path 2 the folder' "bisync cloud-folder:sub $mp " "$call"
has 'the listings live in the volume' "--workdir $state/bisync" "$call"
has 'a stale lock expires' '--max-lock 5m' "$call"
has 'the 50% delete guard' '--max-delete 50' "$call"
has 'unattended runs recover' '--resilient --recover' "$call"
has 'the marker is not synced' '--exclude /.cloud-folder-bisync' "$call"
hasnt 'no conflict resolution: bisync keeps both versions' '--conflict-resolve' "$call"
check 'the remote file arrived' from-remote "$(cat "$mp/remote.txt" 2>/dev/null)"
check 'the marker is in the folder' yes "$(yesno test -f "$mp/.cloud-folder-bisync")"
check 'the record says ok' yes "$(yesno grep -qx 'result=ok' "$state/last-sync")"
run -- status
check 'synced: status exits 0' 0 "$rc"
has 'synced: ok' 'ok: the folder is synced and writable' "$out"
has 'synced: the last sync' 'last sync: 20' "$out"
run -- status --json
check '--json: verdict ok' ok "$(field verdict)"
check '--json: mode sync' sync "$(field mode)"
check '--json: configured' true "$(field configured)"
check '--json: reachable' true "$(field remote_reachable)"
check '--json: last result' ok "$(field last_result)"
check '--json: nothing pending' 0 "$(field pending)"
check '--json: no sync running' false "$(field sync_running)"

sleep 1.1
echo from-local > "$mp/local.txt"
run -- status --json
check 'a local change counts as pending' 1 "$(field pending)"
run -- shutdown-check 0
check 'shutdown check with a pending change: exit 1' 1 "$rc"
has 'and says to sync first' 'changed since the last successful sync started; run task cloud-folder:sync first' "$out"
: > "$FAKE_CALLS"
run -- sync
check 'second sync: exit 0' 0 "$rc"
hasnt 'second sync: no --resync' '--resync' "$(last_call bisync)"
check 'the local file reached the remote' from-local "$(cat "$remote_dir/sub/local.txt" 2>/dev/null)"
run -- shutdown-check 0
check 'shutdown check after the sync: exit 0' 0 "$rc"
has 'and says it is safe' 'safe to stop' "$out"

# A new folder (a rebuild gives an empty one): the marker is gone, so the next sync resyncs.
rm -f "$mp/.cloud-folder-bisync"
run -- status
check 'a folder without the marker: never synced here, exit 1' 1 "$rc"
run -- sync
has 'a folder without the marker gets a resync' '--resync' "$(last_call bisync)"
run CLOUD_FOLDER_REMOTE_PATH=other -- sync
has 'another remotePath gets a resync' '(--resync: the remote or the folder changed)' "$out"
mkdir -p "$remote_dir/other"
run -- sync
run -- sync -- --resync
check 'sync: an unknown argument exits 2' 2 "$rc"
run -- sync --resync
has 'sync --resync forces one' '--resync' "$(last_call bisync)"

# --- failures
run FAKE_RC=1 FAKE_ERROR='Safety abort: too many deletes (>50%, 3 of 3) on Path2' -- sync
check 'a failed sync: exit 1' 1 "$rc"
has 'and says what failed' 'too many deletes' "$out"
has 'and how to pass the delete guard' 'task cloud-folder:sync -- --force' "$out"
run -- status
check 'after a failed sync: status exits 1' 1 "$rc"
has 'after a failed sync: sync-failed' 'not usable (sync-failed)' "$out"
run -- sync --force
has 'sync --force reaches bisync' '--force' "$(last_call bisync)"
check 'sync --force: exit 0' 0 "$rc"
run FAKE_RC=7 FAKE_ERROR='Bisync critical error' -- sync
check 'a critical error: exit 7' 7 "$rc"
touch "$state/bisync/x.path1.lst-err"
run -- status
has 'listings set aside: needs-resync' 'not usable (needs-resync)' "$out"
rm -f "$state/bisync/x.path1.lst-err"
run -- sync
run FAKE_UNREACHABLE=1 -- status --json
check 'an unreachable remote is reported' false "$(field remote_reachable)"
check 'but does not fail the folder itself' ok "$(field verdict)"

# --- one sync at a time, and the shutdown check while one runs
rm -f "$FAKE_PIDFILE"
base_env FAKE_SLEEP=4 bash "$setup_sh" sync > "$T/bg-sync.out" 2>&1 &
bg=$!
for _ in $(seq 1 50); do [ -s "$FAKE_PIDFILE" ] && break; sleep 0.1; done
run -- sync
check 'a second sync while one runs: exit 4' 4 "$rc"
has 'and says one is running' 'a sync is already running' "$out"
run -- status --json
check 'status: sync running' true "$(field sync_running)"
hasnt 'no process has the token in its arguments' "$SECRET" "$(ps -eo args)"
run -- shutdown-check 0
check 'shutdown check while a sync runs: exit 1' 1 "$rc"
has 'and says a sync is running' 'REFUSE: a sync is still running' "$out"
run -- shutdown-check 20
check 'shutdown check waiting for the sync to end: exit 0' 0 "$rc"
has 'it waited' 'waiting up to 20s' "$out"
wait "$bg"
check 'the background sync ended ok' 0 "$?"
cat "$T/bg-sync.out" >> "$ALL_OUT"

# --- the timer
run CLOUD_FOLDER_SYNC_INTERVAL=0 -- start
has 'syncInterval 0: no timer' 'timer: off' "$out"
run CLOUD_FOLDER_SYNC_INTERVAL=1x -- start
check 'a syncInterval that is not a duration: exit 1' 1 "$rc"
: > "$FAKE_CALLS"
run CLOUD_FOLDER_SYNC_INTERVAL=1s -- start
check 'start: exit 0' 0 "$rc"
has 'start: started' 'timer: started (pid' "$out"
loop_pid="$(cat "$state/run/loop.pid" 2>/dev/null)"
run CLOUD_FOLDER_SYNC_INTERVAL=1s -- start
has 'a second start leaves it' "timer: already running (pid $loop_pid" "$out"
check 'one loop process' 1 "$(pgrep -f "$(readlink -f "$setup_sh") run" | wc -l | tr -d ' ')"
for _ in $(seq 1 40); do [ "$(grep -c '^bisync' "$FAKE_CALLS")" -ge 2 ] && break; sleep 0.25; done
check 'the timer syncs on its own, again and again' yes "$(yesno test "$(grep -c '^bisync' "$FAKE_CALLS")" -ge 2)"
run -- status --json
check 'status: timer running' true "$(field timer_running)"
check 'status: timer pid' "$loop_pid" "$(field timer_pid)"
run -- stop
check 'stop: exit 0' 0 "$rc"
has 'stop: stopped' 'timer: stopped' "$out"
check 'the loop is gone' no "$(yesno kill -0 "$loop_pid" 2>/dev/null)"
check 'its PID file is gone' no "$(yesno test -e "$state/run/loop.pid")"
run -- stop
has 'stop again: not running' 'timer: not running' "$out"
echo 999999 > "$state/run/loop.pid"
run CLOUD_FOLDER_SYNC_INTERVAL=1s -- start
has 'a stale PID file does not block a start' 'timer: started (pid' "$out"
run -- stop

# Stopping the timer in the middle of a sync: bisync is asked to stop, the record says so.
rm -f "$FAKE_PIDFILE"
run CLOUD_FOLDER_SYNC_INTERVAL=1s FAKE_SLEEP=30 -- start
for _ in $(seq 1 50); do [ -s "$FAKE_PIDFILE" ] && break; sleep 0.1; done
run -- stop
check 'stop during a sync: exit 0' 0 "$rc"
check 'the sync was stopped' no "$(yesno kill -0 "$(cat "$FAKE_PIDFILE")" 2>/dev/null)"
check 'the record says interrupted' yes "$(yesno grep -qx 'result=interrupted' "$state/last-sync")"
check 'no sync PID file is left' no "$(yesno test -e "$state/run/sync.pid")"
run -- sync
check 'the next sync runs' 0 "$rc"

# --- the post-start hook in sync mode
run --
check 'post-start in sync mode: exit 0' 0 "$rc"
has 'post-start reports sync' 'mode sync' "$out"
run CLOUD_FOLDER_MODE=host -- shutdown-check 0
check 'shutdown check in host mode: exit 0' 0 "$rc"

# --- the Feature Taskfile hands -- --resync and WAIT to the script
if command -v task >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec bash %q "$@"\n' "$setup_sh" > "$T/bin/cloud-folder-setup"
  chmod +x "$T/bin/cloud-folder-setup"
  out="$(cd "$T" && base_env task -s -t "$taskfile" sync -- --resync 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
  check 'task sync -- --resync: exit 0' 0 "$rc"
  has 'task sync -- --resync reaches bisync' '--resync' "$(last_call bisync)"
  out="$(cd "$T" && base_env task -s -t "$taskfile" shutdown-check WAIT=0 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
  check 'task shutdown-check WAIT=0: exit 0' 0 "$rc"
  out="$(cd "$T" && base_env task -s -t "$taskfile" status CLOUD_FOLDER_REMOTE_PATH=missing -- --json 2>&1)"
  printf '%s\n' "$out" >> "$ALL_OUT"
  check 'task status: a command-line CLOUD_FOLDER_REMOTE_PATH reaches the script' 'cloud-folder:missing' "$(field remote 2>/dev/null)"
else
  echo "skip - the Taskfile checks: task is not on PATH"
fi

# --- the token never leaves the config
hasnt 'no output ever showed the token' "$SECRET" "$(cat "$ALL_OUT")"
hasnt 'no output ever showed the client secret' "$CSECRET" "$(cat "$ALL_OUT")"
leaks="$(grep -rlF -e "$SECRET" -e "$CSECRET" "$state" 2>/dev/null | grep -v '/rclone.conf$')"
check 'only rclone.conf holds a secret in the volume (logs, record, listings do not)' '' "$leaks"
hasnt 'no rclone call ever had a secret on its command line' "$SECRET" "$(cat "$FAKE_CALLS.all")"
hasnt 'nor the client secret' "$CSECRET" "$(cat "$FAKE_CALLS.all")"
check 'the state folder is private' 700 "$(stat -c %a "$state")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
