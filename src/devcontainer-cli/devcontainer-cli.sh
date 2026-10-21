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
#       `stop` is not a CLI subcommand: it stops the workspace's containers
#       (found by their devcontainer.local_folder label, the drive letter of a
#       Windows path matched in either case) through the engine. With
#       --cmd-b64 it first runs that check inside the container (not with
#       --force) and refuses to stop when it fails; nothing running = "already
#       stopped", exit 0.
#       `running` is not one either: silent, exit 0 when such a container runs,
#       1 when none does, 2 when the engine cannot be asked.
#       A failed `exec` says which of three things failed: the command (its
#       exit code is passed on), no running container (1), the engine (2).
#
# Host settings, same names as the PowerShell flavour and the Taskfile:
#   DEVCONTAINER_DOCKER_PATH   docker-compatible CLI for --docker-path (name
#                              on PATH or full path). Unset = docker on PATH.
#   DEVCONTAINER_NODE_VERSION  portable Node.js version (default below).
#   DEVCONTAINER_CLI_VERSION   @devcontainers/cli version (default latest).
#                              Pinning it forces the cached install even if a
#                              `devcontainer` is on PATH.
#
# Verification: the Node.js download is checked against nodejs.org's
# SHASUMS256.txt. The CLI itself is NOT: it comes through `npm install` and
# only npm's own integrity metadata protects it (no checksum, no lockfile).
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

# The folder as the CLI labels it can differ from the folder as given in the
# drive letter's case (`devcontainer up` writes c:\..., the Taskfile has C:\...)
# and the engine's label filter is case-sensitive. Prints the folder as given,
# then with the drive letter lowercased, then uppercased (only for an X:\ path;
# paths on Linux/macOS have no drive), without repeats.
workspace_variants() {
  local w="$1" rest first lo up
  printf '%s\n' "$w"
  if [[ "$w" =~ ^[A-Za-z]:[\\/] ]]; then
    rest="${w:1}"; first="${w:0:1}"
    lo="$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')"
    up="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
    [ "$lo$rest" = "$w" ] || printf '%s\n' "$lo$rest"
    [ "$up$rest" = "$w" ] || printf '%s\n' "$up$rest"
  fi
}

engine_name() { local e; e="$(resolve_docker_path)" || return 1; printf '%s' "${e:-docker}"; }

# The CLI has no stop: find the workspace's container by the label `devcontainer up`
# puts on it and stop it through the same engine. Prints the ids of the first
# folder spelling that matches (none = nothing runs); returns 2, with the engine's
# own error on stderr, when the engine cannot list containers.
running_ids() {
  local workspace="$1" engine v out
  engine="$(engine_name)" || return 2
  while IFS= read -r v; do
    out="$("$engine" ps -q --filter "label=devcontainer.local_folder=$v")" || return 2
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  done < <(workspace_variants "$workspace")
  return 0
}

engine_unreachable() {
  echo "devcontainer-cli: the container engine ($(engine_name || echo '?')) could not be reached." >&2
}

# Exit 0 when a container of the workspace runs, 1 when none does, 2 when the
# engine cannot list containers. Prints nothing on stdout.
mode_running() {
  local ids
  ids="$(running_ids "$1")" || { engine_unreachable; exit 2; }
  [ -n "$ids" ]
}

# stop <workspace> <check-b64> <force>: nothing running = "already stopped", exit 0;
# else, unless forced, the check command runs inside the container (no `up`) and
# a failure refuses the stop with its exit code; then the container(s) stop.
mode_stop() {
  local workspace="$1" check_b64="$2" force="$3" engine ids rc=0 check
  ids="$(running_ids "$workspace")" || { engine_unreachable; exit 2; }
  if [ -z "$ids" ]; then
    echo "No running devcontainer for $workspace: already stopped."
    return 0
  fi
  if [ -n "$force" ]; then
    echo "FORCE set: skipping the shutdown check."
  elif [ -n "$check_b64" ]; then
    check="$(printf '%s' "$check_b64" | base64 -d)"
    echo "Running the shutdown check ($check); if it fails the stop is refused."
    run_cli exec "$workspace" "$check_b64" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "Not stopping: the shutdown check ($check) found the problems above. Fix them (shutdown-devhost skill) or run again with FORCE=1." >&2
      exit "$rc"
    fi
  fi
  engine="$(engine_name)"
  echo "Container engine: $engine" >&2
  # shellcheck disable=SC2086  # one id per line, word splitting intended
  "$engine" stop $ids
}

# The folder as the engine and CLI should see it: a Windows drive path (Git
# Bash) as given, any other made absolute.
resolve_workspace() {
  if [[ "$1" =~ ^[A-Za-z]:[\\/] ]]; then printf '%s' "$1"; else (cd "$1" && pwd); fi
}

# run_cli <subcommand> <workspace> <cmd-b64> [cli args...]: one @devcontainers/cli
# call; returns its exit code.
run_cli() {
  local subcommand="$1" workspace="$2" cmd_b64="$3"; shift 3
  local -a args=("$subcommand")
  case "$subcommand" in
    up | set-up | build | run-user-commands | read-configuration | outdated | upgrade | exec)
      [ -n "$workspace" ] || die 'run: --workspace-folder is required for this subcommand'
      args+=(--workspace-folder "$(resolve_workspace "$workspace")") ;;
  esac
  # Only the subcommands that drive an engine take --docker-path;
  # `features ...`, `templates ...` and `outdated` reject it.
  local engine
  case "$subcommand" in
    up | set-up | build | run-user-commands | read-configuration | upgrade | exec)
      engine="$(resolve_docker_path)"
      if [ -n "$engine" ]; then
        echo "Container engine: $engine" >&2
        args+=(--docker-path "$engine")
      fi ;;
  esac
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

# A failed exec: say which of three things failed, by asking the engine.
explain_exec_failure() { # <exit code> <workspace> <command text>
  local rc="$1" workspace="$2" text="$3" ids lrc=0
  ids="$(running_ids "$workspace")" || lrc=$?
  if [ "$lrc" -ne 0 ]; then
    engine_unreachable
    exit 2
  elif [ -z "$ids" ]; then
    echo "No running devcontainer for $workspace. Start it with: task dc:start" >&2
    exit 1
  fi
  echo "The command exited with code $rc inside the devcontainer: ${text:0:80} (its output is above)." >&2
  exit "$rc"
}

mode_run() {
  local subcommand="${1:-}"; shift || true
  [ -n "$subcommand" ] || die 'run: missing subcommand'
  local workspace='' cmd_b64='' force=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace-folder) workspace="$2"; shift 2 ;;
      --cmd-b64) cmd_b64="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  case "$subcommand" in
    stop | running)
      [ -n "$workspace" ] || die "run: --workspace-folder is required for $subcommand"
      workspace="$(resolve_workspace "$workspace")"
      if [ "$subcommand" = stop ]; then mode_stop "$workspace" "$cmd_b64" "$force"; else mode_running "$workspace"; fi
      return ;;
  esac

  local rc=0
  run_cli "$subcommand" "$workspace" "$cmd_b64" "$@" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$subcommand" = exec ]; then
    local text="$*"
    [ -z "$cmd_b64" ] || text="$(printf '%s' "$cmd_b64" | base64 -d)"
    explain_exec_failure "$rc" "$(resolve_workspace "$workspace")" "$text"
  fi
  return "$rc"
}

case "${1:-}" in
  install) shift; mode_install "$@" ;;
  init) shift; mode_init "$@" ;;
  run) shift; mode_run "$@" ;;
  *) sed -n '2,30p' "$0" >&2; exit 2 ;;
esac
