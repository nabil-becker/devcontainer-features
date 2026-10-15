#!/bin/bash
# Auto-generated scenario: the gh Feature with default options (install=auto,
# version=latest, gitCredentialHelper=true) on an image without a prior gh,
# so the release binary is installed. Run with:
#   devcontainer features test -f gh --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "gh is on PATH" command -v gh
check "gh reports a version" bash -c "gh --version | grep -E '^gh version [0-9]+\.[0-9]+\.[0-9]+'"
check "release binary installed" bash -c "[ \"\$(command -v gh)\" = /usr/local/bin/gh ]"
check "binary is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/gh)\" = root ]"
check "GH_CONFIG_DIR set" bash -c "[ \"\$GH_CONFIG_DIR\" = /var/lib/devcontainer-features/gh ]"

check "dcf-persist on PATH" command -v dcf-persist
check "gh-setup on PATH" command -v gh-setup
check "options baked for gh-setup" grep -q '^GITCREDENTIALHELPER=true$' /usr/local/share/gh-feature/options.env
check "gh-setup reports the state dir" bash -c "gh-setup | grep -E '^gh: /var/lib/devcontainer-features/gh \((volume|bind|image), writable\)$'"
check "gh-setup reports the login state" bash -c "gh-setup | grep -E '^gh: (logged in|no login yet)'"
# Plain debian/ubuntu base images have no git; the helper is then skipped.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "gh-setup configures the git credential helper (or skips it without git)" bash -c '
  if command -v git >/dev/null 2>&1; then
    gh-setup | grep -qE "credential helper for https://github.com: gh auth git-credential \((set|kept)\)"
    [ "$(git config --global --get-all credential.https://github.com.helper)" = "$(printf "\n!gh auth git-credential")" ]
    gh-setup | grep -qF "gh auth git-credential (kept)"   # idempotent
  else
    gh-setup | grep -qF "git not found, credential helper skipped"
  fi'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/gh.yml

reportResults
