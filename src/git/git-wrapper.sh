#!/bin/sh
# devcontainer-features git wrapper (git Feature)
# The checkout's git dir may live outside the workspace, reached through
# GIT_DIR and GIT_WORK_TREE (containerEnv). Those two variables reach every
# process, so without this wrapper git inside a linked worktree or a nested
# repository would run against the main checkout, and `git init` / `git
# commit` in a temporary folder (a test fixture) would re-initialise the real
# repository and commit onto its branch. The wrapper scopes the variables to
# the main checkout: everywhere else git behaves as if they were not set.
# @REAL_GIT@ is baked in by install.sh.
real="${GIT_WRAPPER_REAL_GIT:-@REAL_GIT@}"

# Commit identity (commitName / commitEmail options): install.sh writes the
# two values to a file. Environment variables beat every config level, so a
# repository-local user.email cannot override them, and `commit -s` signs off
# with the committer identity. Each variable the caller already set wins. With
# commitWhenEnv (DCF_COMMIT_WHEN_ENV, a variable name) the identity applies
# only when that variable is set and non-empty: agents, not a person's shell.
idfile="${GIT_WRAPPER_IDENTITY_FILE:-/usr/local/share/git-feature/identity.env}"
if [ -r "$idfile" ]; then
  # shellcheck disable=SC1090  # written by install.sh
  . "$idfile"
  dcf_agent=1
  if [ -n "${DCF_COMMIT_WHEN_ENV:-}" ]; then
    eval "[ -n \"\${$DCF_COMMIT_WHEN_ENV:-}\" ]" || dcf_agent=
  fi
  if [ -n "${DCF_COMMIT_EMAIL:-}" ] && [ -n "$dcf_agent" ]; then
    : "${GIT_AUTHOR_NAME:=$DCF_COMMIT_NAME}" "${GIT_AUTHOR_EMAIL:=$DCF_COMMIT_EMAIL}"
    : "${GIT_COMMITTER_NAME:=$DCF_COMMIT_NAME}" "${GIT_COMMITTER_EMAIL:=$DCF_COMMIT_EMAIL}"
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  fi
fi

[ -n "${GIT_DIR:-}" ] || exec "$real" "$@"

# The directory that counts is the one git will run in: $PWD, moved by each
# -C before the subcommand. A -c takes a value that must not be mistaken for
# the subcommand; everything else up to the first non-option is skipped.
dir=$PWD
prev=
sub=
for a in "$@"; do
  if [ "$prev" = "-C" ]; then
    case "$a" in /*) dir=$a ;; *) dir=$dir/$a ;; esac
  elif [ "$prev" != "-c" ]; then
    case "$a" in --) break ;; -*) ;; *) sub=$a; break ;; esac
  fi
  prev=$a
done

dir=$(cd "$dir" 2>/dev/null && pwd -P) || exec "$real" "$@"
wt=
[ -n "${GIT_WORK_TREE:-}" ] && wt=$(cd "$GIT_WORK_TREE" 2>/dev/null && pwd -P)

# 1. Commands that create a repository mean "here", never the main checkout:
#    with the variables kept, clone would check out into GIT_WORK_TREE and a
#    re-init at the root would write core.worktree (a container path) into
#    the shared git dir's config, which breaks git on the host.
# 2. Outside the work tree the main checkout is not what git is being asked
#    about.
# 3. Inside it, the nearest ancestor with a .git (file or directory) is the
#    repository git would find on its own; the main checkout has one too (its
#    pointer file), so only a root that is not GIT_WORK_TREE means "nested".
case "$sub" in
  init | clone) unset GIT_DIR GIT_WORK_TREE ;;
esac
if [ -n "${GIT_DIR:-}" ] && [ -n "$wt" ]; then
  case "$dir" in "$wt" | "$wt"/*) ;; *) unset GIT_DIR GIT_WORK_TREE ;; esac
fi
if [ -n "${GIT_DIR:-}" ]; then
  root=$dir
  while [ -n "$root" ] && [ ! -e "$root/.git" ]; do root=${root%/*}; done
  if [ -n "$root" ] && [ "$root" != "$wt" ]; then unset GIT_DIR GIT_WORK_TREE; fi
fi
exec "$real" "$@"
