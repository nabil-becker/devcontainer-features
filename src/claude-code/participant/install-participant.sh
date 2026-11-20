#!/usr/bin/env bash
# install-participant.sh: installs the participant component (the agents command, its Taskfile and
# its state folders) into one place, /usr/local/lib/dcf-participant, for every Feature that carries
# a copy of it (components/participant/, vendored into src/<id>/participant/ by
# `task components:sync`). Run as root by a Feature's install.sh:
#
#   bash "$feature_dir/participant/install-participant.sh" --by <feature id> [--taskfile true|false]
#
# Idempotent across Features: when a copy of the same or a newer COMPONENT_VERSION is already
# installed, nothing is copied (the newer copy wins, ADR-0061); only the Taskfile include is added
# when this caller wants it and it is missing. So the agents Feature and claude-code
# (participants: true) installed together leave a single copy, in whichever order they run.
#
# What lands (the same paths the agents Feature used up to 2.1.3, so behaviour is unchanged):
#   /usr/local/lib/dcf-participant/     agents.sh, taskfile.yml, COMPONENT_VERSION, installed-by
#   /usr/local/bin/agents               a symlink to the agents.sh above
#   /usr/local/share/go-task/includes.d/agents.yml   the Taskfile (agents: namespace), on request
#   /var/lib/devcontainer-features/agents (1777) and its leases/ (0777)   state, not a volume
#
# The DCF_PARTICIPANT_* variables move every path, for the Docker-free test only.
set -euo pipefail

by="" taskfile=true
while [ $# -gt 0 ]; do
  case "$1" in
    --by) by="${2:-}"; shift 2 ;;
    --taskfile) taskfile="${2:-true}"; shift 2 ;;
    *) echo "install-participant: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$by" ] || { echo "install-participant: --by <feature id> is required" >&2; exit 2; }

src="$(cd "$(dirname "$0")" && pwd)"
lib="${DCF_PARTICIPANT_LIB:-/usr/local/lib/dcf-participant}"
bin_dir="${DCF_PARTICIPANT_BIN:-/usr/local/bin}"
includes_d="${DCF_PARTICIPANT_INCLUDES:-/usr/local/share/go-task/includes.d}"
state="${DCF_PARTICIPANT_STATE:-/var/lib/devcontainer-features/agents}"

ours="$(head -n 1 "$src/COMPONENT_VERSION" | tr -d '[:space:]')"
have=""
[ ! -f "$lib/COMPONENT_VERSION" ] || have="$(head -n 1 "$lib/COMPONENT_VERSION" | tr -d '[:space:]')"

# version_ge <a> <b>: a >= b for x.y.z (missing parts are 0; no sort -V, which busybox lacks).
version_ge() {
  local IFS=. i a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    if [ "${a[i]:-0}" -gt "${b[i]:-0}" ]; then return 0; fi
    if [ "${a[i]:-0}" -lt "${b[i]:-0}" ]; then return 1; fi
  done
  return 0
}

refresh_registry() {
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
}

if [ -n "$have" ] && [ -x "$lib/agents.sh" ] && version_ge "$have" "$ours"; then
  echo "participant: component $have already installed (by $(head -n 1 "$lib/installed-by" 2>/dev/null || echo unknown)); $by's copy ($ours) not installed"
  if [ "$taskfile" = "true" ] && [ ! -e "$includes_d/agents.yml" ]; then
    mkdir -p "$includes_d"
    install -m 0644 "$lib/taskfile.yml" "$includes_d/agents.yml"
    refresh_registry
  fi
  exit 0
fi

# Install (or replace an older copy): built beside, then moved into place.
mkdir -p "$(dirname "$lib")"
rm -rf "$lib.new"
mkdir -p "$lib.new"
install -m 0755 "$src/agents.sh" "$lib.new/agents.sh"
install -m 0644 "$src/taskfile.yml" "$lib.new/taskfile.yml"
install -m 0644 "$src/COMPONENT_VERSION" "$lib.new/COMPONENT_VERSION"
printf '%s\n' "$by" > "$lib.new/installed-by"
chmod 0644 "$lib.new/installed-by"
rm -rf "$lib"
mv "$lib.new" "$lib"
chmod 0755 "$lib"

mkdir -p "$bin_dir"
ln -sfn "$lib/agents.sh" "$bin_dir/agents"

# Any user writes their markers here; the sticky bit keeps users out of each other's.
mkdir -p "$state"
chmod 1777 "$state"
# The leases: no sticky bit, so a dead holder owned by another user (root at post-start, the
# remote user in a terminal) can be taken over.
mkdir -p "$state/leases"
chmod 0777 "$state/leases"

# The Taskfile: on request, and refreshed when an older copy put one there.
if [ "$taskfile" = "true" ] || [ -e "$includes_d/agents.yml" ]; then
  mkdir -p "$includes_d"
  install -m 0644 "$lib/taskfile.yml" "$includes_d/agents.yml"
  refresh_registry
fi
if [ -n "$have" ]; then
  echo "participant: replaced component $have with $ours (by $by)"
else
  echo "participant: installed component $ours (by $by)"
fi
