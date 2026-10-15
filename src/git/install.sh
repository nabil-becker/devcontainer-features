#!/usr/bin/env bash
# Augments the git already in the image (base image, common-utils or
# ghcr.io/devcontainers/features/git) for devcontainers whose checkout keeps
# its git dir outside the workspace (GIT_DIR + GIT_WORK_TREE in containerEnv):
#   - /usr/local/bin/git, a wrapper that drops GIT_DIR/GIT_WORK_TREE inside
#     linked worktrees and nested repositories (git-wrapper.sh);
#   - /usr/local/bin/git-setup, the per-container setup (safe.directory,
#     core.hooksPath) that this Feature's postCreateCommand hook runs.
# Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): WORKTREEAWARE, SAFEDIRECTORY, HOOKSPATH.
#
# State: devcontainer-feature.json points GIT_CONFIG_GLOBAL at
# /var/lib/devcontainer-features/git/gitconfig and mounts a named volume on
# that folder, so the global config survives rebuilds. At build time the
# folder does not exist yet; git reads tolerate a missing global config and
# nothing here writes one (the post-create hook does).
set -euo pipefail

WORKTREEAWARE="${WORKTREEAWARE:-true}"
# An explicitly empty string is a valid value for these two ("do nothing"),
# hence "-" rather than ":-".
SAFEDIRECTORY="${SAFEDIRECTORY-workspace}"
HOOKSPATH="${HOOKSPATH-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "git: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends git ca-certificates
    rm -rf /var/lib/apt/lists/*
  else
    echo "git: git is not installed and apt-get is unavailable." >&2
    exit 1
  fi
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/git-feature
aside=/usr/local/libexec/git-feature
wrapper=/usr/local/bin/git
marker='# devcontainer-features git wrapper'
mkdir -p "$share"

install -m 0755 "$feature_dir/git-setup.sh" /usr/local/bin/git-setup

real_git=""
if [ "$WORKTREEAWARE" = "true" ]; then
  # A git already at /usr/local/bin that is not our wrapper (built from source
  # by ghcr.io/devcontainers/features/git) is moved aside so the wrapper can
  # take its place and still forward to it; otherwise the real git is the
  # first one on PATH that is not the wrapper itself (re-runs).
  if [ -e "$wrapper" ] && ! grep -qs "^$marker" "$wrapper"; then
    mkdir -p "$aside"
    mv "$wrapper" "$aside/git"
  fi
  if [ -x "$aside/git" ]; then
    real_git="$aside/git"
  else
    while IFS= read -r candidate; do
      if [ "$candidate" != "$wrapper" ]; then real_git="$candidate"; break; fi
    done < <(type -aP git)
  fi
  if [ -z "$real_git" ]; then
    echo "git: no git found on PATH other than $wrapper" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  sed "s|@REAL_GIT@|$real_git|" "$feature_dir/git-wrapper.sh" > "$tmp"
  install -m 0755 "$tmp" "$wrapper"
else
  # Leave the image as if the wrapper had never been there.
  if [ -e "$wrapper" ] && grep -qs "^$marker" "$wrapper"; then
    rm -f "$wrapper"
  fi
  if [ -x "$aside/git" ]; then
    mv "$aside/git" "$wrapper"
  fi
fi

# The options, as defaults for git-setup (the hook and `task git:setup` must
# behave the same) and the resolved real git for the version report.
{
  echo "# Written by the git Feature's install.sh from its options; sourced by git-setup."
  printf 'SAFEDIRECTORY=%q\n' "$SAFEDIRECTORY"
  printf 'HOOKSPATH=%q\n' "$HOOKSPATH"
  printf 'REALGIT=%q\n' "$real_git"
} > "$share/options.env"
chmod 0644 "$share/options.env"

echo "git: $(git --version) at $(command -v git)${real_git:+ (wrapper -> $real_git)}"

# dcf-persist is the shared state-directory helper the hook calls (verbatim
# copy of src/common/dcf-persist.sh; every Feature of this collection
# installs the same file).
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/git.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
