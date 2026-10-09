#!/usr/bin/env bash
# Installs Anthropic's Claude Code CLI (https://code.claude.com/docs).
# Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): VERSION.
#
# Why not the official installer (`curl -fsSL https://claude.ai/install.sh |
# bash`): it installs per-user under $HOME/.local, and Feature scripts run as
# root, so `claude` would land in /root/.local/bin where remoteUser can't
# reach it. This performs the same download + SHA-256 check the installer does
# (against the per-release manifest.json), then puts the single static binary
# in /usr/local/bin for every user.
#
# Why not ghcr.io/anthropics/devcontainer-features/claude-code: it has no
# version option and installs via npm, pulling in Node.js when absent.
#
# The binary is root-owned, so the in-app auto-updater can't replace it -
# devcontainer-feature.json sets DISABLE_AUTOUPDATER=1 and a rebuild picks up
# new versions instead.
set -euo pipefail

VERSION="${VERSION:-stable}"
BASE_URL="https://downloads.claude.ai/claude-code-releases"

if [ "$(id -u)" -ne 0 ]; then
  echo "claude-code: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

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
