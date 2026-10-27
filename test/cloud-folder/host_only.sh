#!/bin/bash
# Scenario 'host_only' (see scenarios.json): mode host installs no rclone (host mode does not use it)
# and makes the link as before.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no rclone in mode host" bash -c "! command -v rclone"
check "the mount point links to the host mount" bash -c "[ \"\$(readlink /mnt/cloud-folder)\" = /mnt/cloud-folder-host ]"
check "status fails as not-mounted" bash -c "cloud-folder-setup status | grep -F 'not usable (not-mounted)'"
check "the shutdown check has nothing to wait for" bash -c "cloud-folder-setup shutdown-check 0 | grep -F 'no sync in flight'"

reportResults
