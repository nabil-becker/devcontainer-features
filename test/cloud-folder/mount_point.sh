#!/bin/bash
# Scenario 'mount_point' (see scenarios.json): mode host and mountPoint /mnt/shared, as vscode.
# /mnt/shared links to the host mount. Nothing is mounted, so status fails as not-mounted; then a
# mount table faked through the test hook DCF_CLOUD_FOLDER_MOUNTINFO lists a root-owned folder at
# the host mount: present through the link, but not writable.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "options baked" bash -c "grep -qx 'MODE=host' /usr/local/share/cloud-folder-feature/options.env && grep -qx 'MOUNTPOINT=/mnt/shared' /usr/local/share/cloud-folder-feature/options.env"
check "mode host with nothing mounted fails" bash -c "! cloud-folder-setup status"
check "mountPoint links to the host mount" bash -c "[ \"\$(readlink /mnt/shared)\" = /mnt/cloud-folder-host ]"
check "and says not-mounted at the option's path" bash -c "cloud-folder-setup status | grep -F 'mount point /mnt/shared -> /mnt/cloud-folder-host: missing' && cloud-folder-setup status | grep -F 'not usable (not-mounted)'"

sudo mkdir -p /mnt/cloud-folder-host
sudo chmod 0755 /mnt/cloud-folder-host
fake="$(mktemp)"
echo '30 22 0:50 /shared /mnt/cloud-folder-host rw,relatime - fakefs host rw' > "$fake"
check "a mounted folder vscode cannot write fails" bash -c "! DCF_CLOUD_FOLDER_MOUNTINFO=$fake cloud-folder-setup status"
check "and says unwritable" bash -c "DCF_CLOUD_FOLDER_MOUNTINFO=$fake cloud-folder-setup status | grep -F 'not usable (unwritable)'"
check "the post-start report still exits 0" bash -c "DCF_CLOUD_FOLDER_MOUNTINFO=$fake cloud-folder-setup >/dev/null"
check "CLOUD_FOLDER_MOUNT_POINT overrides the option" bash -c "CLOUD_FOLDER_MOUNT_POINT=/elsewhere cloud-folder-setup status | grep -F 'mount point /elsewhere: missing'"
check "task status fails too (a start-up check can stop)" bash -c "! task -t /usr/local/share/go-task/includes.d/cloud-folder.yml status"

reportResults
