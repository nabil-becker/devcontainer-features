#!/bin/bash
# Scenario 'no_credential_helper' (see scenarios.json): gitCredentialHelper=false,
# remoteUser=vscode. gh-setup leaves the git config alone.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "option baked" grep -q '^GITCREDENTIALHELPER=false$' /usr/local/share/gh-feature/options.env
check "gh-setup reports the helper as not configured" bash -c "gh-setup | grep -qF 'git credential helper not configured'"
check "no github.com credential helper in the global git config" bash -c "! git config --global --get-all credential.https://github.com.helper"
check "env override turns it on without a rebuild" bash -c "GH_SETUP_GIT_CREDENTIAL_HELPER=true gh-setup | grep -qF 'gh auth git-credential (set)' && git config --global --get-all credential.https://github.com.helper | grep -qF 'gh auth git-credential'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && gh --version'

reportResults
