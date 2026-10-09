#!/usr/bin/env bash
# Installs Microsoft DSC v3 (https://github.com/PowerShell/DSC) into
# /opt/dsc. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): VERSION, SHA256.
#
# DSC releases ship no checksums file, but GitHub records a sha256 digest for
# every release asset and exposes it through the Releases API. The tarball
# is verified against that digest, or against the SHA256 option when set
# (which also avoids the API call entirely).
set -euo pipefail

VERSION="${VERSION:-latest}"
SHA256="${SHA256:-}"
repo="PowerShell/DSC"
prefix=/opt/dsc

if [ "$(id -u)" -ne 0 ]; then
  echo "dsc: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
command -v tar >/dev/null 2>&1 || missing+=(tar)
if [ -z "$SHA256" ] && ! command -v jq >/dev/null 2>&1; then missing+=(jq); fi
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "dsc: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "dsc: unsupported architecture $(uname -m)" >&2
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
  echo "dsc: could not resolve a DSC version from '$VERSION'" >&2
  exit 1
fi

asset="DSC-${VERSION}-${arch}-linux.tar.gz"
base_url="https://github.com/$repo/releases/download/v${VERSION}"

if [ -z "$SHA256" ]; then
  auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); fi
  SHA256="$(curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases/tags/v${VERSION}" |
    jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // empty' | sed 's/^sha256://')"
  if [ -z "$SHA256" ]; then
    echo "dsc: GitHub did not return a digest for $asset (rate limited, or asset missing). Set the sha256 option explicitly." >&2
    exit 1
  fi
fi
if [[ ! "$SHA256" =~ ^[a-fA-F0-9]{64}$ ]]; then
  echo "dsc: '$SHA256' is not a sha256 hex digest" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "dsc: downloading DSC v${VERSION} (${asset})..."
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
echo "${SHA256}  $tmp/$asset" | sha256sum -c -

# Installed whole: dsc looks up its bundled resource manifests (and the
# PowerShell adapter) next to its own binary, so it must stay in one folder
# that is on PATH - devcontainer-feature.json prepends /opt/dsc.
rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$tmp/$asset" -C "$prefix"
chmod -R a+rX "$prefix"
ln -sf "$prefix/dsc" /usr/local/bin/dsc

"$prefix/dsc" --version

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/dsc.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
