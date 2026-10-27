#!/bin/bash
# Scenario 'sync_local' (see scenarios.json): mode sync with the real rclone, as vscode, mountPoint
# /mnt/shared-docs (a plain folder, no link), remotePath sub, syncInterval 0. No SharePoint: the
# remote cloud-folder is an rclone alias of a local folder, written into the Feature volume's config
# with a token line that must never show up anywhere else. Covers the first sync (a resync), a
# file each way, the status, the shutdown check refusing pending changes, the timer started once
# and stopped, and the token never in a process's arguments, a log or the setup output.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

state=/var/lib/devcontainer-features/cloud-folder
marker='TOKENMARKER-not-a-real-token'
out=/tmp/cf-output
: > "$out"

check "mountPoint is a folder, not a link" bash -c "test -d /mnt/shared-docs && ! test -L /mnt/shared-docs"
check "the post-start hook runs (again) and hands the folders to the user" bash -c "cloud-folder-setup >> $out 2>&1 && [ \"\$(stat -c %U $state)\" = vscode ]"

mkdir -p /tmp/cf-remote/sub
echo from-remote > /tmp/cf-remote/sub/remote.txt
(umask 077; printf '[cloud-folder]\ntype = alias\nremote = /tmp/cf-remote\ntoken = {"access_token":"%s"}\n' "$marker" > "$RCLONE_CONFIG")

check "configured, never synced: status fails" bash -c "! cloud-folder-setup status >> $out 2>&1"
check "and says never-synced" bash -c "cloud-folder-setup status | tee -a $out | grep -F 'not usable (never-synced)'"
check "the first sync is a resync and succeeds" bash -c "cloud-folder-setup sync 2>&1 | tee -a $out | grep -F '(--resync: first sync of /mnt/shared-docs)'"
check "the remote file arrived" grep -qx from-remote /mnt/shared-docs/remote.txt
check "status passes" bash -c "cloud-folder-setup status >> $out 2>&1"
check "status --json says ok and reachable" bash -c "cloud-folder-setup status --json | tee -a $out | grep -F '\"remote_reachable\":true' | grep -F '\"verdict\":\"ok\"'"
sleep 1.1
echo from-local > /mnt/shared-docs/local.txt
check "the shutdown check refuses a pending change" bash -c "! cloud-folder-setup shutdown-check 0 >> $out 2>&1"
check "a second sync (no resync) sends it up" bash -c "cloud-folder-setup sync 2>&1 | tee -a $out | grep -E '^cloud-folder: sync ok in [0-9]+s\$'"
check "the local file is on the remote" grep -qx from-local /tmp/cf-remote/sub/local.txt
check "the marker is not on the remote" bash -c "! test -e /tmp/cf-remote/sub/.cloud-folder-bisync"
check "the shutdown check passes" bash -c "cloud-folder-setup shutdown-check 0 >> $out 2>&1"
check "the config is mode 600" bash -c "[ \"\$(stat -c %a \$RCLONE_CONFIG)\" = 600 ]"
check "bisync's listings live in the volume" bash -c "ls $state/bisync | grep -q '\\.lst\$'"

check "the timer starts" bash -c "CLOUD_FOLDER_SYNC_INTERVAL=2s cloud-folder-setup start | tee -a $out | grep -F 'timer: started'"
check "a second start leaves it" bash -c "CLOUD_FOLDER_SYNC_INTERVAL=2s cloud-folder-setup start | tee -a $out | grep -F 'timer: already running'"
check "one loop" bash -c "[ \"\$(pgrep -fc 'cloud-folder-setup run')\" = 1 ]"
# Sample every process's arguments while the timer syncs.
for _ in $(seq 1 30); do ps -eo args >> /tmp/cf-ps; sleep 0.2; done
check "the timer synced" bash -c "grep -F 'sync ok' $state/timer.log"
check "the timer stops" bash -c "cloud-folder-setup stop | tee -a $out | grep -F 'timer: stopped'"
check "no loop left" bash -c "! pgrep -f 'cloud-folder-setup run'"

check "the token is in no process's arguments" bash -c "! grep -F '$marker' /tmp/cf-ps"
check "the token is in no output" bash -c "! grep -F '$marker' $out"
check "the token is in no file of the volume but the config" bash -c "[ -z \"\$(grep -rlF '$marker' $state | grep -v '/rclone.conf\$')\" ]"
check "task cloud-folder:sync works" task -t /usr/local/share/go-task/includes.d/cloud-folder.yml sync

reportResults
