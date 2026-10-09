#!/usr/bin/env bash
# Installs @devcontainers/cli on a private Node.js. The logic lives in
# devcontainer-cli.sh next to this file - the same script the host-side
# devcontainer:* tasks run on Linux/macOS - invoked here in "install" mode.
# Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): VERSION, NODEVERSION.
set -euo pipefail

feature_dir="$(cd "$(dirname "$0")" && pwd)"
bash "$feature_dir/devcontainer-cli.sh" install

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/devcontainer-cli.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
