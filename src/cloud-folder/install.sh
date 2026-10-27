#!/usr/bin/env bash
# Installs the cloud-folder Feature's pieces: cloud-folder-setup (the
# postStartCommand, also behind `task cloud-folder:status`) and the Feature
# Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): MODE, MOUNTPOINT.
#
# This version knows host mode only (a bind mount the launcher adds), so
# nothing is downloaded and there is nothing to verify. rclone, its config
# volume and the sync and mount modes come in a later version.
#
# The launcher bind-mounts the host folder at one fixed path, the host mount
# (HOST_MOUNT below, the same constant as in both launcher twins). When the
# option mountPoint is another path, it becomes a symbolic link to the host
# mount here, so a consumer names the path once (the option). Neither path is
# created as a folder: when nothing is mounted the link dangles and the folder
# is absent, so no one writes into a bare folder of the image by mistake;
# Docker creates the host mount when the launcher mounts onto it. The rclone
# modes of a later version fill mountPoint themselves and make no link.
set -euo pipefail

HOST_MOUNT=/mnt/cloud-folder-host

MODE="${MODE:-auto}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/cloud-folder}"

if [ "$(id -u)" -ne 0 ]; then
  echo "cloud-folder: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

case "$MODE" in
  auto | host) ;;
  *) echo "cloud-folder: option mode '$MODE' is not known to this version (auto or host)." >&2; exit 1 ;;
esac
case "$MOUNTPOINT" in
  /?*) ;;
  *) echo "cloud-folder: option mountPoint '$MOUNTPOINT' must be an absolute path." >&2; exit 1 ;;
esac

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n 1)"

# cloud-folder-setup reads its option defaults from options.env, so the hook
# and the tasks agree; CLOUD_FOLDER_* in the environment override them.
share=/usr/local/share/cloud-folder-feature
mkdir -p "$share"
{
  echo "# Written by the cloud-folder Feature's install.sh from its options; sourced by cloud-folder-setup."
  printf 'MODE=%q\n' "$MODE"
  printf 'MOUNTPOINT=%q\n' "$MOUNTPOINT"
  printf 'FEATURE_VERSION=%q\n' "${version:-unknown}"
  printf 'HOST_MOUNT=%q\n' "$HOST_MOUNT"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/cloud-folder-setup.sh" /usr/local/bin/cloud-folder-setup

# Host mode (all this version knows): mountPoint leads to the host mount. A refusal (a folder with
# content, or a file, already at mountPoint) fails the build with the reason.
/usr/local/bin/cloud-folder-setup link "$MOUNTPOINT" "$HOST_MOUNT"

echo "cloud-folder: Feature ${version:-unknown}, mode $MODE, mount point $MOUNTPOINT, host mount $HOST_MOUNT"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/cloud-folder.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
