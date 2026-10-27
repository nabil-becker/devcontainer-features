#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): rcloneVersion=1.75.1, a version not pinned in the
# Feature's rclone-checksums.txt, so the install verified it against the release's SHA256SUMS.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "rclone 1.75.1 installed" bash -c "rclone version | head -n 1 | grep -Fx 'rclone v1.75.1'"
check "the option is baked" grep -qx 'RCLONEVERSION=1.75.1' /usr/local/share/cloud-folder-feature/options.env
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && rclone version >/dev/null'
check "version names it" bash -c "cloud-folder-setup version | grep -F 'rclone: rclone v1.75.1'"

reportResults
