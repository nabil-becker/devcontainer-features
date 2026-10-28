#!/usr/bin/env bash
# Installs the cloud-folder Feature's pieces: rclone (for the sync mode; pinned and
# checksum-verified, only when absent), cloud-folder-setup (the postStartCommand, also behind
# every `task cloud-folder:*`), dcf-persist (the collection's state-folder helper) and the
# Feature Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): MODE, MOUNTPOINT, REMOTETYPE, DRIVETYPE, SITEURL, REMOTEPATH,
# SYNCINTERVAL, RCLONEVERSION.
#
# Two layouts, chosen by the option mode:
#   auto, host  The launcher bind-mounts the host folder at one fixed path, the host mount
#               (HOST_MOUNT below, the same constant as in both launcher twins). When the option
#               mountPoint is another path, it becomes a symbolic link to the host mount, so a
#               consumer names the path once. Neither path is created as a folder: when nothing
#               is mounted the link dangles and the folder is absent. In auto, when no host
#               folder is mounted and a remote is configured, the sync mode fills the folder the
#               link leads to (cloud-folder-setup creates it at start).
#   sync        mountPoint is a plain folder of the image, filled by `rclone bisync`; no link.
#
# rclone: downloaded from the publisher (downloads.rclone.org) as the release zip, verified
# against the sha256 pinned in rclone-checksums.txt for that version and architecture or, for
# a version not listed there, against the release's SHA256SUMS; never piped into a shell. Not
# installed in mode host (it is not used there), and kept as it is when the image already has
# one (another Feature installed it first: installsAfter orders this one behind them).
set -euo pipefail

# Every download goes through dcf_curl (dcf-curl.sh, the collection's retry helper, vendored from
# src/common): curl with --retry and, on curl 7.71+, --retry-all-errors.
# shellcheck source=src/cloud-folder/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

HOST_MOUNT=/mnt/cloud-folder-host
STATE_DIR=/var/lib/devcontainer-features/cloud-folder
DOWNLOADS=https://downloads.rclone.org

MODE="${MODE:-auto}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/cloud-folder}"
REMOTETYPE="${REMOTETYPE:-sharepoint}"
DRIVETYPE="${DRIVETYPE:-documentLibrary}"
SITEURL="${SITEURL:-}"
REMOTEPATH="${REMOTEPATH:-}"
SYNCINTERVAL="${SYNCINTERVAL:-15m}"
RCLONEVERSION="${RCLONEVERSION:-1.75.2}"

if [ "$(id -u)" -ne 0 ]; then
  echo "cloud-folder: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

case "$MODE" in
  auto | host | sync) ;;
  *) echo "cloud-folder: option mode '$MODE' is not known to this version (auto, host or sync)." >&2; exit 1 ;;
esac
case "$MOUNTPOINT" in
  /?*) ;;
  *) echo "cloud-folder: option mountPoint '$MOUNTPOINT' must be an absolute path." >&2; exit 1 ;;
esac
case "$REMOTETYPE" in
  sharepoint | onedrive) ;;
  *) echo "cloud-folder: option remoteType '$REMOTETYPE' is not known (sharepoint or onedrive)." >&2; exit 1 ;;
esac
case "$DRIVETYPE" in
  personal | business | documentLibrary) ;;
  *) echo "cloud-folder: option driveType '$DRIVETYPE' is not known (personal, business or documentLibrary)." >&2; exit 1 ;;
esac
if [[ ! "$SYNCINTERVAL" =~ ^[0-9]+[smh]?$ ]]; then
  echo "cloud-folder: option syncInterval '$SYNCINTERVAL' is not a duration (for example 15m, 900s, 1h, or 0 for on demand only)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n 1)"

# ---------------------------------------------------------------- rclone ----
# The first line of `<rclone> version`. sed reads all of the output: `| head -n 1` closes the pipe
# after one line, rclone (still writing) gets SIGPIPE, and under pipefail the 141 stopped the
# install (a --no-cache rebuild, intermittently). test/cloud-folder/unit/version_test.sh.
rclone_version_line() { # <rclone binary>
  "$1" version 2>/dev/null | sed -n 1p
}

install_rclone() {
  local arch v asset sum tmp missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  if [ "${#missing[@]}" -gt 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends "${missing[@]}"
      rm -rf /var/lib/apt/lists/*
    else
      echo "cloud-folder: missing ${missing[*]} and no apt-get to install them." >&2
      return 1
    fi
  fi
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "cloud-folder: rclone: unsupported architecture $(uname -m) (amd64 and arm64)" >&2; return 1 ;;
  esac

  v="$RCLONEVERSION"
  if [ "$v" = latest ]; then
    # The publisher's one-line version file ("rclone v1.75.2").
    v="$(dcf_curl -fsSL "$DOWNLOADS/version.txt" | sed -n 's/^rclone v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
    echo "cloud-folder: rcloneVersion latest resolves to $v"
  fi
  v="${v#v}"
  if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "cloud-folder: could not resolve an rclone version from '$RCLONEVERSION'" >&2
    return 1
  fi

  asset="rclone-v${v}-linux-${arch}.zip"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the trap must remove this tmp
  trap "rm -rf '$tmp'" RETURN
  # 1. The digest pinned in this Feature: no trust in what the server says about itself.
  sum="$(awk -v n="$asset" '$2 == n { print $1; exit }' "$feature_dir/rclone-checksums.txt" 2>/dev/null || true)"
  if [ -z "$sum" ]; then
    # 2. A version not pinned here: the release's SHA256SUMS from the publisher.
    sum="$(dcf_curl -fsSL "$DOWNLOADS/v${v}/SHA256SUMS" | awk -v n="$asset" '$2 == n { print $1; exit }' || true)"
    [ -n "$sum" ] && echo "cloud-folder: rclone $v is not pinned in this Feature; verifying against the release's SHA256SUMS"
  fi
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "cloud-folder: no sha256 for $asset (not in rclone-checksums.txt, not in the release's SHA256SUMS)." >&2
    return 1
  fi
  echo "cloud-folder: downloading rclone v${v} (${asset})..."
  dcf_curl -fsSL -o "$tmp/$asset" "$DOWNLOADS/v${v}/$asset"
  echo "${sum}  $tmp/$asset" | sha256sum -c -
  unzip -q -j -o "$tmp/$asset" "rclone-v${v}-linux-${arch}/rclone" -d "$tmp/x"
  install -m 0755 "$tmp/x/rclone" /usr/local/bin/rclone
  rclone_version_line /usr/local/bin/rclone
}

if [ "$MODE" = host ]; then
  echo "cloud-folder: mode host: rclone is not installed (host mode does not use it)"
elif found="$(command -v rclone 2>/dev/null)"; then
  echo "cloud-folder: keeping the rclone already in the image ($found, $(rclone_version_line "$found")); rcloneVersion '$RCLONEVERSION' is ignored."
else
  install_rclone
fi

# ------------------------------------------------------- ecosystem pieces ----
# cloud-folder-setup reads its option defaults from options.env, so the hook and the tasks
# agree; CLOUD_FOLDER_* in the environment override them.
share=/usr/local/share/cloud-folder-feature
mkdir -p "$share"
{
  echo "# Written by the cloud-folder Feature's install.sh from its options; sourced by cloud-folder-setup."
  printf 'MODE=%q\n' "$MODE"
  printf 'MOUNTPOINT=%q\n' "$MOUNTPOINT"
  printf 'REMOTETYPE=%q\n' "$REMOTETYPE"
  printf 'DRIVETYPE=%q\n' "$DRIVETYPE"
  printf 'SITEURL=%q\n' "$SITEURL"
  printf 'REMOTEPATH=%q\n' "$REMOTEPATH"
  printf 'SYNCINTERVAL=%q\n' "$SYNCINTERVAL"
  printf 'RCLONEVERSION=%q\n' "$RCLONEVERSION"
  printf 'FEATURE_VERSION=%q\n' "${version:-unknown}"
  printf 'HOST_MOUNT=%q\n' "$HOST_MOUNT"
  printf 'STATE_DIR=%q\n' "$STATE_DIR"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/cloud-folder-setup.sh" /usr/local/bin/cloud-folder-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# The state folder is the Feature's volume (devcontainer-feature.json), mounted at start, not
# at build: nothing is written into it here. cloud-folder-setup hands it to the remote user.
mkdir -p "$STATE_DIR"

# The mount point. A refusal (a folder with content, or a file, where the link must go; a file
# where the folder must go) fails the build with the reason.
if [ "$MODE" = sync ]; then
  /usr/local/bin/cloud-folder-setup folder "$MOUNTPOINT"
else
  /usr/local/bin/cloud-folder-setup link "$MOUNTPOINT" "$HOST_MOUNT"
fi

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
