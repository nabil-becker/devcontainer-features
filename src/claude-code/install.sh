#!/usr/bin/env bash
# Installs Anthropic's Claude Code CLI (https://code.claude.com/docs) and the
# pieces that make it part of this collection's ecosystem: the claude-host
# launcher, the claude-fleet command, the post-create setup of CLAUDE_CONFIG_DIR, and the Feature
# Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): INSTALL, VERSION.
#
# State: devcontainer-feature.json points CLAUDE_CONFIG_DIR at
# /var/lib/devcontainer-features/claude-code and mounts a named volume there,
# so login and sessions survive rebuilds. That target exists only once the
# container runs; nothing here writes to it (the post-create hook does).
#
# Augment, don't duplicate: with install=auto (the default) a `claude` that is
# already in the image - put there by the official
# ghcr.io/anthropics/devcontainer-features/claude-code (npm, ordered before
# this Feature by installsAfter) or by a base image - is left alone and only
# the ecosystem pieces are added. The native binary is installed only when no
# claude exists (or install=native): the official Feature has no version
# option, no checksum and needs Node.js, so pinning and verification need
# this installer.
#
# Why not the official installer (`curl -fsSL https://claude.ai/install.sh |
# bash`): it installs per-user under $HOME/.local, and Feature scripts run as
# root, so `claude` would land in /root/.local/bin where remoteUser can't
# reach it. This performs the same download + SHA-256 check the installer does
# (against the per-release manifest.json), then puts the single static binary
# in /usr/local/bin for every user.
#
# The binary is root-owned either way, so the in-app auto-updater can't
# replace it - devcontainer-feature.json sets DISABLE_AUTOUPDATER=1 and a
# rebuild picks up new versions instead.
set -euo pipefail

INSTALL="${INSTALL:-auto}"
VERSION="${VERSION:-stable}"
BASE_URL="https://downloads.claude.ai/claude-code-releases"

if [ "$(id -u)" -ne 0 ]; then
  echo "claude-code: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

# A claude from an earlier Feature: on PATH, or in the places the official
# Feature's `npm install -g` puts it (the node Feature's nvm prefix, the
# distro prefix) when PATH does not yet carry them at build time.
existing_claude() {
  local c
  c="$(command -v claude 2>/dev/null || true)"
  if [ -n "$c" ] && [ "$c" != /usr/local/bin/claude ]; then
    echo "$c"
    return 0
  fi
  for c in /usr/local/share/nvm/versions/node/*/bin/claude /usr/bin/claude /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js; do
    if [ -e "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

install_native() {
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends curl ca-certificates
      rm -rf /var/lib/apt/lists/*
    else
      echo "claude-code: curl is required and apt-get is unavailable." >&2
      exit 1
    fi
  fi

  # tmp is deliberately not local: the EXIT trap below runs after this
  # function has returned, and set -u would abort on an unbound name.
  local arch platform checksum
  case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "claude-code: unsupported architecture $(uname -m)" >&2
      exit 1
      ;;
  esac
  platform="linux-${arch}"
  if ldd /bin/ls 2>&1 | grep -q musl; then
    platform="${platform}-musl"
  fi

  # 'stable'/'latest' are channel files on the release bucket containing a
  # version number.
  case "$VERSION" in
    stable | latest) VERSION="$(curl -fsSL "$BASE_URL/$VERSION")" ;;
  esac
  VERSION="${VERSION#v}"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "claude-code: invalid version '$VERSION'" >&2
    exit 1
  fi

  # Extract platforms["<platform>"].checksum without depending on jq (not in
  # every base image): each platform's object has no nested braces.
  checksum="$(curl -fsSL "$BASE_URL/$VERSION/manifest.json" | tr -d '\n\r\t ' |
    grep -o "\"$platform\":{[^{}]*}" | grep -o '"checksum":"[a-f0-9]\{64\}"' | cut -d'"' -f4)"
  if [ -z "$checksum" ]; then
    echo "claude-code: $platform not found in the $VERSION manifest" >&2
    exit 1
  fi

  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  echo "claude-code: downloading Claude Code v${VERSION} (${platform})..."
  curl -fsSL -o "$tmp" "$BASE_URL/$VERSION/$platform/claude"
  echo "$checksum  $tmp" | sha256sum -c -
  install -m 0755 "$tmp" /usr/local/bin/claude
  /usr/local/bin/claude --version
}

case "$INSTALL" in
  native) install_native ;;
  none) echo "claude-code: install=none, not installing the binary (expected from another Feature or the image)." ;;
  auto)
    if found="$(existing_claude)"; then
      echo "claude-code: keeping the claude already in the image ($found); version '$VERSION' is ignored. Set install=native to replace it with the verified native binary."
    else
      install_native
    fi
    ;;
  *)
    echo "claude-code: invalid install option '$INSTALL' (auto, native, none)" >&2
    exit 1
    ;;
esac

# ------------------------------------------------------- ecosystem pieces ----
# claude-host resumes the host session by UUID (HOST_SESSION); the setup
# script is this Feature's postCreateCommand (see devcontainer-feature.json).
feature_dir="$(cd "$(dirname "$0")" && pwd)"
install -m 0755 "$feature_dir/claude-host.sh" /usr/local/bin/claude-host
# claude-fleet starts several sessions in the background without a second copy of
# any, and opens the agent view (SESSIONS, see NOTES.md).
install -m 0755 "$feature_dir/claude-fleet.sh" /usr/local/bin/claude-fleet
# claude-host-pin writes the pinned session id (opt-in SessionStart hook, and what
# claude-host's CLAUDE_HOST_UPDATE_PIN calls).
install -m 0755 "$feature_dir/claude-host-pin.sh" /usr/local/bin/claude-host-pin
install -m 0755 "$feature_dir/claude-code-setup.sh" /usr/local/bin/claude-code-setup
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
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/claude-code.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
