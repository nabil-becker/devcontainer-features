#!/usr/bin/env bash
# Installs @devcontainers/cli on a private Node.js (see
# devcontainer-feature.json). Feature options arrive as upper-cased
# environment variables: VERSION, NODEVERSION.
#
# @devcontainers/cli needs Node.js. Rather than putting a system-wide Node.js
# on the image (and on every user's PATH), a pinned, checksum-verified
# nodejs.org build is unpacked under /opt/devcontainer-cli/node and used only
# by the /usr/local/bin/devcontainer wrapper - the same "portable Node.js,
# nothing installed globally" approach taskfiles/devcontainer.yml uses on the
# Windows host.
set -euo pipefail

VERSION="${VERSION:-latest}"
NODEVERSION="${NODEVERSION:-24.21.0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "devcontainer-cli: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
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
    echo "devcontainer-cli: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) node_arch=x64 ;;
  aarch64 | arm64) node_arch=arm64 ;;
  armv7l) node_arch=armv7l ;;
  *)
    echo "devcontainer-cli: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

prefix=/opt/devcontainer-cli
node_dist="node-v${NODEVERSION}-linux-${node_arch}"
node_asset="${node_dist}.tar.gz"
node_url="https://nodejs.org/dist/v${NODEVERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "devcontainer-cli: downloading private Node.js v${NODEVERSION}..."
curl -fsSL -o "$tmp/$node_asset" "$node_url/$node_asset"
curl -fsSL -o "$tmp/SHASUMS256.txt" "$node_url/SHASUMS256.txt"
(cd "$tmp" && grep " ${node_asset}\$" SHASUMS256.txt | sha256sum -c -)

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$tmp/$node_asset" -C "$prefix"
mv "$prefix/$node_dist" "$prefix/node"

pkg="@devcontainers/cli"
[ "$VERSION" = "latest" ] || pkg="${pkg}@${VERSION}"
echo "devcontainer-cli: installing ${pkg}..."
# npm's own cache would otherwise land in /root/.npm inside the image layer.
PATH="$prefix/node/bin:$PATH" npm_config_cache="$tmp/npm-cache" \
  npm install -g --prefix "$prefix" --no-audit --no-fund --loglevel=error "$pkg"

entrypoint="$prefix/lib/node_modules/@devcontainers/cli/devcontainer.js"
if [ ! -f "$entrypoint" ]; then
  echo "devcontainer-cli: expected $entrypoint after npm install" >&2
  exit 1
fi
chmod -R a+rX "$prefix"

# The npm-generated bin shim uses `#!/usr/bin/env node`, which would need
# node on PATH; a wrapper that names the private node explicitly does not.
printf '#!/bin/sh\n# @devcontainers/cli on its private Node.js (installed by the devcontainer-cli Feature).\nexec "%s/node/bin/node" "%s" "$@"\n' \
  "$prefix" "$entrypoint" > /usr/local/bin/devcontainer
chmod 0755 /usr/local/bin/devcontainer

/usr/local/bin/devcontainer --version

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/devcontainer-cli.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
