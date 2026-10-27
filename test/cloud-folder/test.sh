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
check "the Feature version is baked" grep -qx 'FEATURE_VERSION=1.0.0' /usr/local/share/cloud-folder-feature/options.env
check "the host mount path is baked" grep -qx 'HOST_MOUNT=/mnt/cloud-folder-host' /usr/local/share/cloud-folder-feature/options.env
check "the mount point is a link to the host mount" bash -c "[ \"\$(readlink /mnt/cloud-folder)\" = /mnt/cloud-folder-host ]"
check "the host mount is not created by the image" bash -c "! test -e /mnt/cloud-folder-host"
check "version names the mount point" bash -c "cloud-folder-setup version | grep -F 'mount point /mnt/cloud-folder'"
check "the post-start report exits 0 and reports" bash -c "cloud-folder-setup | grep -E '^cloud-folder: '"
check "status fails with no source" bash -c "! cloud-folder-setup status"
check "status says no source" bash -c "cloud-folder-setup status | grep -F 'not usable (no-source)'"
check "status shows the link" bash -c "cloud-folder-setup status | grep -F 'mount point /mnt/cloud-folder -> /mnt/cloud-folder-host: missing'"
check "status --json is JSON with verdict no-source" bash -c "cloud-folder-setup status --json | grep -F '\"verdict\":\"no-source\"'"
check "CLOUD_FOLDER_MODE=sync is refused by this version" bash -c "CLOUD_FOLDER_MODE=sync cloud-folder-setup status | grep -F 'not in this version'"
check "rclone is not installed by this version" bash -c "! command -v rclone"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/cloud-folder.yml

reportResults
