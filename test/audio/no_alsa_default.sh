#!/bin/bash
# Scenario 'no_alsa_default' (see scenarios.json): alsaDefault=false. ALSA is left alone (no
# /etc/asound.conf written); the tools are still installed.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no asound.conf written" bash -c "! grep -qs 'audio Feature' /etc/asound.conf"
check "rec still installed" command -v rec
check "arecord still installed" command -v arecord

reportResults
