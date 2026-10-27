#!/bin/bash
# Scenario 'fixed_path' (see scenarios.json): mountPoint is the host mount itself
# (/mnt/cloud-folder-host), so the install makes no link and creates nothing.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no link at the host mount" bash -c "! test -L /mnt/cloud-folder-host"
check "nothing created at the host mount" bash -c "! test -e /mnt/cloud-folder-host"
check "no link at the default path either" bash -c "! test -e /mnt/cloud-folder && ! test -L /mnt/cloud-folder"
check "status names the host mount, no arrow" bash -c "cloud-folder-setup status | grep -F 'mount point /mnt/cloud-folder-host: missing'"

reportResults
