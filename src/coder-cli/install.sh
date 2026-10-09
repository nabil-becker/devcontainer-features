#!/usr/bin/env bash
# Installs the Coder CLI (https://coder.com) from GitHub releases, verified
# against the release's checksums file. Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): VERSION.
#
# Why not `curl https://coder.com/install.sh | sh`: that script picks the
# install method and version for you and performs no checksum verification.
set -euo pipefail

VERSION="${VERSION:-latest}"
repo="coder/coder"

if [ "$(id -u)" -ne 0 ]; then
  echo "coder-cli: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
command -v tar >/dev/null 2>&1 || missing+=(tar)
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "coder-cli: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  armv7l) arch=armv7 ;;
  *)
    echo "coder-cli: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

# Resolve "latest" through the GitHub redirect rather than the API (no token,
# no rate limit): releases/latest 302s to releases/tag/v<version>.
if [ "$VERSION" = "latest" ]; then
  VERSION="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" | sed -E 's#.*/tag/v?##')"
fi
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "coder-cli: could not resolve a Coder version from '$VERSION'" >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/v${VERSION}"
asset="coder_${VERSION}_linux_${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "coder-cli: downloading Coder v${VERSION} (${asset})..."
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base_url/coder_${VERSION}_checksums.txt"
(cd "$tmp" && grep -E "  ${asset}\$" checksums.txt | sha256sum -c -)

mkdir -p "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x"
install -m 0755 "$tmp/x/coder" /usr/local/bin/coder

/usr/local/bin/coder version

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/coder-cli.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
