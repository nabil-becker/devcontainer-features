#!/usr/bin/env bash
# Installs Microsoft DSC v3 (https://github.com/PowerShell/DSC) into
# /opt/dsc. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): VERSION, SHA256.
#
# DSC releases ship no checksums file, but GitHub records a sha256 digest for
# every release asset. The tarball is verified against, in order: the SHA256
# option, digests.txt (pinned in this Feature), then the digest shown on the
# release page. The Releases API (api.github.com) is never called: its
# unauthenticated rate limit broke CI and a Feature build gets no token.
set -euo pipefail

# Every download goes through dcf_curl (dcf-curl.sh, the collection's retry helper, vendored from
# src/common): curl with --retry and, on curl 7.71+, --retry-all-errors.
# shellcheck source=src/dsc/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

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
  VERSION="$(dcf_curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" | sed -E 's#.*/tag/v?##')"
fi
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "dsc: could not resolve a DSC version from '$VERSION'" >&2
  exit 1
fi

asset="DSC-${VERSION}-${arch}-linux.tar.gz"
base_url="https://github.com/$repo/releases/download/v${VERSION}"

here="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$SHA256" ]; then
  # 1. Digests pinned in this Feature: no network, nothing to rate-limit.
  SHA256="$(awk -v n="$asset" '$2 == n { print $1; exit }' "$here/digests.txt" 2>/dev/null || true)"
fi
if [ -z "$SHA256" ]; then
  # 2. The release page's asset list (github.com, not api.github.com): it
  #    shows the sha256 GitHub records for each asset, and the unauthenticated
  #    API's hourly limit does not apply to it.
  page="$(dcf_curl -fsSL "https://github.com/$repo/releases/expanded_assets/v${VERSION}" || true)"
  SHA256="$(printf '%s' "$page" | grep -oE "digest for ${asset//./\\.}\"[^>]*value=\"sha256:[0-9a-fA-F]{64}" | grep -oE '[0-9a-fA-F]{64}$' | head -n1 || true)"
  if [ -z "$SHA256" ]; then
    echo "dsc: no digest for $asset in digests.txt or on the release page. Set the sha256 option explicitly." >&2
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
dcf_curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
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
  install -m 0644 "$here/taskfile.yml" "$includes_d/dsc.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
