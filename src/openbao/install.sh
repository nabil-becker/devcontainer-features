#!/usr/bin/env bash
# Installs the OpenBao CLI (https://openbao.org) from GitHub releases,
# verified against the release's checksums.txt. Feature options arrive as
# upper-cased environment variables (see devcontainer-feature.json): VERSION.
set -euo pipefail

VERSION="${VERSION:-latest}"
repo="openbao/openbao"

if [ "$(id -u)" -ne 0 ]; then
  echo "openbao: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
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
    echo "openbao: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "openbao: unsupported architecture $(uname -m)" >&2
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
  echo "openbao: could not resolve an OpenBao version from '$VERSION'" >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/v${VERSION}"
asset="openbao_${VERSION}_linux_${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "openbao: downloading OpenBao v${VERSION} (${asset})..."
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base_url/checksums.txt"
(cd "$tmp" && grep -E "  ${asset}\$" checksums.txt | sha256sum -c -)

mkdir -p "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x" bao
install -m 0755 "$tmp/x/bao" /usr/local/bin/bao

/usr/local/bin/bao version

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/openbao.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
