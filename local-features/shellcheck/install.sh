#!/usr/bin/env bash
# Installs shellcheck from the release asset, verified against a pinned SHA-256.
# Feature options arrive as upper-cased environment variables: VERSION.
#
# Why not the devcontainers-extra Feature: it asks the GitHub API about the release
# without a token, and from a shared CI runner IP that fails with HTTP 403 rate limit
# exceeded. An asset download is not an API call.
#
# To bump: download both tar.xz assets of the release, take the SHA-256 from the release's
# asset digests (gh api repos/koalaman/shellcheck/releases/tags/v<version>) and compare it
# with sha256sum of your download, then add the two lines to the table below and change the
# version in both .devcontainer configs. `task lint:toolchain` checks the table has the pin.
set -euo pipefail

# shellcheck source=local-features/shellcheck/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

VERSION="${VERSION:-0.11.0}"
VERSION="${VERSION#v}"

if [ "$(id -u)" -ne 0 ]; then
  echo "shellcheck: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "shellcheck: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

# SHA-256 of shellcheck-v<version>.linux.<arch>.tar.xz (the table the drift check reads).
case "${VERSION}/${arch}" in
  0.11.0/x86_64) want=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
  0.11.0/aarch64) want=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
  *)
    echo "shellcheck: no pinned checksum for ${VERSION} on ${arch}; add it to install.sh" >&2
    exit 1
    ;;
esac

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
command -v tar >/dev/null 2>&1 || missing+=(tar)
command -v xz >/dev/null 2>&1 || missing+=(xz-utils)
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "shellcheck: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

asset="shellcheck-v${VERSION}.linux.${arch}.tar.xz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "shellcheck: downloading v${VERSION} (${asset})..."
dcf_curl -fsSL -o "$tmp/$asset" "https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${asset}"
echo "${want}  ${tmp}/${asset}" | sha256sum -c -

tar -xJf "$tmp/$asset" -C "$tmp"
install -m 0755 "$tmp/shellcheck-v${VERSION}/shellcheck" /usr/local/bin/shellcheck
/usr/local/bin/shellcheck --version
