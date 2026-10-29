#!/bin/bash
# Scenario 'auto_no_fuse' (see scenarios.json): the default mode auto in a container the launcher
# gave no FUSE (no runArgs): fuse3 is installed, the FUSE check says what is missing, and once a
# remote is configured auto falls to sync rather than failing (proposal section 7, slice 3).
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "fuse3 installed in mode auto" bash -c "command -v fusermount3"
check "fuse-check fails and says why" bash -c "! cloud-folder-setup fuse-check && cloud-folder-setup fuse-check | grep -E 'FUSE not usable: (no /dev/fuse|.*CAP_SYS_ADMIN|.*AppArmor)'"
mkdir -p /tmp/cf-remote
(umask 077; printf '[cloud-folder]\ntype = alias\nremote = /tmp/cf-remote\n' > "$RCLONE_CONFIG")
check "with a remote, auto takes sync and says FUSE is not usable" bash -c "cloud-folder-setup status --json | grep -F '\"mode\":\"sync\"' | grep -F 'FUSE is not usable'"
check "version names the FUSE state" bash -c "cloud-folder-setup version | grep -F 'FUSE: not usable'"

reportResults
