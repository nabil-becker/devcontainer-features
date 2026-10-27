#!/bin/bash
# Scenario 'mounted' (see scenarios.json): a real mount (a named volume, as root) at the host mount
# /mnt/cloud-folder-host stands in for the launcher's bind mount of the host folder; the default
# mountPoint /mnt/cloud-folder links to it. auto must choose host; the folder is reported empty and
# then not empty, through the link; status passes.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the host mount is a mount" bash -c "awk '\$5 == \"/mnt/cloud-folder-host\"' /proc/self/mountinfo | grep -q ."
check "the mount point links to it" bash -c "[ \"\$(readlink /mnt/cloud-folder)\" = /mnt/cloud-folder-host ]"
check "auto chooses host" bash -c "cloud-folder-setup status | grep -F 'mode host (auto: something is mounted at /mnt/cloud-folder)'"
check "an empty mounted folder passes with a warning" bash -c "cloud-folder-setup status | grep -F 'ok, but empty'"
check "status passes when mounted and writable" cloud-folder-setup status
check "status wrote nothing" bash -c "[ -z \"\$(ls -A /mnt/cloud-folder)\" ]"
echo note > /mnt/cloud-folder/minutes.txt
check "a file written through the link is in the host mount" grep -qx note /mnt/cloud-folder-host/minutes.txt
check "a mounted folder with a file is ok" bash -c "cloud-folder-setup status | grep -F 'ok: the folder is mounted and writable'"
check "status --json says ok" bash -c "cloud-folder-setup status --json | grep -F '\"ok\":true'"
check "task cloud-folder:status passes" task -t /usr/local/share/go-task/includes.d/cloud-folder.yml status
rm -f /mnt/cloud-folder/minutes.txt

reportResults
