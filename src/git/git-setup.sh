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
# They come from containerEnv (the per-repo mount), or, without GIT_DIR, from
# the workspace's .git pointer mapped onto GIT_DIRS_ROOT (the one .git-dirs
# mount; git-dirs.sh, the code the wrapper uses). Kept in the Feature's state
# folder, which is writable by this user; never fatal.
dirs_file="${GIT_WRAPPER_DIRS_FILE:-/var/lib/devcontainer-features/git/dirs.env}"
gitdirs_lib="${GIT_WRAPPER_GITDIRS_LIB:-/usr/local/share/git-feature/git-dirs.sh}"
record_dirs() { # <git dir> <work tree> <where from>
  [ -d "$(dirname "$dirs_file")" ] || return 0
  sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"; }
  if {
    echo "# Written by git-setup from $3; sourced by the git wrapper."
    printf 'DCF_GIT_DIR=%s\n' "$(sq "$1")"
    printf 'DCF_WORK_TREE=%s\n' "$(sq "$2")"
  } > "$dirs_file.tmp" 2>/dev/null && mv -f "$dirs_file.tmp" "$dirs_file" 2>/dev/null; then
    echo "git dir: recorded GIT_DIR and GIT_WORK_TREE in $dirs_file"
  else
    rm -f "$dirs_file.tmp" 2>/dev/null || true
    echo "git dir: could not write $dirs_file"
  fi
}
git_dir=''
recorded=''
case "${GIT_DIR:-}" in
  '' | */not-a-git-repository)
    # The workspace's top level: what git reports (through the wrapper, which
    # maps the pointer), else the nearest folder above with a .git, else here.
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=''
    if [ -z "$top" ]; then
      top="$workspace"
      while [ -n "$top" ] && [ ! -e "$top/.git" ]; do top="${top%/*}"; done
      [ -n "$top" ] || top="$workspace"
    fi
    workspace="$top"
    if [ -f "$top/.git" ] && [ -r "$gitdirs_lib" ]; then
      # shellcheck disable=SC1090  # installed by install.sh
      . "$gitdirs_lib"
      dcf_gitdirs_resolve "$top"
      mount_line="\"source=\${localEnv:DCF_HOST_HOME}/.git-dirs,target=$DCF_GITDIRS_ROOT,type=bind\""
      # DCF_HOST_HOME is empty when VS Code opened the folder without the launcher.
      # shellcheck disable=SC2016  # ${localEnv:...} is text for devcontainer.json, not ours to expand
      vscode_hint='(opened straight in VS Code, the launcher did not run: use ${localEnv:USERPROFILE} on a Windows host or ${localEnv:HOME} on Linux, macOS and WSL in place of ${localEnv:DCF_HOST_HOME})'
      case "$DCF_GITDIRS_STATE" in
        mapped)
          echo "git dir: $DCF_GITDIRS_POINTER -> $DCF_GITDIRS_PATH (through $DCF_GITDIRS_ROOT)"
          git_dir="$DCF_GITDIRS_PATH"
          record_dirs "$git_dir" "$top" "the workspace's .git pointer mapped onto $DCF_GITDIRS_ROOT"
          recorded=1
          ;;
        missing)
          echo "git dir: NOT MOUNTED - $top/.git points to $DCF_GITDIRS_POINTER, expected at $DCF_GITDIRS_PATH; the launcher adds the mount when started through the bootstrap tasks (task devcontainer:up), else add to devcontainer.json \"mounts\": [$mount_line] $vscode_hint and rebuild" ;;
        outside)
          echo "git dir: OUTSIDE .git-dirs - $top/.git points to $DCF_GITDIRS_POINTER, which the container cannot reach; keep the git dir under %USERPROFILE%\\.git-dirs\\<owner>\\<repo> (update the pointer); the launcher adds the mount when started through the bootstrap tasks (task devcontainer:up), else add to devcontainer.json \"mounts\": [$mount_line] $vscode_hint" ;;
      esac
    fi
    ;;
  *)
    git_dir="$GIT_DIR"
    if [ -n "${GIT_WORK_TREE:-}" ]; then
      record_dirs "$GIT_DIR" "$GIT_WORK_TREE" "containerEnv GIT_DIR and GIT_WORK_TREE"
      recorded=1
    fi
    ;;
esac
# Nothing to restore: no stale file. A placeholder run (from inside Claude
# Code) keeps what post-create recorded.
if [ -z "$recorded" ] && [ -z "${GIT_DIR:-}" ]; then rm -f "$dirs_file" 2>/dev/null || true; fi

# safe.directory first: the workspace and the git dir are bind mounts owned
# by another uid, and every repo-local command below needs them trusted.
# Run from / so a workspace whose .git pointer git cannot follow (the mount is
# missing) does not make git refuse the global config too.
add_safe_directory() {
  if git -C / config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "$1"; then
    echo "safe.directory: $1 (kept)"
  elif git -C / config --global --add safe.directory "$1" 2>/dev/null; then
    echo "safe.directory: $1 (added)"
  else
    echo "safe.directory: could not add $1 (is the global git config writable?)"
  fi
}
case "$safe_directory" in
  workspace)
    add_safe_directory "$workspace"
    [ -n "$git_dir" ] && add_safe_directory "$git_dir"
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
echo "GIT_DIR: ${GIT_DIR:-(not set)}${git_dir:+ (git dir $git_dir)}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "workspace $workspace: ok ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no commits yet'))"
else
  echo "workspace $workspace: NOT AVAILABLE (is the git-dir mount present?)"
fi
