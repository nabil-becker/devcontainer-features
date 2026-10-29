#!/usr/bin/env bash
# Docker-free tests of cloud-folder-setup's mount mode and of auto's order (host, then mount, then
# sync) (src/cloud-folder/cloud-folder-setup.sh), with no FUSE and no privilege:
#   - the FUSE check is a function of what it reads, each replaced by a test hook: the device
#     (DCF_CLOUD_FOLDER_FUSE_DEV: missing, a plain file, or /dev/null, a character device anyone
#     opens), the bounding set (DCF_CLOUD_FOLDER_PROC_STATUS: Docker's default a80425fb has no
#     CAP_SYS_ADMIN), the AppArmor profile (DCF_CLOUD_FOLDER_APPARMOR) and fusermount
#     (DCF_CLOUD_FOLDER_FUSERMOUNT);
#   - a fake rclone plays `rclone mount` by adding a fuse.rclone line to a mount table file
#     (DCF_CLOUD_FOLDER_MOUNTINFO) and waiting; a fake fusermount3 -u takes it away; `rclone rc
#     vfs/stats` answers with a recorded reply of rclone 1.75.2 (fixtures/vfs-stats-*.json,
#     recorded from `rclone serve webdav --vfs-cache-mode writes --rc` with two uploads queued,
#     and with cache mode off), or fails as an unreachable remote control does.
# Covered: fuse-check per cause; auto choosing mount, sync (no FUSE, or a sync copy already in
# the folder) or none; mount mode with no FUSE (the DCF_HOST_FUSE hint); the post-start hook
# mounting with --vfs-cache-mode writes, the cache in the volume and the remote control on
# localhost without --rc-no-auth; start idempotent; a folder with files refused; rclone exiting;
# status and --json from the vfs/stats reply (pending, cache off, failed uploads, no answer); the
# shutdown check and unmount refusing pending uploads, --force; the Feature Taskfile's unmount.
# Part of `task lint` (`task test:cloud-folder-unit`). SETUP_SH points the tests at another copy.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/cloud-folder/cloud-folder-setup.sh}"
taskfile="$here/../../../src/cloud-folder/taskfile.yml"
fixtures="$here/fixtures"

T="$(mktemp -d)"
cleanup() {
  local p
  for p in "$T"/state/run/*.pid; do [ -f "$p" ] && kill -TERM "$(cat "$p")" 2>/dev/null; done
  pkill -f "$T/bin/rclone" 2>/dev/null
  sleep 0.2
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
field() { python3 -c 'import json, sys; v = json.loads(sys.stdin.read())[sys.argv[1]]; print(json.dumps(v) if not isinstance(v, str) else v)' "$1" <<<"$out"; }

state="$T/state"
mp="$T/cloud folder"
mkdir -p "$T/bin" "$T/remote"
mount_table() { echo '22 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw' > "$T/mountinfo"; }
mount_table
printf 'Name:\tbash\nCapBnd:\t000001ffffffffff\n' > "$T/status-admin"
printf 'Name:\tbash\nCapBnd:\ta80425fb\n' > "$T/status-docker"
echo 'unconfined' > "$T/aa-unconfined"
echo 'docker-default (enforce)' > "$T/aa-docker"
touch "$T/plain-file"
sed 's/"uploadsQueued": 2/"uploadsQueued": 0/' "$fixtures/vfs-stats-queued.json" > "$T/vfs-idle.json"
sed 's/"erroredFiles": 0/"erroredFiles": 3/; s/"uploadsQueued": 2/"uploadsQueued": 0/' "$fixtures/vfs-stats-queued.json" > "$T/vfs-errored.json"

# The fake rclone. mount: FAKE_MOUNT_FAIL=1 logs an error and exits 1; otherwise one fuse.rclone
# line in the mount table, then wait until TERM (which takes the line away). rc vfs/stats:
# FAKE_RC_DOWN=1 fails as an rc that does not answer; else FAKE_VFS_STATS is the reply.
cat > "$T/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
case "$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  lsjson) echo '{}'; exit 0 ;;
  rc)
    [ "${FAKE_RC_DOWN:-}" = 1 ] && { echo '{"error": "connection failed", "status": 503}'; exit 5; }
    cat "$FAKE_VFS_STATS"; exit 0 ;;
  mount)
    target="$3" log=''
    shift 3
    while [ $# -gt 0 ]; do [ "$1" = --log-file ] && { log="$2"; shift; }; shift; done
    if [ "${FAKE_MOUNT_FAIL:-}" = 1 ]; then echo '2026/10/29 10:00:00 CRITICAL: Fatal error: failed to mount FUSE fs: fusermount: exit status 1' >> "$log"; exit 1; fi
    e="${target// /\\040}"
    unmount() { grep -vF " $e rw,nosuid,nodev - fuse.rclone " "$DCF_CLOUD_FOLDER_MOUNTINFO" > "$DCF_CLOUD_FOLDER_MOUNTINFO.tmp"; mv -f "$DCF_CLOUD_FOLDER_MOUNTINFO.tmp" "$DCF_CLOUD_FOLDER_MOUNTINFO"; }
    trap 'unmount; exit 0' TERM
    echo "40 22 0:60 / $e rw,nosuid,nodev - fuse.rclone cloud-folder: rw,user_id=1000" >> "$DCF_CLOUD_FOLDER_MOUNTINFO"
    while :; do sleep 0.1; done ;;
esac
echo "fake rclone: unexpected call: $*" >&2
exit 2
FAKE
# The fake fusermount3 -u <path>: ends the fake mount (its TERM trap takes the line away).
cat > "$T/bin/fusermount3" <<'FAKE'
#!/usr/bin/env bash
printf 'fusermount3 %s\n' "$*" >> "$FAKE_CALLS"
[ "$1" = -u ] || exit 1
p="$(cat "$DCF_CLOUD_FOLDER_STATE_DIR/run/mount.pid" 2>/dev/null)"
[ -n "$p" ] && kill -TERM "$p" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'fuse.rclone' "$DCF_CLOUD_FOLDER_MOUNTINFO" || exit 0; sleep 0.1; done
exit 1
FAKE
chmod +x "$T/bin/rclone" "$T/bin/fusermount3"
export FAKE_CALLS="$T/calls"
: > "$FAKE_CALLS"

conf_remote() { mkdir -p "$state"; (umask 077; printf '[cloud-folder]\ntype = alias\nremote = %s\n' "$T/remote" > "$state/rclone.conf"); }

# run [VAR=value ...] -- <script args>: out = stdout+stderr, rc = exit status. Clean environment;
# FUSE is usable unless a hook says otherwise.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out="$(env -i PATH="$T/bin:$PATH" HOME="$T" FAKE_CALLS="$FAKE_CALLS" FAKE_VFS_STATS="$fixtures/vfs-stats-queued.json" \
    DCF_CLOUD_FOLDER_STATE_DIR="$state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" DCF_CLOUD_FOLDER_HOST_MOUNT="$mp" \
    DCF_CLOUD_FOLDER_FUSE_DEV=/dev/null DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-admin" DCF_CLOUD_FOLDER_APPARMOR="$T/aa-unconfined" \
    DCF_CLOUD_FOLDER_MOUNT_WAIT=3 CLOUD_FOLDER_STOP_WAIT=0 CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_SYNC_INTERVAL=0 \
    "${envs[@]}" bash "$setup_sh" "$@" 2>&1)"
  rc=$?
}

# --- the FUSE check, one cause at a time
run DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" -- fuse-check
check 'fuse-check: no device: exit 1' 1 "$rc"
has 'fuse-check: no device: says the launcher grants it' "no $T/no-fuse in the container (the launcher grants FUSE when the project sets DCF_HOST_FUSE=1)" "$out"
run DCF_CLOUD_FOLDER_FUSE_DEV="$T/plain-file" -- fuse-check
check 'fuse-check: a plain file: exit 1' 1 "$rc"
has 'fuse-check: a plain file: not a character device' 'is not a character device' "$out"
run DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-docker" -- fuse-check
check "fuse-check: Docker's default bounding set: exit 1" 1 "$rc"
has "fuse-check: Docker's default bounding set: no CAP_SYS_ADMIN" 'no CAP_SYS_ADMIN' "$out"
run DCF_CLOUD_FOLDER_APPARMOR="$T/aa-docker" -- fuse-check
check 'fuse-check: docker-default AppArmor: exit 1' 1 "$rc"
has 'fuse-check: docker-default AppArmor: says so' 'the AppArmor profile docker-default denies mount (--security-opt=apparmor=unconfined)' "$out"
run DCF_CLOUD_FOLDER_FUSERMOUNT=no-such-fusermount -- fuse-check
check 'fuse-check: no fusermount3: exit 1' 1 "$rc"
has 'fuse-check: no fusermount3: names the package' 'no fusermount3 on PATH (the fuse3 package' "$out"
run DCF_CLOUD_FOLDER_PROC_STATUS="$T/none" DCF_CLOUD_FOLDER_APPARMOR="$T/none" -- fuse-check
check 'fuse-check: unreadable status and AppArmor files do not block' 0 "$rc"
run -- fuse-check
check 'fuse-check: all granted: exit 0' 0 "$rc"
has 'fuse-check: all granted: says what it found' 'FUSE usable: /dev/null opens, CAP_SYS_ADMIN is in the bounding set, fusermount3 is on PATH' "$out"

# --- auto's order with nothing mounted
run -- status --json
check 'auto, no remote, FUSE usable: mode none' none "$(field mode)"
has 'auto, no remote, FUSE usable: says a sign-in gives mount' 'FUSE is usable, so a sign-in gives mount mode' "$(field why)"
check 'auto, no remote: --json carries fuse' true "$(field fuse)"
conf_remote
run DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" -- status --json
check 'auto, a remote, no FUSE: mode sync' sync "$(field mode)"
has 'auto, a remote, no FUSE: says why' 'FUSE is not usable (no '"$T"'/no-fuse in the container' "$(field why)"
check 'auto, a remote, no FUSE: --json fuse false' false "$(field fuse)"
mkdir -p "$mp"; touch "$mp/.cloud-folder-bisync"
run -- status --json
check 'auto, a remote, FUSE, a sync copy in the folder: sync stays' sync "$(field mode)"
has 'auto, a sync copy: says how to move to mount' 'holds a sync copy, so sync stays' "$(field why)"
rm -rf "$mp"
run -- status --json
check 'auto, a remote, FUSE: mode mount' mount "$(field mode)"
check 'auto, a remote, FUSE, not mounted: verdict not-mounted' not-mounted "$(field verdict)"
check 'not mounted: status exits 1' 1 "$rc"

# --- mode mount without FUSE
run CLOUD_FOLDER_MODE=mount DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-docker" -- status
check 'mode mount, no FUSE: exit 1' 1 "$rc"
has 'mode mount, no FUSE: verdict no-fuse' 'not usable (no-fuse)' "$out"
has 'mode mount, no FUSE: names the launcher variable' 'set DCF_HOST_FUSE=1 in .devcontainer/.env on the host' "$out"
run CLOUD_FOLDER_MODE=mount DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-docker" --
check 'mode mount, no FUSE: the post-start hook never fails' 0 "$rc"
has 'mode mount, no FUSE: the hook says why it did not mount' 'mount: not started, FUSE is not usable: no CAP_SYS_ADMIN' "$out"
check 'mode mount, no FUSE: rclone mount never ran' 0 "$(grep -c '^mount ' "$FAKE_CALLS")"

# --- a folder with files is not mounted over
mkdir -p "$mp"; echo stray > "$mp/stray.txt"
run -- start
check 'start over a folder with files: exit 1' 1 "$rc"
has 'start over a folder with files: says rclone would not' 'is not empty and rclone does not mount over files' "$out"
rm -rf "$mp"

# --- rclone exiting at start
run FAKE_MOUNT_FAIL=1 -- start
check 'rclone exits at start: exit 1' 1 "$rc"
has 'rclone exits at start: its error is shown' 'mount: rclone exited without mounting: CRITICAL: Fatal error: failed to mount FUSE fs' "$out"

# --- the post-start hook mounts
: > "$FAKE_CALLS"
run --
check 'post-start in auto with FUSE: exit 0' 0 "$rc"
has 'post-start: mounted' "mount: cloud-folder: mounted at $mp" "$out"
has 'post-start: the report says mount' 'cloud-folder: mode mount (auto: rclone is mounted at' "$out"
has 'post-start: the report reads the queue' 'VFS cache (writes): uploads in progress 0, queued 2, failed 0' "$out"
calls="$(grep '^mount ' "$FAKE_CALLS")"
has 'the mount: the remote on the folder' "mount cloud-folder: $mp" "$calls"
has 'the mount: VFS cache mode writes (so the queue can be read)' '--vfs-cache-mode writes' "$calls"
has 'the mount: the cache in the volume' "--cache-dir $state/cache" "$calls"
has 'the mount: the remote control on localhost' '--rc --rc-addr 127.0.0.1:5572' "$calls"
hasnt 'the mount: no unauthenticated remote control' '--rc-no-auth' "$calls"
hasnt 'the mount: not --daemon (the PID file must be right)' '--daemon' "$calls"
check 'the mount: the config file is mode 600' 600 "$(stat -c %a "$state/rclone.conf")"
check 'the mount: a PID file' yes "$([ -s "$state/run/mount.pid" ] && echo yes || echo no)"
run -- start
check 'a second start: exit 0' 0 "$rc"
has 'a second start: already mounted' 'mount: already mounted at' "$out"
check 'a second start: one mount' 1 "$(grep -c 'fuse.rclone' "$T/mountinfo")"

# --- status from the recorded vfs/stats replies
run -- status --json
check 'status: verdict empty (ok)' empty "$(field verdict)"
check 'status: ok' true "$(field ok)"
check 'status: exit 0' 0 "$rc"
check 'status: rclone mounted' true "$(field rclone_mounted)"
check 'status: cache mode writes (CacheMode 2)' writes "$(field cache_mode)"
check 'status: uploads queued' 2 "$(field uploads_queued)"
check 'status: uploads pending' 2 "$(field uploads_pending)"
check 'status: rc answers' true "$(field rc_answers)"
run FAKE_VFS_STATS="$fixtures/vfs-stats-off.json" -- status --json
check 'cache mode off: no queue (null)' null "$(field uploads_pending)"
check 'cache mode off: named' off "$(field cache_mode)"
run FAKE_VFS_STATS="$fixtures/vfs-stats-off.json" -- status
has 'cache mode off: pending unknown' 'no upload queue to read (cache mode off?): pending uploads unknown' "$out"
run FAKE_RC_DOWN=1 -- status --json
check 'rc not answering: rc_answers false' false "$(field rc_answers)"
check 'rc not answering: still usable' true "$(field ok)"
run FAKE_RC_DOWN=1 -- status
has 'rc not answering: said' 'remote control on 127.0.0.1:5572 does not answer: pending uploads unknown' "$out"
run FAKE_VFS_STATS="$T/vfs-errored.json" -- status
check 'failed uploads: exit 1' 1 "$rc"
has 'failed uploads: verdict upload-errors' 'not usable (upload-errors): 3 file(s) failed to upload' "$out"
echo doc > "$mp/doc.txt"
run FAKE_VFS_STATS="$T/vfs-idle.json" -- status
check 'mounted with content, nothing pending: exit 0' 0 "$rc"
has 'mounted with content: ok' 'ok: the remote is mounted and writable (0 upload(s) pending)' "$out"
run -- sync
check 'sync in mount mode: exit 3 (nothing to sync)' 3 "$rc"

# --- the shutdown check and unmount
run -- shutdown-check 0
check 'shutdown check, uploads pending: exit 1' 1 "$rc"
has 'shutdown check, uploads pending: refuses' 'REFUSE: 2 upload(s) still pending after 0s' "$out"
run FAKE_RC_DOWN=1 -- shutdown-check 0
check 'shutdown check, queue unreadable: exit 1' 1 "$rc"
has 'shutdown check, queue unreadable: refuses' 'REFUSE: the upload queue cannot be read' "$out"
run FAKE_VFS_STATS="$T/vfs-idle.json" -- shutdown-check 0
check 'shutdown check, nothing pending: exit 0' 0 "$rc"
has 'shutdown check, nothing pending: safe' 'mode mount, no upload pending: safe to stop' "$out"
run -- unmount
check 'unmount, uploads pending: exit 1' 1 "$rc"
has 'unmount, uploads pending: refuses' 'mount: not unmounted, 2 upload(s) still pending after 0s' "$out"
check 'unmount refused: still mounted' 1 "$(grep -c 'fuse.rclone' "$T/mountinfo")"
run FAKE_VFS_STATS="$T/vfs-idle.json" -- stop
check 'stop in mount mode, nothing pending: exit 0' 0 "$rc"
has 'stop in mount mode: unmounted' "mount: unmounted $mp" "$out"
check 'stop: fusermount3 -u ran' 1 "$(grep -c "^fusermount3 -u $mp\$" "$FAKE_CALLS")"
check 'stop: the mount is gone' 0 "$(grep -c 'fuse.rclone' "$T/mountinfo")"
check 'stop: the PID file is gone' no "$([ -e "$state/run/mount.pid" ] && echo yes || echo no)"
run -- shutdown-check 0
check 'shutdown check, nothing mounted: exit 0' 0 "$rc"
rm -f "$mp/doc.txt"
run -- start
has 'start again' 'mounted at' "$out"
run -- unmount --force
check 'unmount --force with uploads pending: exit 0' 0 "$rc"
check 'unmount --force: the mount is gone' 0 "$(grep -c 'fuse.rclone' "$T/mountinfo")"
run -- unmount --bogus
check 'unmount: an unknown argument: exit 2' 2 "$rc"
run -- unmount
has 'unmount when not mounted: says so' 'mount: not mounted' "$out"

# --- the Feature Taskfile hands -- --force to unmount
if command -v task >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec bash %q "$@"\n' "$setup_sh" > "$T/bin/cloud-folder-setup"
  chmod +x "$T/bin/cloud-folder-setup"
  out="$(cd "$T" && env -i PATH="$T/bin:$PATH" HOME="$T" FAKE_CALLS="$FAKE_CALLS" DCF_CLOUD_FOLDER_STATE_DIR="$state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" \
    DCF_CLOUD_FOLDER_FUSE_DEV=/dev/null DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-admin" DCF_CLOUD_FOLDER_APPARMOR="$T/aa-unconfined" \
    task -s -t "$taskfile" unmount CLOUD_FOLDER_MOUNT_POINT="$mp" -- --bogus 2>&1)"
  has 'task unmount: CLI_ARGS reach the script' "unmount: unknown argument '--bogus'" "$out"
else
  echo "skip - the Taskfile check: task is not on PATH"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
