#!/usr/bin/env bash
# Installs kubeconform (https://github.com/yannh/kubeconform) from GitHub
# releases, verified against the release's CHECKSUMS file. Feature options
# arrive as upper-cased environment variables (see devcontainer-feature.json):
# VERSION.
set -euo pipefail

VERSION="${VERSION:-latest}"
repo="yannh/kubeconform"

if [ "$(id -u)" -ne 0 ]; then
  echo "kubeconform: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
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
    echo "kubeconform: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  armv7l) arch=armv6 ;;
  *)
    echo "kubeconform: unsupported architecture $(uname -m)" >&2
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
  echo "kubeconform: could not resolve a kubeconform version from '$VERSION'" >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/v${VERSION}"
asset="kubeconform-linux-${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "kubeconform: downloading kubeconform v${VERSION} (${asset})..."
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL -o "$tmp/CHECKSUMS" "$base_url/CHECKSUMS"
(cd "$tmp" && grep -E "  ${asset}\$" CHECKSUMS | sha256sum -c -)

mkdir -p "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x" kubeconform
install -m 0755 "$tmp/x/kubeconform" /usr/local/bin/kubeconform

/usr/local/bin/kubeconform -v

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/kubeconform.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
