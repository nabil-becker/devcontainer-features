#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false. The Feature's Taskfile is
# not registered; the tools and audio-check still are installed.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile absent" bash -c "! test -e /usr/local/share/go-task/includes.d/audio.yml"
check "audio-check still installed" command -v audio-check
check "rec still installed" command -v rec

reportResults
