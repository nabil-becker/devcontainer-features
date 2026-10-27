#!/bin/bash
# Auto-generated scenario: the cloud-folder Feature with default options (mode auto, mountPoint
# /mnt/cloud-folder) and nothing mounted: the status must say there is no source and fail. Run with:
#   devcontainer features test -f cloud-folder --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "cloud-folder-setup on PATH" command -v cloud-folder-setup
check "cloud-folder-setup is root-owned" bash -c "[ \"\$(stat -c %U \"\$(command -v cloud-folder-setup)\")\" = root ]"
check "options baked for cloud-folder-setup" bash -c "grep -qx 'MODE=auto' /usr/local/share/cloud-folder-feature/options.env && grep -qx 'MOUNTPOINT=/mnt/cloud-folder' /usr/local/share/cloud-folder-feature/options.env"
check "the Feature version is baked" grep -qx 'FEATURE_VERSION=1.1.0' /usr/local/share/cloud-folder-feature/options.env
check "the host mount path is baked" grep -qx 'HOST_MOUNT=/mnt/cloud-folder-host' /usr/local/share/cloud-folder-feature/options.env
check "the mount point is a link to the host mount" bash -c "[ \"\$(readlink /mnt/cloud-folder)\" = /mnt/cloud-folder-host ]"
check "the host mount is not created by the image" bash -c "! test -e /mnt/cloud-folder-host"
check "version names the mount point" bash -c "cloud-folder-setup version | grep -F 'mount point /mnt/cloud-folder'"
check "the post-start report exits 0 and reports" bash -c "cloud-folder-setup | grep -E '^cloud-folder: '"
check "status fails with no source" bash -c "! cloud-folder-setup status"
check "status says no source" bash -c "cloud-folder-setup status | grep -F 'not usable (no-source)'"
check "status shows the link" bash -c "cloud-folder-setup status | grep -F 'mount point /mnt/cloud-folder -> /mnt/cloud-folder-host: missing'"
check "status --json is JSON with verdict no-source" bash -c "cloud-folder-setup status --json | grep -F '\"verdict\":\"no-source\"'"
check "CLOUD_FOLDER_MODE=mount is refused by this version" bash -c "CLOUD_FOLDER_MODE=mount cloud-folder-setup status | grep -F 'not in this version'"
check "CLOUD_FOLDER_MODE=sync with no remote says to sign in" bash -c "CLOUD_FOLDER_MODE=sync cloud-folder-setup status | grep -F 'not usable (not-configured)'"
check "rclone installed at the pinned default" bash -c "rclone version | head -n 1 | grep -Fx 'rclone v1.75.2'"
check "rclone is root-owned in /usr/local/bin" bash -c "[ \"\$(stat -c %U /usr/local/bin/rclone)\" = root ]"
check "RCLONE_CONFIG points into the Feature volume" bash -c "[ \"\$RCLONE_CONFIG\" = /var/lib/devcontainer-features/cloud-folder/rclone.conf ]"
check "the state folder is a volume" bash -c "awk '\$5 == \"/var/lib/devcontainer-features/cloud-folder\"' /proc/self/mountinfo | grep -q ."
check "no timer without a remote" bash -c "! test -e /var/lib/devcontainer-features/cloud-folder/run/loop.pid"
check "the shutdown check passes with no sync mode" cloud-folder-setup shutdown-check 0

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/cloud-folder.yml

reportResults
