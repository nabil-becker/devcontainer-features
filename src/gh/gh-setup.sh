#!/usr/bin/env bash
# gh-setup: the gh Feature's postCreateCommand, run as the remote user from
# the workspace folder after every create/rebuild; also behind
# `task gh:setup`. Idempotent, never fatal: a problem is reported, not
# allowed to abort the rest of post-create.
#
# 1. dcf-persist makes GH_CONFIG_DIR (the Feature's named volume, or a bind
#    mount a repo put on the same target) exist and belong to the remote
#    user, so `gh auth login` can store its token there and keep it across
#    rebuilds.
# 2. With gitCredentialHelper (default true), git takes credentials for
#    https://github.com from gh: the helper list is reset to '' (drop
#    whatever the image configured) then `!gh auth git-credential`, exactly
#    what a repo otherwise scripts in its own post-create.
# 3. Reports the gh version, whether a login is present (exit code of
#    `gh auth status` only; its output could name the account) and the next
#    step when it is not.
set -u

# Defaults baked by install.sh from the Feature options. GH_SETUP_* in the
# environment (containerEnv) override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/gh-feature/options.env ] && source /usr/local/share/gh-feature/options.env
credential_helper="${GH_SETUP_GIT_CREDENTIAL_HELPER-${GITCREDENTIALHELPER:-true}}"
dir="${GH_CONFIG_DIR:-$HOME/.config/gh}"

dcf-persist --label gh "$dir"

key="credential.https://github.com.helper"
# '' then the gh helper; `--get-all` prints the empty value as an empty line.
want=$'\n!gh auth git-credential'
if [ "$credential_helper" != "true" ]; then
  echo "gh: git credential helper not configured (gitCredentialHelper=false)"
elif ! command -v git >/dev/null 2>&1; then
  echo "gh: git not found, credential helper skipped"
else
  # git creates the global config file on first write but not its folder
  # (the git Feature's volume, or wherever the repo points the variable).
  # The folder may be another Feature's volume (git's) that its own hook has
  # not handed to this user yet, so make it usable here as well.
  if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
    dcf-persist "$(dirname "$GIT_CONFIG_GLOBAL")" >/dev/null 2>&1 || true
  fi
  if [ "$(git config --global --get-all "$key" 2>/dev/null || true)" = "$want" ]; then
    echo "gh: git credential helper for https://github.com: gh auth git-credential (kept)"
  elif git config --global --replace-all "$key" '' 2>/dev/null && git config --global --add "$key" '!gh auth git-credential' 2>/dev/null; then
    echo "gh: git credential helper for https://github.com: gh auth git-credential (set)"
  else
    echo "gh: could not set the git credential helper (is the global git config writable?)" >&2
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh: not found on PATH (install=none without another gh in the image?)" >&2
  exit 0
fi
echo "gh: $(gh --version 2>/dev/null | head -n 1) at $(command -v gh)"
if gh auth status >/dev/null 2>&1; then
  echo "gh: logged in (state in $dir)"
else
  echo "gh: no login yet; run 'gh auth login' (or task gh:login) once, it persists in $dir"
fi
exit 0
