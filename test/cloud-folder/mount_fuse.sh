#!/bin/bash
# Scenario 'mount_fuse' (see scenarios.json): mode mount, mountPoint /mnt/shared-live (a plain
# folder), as vscode, with the three run arguments the launcher grants on DCF_HOST_FUSE=1 written
# into the scenario as runArgs. The remote is an rclone alias of a local folder. Where the engine
# has FUSE (it needs /dev/fuse on the host running the test), it covers the real rclone mount: the
# post-start hook mounting, a file each way, the status reading vfs/stats, the shutdown check and
# unmount. Where it has none, the FUSE check must say why, the mount checks are skipped with one
# line naming the cause, and the status must fail as no-fuse (proposal section 11, item 7: whether
# CI can run a mount; the line in the log answers it).
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

state=/var/lib/devcontainer-features/cloud-folder
check "fuse3 installed (fusermount3 on PATH)" bash -c "command -v fusermount3"
check "rclone installed" bash -c "command -v rclone"
check "mountPoint is a folder, not a link" bash -c "test -d /mnt/shared-live && ! test -L /mnt/shared-live"
check "the run arguments reached the container: /dev/fuse is there" test -c /dev/fuse

mkdir -p /tmp/cf-remote
echo from-remote > /tmp/cf-remote/remote.txt
(umask 077; printf '[cloud-folder]\ntype = alias\nremote = /tmp/cf-remote\n' > "$RCLONE_CONFIG")

if ! why="$(cloud-folder-setup fuse-check)"; then
  echo "SKIP the rclone mount checks: $why"
  check "no FUSE: the status fails as no-fuse" bash -c "cloud-folder-setup status | grep -F 'not usable (no-fuse)'"
  reportResults
  exit 0
fi

check "the post-start hook mounts the remote" bash -c "cloud-folder-setup | grep -F 'mount: cloud-folder: mounted at /mnt/shared-live'"
check "it is an rclone mount" bash -c "awk '\$5 == \"/mnt/shared-live\"' /proc/self/mountinfo | grep -F fuse.rclone"
check "the remote file is there" grep -qx from-remote /mnt/shared-live/remote.txt
check "status passes and reads the queue" bash -c "cloud-folder-setup status | grep -F 'VFS cache (writes): uploads in progress'"
check "status --json: cache mode writes" bash -c "cloud-folder-setup status --json | grep -F '\"cache_mode\":\"writes\"'"
check "the remote control is bound to localhost" bash -c "tr '\\0' ' ' < /proc/\$(cat $state/run/mount.pid)/cmdline | grep -F -- '--rc-addr 127.0.0.1:5572'"
check "a write-only method is refused without credentials" bash -c "! rclone rc core/quit --url http://127.0.0.1:5572/ >/dev/null 2>&1"
echo from-local > /mnt/shared-live/local.txt
check "the shutdown check waits for the upload, then passes" bash -c "cloud-folder-setup shutdown-check 30"
check "the local file reached the remote" grep -qx from-local /tmp/cf-remote/local.txt
check "unmount" bash -c "cloud-folder-setup unmount | grep -F 'mount: unmounted /mnt/shared-live'"
check "no rclone mount left" bash -c "! awk '\$5 == \"/mnt/shared-live\"' /proc/self/mountinfo | grep -q fuse.rclone"
check "start mounts again" bash -c "cloud-folder-setup start | grep -F 'mounted at /mnt/shared-live'"
check "stop unmounts" bash -c "cloud-folder-setup stop | grep -F 'mount: unmounted'"

reportResults
