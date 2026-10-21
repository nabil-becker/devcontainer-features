# shellcheck shell=sh
# shellcheck disable=SC2034  # the DCF_GITDIRS_* results are read by the sourcing script
# devcontainer-features git Feature: map a checkout's .git pointer that holds
# a host path under .git-dirs onto the folder mounted at GIT_DIRS_ROOT.
# Sourced (POSIX sh) by the git wrapper and by git-setup, so both resolve a
# pointer the same way; install.sh puts it at
# /usr/local/share/git-feature/git-dirs.sh. No subprocess: one file read and
# string operations, because the wrapper runs it on every git call in such a
# checkout.
#
# On Windows a checkout's .git is a file `gitdir: C:/Users/<user>/.git-dirs/
# <owner>/<repo>` (outside OneDrive). The consuming repo bind-mounts the whole
# %USERPROFILE%\.git-dirs at GIT_DIRS_ROOT (default /git-dirs); everything
# after the .git-dirs segment (matched case-insensitively, \ and / alike) is
# joined onto that root.

# dcf_gitdirs_resolve <dir>: <dir> is a folder whose .git is a file. Sets
#   DCF_GITDIRS_STATE   none     no pointer file, or not `gitdir: ...`
#                       native   the pointer already names a git dir (HEAD
#                                there): a Linux path, a linked worktree;
#                                a relative pointer resolves against <dir>
#                       mapped   DCF_GITDIRS_PATH is <root>/<rest> and has HEAD
#                       missing  it has a .git-dirs segment but <root>/<rest>
#                                has no HEAD (the mount is missing or the
#                                folder is not under the mounted .git-dirs)
#                       outside  a path the container cannot use, with no
#                                .git-dirs segment (or one that climbs out
#                                with ..)
#   DCF_GITDIRS_POINTER the gitdir value as read (CR and trailing / removed)
#   DCF_GITDIRS_PATH    the git dir for native and mapped, the expected one
#                       for missing, empty otherwise
#   DCF_GITDIRS_ROOT    the root in use
# Always returns 0. Only _dcf_* names are used as scratch variables.
dcf_gitdirs_resolve() {
  DCF_GITDIRS_STATE=none
  DCF_GITDIRS_POINTER=
  DCF_GITDIRS_PATH=
  DCF_GITDIRS_ROOT=${GIT_DIRS_ROOT:-/git-dirs}
  while :; do
    case "$DCF_GITDIRS_ROOT" in ?*/) DCF_GITDIRS_ROOT=${DCF_GITDIRS_ROOT%/} ;; *) break ;; esac
  done
  [ -f "$1/.git" ] || return 0
  _dcf_p=
  # read fails on a last line without a newline but still fills the variable.
  IFS= read -r _dcf_p < "$1/.git" || [ -n "$_dcf_p" ] || return 0
  case "$_dcf_p" in "gitdir: "?*) _dcf_p=${_dcf_p#gitdir: } ;; *) return 0 ;; esac
  # A file written on Windows may end in CR; then drop trailing separators.
  while :; do
    case "$_dcf_p" in
      *[[:cntrl:]] | ?*/ | ?*\\) _dcf_p=${_dcf_p%?} ;;
      *) break ;;
    esac
  done
  DCF_GITDIRS_POINTER=$_dcf_p
  case "$_dcf_p" in /*) _dcf_q=$_dcf_p ;; *) _dcf_q=$1/$_dcf_p ;; esac
  if [ -f "$_dcf_q/HEAD" ]; then
    DCF_GITDIRS_STATE=native DCF_GITDIRS_PATH=$_dcf_q
    return 0
  fi
  DCF_GITDIRS_STATE=outside
  case "$_dcf_p" in
    *[/\\][.][Gg][Ii][Tt]-[Dd][Ii][Rr][Ss][/\\]?*) ;;
    *) return 0 ;;
  esac
  _dcf_rest=${_dcf_p#*[/\\][.][Gg][Ii][Tt]-[Dd][Ii][Rr][Ss][/\\]}
  while :; do
    case "$_dcf_rest" in
      *\\*) _dcf_rest="${_dcf_rest%%\\*}/${_dcf_rest#*\\}" ;;
      *) break ;;
    esac
  done
  case "/$_dcf_rest/" in */../* | */./* | //*) return 0 ;; esac
  DCF_GITDIRS_PATH=$DCF_GITDIRS_ROOT/$_dcf_rest
  if [ -f "$DCF_GITDIRS_PATH/HEAD" ]; then
    DCF_GITDIRS_STATE=mapped
  else
    DCF_GITDIRS_STATE=missing
  fi
  return 0
}
