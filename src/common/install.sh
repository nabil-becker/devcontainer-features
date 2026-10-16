#!/usr/bin/env bash
# Installs the collection's shared helpers on PATH. Today one: dcf-persist
# (dcf-persist.sh), the script behind every <id>-setup post-create hook that
# makes a tool's state directory usable by the remote user. The other
# Features carry a verbatim copy and install it themselves, so this Feature
# is for a repo's own scripts and as the canonical source; installing over
# an identical copy is fine. Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): INSTALLTASKFILE only.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "common: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"

# install(1) writes a fresh file and renames it over the target, so a copy
# another Feature left there (identical or older) is replaced, never appended
# to or chmod-ed in place.
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

echo "dcf-persist: installed"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/common.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
