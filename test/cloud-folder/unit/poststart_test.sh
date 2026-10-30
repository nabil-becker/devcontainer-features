#!/usr/bin/env bash
# Docker-free tests of the cloud-folder post-start hook (cloud-folder-setup with no argument): it
# exits 0 whatever happens (rclone failing, a mount that never appears, no sign-in, a closed
# stdout pipe), returns within DCF_CLOUD_FOLDER_START_BUDGET, and the explicit commands (start,
# sync, status) keep their real exit codes. A fake rclone plays the failures.
# Part of `task lint` (`task test:cloud-folder-unit`). SETUP_SH points the tests at another copy.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/cloud-folder/cloud-folder-setup.sh}"

T="$(mktemp -d)"
cleanup() {
  local p
  for p in "$T"/state/run/*.pid; do [ -f "$p" ] && kill -TERM "$(cat "$p")" 2>/dev/null; done
  pkill -f "$T/bin/rclone" 2>/dev/null
  chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (missing '$2' in: $3)"; fi; }

mkdir -p "$T/bin" "$T/state"
mp="$T/mnt/cf"; state="$T/state"
: > "$T/mountinfo"
printf 'Name:\tbash\nCapBnd:\t000001ffffffffff\n' > "$T/status-admin"
echo unconfined > "$T/aa"

# The fake rclone: FAKE_LS=fail makes lsjson fail, FAKE_LS=slow makes it sleep; FAKE_MOUNT=hang
# stays alive without ever mounting, FAKE_MOUNT=fail exits 1; every call also sleeps FAKE_STALL s.
cat > "$T/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_STALL:-}" ] && sleep "$FAKE_STALL"
case "$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  lsjson)
    [ "${FAKE_LS:-}" = fail ] && { echo 'Failed: connection attempt failed' >&2; exit 1; }
    [ "${FAKE_LS:-}" = slow ] && sleep 100
    echo '{}'; exit 0 ;;
  mount)
    [ "${FAKE_MOUNT:-}" = fail ] && exit 1
    while :; do sleep 0.1; done ;;
  bisync) [ "${FAKE_SYNC:-}" = fail ] && exit 7; exit 0 ;;
esac
exit 2
FAKE
printf "#!/bin/sh\nexit 0\n" > "$T/bin/fusermount3"
chmod +x "$T/bin/rclone" "$T/bin/fusermount3"

conf_remote() { mkdir -p "$state"; (umask 077; printf '[cloud-folder]\ntype = alias\nremote = %s\n' "$T/remote" > "$state/rclone.conf"); }
drop_conf() { rm -f "$state/rclone.conf"; }

# run [VAR=value ...] -- <args>: out = stdout+stderr, rc = the exit status, secs = how long it took.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  local t0=$SECONDS
  out="$(env -i PATH="$T/bin:$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" \
    DCF_CLOUD_FOLDER_HOST_MOUNT="$mp" DCF_CLOUD_FOLDER_FUSE_DEV=/dev/null DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-admin" \
    DCF_CLOUD_FOLDER_APPARMOR="$T/aa" CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_SYNC_INTERVAL=0 \
    "${envs[@]}" bash "$setup_sh" "$@" 2>&1)"
  rc=$?
  secs=$((SECONDS - t0))
}

# --- not signed in
drop_conf
run -- 
check 'not signed in: post-start exits 0' 0 "$rc"
run CLOUD_FOLDER_MODE=sync --
check 'sync mode, not signed in: post-start exits 0' 0 "$rc"
run CLOUD_FOLDER_MODE=sync -- status
check 'sync mode, not signed in: status keeps exit 1' 1 "$rc"

# --- rclone failing: mode mount
conf_remote
run CLOUD_FOLDER_MODE=mount FAKE_MOUNT=fail DCF_CLOUD_FOLDER_MOUNT_WAIT=3 --
check 'mount: rclone exits at once: post-start exits 0' 0 "$rc"
run CLOUD_FOLDER_MODE=mount FAKE_MOUNT=fail DCF_CLOUD_FOLDER_MOUNT_WAIT=3 -- start
check 'mount: rclone exits at once: explicit start keeps exit 1' 1 "$rc"
run CLOUD_FOLDER_MODE=mount FAKE_LS=fail FAKE_MOUNT=fail DCF_CLOUD_FOLDER_MOUNT_WAIT=3 --
check 'mount: the remote unreachable: post-start exits 0' 0 "$rc"

# --- a mount that never becomes ready: bounded by the mount wait, and by the budget
run CLOUD_FOLDER_MODE=mount FAKE_MOUNT=hang DCF_CLOUD_FOLDER_MOUNT_WAIT=2 --
check 'mount never ready: post-start exits 0' 0 "$rc"
has 'mount never ready: says so' 'has not mounted' "$out"
pkill -f "$T/bin/rclone" 2>/dev/null; rm -f "$state/run/mount.pid"; sleep 0.3
run CLOUD_FOLDER_MODE=mount FAKE_MOUNT=hang DCF_CLOUD_FOLDER_MOUNT_WAIT=60 DCF_CLOUD_FOLDER_START_BUDGET=3 --
check 'budget 3 s, mount wait 60 s: post-start exits 0' 0 "$rc"
check 'budget 3 s: returned within about 3 s' yes "$([ "$secs" -le 8 ] && echo yes || echo "no ($secs s)")"
has 'budget: says it was not finished and how to look' 'not finished within 3s' "$out"
pkill -f "$T/bin/rclone" 2>/dev/null; rm -f "$state/run/mount.pid"; sleep 0.3

# --- the reachability check hanging (a network that times out)
run CLOUD_FOLDER_MODE=sync FAKE_LS=slow DCF_CLOUD_FOLDER_START_BUDGET=3 --
check 'remote hangs: post-start exits 0' 0 "$rc"
check 'remote hangs: returned within about 3 s' yes "$([ "$secs" -le 8 ] && echo yes || echo "no ($secs s)")"

# --- sync mode, a failing sync: the explicit task keeps its exit code
mkdir -p "$mp"
run CLOUD_FOLDER_MODE=sync FAKE_SYNC=fail -- sync
check 'sync fails: explicit sync exits non-zero' yes "$([ "$rc" -ne 0 ] && echo yes || echo "no ($rc)")"
run CLOUD_FOLDER_MODE=sync FAKE_SYNC=fail --
check 'sync fails: post-start exits 0' 0 "$rc"

# --- a closed stdout pipe: no SIGPIPE exit (141)
for mode in sync mount; do
  rm -rf "$mp"; pkill -f "$T/bin/rclone" 2>/dev/null; rm -f "$state/run/mount.pid"; : > "$T/mountinfo"
  env -i PATH="$T/bin:$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" \
    DCF_CLOUD_FOLDER_HOST_MOUNT="$mp" DCF_CLOUD_FOLDER_FUSE_DEV=/dev/null DCF_CLOUD_FOLDER_PROC_STATUS="$T/status-admin" \
    DCF_CLOUD_FOLDER_APPARMOR="$T/aa" CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_SYNC_INTERVAL=0 CLOUD_FOLDER_MODE=$mode \
    FAKE_STALL=1 DCF_CLOUD_FOLDER_MOUNT_WAIT=2 bash "$setup_sh" 2>&1 | head -c 1 >/dev/null
  check "closed stdout pipe, mode $mode: post-start exits 0" 0 "${PIPESTATUS[0]}"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
