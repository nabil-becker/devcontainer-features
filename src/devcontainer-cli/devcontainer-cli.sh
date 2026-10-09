#!/usr/bin/env bash
# Single source of the bash logic for running @devcontainers/cli on a private
# Node.js - nothing installed system-wide, nothing on PATH except the CLI.
#
#   devcontainer-cli.sh install
#       Feature build (root): Node.js + @devcontainers/cli under
#       /opt/devcontainer-cli and a /usr/local/bin/devcontainer wrapper.
#       Options from the Feature: VERSION (CLI), NODEVERSION.
#   devcontainer-cli.sh init [--force]
#       Host (Linux/macOS, run by the devcontainer:init task): make sure the
#       CLI is available - `devcontainer` on PATH when the version is
#       "latest", else a cached copy under ${XDG_CACHE_HOME:-~/.cache}/
#       devcontainer-features - and report the container engine.
#   devcontainer-cli.sh run <subcommand> --workspace-folder <dir> [--cmd-b64 <b64>] [-- <cli args...>]
#       Host: run one CLI subcommand (what every devcontainer:* task does).
#
# Host settings, same names as the PowerShell flavour and the Taskfile:
#   DEVCONTAINER_DOCKER_PATH   docker-compatible CLI for --docker-path (name
#                              on PATH or full path). Unset = docker on PATH.
#   DEVCONTAINER_NODE_VERSION  portable Node.js version (default below).
#   DEVCONTAINER_CLI_VERSION   @devcontainers/cli version (default latest).
#                              Pinning it forces the cached install even if a
#                              `devcontainer` is on PATH.
#
# Every download is verified: Node.js against nodejs.org's SHASUMS256.txt;
# the CLI comes through npm's registry with its integrity metadata.
set -euo pipefail

default_node_version="24.21.0"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-features"

die() { echo "devcontainer-cli: $*" >&2; exit 1; }

ensure_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  [ "${#missing[@]}" -gt 0 ] || return 0
  if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    die "missing ${missing[*]}; install them and retry."
  fi
}

node_platform() { # prints "<os>-<arch>" in nodejs.org naming
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in linux | darwin) ;; *) die "unsupported OS $os" ;; esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7l ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

sha256_check() { # <file> <expected-hex>
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$1" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  fi
  [ "$actual" = "$2" ] || die "SHA-256 mismatch for $1 (expected $2, got $actual)"
}

# download_node <version> <parent-dir>: verified nodejs.org build extracted
# to <parent-dir>/node-v<version>-<os>-<arch>; prints that directory.
download_node() {
  local version="$1" parent="$2" dist dir url tmp expected
  dist="node-v${version}-$(node_platform)"
  dir="$parent/$dist"
  if [ ! -x "$dir/bin/node" ]; then
    echo "Downloading portable Node.js v${version} (cached under $parent)..." >&2
    url="https://nodejs.org/dist/v${version}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/$dist.tar.gz" "$url/$dist.tar.gz"
    curl -fsSL -o "$tmp/SHASUMS256.txt" "$url/SHASUMS256.txt"
    expected="$(grep " ${dist}.tar.gz\$" "$tmp/SHASUMS256.txt" | cut -d' ' -f1)"
    [ -n "$expected" ] || die "$dist.tar.gz not found in SHASUMS256.txt"
    sha256_check "$tmp/$dist.tar.gz" "$expected"
    mkdir -p "$parent"
    tar -xzf "$tmp/$dist.tar.gz" -C "$parent"
    rm -rf "$tmp"
    [ -x "$dir/bin/node" ] || die "expected $dir/bin/node after extraction"
  fi
  printf '%s' "$dir"
}

# install_cli <node-dir> <prefix> <cli-version>: `npm install -g --prefix
# <prefix>` of @devcontainers/cli using that Node; prints the entrypoint
# <prefix>/lib/node_modules/@devcontainers/cli/devcontainer.js. Reuses an
# existing install when it already matches the requested version.
install_cli() {
  local node_dir="$1" prefix="$2" cli_version="$3" pkg_dir entry installed pkg
  pkg_dir="$prefix/lib/node_modules/@devcontainers/cli"
  entry="$pkg_dir/devcontainer.js"
  if [ -f "$entry" ]; then
    if [ "$cli_version" = latest ]; then printf '%s' "$entry"; return 0; fi
    installed="$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "$pkg_dir/package.json" | head -n1)"
    if [ "$installed" = "$cli_version" ]; then printf '%s' "$entry"; return 0; fi
    echo "Installed @devcontainers/cli is $installed; replacing with $cli_version..." >&2
  else
    echo "Installing @devcontainers/cli@$cli_version into $prefix..." >&2
  fi
  pkg="@devcontainers/cli"; [ "$cli_version" = latest ] || pkg="$pkg@$cli_version"
  mkdir -p "$prefix"
  PATH="$node_dir/bin:$PATH" npm_config_cache="${NPM_CACHE_DIR:-$HOME/.npm}" \
    npm install -g --prefix "$prefix" --no-audit --no-fund --loglevel=error "$pkg" >&2
  [ -f "$entry" ] || die "expected $entry after npm install"
  printf '%s' "$entry"
}

# ------------------------------------------------------------ install ----
mode_install() {
  [ "$(id -u)" -eq 0 ] || die "install mode must run as root (the devcontainer Feature lifecycle does this)."
  local cli_version="${VERSION:-latest}" node_version="${NODEVERSION:-$default_node_version}"
  local prefix=/opt/devcontainer-cli node_dir entry tmpcache
  ensure_tools
  rm -rf "$prefix"
  mkdir -p "$prefix"
  node_dir="$(download_node "$node_version" "$prefix")"
  mv "$node_dir" "$prefix/node"
  # npm's cache would otherwise land in /root/.npm inside the image layer.
  tmpcache="$(mktemp -d)"
  entry="$(NPM_CACHE_DIR="$tmpcache" install_cli "$prefix/node" "$prefix" "$cli_version")"
  rm -rf "$tmpcache"
  chmod -R a+rX "$prefix"
  # The npm bin shim uses `#!/usr/bin/env node`, which would need node on
  # PATH; a wrapper naming the private node explicitly does not.
  printf '#!/bin/sh\n# @devcontainers/cli on its private Node.js (installed by the devcontainer-cli Feature).\nexec "%s/node/bin/node" "%s" "$@"\n' \
    "$prefix" "$entry" > /usr/local/bin/devcontainer
  chmod 0755 /usr/local/bin/devcontainer
  /usr/local/bin/devcontainer --version
}

# --------------------------------------------------------------- host ----
resolve_docker_path() {
  local spec="${DEVCONTAINER_DOCKER_PATH:-}"
  if [ -n "$spec" ]; then
    [ "$spec" = docker ] && return 0
    if [ -x "$spec" ]; then printf '%s' "$spec"; return 0; fi
    if command -v "$spec" >/dev/null 2>&1; then command -v "$spec"; return 0; fi
    die "DEVCONTAINER_DOCKER_PATH '$spec' is neither an executable file nor a command on PATH."
  fi
  command -v docker >/dev/null 2>&1 || die 'docker is not on PATH; install a Docker-compatible engine or set DEVCONTAINER_DOCKER_PATH.'
}

# Prints the command (one element per line) that runs the devcontainer CLI.
host_cli_command() {
  local cli_version="${DEVCONTAINER_CLI_VERSION:-latest}" node_version="${DEVCONTAINER_NODE_VERSION:-$default_node_version}"
  if [ "$cli_version" = latest ] && command -v devcontainer >/dev/null 2>&1; then
    command -v devcontainer
    return 0
  fi
  ensure_tools
  local node_dir entry
  node_dir="$(download_node "$node_version" "$cache_root")"
  entry="$(install_cli "$node_dir" "$cache_root/devcontainers-cli" "$cli_version")"
  printf '%s\n%s' "$node_dir/bin/node" "$entry"
}

mode_init() {
  local engine
  [ "${1:-}" = --force ] && rm -rf "$cache_root/devcontainers-cli"
  engine="$(resolve_docker_path)"
  echo "Container engine : ${engine:-docker (on PATH)}"
  local -a cli
  mapfile -t cli < <(host_cli_command)
  echo "devcontainer CLI : $("${cli[@]}" --version) (${cli[*]})"
}

mode_run() {
  local subcommand="${1:-}"; shift || true
  [ -n "$subcommand" ] || die 'run: missing subcommand'
  local workspace='' cmd_b64=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace-folder) workspace="$2"; shift 2 ;;
      --cmd-b64) cmd_b64="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  local -a args=("$subcommand")
  case "$subcommand" in
    up | set-up | build | run-user-commands | read-configuration | outdated | upgrade | exec)
      [ -n "$workspace" ] || die 'run: --workspace-folder is required for this subcommand'
      args+=(--workspace-folder "$(cd "$workspace" && pwd)") ;;
  esac
  local engine
  engine="$(resolve_docker_path)"
  if [ -n "$engine" ]; then
    echo "Container engine: $engine" >&2
    args+=(--docker-path "$engine")
  fi
  if [ -n "$cmd_b64" ]; then
    [ "$subcommand" = exec ] || die '--cmd-b64 is only meaningful with exec'
    args+=(bash -lc "$(printf '%s' "$cmd_b64" | base64 -d)")
  else
    args+=("$@")
  fi

  local -a cli
  mapfile -t cli < <(host_cli_command)
  "${cli[@]}" "${args[@]}"
}

case "${1:-}" in
  install) shift; mode_install "$@" ;;
  init) shift; mode_init "$@" ;;
  run) shift; mode_run "$@" ;;
  *) sed -n '2,24p' "$0" >&2; exit 2 ;;
esac
