#!/usr/bin/env bash
# Installs the Argo CD CLI (https://argo-cd.readthedocs.io) from GitHub
# releases, verified against the release's cli_checksums.txt. Feature options
# arrive as upper-cased environment variables (see devcontainer-feature.json):
# VERSION.
set -euo pipefail

VERSION="${VERSION:-latest}"
repo="argoproj/argo-cd"

if [ "$(id -u)" -ne 0 ]; then
  echo "argocd: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends curl ca-certificates
    rm -rf /var/lib/apt/lists/*
  else
    echo "argocd: curl is required and apt-get is unavailable." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "argocd: unsupported architecture $(uname -m)" >&2
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
  echo "argocd: could not resolve an Argo CD version from '$VERSION'" >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/v${VERSION}"
asset="argocd-linux-${arch}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "argocd: downloading Argo CD CLI v${VERSION} (${asset})..."
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL -o "$tmp/cli_checksums.txt" "$base_url/cli_checksums.txt"
(cd "$tmp" && grep -E "  ${asset}\$" cli_checksums.txt | sha256sum -c -)

install -m 0755 "$tmp/$asset" /usr/local/bin/argocd

/usr/local/bin/argocd version --client --short

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/argocd.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
