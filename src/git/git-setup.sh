#!/usr/bin/env bash
# Per-container git setup. The git Feature's postCreateCommand hook runs it
# as the remote user from the workspace folder; `task git:setup` re-runs it.
# Idempotent and never fatal: a broken git-dir mount must not abort the rest
# of post-create, so every problem is reported and the exit status stays 0.
set -euo pipefail

# Defaults baked by install.sh from the Feature options. GIT_SETUP_* in the
# environment (containerEnv) override them without a rebuild; set-but-empty
# counts as an override, so a repo can switch a step off.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/git-feature/options.env ] && source /usr/local/share/git-feature/options.env
safe_directory="${GIT_SETUP_SAFE_DIRECTORY-${SAFEDIRECTORY:-workspace}}"
hooks_path="${GIT_SETUP_HOOKS_PATH-${HOOKSPATH:-}}"
workspace="$PWD"

# git creates the global config file on first write but not its folder. The
# Feature's own containerEnv points GIT_CONFIG_GLOBAL into its named volume
# (/var/lib/devcontainer-features/git); a repo may point it elsewhere. Either
# way the folder may arrive root-owned: dcf-persist creates it, hands it to
# the current user and reports what backs it.
if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
  dcf-persist --label git "$(dirname "$GIT_CONFIG_GLOBAL")"
fi

# The real GIT_DIR and GIT_WORK_TREE, for the wrapper: Claude Code overwrites
# both with a not-a-git-repository placeholder when it cannot use the
# checkout's .git pointer, and the wrapper needs them from somewhere stable.
# They are in the container's environment now (containerEnv). Kept in the
# Feature's state folder, which is writable by this user; never fatal.
dirs_file="${GIT_WRAPPER_DIRS_FILE:-/var/lib/devcontainer-features/git/dirs.env}"
case "${GIT_DIR:-}" in
  '' | */not-a-git-repository) ;;
  *)
    if [ -n "${GIT_WORK_TREE:-}" ] && [ -d "$(dirname "$dirs_file")" ]; then
      sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"; }
      if {
        echo "# Written by git-setup from containerEnv GIT_DIR and GIT_WORK_TREE; sourced by the git wrapper."
        printf 'DCF_GIT_DIR=%s\n' "$(sq "$GIT_DIR")"
        printf 'DCF_WORK_TREE=%s\n' "$(sq "$GIT_WORK_TREE")"
      } > "$dirs_file.tmp" 2>/dev/null && mv -f "$dirs_file.tmp" "$dirs_file" 2>/dev/null; then
        echo "git dir: recorded GIT_DIR and GIT_WORK_TREE in $dirs_file"
      else
        rm -f "$dirs_file.tmp" 2>/dev/null || true
        echo "git dir: could not write $dirs_file"
      fi
    fi
    ;;
esac
[ -n "${GIT_DIR:-}" ] || rm -f "$dirs_file" 2>/dev/null || true

# safe.directory first: the workspace and the git dir are bind mounts owned
# by another uid, and every repo-local command below needs them trusted.
add_safe_directory() {
  if git config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "$1"; then
    echo "safe.directory: $1 (kept)"
  elif git config --global --add safe.directory "$1" 2>/dev/null; then
    echo "safe.directory: $1 (added)"
  else
    echo "safe.directory: could not add $1 (is the global git config writable?)"
  fi
}
case "$safe_directory" in
  workspace)
    add_safe_directory "$workspace"
    [ -n "${GIT_DIR:-}" ] && add_safe_directory "$GIT_DIR"
    ;;
  '') echo "safe.directory: not configured" ;;
  *) add_safe_directory "$safe_directory" ;;
esac

# Repo-local: with GIT_DIR set this lands in that git dir, which is what the
# host-side git reads too.
if [ -n "$hooks_path" ]; then
  if [ "$(git config --get core.hooksPath 2>/dev/null || true)" = "$hooks_path" ]; then
    echo "hooksPath: $hooks_path (kept)"
  elif git config core.hooksPath "$hooks_path" 2>/dev/null; then
    echo "hooksPath: $hooks_path (set)"
  else
    echo "hooksPath: could not set $hooks_path (no repository at $workspace?)"
  fi
else
  echo "hooksPath: not configured"
fi

# Report what this container's git looks like, so a missing mount or a
# bypassed wrapper shows up in the post-create log.
git_bin="$(command -v git)"
if grep -qs '^# devcontainer-features git wrapper' "$git_bin"; then
  echo "git: $(git --version) via wrapper $git_bin -> ${GIT_WRAPPER_REAL_GIT:-${REALGIT:-?}}"
else
  echo "git: $(git --version) at $git_bin (no wrapper)"
fi
echo "GIT_DIR: ${GIT_DIR:-(not set)}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "workspace $workspace: ok ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no commits yet'))"
else
  echo "workspace $workspace: NOT AVAILABLE (is the git-dir mount present?)"
fi
