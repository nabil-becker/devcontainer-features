#!/usr/bin/env bash
# `task devcontainer:homes` on Linux/macOS - bash twin of
# Initialize-DevcontainerHomes.ps1 (same behaviour and settings): creates the
# host-side folders a devcontainer.json bind-mounts for tool state, so the
# container never fails to start on a missing mount source. Meant as the
# devcontainer's initializeCommand:
#
#   "initializeCommand": "task devcontainer:homes NAME=myrepo -- claude gh"
#
#   devcontainer-homes.sh --name <slug> [--root <dir>] [--git-dir <dir>] [--] <dir>...
#
#   --name     folder under the homes root for this repository (a slug, the
#              same literal the mounts in devcontainer.json use)
#   --root     homes root; default $DEVCONTAINER_HOMES, else ~/.devcontainer-homes
#   --git-dir  optional git dir kept outside the checkout; fail plainly if it
#              has no HEAD, rather than letting the GIT_DIR mount fail later
#   <dir>...   folders to create under <root>/<name>, e.g. claude gh azure
set -euo pipefail

name='' root="${DEVCONTAINER_HOMES:-}" git_dir=''
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --git-dir) git_dir="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "devcontainer-homes: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "devcontainer:homes NAME '$name' must be a plain slug (letters, digits, . _ -), the same one the mounts in devcontainer.json use." >&2
  exit 2
fi
root="${root:-$HOME/.devcontainer-homes}"
base="$root/$name"
mkdir -p "$base"
echo "devcontainer homes: $base"
# Task passes CLI_ARGS as one string; split it like the PowerShell flavour.
# shellcheck disable=SC2068  # word splitting is the point here
for d in $@; do
  if [ -d "$base/$d" ]; then state=exists; else state=created; fi
  mkdir -p "$base/$d"
  printf '  %s\t%s\n' "$d" "$state"
done

if [ -n "$git_dir" ]; then
  if [ ! -e "$git_dir/HEAD" ]; then
    echo "git dir not found at $git_dir (no HEAD). The devcontainer bind-mounts it as GIT_DIR; create or move the repository's git dir there first." >&2
    exit 1
  fi
  printf '  git dir\t%s\n' "$git_dir"
fi
