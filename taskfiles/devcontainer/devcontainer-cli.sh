#!/usr/bin/env bash
# Linux/macOS flavour of Invoke-DevcontainerCli.ps1 - the devcontainer:* tasks
# in ../devcontainer.yml call this on those platforms and the PowerShell on
# Windows. Same settings, same environment variables:
#
#   DEVCONTAINER_DOCKER_PATH   docker-compatible CLI for --docker-path (name on
#                              PATH or full path). Unset = docker on PATH.
#   DEVCONTAINER_NODE_VERSION  portable Node.js used when no `devcontainer` is
#                              on PATH (default below).
#   DEVCONTAINER_CLI_VERSION   @devcontainers/cli version (default latest).
#                              Pinning it forces the portable install even if
#                              a `devcontainer` is on PATH.
#
# Usage:
#   devcontainer-cli.sh init [--force]
#   devcontainer-cli.sh run <subcommand> --workspace-folder <dir> [--cmd-b64 <b64>] [-- <cli args...>]
#
# Nothing is installed system-wide: a sha256-verified nodejs.org build and the
# CLI are cached under ${XDG_CACHE_HOME:-~/.cache}/devcontainer-features.
set -euo pipefail

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/devcontainer-features"
node_version="${DEVCONTAINER_NODE_VERSION:-24.21.0}"
cli_version="${DEVCONTAINER_CLI_VERSION:-latest}"

die() { echo "devcontainer-cli: $*" >&2; exit 1; }

sha256_check() { # <file> <expected-hex>
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$1" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  fi
  [ "$actual" = "$2" ] || die "SHA-256 mismatch for $1 (expected $2, got $actual)"
}

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

portable_node_dir() {
  local os arch dist dir url tmp expected
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in linux | darwin) ;; *) die "unsupported OS $os" ;; esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  dist="node-v${node_version}-${os}-${arch}"
  dir="$cache_root/$dist"
  if [ ! -x "$dir/bin/node" ]; then
    echo "Downloading portable Node.js v${node_version} (one-time; cached under $cache_root)..." >&2
    url="https://nodejs.org/dist/v${node_version}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/$dist.tar.gz" "$url/$dist.tar.gz"
    curl -fsSL -o "$tmp/SHASUMS256.txt" "$url/SHASUMS256.txt"
    expected="$(grep " ${dist}.tar.gz\$" "$tmp/SHASUMS256.txt" | cut -d' ' -f1)"
    [ -n "$expected" ] || die "$dist.tar.gz not found in SHASUMS256.txt"
    sha256_check "$tmp/$dist.tar.gz" "$expected"
    mkdir -p "$cache_root"
    tar -xzf "$tmp/$dist.tar.gz" -C "$cache_root"
    rm -rf "$tmp"
    [ -x "$dir/bin/node" ] || die "expected $dir/bin/node after extraction"
  fi
  printf '%s' "$dir"
}

cli_entrypoint() { # prints path to devcontainer.js, installing if needed
  local node_dir cli_dir pkg_dir entry installed pkg
  node_dir="$(portable_node_dir)"
  cli_dir="$cache_root/devcontainers-cli"
  pkg_dir="$cli_dir/node_modules/@devcontainers/cli"
  entry="$pkg_dir/devcontainer.js"
  if [ -f "$entry" ]; then
    if [ "$cli_version" = latest ]; then printf '%s' "$entry"; return 0; fi
    installed="$(sed -nE 's/.*"version": *"([^"]+)".*/\1/p' "$pkg_dir/package.json" | head -n1)"
    if [ "$installed" = "$cli_version" ]; then printf '%s' "$entry"; return 0; fi
    echo "Cached @devcontainers/cli is $installed; replacing with $cli_version..." >&2
  else
    echo "Installing @devcontainers/cli@$cli_version (one-time; cached at $cli_dir)..." >&2
  fi
  pkg="@devcontainers/cli"; [ "$cli_version" = latest ] || pkg="$pkg@$cli_version"
  mkdir -p "$cli_dir"
  PATH="$node_dir/bin:$PATH" npm install --prefix "$cli_dir" --no-save --no-audit --no-fund --loglevel=error "$pkg" >&2
  [ -f "$entry" ] || die "expected $entry after npm install"
  printf '%s' "$entry"
}

# Prints the command (as separate lines) that runs the devcontainer CLI.
cli_command() {
  if [ "$cli_version" = latest ] && command -v devcontainer >/dev/null 2>&1; then
    command -v devcontainer
  else
    local entry
    entry="$(cli_entrypoint)"
    printf '%s\n%s' "$(portable_node_dir)/bin/node" "$entry"
  fi
}

cmd_init() {
  local force=false engine
  [ "${1:-}" = --force ] && force=true
  engine="$(resolve_docker_path)"
  echo "Container engine : ${engine:-docker (on PATH)}"
  if $force; then rm -rf "$cache_root/devcontainers-cli"; fi
  local -a cli
  mapfile -t cli < <(cli_command)
  echo "devcontainer CLI : $("${cli[@]}" --version) (${cli[*]})"
}

cmd_run() {
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
  mapfile -t cli < <(cli_command)
  "${cli[@]}" "${args[@]}"
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  run) shift; cmd_run "$@" ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
