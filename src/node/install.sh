#!/usr/bin/env bash
set -euo pipefail
umask 022

node_version="${VERSION:-24.21.0}"
if [[ "$(id -u)" != "0" ]]; then
    echo "This feature must be installed as root." >&2
    exit 1
fi
if [[ ! "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must be an exact Node.js release (X.Y.Z)." >&2
    exit 1
fi

source /etc/os-release
case "$ID" in
    debian|ubuntu) ;;
    *) echo "Only Debian and Ubuntu are supported." >&2; exit 1 ;;
esac
case "$(dpkg --print-architecture)" in
    amd64) arch="x64" ;;
    arm64) arch="arm64" ;;
    *) echo "Only amd64 and arm64 are supported." >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils
rm -rf /var/lib/apt/lists/*

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
archive="node-v${node_version}-linux-${arch}.tar.xz"
url="https://nodejs.org/dist/v${node_version}"
curl --fail --show-error --silent --location --retry 3 \
    --proto '=https' --proto-redir '=https' \
    "$url/$archive" -o "$temp_dir/$archive"
curl --fail --show-error --silent --location --retry 3 \
    --proto '=https' --proto-redir '=https' \
    "$url/SHASUMS256.txt" -o "$temp_dir/SHASUMS256.txt"
(
    cd "$temp_dir"
    awk -v archive="$archive" '$2 == archive { print }' SHASUMS256.txt > checksum.txt
    [[ "$(wc -l < checksum.txt)" -eq 1 ]]
    sha256sum --check --strict checksum.txt
)

prefix="/usr/local/share/devcontainer-node"
mkdir -p "$prefix/$node_version"
tar --extract --xz --file "$temp_dir/$archive" \
    --directory "$prefix/$node_version" --strip-components=1 --no-same-owner
ln -sfnT "$prefix/$node_version" "$prefix/current"
export PATH="$prefix/current/bin:$PATH"
node --version
npm --version
