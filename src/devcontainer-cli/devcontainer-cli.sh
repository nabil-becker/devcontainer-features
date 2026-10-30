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
#       `prepshutdown` is the same without the stop: it runs the check and
#       stops nothing (devcontainer:prepshutdown).
#       `running` is not one either: silent, exit 0 when such a container runs,
#       1 when none does, 2 when the engine cannot be asked.
#       `host` is not one either: it prints the resolved host type, the engine
#       command, the DCF_HOST_* values and the host mounts `up` would add (and
#       those it would skip), and starts nothing (devcontainer:host).
#       `cloud-folder-login` is not one either: the cloud-folder Feature's sign-in from the
#       workstation (relay, --paste, --workstation-rclone; see "cloud-folder login" below).
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
#   HOST_TYPE, HOST_TYPE_PRIORITY  the host type (see "host type" below); the
#                              launcher sets DCF_HOST_TYPE, DCF_HOST_HOME and
#                              DCF_HOST_SSH_AGENT before it runs the CLI.
#   HOST_MOUNTS                false (or 0, no) = the launcher adds no host mounts to `up`
#                              (see "host mounts" below). Default on.
#   SSH_AGENT_MODE             key = the user opts into a signing key kept in the container
#                              (the ssh-agent Feature's key mode): DCF_HOST_SSH_AGENT=key and
#                              no agent socket is mounted. Unset = the host type decides.
#   DCF_HOST_CLOUD_FOLDER      a host folder (one a sync client keeps) that `up` bind-mounts at
#                              /mnt/cloud-folder-host, the cloud-folder Feature's host mount (its
#                              mountPoint links there); passed on to the CLI as is.
#                              Unset = no host folder, no mount.
#   DCF_HOST_MACHINE           the workstation's machine name (hostname -s), cut to letters, digits,
#                              dot, underscore and hyphen (at most 63): always set by the launcher
#                              for up and rebuild; the repository's containerEnv passes it on.
#   DCF_HOST_FUSE              1 (or true, yes, on) = the project asks for FUSE on this machine,
#                              for the cloud-folder Feature's mount mode (ADR 0031): the
#                              launcher sets DCF_HOST_FUSE_DEVICE, DCF_HOST_FUSE_CAP and
#                              DCF_HOST_FUSE_SECURITY to --device=/dev/fuse,
#                              --cap-add=SYS_ADMIN and --security-opt=apparmor=unconfined, which
#                              the repository's runArgs read with ${localEnv:...:<default>} (the
#                              CLI has no option for run arguments). Unset = no grant, and the
#                              three are removed from the CLI's environment. Never by default.
#                              Not granted when the engine is wslc (no --device, --cap-add or
#                              --security-opt option): a warning, the start goes on without.
#   DEVCONTAINER_BUILD_LOCK    0 = do not serialise image builds (below).
#   DEVCONTAINER_BUILD_LOCK_FEATURES_TEST  true = `features test` takes the
#                              lock too (default false).
#
# Builds are serialised: `up` and `build` hold an flock on
# $cache_root/build.lock while they run, and a second one prints "waiting for
# another devcontainer build to finish..." and then proceeds. Why: when the
# engine has no BuildKit build context (wslc), the CLI tags the Feature content
# image `dev_container_feature_content_temp` for every repository, so two builds
# at once overwrite each other's image ("/tmp/build-features/<feature>_N": not
# found). The kernel drops the lock when the holder dies, so a crash leaves
# nothing stale. Without flock (stock macOS) no lock is taken.
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

# dcf_curl (dcf-curl.sh, the collection's retry helper vendored from
# src/common) sits next to this script: in the Feature folder at build time,
# in host/ where the bootstrap vendors both. Loaded only when Node.js is
# downloaded, so every other verb runs without it.
load_dcf_curl() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -r "$here/dcf-curl.sh" ] || die "dcf-curl.sh is missing next to $here/devcontainer-cli.sh (re-run the bootstrap)"
  # shellcheck source=src/devcontainer-cli/dcf-curl.sh
  . "$here/dcf-curl.sh"
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
    load_dcf_curl
    dcf_curl -fsSL -o "$tmp/$dist.tar.gz" "$url/$dist.tar.gz"
    dcf_curl -fsSL -o "$tmp/SHASUMS256.txt" "$url/SHASUMS256.txt"
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

# ------------------------------------------------------------ host type ----
# HOST_TYPE says what kind of host the launcher runs on (docs/proposals/host-profile.md,
# ADR 0024); the PowerShell twin (bootstrap/host/DevcontainerCli.psm1) does the same.
#   HOST_TYPE            auto (default) or one id; an explicit id skips detection.
#   HOST_TYPE_PRIORITY   ordered comma list `auto` walks; default per OS below.
# Ids: windows-docker, windows-wsl-docker, windows-wslc, linux, macos. This
# script runs on Linux, macOS and inside a WSL distro, so only linux, macos and
# windows-wsl-docker can be chosen here; the Windows ids belong to the
# PowerShell launcher. The engine is not chosen by the host type here: docker
# on PATH, or DEVCONTAINER_DOCKER_PATH, which always wins.
# Evidence can be replaced for tests and odd hosts: DCF_HOST_UNAME (instead of
# `uname -s`), DCF_HOST_PROC_VERSION (file read instead of /proc/version).
host_type_ids='windows-docker, windows-wsl-docker, windows-wslc, linux, macos'

# host_os: prints linux, wsl (a WSL distro), macos or windows (Git Bash and kin).
host_os() {
  local u="${DCF_HOST_UNAME:-$(uname -s)}"
  case "$u" in
    Darwin) echo macos ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *)
      # UNVERIFIED on every WSL version: WSL_DISTRO_NAME set, or the kernel
      # string in /proc/version naming Microsoft.
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft "${DCF_HOST_PROC_VERSION:-/proc/version}" 2>/dev/null; then echo wsl
      else echo linux; fi ;;
  esac
}

host_type_default_priority() {
  case "$(host_os)" in
    wsl) echo windows-wsl-docker ;;
    macos) echo macos ;;
    windows) echo 'windows-docker,windows-wsl-docker,windows-wslc' ;;
    *) echo linux ;;
  esac
}

# host_type_fits <id>: can a launcher on this OS act as that host type at all.
host_type_fits() {
  local os; os="$(host_os)"
  case "$1" in
    linux) [ "$os" = linux ] || [ "$os" = wsl ] ;;
    windows-wsl-docker) [ "$os" = wsl ] ;;
    macos) [ "$os" = macos ] ;;
    *) return 1 ;;
  esac
}

host_type_known() {
  case "$1" in windows-docker | windows-wsl-docker | windows-wslc | linux | macos) return 0 ;; esac
  return 1
}

# resolve_host_type: sets HT_TYPE, HT_WHY, HT_PRIORITY (comma list). Same rules as
# the PowerShell Resolve-HostType: an explicit id skips detection; auto takes the
# first id of the priority list that passes; an unknown id is an error naming the
# valid ones. (Detection here is only "does this OS fit", so unlike the PowerShell
# launcher there is no DEVCONTAINER_DOCKER_PATH fallback for "nothing passed".)
resolve_host_type() {
  local want="${HOST_TYPE:-auto}" prio="${HOST_TYPE_PRIORITY:-}" source=HOST_TYPE_PRIORITY id notes=''
  if [ -z "$prio" ]; then prio="$(host_type_default_priority)"; source='default for this OS'; fi
  local -a ids=()
  local IFS=,
  # shellcheck disable=SC2206  # split on commas on purpose
  ids=($prio)
  IFS=$' \t\n'
  local -a clean=()
  for id in "${ids[@]}"; do
    id="${id//[[:space:]]/}"
    [ -n "$id" ] || continue
    host_type_known "$id" || die "HOST_TYPE_PRIORITY has an unknown host type '$id'. Known ids: $host_type_ids."
    clean+=("$id")
  done
  HT_PRIORITY="$(IFS=,; echo "${clean[*]}")"
  if [ "$want" != auto ]; then
    host_type_known "$want" || die "HOST_TYPE '$want' is unknown. Known ids: auto, $host_type_ids."
    host_type_fits "$want" || die "HOST_TYPE '$want' cannot run from this launcher ($(host_os)); use the PowerShell launcher on Windows. Known ids: $host_type_ids."
    HT_TYPE="$want"; HT_WHY='HOST_TYPE set explicitly (detection skipped)'
    return 0
  fi
  for id in "${clean[@]}"; do
    if host_type_fits "$id"; then
      HT_TYPE="$id"; HT_WHY="auto: first in $source to pass ($id on $(host_os))"
      return 0
    fi
    notes="$notes${notes:+; }$id: the launcher runs on $(host_os)"
  done
  die "HOST_TYPE=auto: no host type in [$HT_PRIORITY] passed. $notes. Set HOST_TYPE=<id> ($host_type_ids), or HOST_TYPE_PRIORITY."
}

# The SSH agent (docs/proposals/host-profile.md section 5): DCF_HOST_SSH_AGENT is socket (the
# launcher mounts a host socket at the ssh-agent Feature's fixed path), none (this host type
# cannot hand the agent over without a process of ours left running on the host) or key (the
# user opted into a key in the container: SSH_AGENT_MODE=key, which also suppresses the mount).
#   linux, windows-wsl-docker  $SSH_AUTH_SOCK of this launcher, when set and a socket
#   macos                      Docker Desktop's /run/host-services/ssh-auth.sock (a path inside
#                              its VM, so it cannot be checked from here)
#   windows-docker, windows-wslc  none: the Windows agent is a named pipe, and bridging it needs a
#                              host process. (windows-wsl-docker driven from Windows is the
#                              PowerShell launcher's: none; this script runs inside the distro.)
ssh_agent_target=/var/lib/devcontainer-features/ssh-agent/agent.sock

# resolve_ssh_agent: sets HT_SSH_AGENT (socket|none|key) and HT_SSH_SOCKET (the source, or empty).
resolve_ssh_agent() {
  HT_SSH_AGENT=none; HT_SSH_SOCKET=''
  if [ "${SSH_AGENT_MODE:-}" = key ]; then HT_SSH_AGENT=key; return 0; fi
  case "$HT_TYPE" in
    linux | windows-wsl-docker)
      if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then HT_SSH_AGENT=socket; HT_SSH_SOCKET="$SSH_AUTH_SOCK"; fi ;;
    macos) HT_SSH_AGENT=socket; HT_SSH_SOCKET=/run/host-services/ssh-auth.sock ;;
  esac
}

# The cloud folder (docs/proposals/cloud-folder.md, slice 1): DCF_HOST_CLOUD_FOLDER names a host
# folder that `up` bind-mounts at one fixed path, the cloud-folder Feature's host mount; the
# Feature links its mountPoint option there, so the consumer names the path once (the option).
# The user sets the variable; the launcher passes it on unchanged, for a repository's containerEnv.
# The same constant is $script:CloudFolderTarget in DevcontainerCli.psm1 and HOST_MOUNT in the
# Feature's install.sh.
cloud_folder_target=/mnt/cloud-folder-host

# resolve_cloud_folder: sets HT_CLOUD_FOLDER (the host path, or empty).
resolve_cloud_folder() { HT_CLOUD_FOLDER="${DCF_HOST_CLOUD_FOLDER:-}"; }

# FUSE on request (docs/proposals/cloud-folder.md, slice 3; ADR 0031): the cloud-folder Feature's
# mount mode needs /dev/fuse, CAP_SYS_ADMIN and an AppArmor profile that allows mount. A Feature's
# capAdd and securityOpt are static (they would reach every consumer) and `devcontainer up` has no
# option for run arguments, so the grant travels as three variables that the repository's runArgs
# read with a harmless default (a label) when they are unset: the bootstrap's devcontainer.json
# carries the three lines. Granted only when DCF_HOST_FUSE asks, never by default.
fuse_vars=(DCF_HOST_FUSE_DEVICE DCF_HOST_FUSE_CAP DCF_HOST_FUSE_SECURITY)
fuse_args=(--device=/dev/fuse --cap-add=SYS_ADMIN --security-opt=apparmor=unconfined)

# fuse_refusal: prints why this host cannot carry the grant, nothing when it can. wslc (WSL
# Containers 3.0.3: `wslc run --help`) has no --device, --cap-add or --security-opt option and
# refuses the whole run when runArgs carry one, so with the windows-wslc host type, or an engine
# command named wslc, the grant is withheld: the container starts without FUSE and the
# cloud-folder Feature's auto mode takes sync. The PowerShell twin is Get-FuseRefusal.
fuse_refusal() {
  local leaf="${DEVCONTAINER_DOCKER_PATH:-docker}"
  leaf="${leaf##*/}"; leaf="${leaf##*\\}"; leaf="${leaf%.exe}"
  if [ "${HT_TYPE:-}" = windows-wslc ] || [ "$leaf" = wslc ]; then
    echo "wslc run (WSL Containers) has no --device, --cap-add or --security-opt option, so the cloud-folder Feature's mount mode cannot run here; its auto mode takes sync"
  fi
}

# resolve_fuse: HT_FUSE_ASKED=1 when DCF_HOST_FUSE asks for FUSE (1, true, yes, on), else empty;
# HT_FUSE=1 when asked for and this host can carry the grant, else empty, with HT_FUSE_WHY
# naming the refusal. Needs HT_TYPE (resolve_host_type first).
resolve_fuse() {
  case "${DCF_HOST_FUSE:-}" in 1 | true | yes | on | TRUE | True | YES | Yes | ON | On) HT_FUSE_ASKED=1 ;; *) HT_FUSE_ASKED='' ;; esac
  HT_FUSE='' HT_FUSE_WHY=''
  [ "$HT_FUSE_ASKED" = 1 ] || return 0
  HT_FUSE_WHY="$(fuse_refusal)"
  [ -n "$HT_FUSE_WHY" ] || HT_FUSE=1
}

# fuse_run_args: the run arguments of the grant, one per line (none when not asked for).
fuse_run_args() { [ "${HT_FUSE:-}" = 1 ] || return 0; printf '%s\n' "${fuse_args[@]}"; }

# resolve_host_profile: HT_* plus HT_HOME, the SSH agent (HT_SSH_AGENT, HT_SSH_SOCKET), the
# cloud folder (HT_CLOUD_FOLDER) and the FUSE request (HT_FUSE).
resolve_host_profile() {
  resolve_host_type
  HT_HOME="${HOME:-}"
  resolve_ssh_agent
  resolve_cloud_folder
  resolve_fuse
  resolve_machine
}

# export_host_env: DCF_HOST_* into this process's environment, which the CLI inherits;
# a repository maps them into the container with containerEnv.
export_host_env() {
  resolve_host_profile
  export DCF_HOST_TYPE="$HT_TYPE" DCF_HOST_HOME="$HT_HOME" DCF_HOST_SSH_AGENT="$HT_SSH_AGENT" DCF_HOST_CLOUD_FOLDER="$HT_CLOUD_FOLDER"
  export DCF_HOST_FUSE="$HT_FUSE" DCF_HOST_MACHINE="$HT_MACHINE"
  local i
  # Set from the fixed list when asked for, removed otherwise: a value left in the user's
  # environment or .env never reaches runArgs.
  for i in 0 1 2; do
    if [ "$HT_FUSE" = 1 ]; then export "${fuse_vars[$i]}=${fuse_args[$i]}"; else unset "${fuse_vars[$i]}"; fi
  done
}

# The machine name (docs/proposals/session-names.md, slice 1): DCF_HOST_MACHINE is the
# workstation's own name, so agents' sessions can say which machine they run on. `hostname -s`
# (else `uname -n` up to the first dot; the PowerShell twin reads $env:COMPUTERNAME on Windows),
# cut to a safe set: letters, digits, dot, underscore and hyphen (anything else becomes a hyphen,
# runs collapse, no leading or trailing hyphen or dot), at most 63 characters; empty when nothing
# is left. Always the launcher's own value, never one inherited from the environment.
sanitise_machine() {
  local n="$1"
  n="${n//[^A-Za-z0-9._-]/-}"
  while [[ "$n" == *--* ]]; do n="${n//--/-}"; done
  while [[ "$n" == [-.]* ]]; do n="${n#?}"; done
  n="${n:0:63}"
  while [[ "$n" == *[-.] ]]; do n="${n%?}"; done
  printf '%s' "$n"
}
resolve_machine() {
  local raw
  raw="$(hostname -s 2>/dev/null || true)"
  [ -n "$raw" ] || { raw="$(uname -n 2>/dev/null || true)"; raw="${raw%%.*}"; }
  HT_MACHINE="$(sanitise_machine "$raw")"
}

# machine_slot_missing <workspace> [cli args...]: succeeds when the repository's devcontainer.json
# (outside comments) does not read DCF_HOST_MACHINE; fails when it does, or when there is no file.
machine_slot_missing() {
  local file text
  file="$(config_file "$@")"
  [ -n "$file" ] || return 1
  text="$(strip_jsonc < "$file")"
  # shellcheck disable=SC2016  # JSON text
  ! grep -qF -- '${localEnv:DCF_HOST_MACHINE' <<<"$text"
}

# machine_check_slot <workspace> [cli args...]: one warning, never a failure, when the repository's
# devcontainer.json lacks the DCF_HOST_MACHINE line.
machine_check_slot() {
  machine_slot_missing "$@" || return 0
  echo "The repository's devcontainer.json does not read DCF_HOST_MACHINE (\"DCF_HOST_MACHINE\": \"\${localEnv:DCF_HOST_MACHINE}\" in containerEnv): agents' session names show \"container\" for {machine} until it does. Copy the line from the bootstrap's devcontainer.json." >&2
}

# ---------------------------------------------------------- host mounts ----
# The mounts the launcher adds to `devcontainer up` (--mount type=bind,source=..,target=..),
# per host type, so a repository declares none (ADR 0024; the PowerShell twin is
# Get-HostMount). Three entries: the host home's .git-dirs at /git-dirs (slice 3), the SSH agent
# socket at the ssh-agent Feature's fixed path where the host type has one (slice 4), and the
# host folder DCF_HOST_CLOUD_FOLDER at the cloud-folder Feature's host mount when it is set.
# `up` (and so rebuild) only: `build` mounts nothing, `exec` runs in an existing container.
# A mount whose target the repository's own devcontainer.json already declares is skipped
# (one line says so); HOST_MOUNTS=false turns all of them off.

# host_mount_specs: prints "name|source|target" lines for HT_TYPE, HT_HOME, HT_SSH_SOCKET and
# HT_CLOUD_FOLDER. The ssh-agent source is a socket (or Docker Desktop's path) and the
# cloud-folder source is the user's folder: neither is ours to create.
host_mount_specs() {
  if [ -n "${HT_HOME:-}" ]; then
    case "$HT_TYPE" in
      linux | macos | windows-wsl-docker | windows-docker | windows-wslc)
        printf 'git-dirs|%s/.git-dirs|/git-dirs\n' "$HT_HOME" ;;
    esac
  fi
  if [ "${HT_SSH_AGENT:-none}" = socket ] && [ -n "${HT_SSH_SOCKET:-}" ]; then
    printf 'ssh-agent|%s|%s\n' "$HT_SSH_SOCKET" "$ssh_agent_target"
  fi
  if [ -n "${HT_CLOUD_FOLDER:-}" ]; then
    printf 'cloud-folder|%s|%s\n' "$HT_CLOUD_FOLDER" "$cloud_folder_target"
  fi
}

host_mounts_enabled() { case "${HOST_MOUNTS:-true}" in false | 0 | no) return 1 ;; esac; }

# strip_jsonc: stdin to stdout without // and /* */ comments (strings untouched).
strip_jsonc() {
  awk '{
    out = ""; n = length($0); i = 1; ins = 0
    while (i <= n) {
      c = substr($0, i, 1); d = substr($0, i, 2)
      if (blk) { if (d == "*/") { blk = 0; i += 2 } else i++; continue }
      if (ins) {
        out = out c
        if (c == "\\") { out = out substr($0, i + 1, 1); i += 2; continue }
        if (c == "\"") ins = 0
        i++; continue
      }
      if (c == "\"") { ins = 1; out = out c; i++; continue }
      if (d == "//") break
      if (d == "/*") { blk = 1; i += 2; continue }
      out = out c; i++
    }
    print out
  }'
}

# configured_mount_targets <workspace> [cli args...]: the mount targets the repository's own
# devcontainer.json declares, one per line: the file --config names, else
# .devcontainer/devcontainer.json, else .devcontainer.json. Read from the file (comments
# stripped) rather than with `devcontainer read-configuration`, which costs a second Node
# start (about 0.25-0.5 s), asks the engine (`docker ps`) and fails when the engine is
# down. Mounts a Feature declares and docker-compose files are not seen.
# config_file <workspace> [cli args...]: the repository's devcontainer.json (the file --config
# names, else .devcontainer/devcontainer.json, else .devcontainer.json), or nothing.
config_file() {
  local ws="$1"; shift
  local file='' prev='' a
  for a in "$@"; do
    case "$a" in --config=*) file="${a#--config=}" ;; *) [ "$prev" != --config ] || file="$a" ;; esac
    prev="$a"
  done
  if [ -z "$file" ]; then
    for a in .devcontainer/devcontainer.json .devcontainer.json; do
      if [ -f "$ws/$a" ]; then file="$ws/$a"; break; fi
    done
  fi
  [ -n "$file" ] && [ -f "$file" ] && printf '%s\n' "$file"
  return 0
}

# fuse_slots_missing <workspace> [cli args...]: prints the DCF_HOST_FUSE_* variables the
# repository's devcontainer.json does not read (outside comments), one per line; nothing when it
# reads all three or there is no file to read.
fuse_slots_missing() {
  local file text v
  file="$(config_file "$@")"
  [ -n "$file" ] || return 0
  text="$(strip_jsonc < "$file")"
  for v in "${fuse_vars[@]}"; do
    grep -qF -- "\${localEnv:$v" <<<"$text" || printf '%s\n' "$v"
  done
}

# fuse_check_slots <workspace> [cli args...]: when FUSE is granted, one warning if the
# repository's devcontainer.json cannot carry the grant (none when the host refuses it:
# fuse_check_refused says why).
fuse_check_slots() {
  local missing
  [ "${HT_FUSE:-}" = 1 ] || return 0
  missing="$(fuse_slots_missing "$@" | tr '\n' ' ')"
  [ -n "$missing" ] || return 0
  echo "DCF_HOST_FUSE=1, but the repository's devcontainer.json has no runArgs reading ${missing% } (\${localEnv:<name>:<default>}): FUSE does not reach the container. Copy the three runArgs lines from the bootstrap's devcontainer.json." >&2
}

# fuse_check_refused: when FUSE is asked for and this host cannot carry the grant, one warning
# naming why; the start goes on without FUSE.
fuse_check_refused() {
  [ "${HT_FUSE_ASKED:-}" = 1 ] && [ "${HT_FUSE:-}" != 1 ] || return 0
  echo "DCF_HOST_FUSE=1, but FUSE is not granted on this host ($HT_TYPE): $HT_FUSE_WHY. The container starts without it; unset DCF_HOST_FUSE in .devcontainer/.env on this machine to drop this warning." >&2
}

configured_mount_targets() {
  local ws="$1"; shift
  local file
  file="$(config_file "$ws" "$@")"
  [ -n "$file" ] || return 0
  # No "mounts" is not an error (grep exits 1): the function must not fail under set -e/pipefail.
  { strip_jsonc < "$file" | tr '\n' ' ' | grep -oE '"mounts"[[:space:]]*:[[:space:]]*\[[^]]*\]' || true; } | {
    grep -oE '((target|destination|dst)=[^,"[:space:]]+|"(target|destination)"[[:space:]]*:[[:space:]]*"[^"]+")' || true
  } | sed -E 's/^(target|destination|dst)=//; s/^"(target|destination)"[[:space:]]*:[[:space:]]*"//; s/"$//; s#(.)/+$#\1#'
}

# resolve_host_mounts <workspace> [cli args...]: sets HM_ADD and HM_SKIP (arrays of
# "name|source|target"); both empty when HOST_MOUNTS=false (HM_ENABLED=false). Needs HT_*.
resolve_host_mounts() {
  local ws="$1"; shift
  local spec target configured
  HM_ADD=(); HM_SKIP=(); HM_ENABLED=true
  host_mounts_enabled || { HM_ENABLED=false; return 0; }
  configured="$(configured_mount_targets "$ws" "$@")"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    target="${spec##*|}"
    if printf '%s\n' "$configured" | grep -qxF -- "$target"; then HM_SKIP+=("$spec"); else HM_ADD+=("$spec"); fi
  done < <(host_mount_specs)
}

# host_mount_args <workspace> [cli args...]: sets HM_ARGS to the `--mount <spec>` pairs for `up`
# (one line printed per skipped mount, the source folders created).
host_mount_args() {
  local ws="$1"; shift
  local spec name source target
  HM_ARGS=()
  resolve_host_mounts "$ws" "$@"
  for spec in ${HM_SKIP[@]+"${HM_SKIP[@]}"}; do
    echo "host mount skipped: ${spec##*|} is already mounted by this repository's devcontainer.json" >&2
  done
  for spec in ${HM_ADD[@]+"${HM_ADD[@]}"}; do
    IFS='|' read -r name source target <<<"$spec"
    case "$source" in
      *,*) echo "host mount $name skipped: the source '$source' contains a comma, which --mount cannot carry." >&2; continue ;;
    esac
    case "$name" in
      ssh-agent) ;; # a socket is not ours to create
      cloud-folder) # the user's folder: never created (an empty one would hide a wrong path)
        # Only a path of this host can be checked; another form (a Windows path) goes to the engine as is.
        case "$source" in
          /*) if [ ! -d "$source" ]; then
                echo "host mount cloud-folder skipped: DCF_HOST_CLOUD_FOLDER '$source' is not a folder on this host; the container starts without it (task cloud-folder:status says so)." >&2
                continue
              fi ;;
        esac ;;
      *) mkdir -p "$source" 2>/dev/null || echo "host mount: could not create $source" >&2 ;;
    esac
    HM_ARGS+=(--mount "type=bind,source=$source,target=$target")
  done
}

# mode_host: `task devcontainer:host`, prints the profile and starts nothing.
mode_host() { # [workspace] [cli args...]
  local engine ws="${1:-$PWD}" spec n src tgt
  shift || true
  resolve_host_profile
  engine="$(resolve_docker_path 2>&1)" || engine="(none: ${engine#devcontainer-cli: })"
  echo "HOST_TYPE          : $HT_TYPE"
  echo "why                : $HT_WHY"
  echo "priority list      : $HT_PRIORITY"
  echo "engine command     : ${engine:-${DEVCONTAINER_DOCKER_PATH:-docker}}"
  echo "DCF_HOST_TYPE      : $HT_TYPE"
  echo "DCF_HOST_HOME      : $HT_HOME"
  echo "DCF_HOST_SSH_AGENT : $HT_SSH_AGENT"
  echo "DCF_HOST_CLOUD_FOLDER: ${HT_CLOUD_FOLDER:-(unset)}"
  echo "DCF_HOST_MACHINE   : ${HT_MACHINE:-(unset)}"
  machine_check_slot "$ws" "$@" 2>&1
  if [ "${HT_FUSE:-}" = 1 ]; then
    echo "DCF_HOST_FUSE      : 1 (runArgs get: $(fuse_run_args | tr '\n' ' '| sed 's/ $//'))"
    fuse_check_slots "$ws" "$@" 2>&1
  elif [ "${HT_FUSE_ASKED:-}" = 1 ]; then
    echo "DCF_HOST_FUSE      : 1 asked for, not granted on $HT_TYPE: $HT_FUSE_WHY"
  else
    echo 'DCF_HOST_FUSE      : (unset: no FUSE grant)'
  fi
  resolve_host_mounts "$ws" "$@"
  if [ "$HM_ENABLED" = false ]; then echo 'host mounts        : off (HOST_MOUNTS=false)'; return 0; fi
  if [ $(( ${#HM_ADD[@]} + ${#HM_SKIP[@]} )) -eq 0 ]; then echo 'host mounts        : none'; return 0; fi
  for spec in ${HM_ADD[@]+"${HM_ADD[@]}"}; do
    IFS='|' read -r n src tgt <<<"$spec"; echo "host mount (add)   : $n: type=bind,source=$src,target=$tgt"
  done
  for spec in ${HM_SKIP[@]+"${HM_SKIP[@]}"}; do
    echo "host mount (skip)  : ${spec%%|*}: ${spec##*|} is already mounted by devcontainer.json"
  done
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
  local workspace="$1" check_b64="$2" force="$3" check_only="${4:-}" engine ids rc=0 check
  ids="$(running_ids "$workspace")" || { engine_unreachable; exit 2; }
  if [ -z "$ids" ]; then
    if [ -n "$check_only" ]; then echo "No running devcontainer for $workspace: nothing to check."
    else echo "No running devcontainer for $workspace: already stopped."; fi
    return 0
  fi
  if [ -n "$force" ] && [ -z "$check_only" ]; then
    echo "FORCE set: skipping the shutdown check."
  elif [ -n "$check_b64" ]; then
    check="$(printf '%s' "$check_b64" | base64 -d)"
    echo "Running the shutdown check ($check); if it fails the stop is refused."
    run_cli exec "$workspace" "$check_b64" || rc=$?
    if [ "$rc" -eq 127 ]; then
      echo "Not stopping: the shutdown check ($check) is not installed in the container (exit 127). Define it, unset STOP_CHECK to use the default resolution, or run again with FORCE=1." >&2
      exit "$rc"
    fi
    if [ "$rc" -ne 0 ]; then
      echo "Not stopping: the shutdown check ($check) found the problems above. Fix them (shutdown-devhost skill) or run again with FORCE=1." >&2
      exit "$rc"
    fi
  fi
  if [ -n "$check_only" ]; then
    echo 'The shutdown check passed (or none is defined): a stop would go ahead.'
    return 0
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
      fi
      export_host_env ;;
  esac
  # Host mounts: `up` only (and so rebuild); after export_host_env, which resolves the host profile.
  if [ "$subcommand" = up ]; then
    host_mount_args "$(resolve_workspace "$workspace")" "$@"
    args+=(${HM_ARGS[@]+"${HM_ARGS[@]}"})
    fuse_check_refused
    fuse_check_slots "$(resolve_workspace "$workspace")" "$@"
    machine_check_slot "$(resolve_workspace "$workspace")" "$@"
  fi
  if [ -n "$cmd_b64" ]; then
    [ "$subcommand" = exec ] || die '--cmd-b64 is only meaningful with exec'
    args+=(bash -lc "$(printf '%s' "$cmd_b64" | base64 -d)")
  else
    args+=("$@")
  fi

  local -a cli
  mapfile -t cli < <(host_cli_command)
  # 9>&-: the CLI and what it starts must not inherit the build lock's descriptor.
  "${cli[@]}" "${args[@]}" 9>&-
}

# Subcommands that build an image (`up` also covers `rebuild`); the others work
# on an existing container and take no lock. `features test` builds too, but
# locks only with DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=true (default false), so
# a long test run does not hold up every repository's rebuild.
builds_image() { # <subcommand> [first argument]
  case "$1" in
    up | build) return 0 ;;
    features) [ "${2:-}" = test ] && case "${DEVCONTAINER_BUILD_LOCK_FEATURES_TEST:-false}" in true | 1) return 0 ;; esac ;;
  esac
  return 1
}

# take_build_lock: flock on descriptor 9 for the rest of this process (released
# when it exits, crashed or not). No-op when DEVCONTAINER_BUILD_LOCK=0 or there is no flock.
take_build_lock() {
  [ "${DEVCONTAINER_BUILD_LOCK:-}" != 0 ] || return 0
  command -v flock > /dev/null 2>&1 || return 0
  mkdir -p "$cache_root"
  exec 9> "$cache_root/build.lock"
  if ! flock -n 9; then
    echo 'waiting for another devcontainer build to finish...' >&2
    flock 9
  fi
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

# warn_general_purpose_key <key file on this host>: warnings (never a refusal) when the key about to
# be imported looks like a general-purpose key: a default file name, or a public key that also opens
# something on this host (listed in ~/.ssh/authorized_keys, or the same as another ~/.ssh/*.pub). The
# public half is FILE.pub, or derived with `ssh-keygen -y` only for a key with no passphrase (an empty
# passphrase is given, so it never prompts; a protected key is skipped). Prints fingerprints, never key
# material.
warn_general_purpose_key() {
  local file="$1" name d pub='' blob fp='' p hit=''
  name="$(basename "$file")"
  for d in id_ed25519 id_ecdsa id_rsa id_dsa id_ed25519_sk id_ecdsa_sk; do
    if [ "$name" = "$d" ]; then
      echo "ssh-key-import: warning: $name is the default name of a general-purpose key. Import only a dedicated signing key (one key per purpose and per container, named <repo>-<container>-sign) that opens nothing else; task ssh-agent:key:new inside the container makes one that never leaves it." >&2
    fi
  done
  if [ -f "$file.pub" ]; then read -r pub < "$file.pub" || true
  elif command -v ssh-keygen >/dev/null 2>&1; then pub="$(ssh-keygen -y -P '' -f "$file" 2>/dev/null </dev/null)" || pub=''; fi
  blob="$(printf '%s\n' "$pub" | awk '{print $2}')" || blob=''
  [ -n "$blob" ] || return 0
  if command -v ssh-keygen >/dev/null 2>&1; then fp="$(printf '%s\n' "$pub" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}')" || fp=''; fi
  if [ -f "$HOME/.ssh/authorized_keys" ] && awk -v b="$blob" '{ for (i = 1; i <= NF; i++) if ($i == b) f = 1 } END { exit !f }' "$HOME/.ssh/authorized_keys"; then
    hit="appears in ~/.ssh/authorized_keys (it logs in to this host)"
  fi
  if [ -z "$hit" ]; then
    for p in "$HOME"/.ssh/*.pub; do
      [ -f "$p" ] || continue
      [ "$p" -ef "$file.pub" ] && continue
      if [ "$(awk '{print $2; exit}' "$p" || true)" = "$blob" ]; then hit="is the same key as ~/.ssh/${p##*/}"; break; fi
    done
  fi
  if [ -n "$hit" ]; then
    echo "ssh-key-import: warning: the public key of $name${fp:+ ($fp)} $hit, so it is a general-purpose key. A key that also opens GitHub, servers or other repos must not live in a container volume: import a dedicated signing key instead (registered at GitHub as a signing key only)." >&2
  fi
  return 0
}

# ssh-key-import <workspace> <key file on this host>: the opt-in key mode's one-shot import
# (task devcontainer:ssh-key-import). The key bytes go to the running container through
# `devcontainer exec` on stdin, never as an argument, into the ssh-agent Feature's key volume
# (ssh-agent-setup key-stdin; it refuses when key mode is off before reading anything), with
# the .pub beside the key when there is one; then the Feature loads the keys. Prints the
# container's lines (a fingerprint), never the key. Nothing is left running on the host.
mode_ssh_key_import() {
  local workspace="$1" file="${2:-}" name ids rc=0
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    die "ssh-key-import: FILE=<path of a private key on this host> is required, and '${file}' is not a file."
  fi
  name="$(basename "$file")"
  warn_general_purpose_key "$file"
  ids="$(running_ids "$workspace")" || { engine_unreachable; exit 2; }
  if [ -z "$ids" ]; then
    echo "No running devcontainer for $workspace. Start it with: task dc:start" >&2
    exit 1
  fi
  run_cli exec "$workspace" '' ssh-agent-setup key-stdin "$name" < "$file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ssh-key-import: the container refused or failed (exit $rc, see above). Key mode must be on there: Feature option keyMode: true, or SSH_AGENT_MODE=key at task devcontainer:up; ssh-agent-setup also needs to be installed (the ssh-agent Feature)." >&2
    exit "$rc"
  fi
  if [ -f "$file.pub" ]; then
    run_cli exec "$workspace" '' ssh-agent-setup key-stdin "$name.pub" < "$file.pub" || { echo "ssh-key-import: the .pub could not be stored (the private key was)." >&2; }
  fi
  run_cli exec "$workspace" '' ssh-agent-setup key-load || exit $?
}

# ---------------------------------------------------- cloud-folder login ----
# task cloud-folder:login from the workstation (devcontainer:cloud-folder-login): the cloud-folder
# Feature's sign-in, which runs `rclone authorize "onedrive"` in the container, reached from the
# workstation's browser. Microsoft sends the browser after the sign-in to the fixed
# http://localhost:53682/ (rclone's app registration allows only that address), which on the
# workstation does not reach the container. Three routes (the PowerShell twin is
# Invoke-CloudFolderLogin):
#   relay (default)  a listener on the workstation's 127.0.0.1:53682, for the sign-in only, relays
#                    each request into the container through `<engine> exec -i` and bash's
#                    /dev/tcp to rclone's listener there (no port mapping, no socat, nothing in
#                    devcontainer.json); the in-container login (`login --relay`) prints rclone's
#                    link, which the default browser opens; the listener closes when the login
#                    ends, fails or times out (CLOUD_FOLDER_LOGIN_TIMEOUT, default 600 s). The
#                    listener is a python3 program (bash cannot listen); without python3, or with
#                    53682 busy here, it says so and takes the paste route.
#   paste (--paste)  the in-container login on this terminal: open the sign-in address, paste the
#                    address the browser fails to open afterwards (or a token).
#   --workstation-rclone  the pinned rclone (the repository's cloud-folder rcloneVersion, else the
#                    Feature's default) fetched into the cache, verified against the release's
#                    SHA256SUMS, runs `rclone authorize "onedrive"` here; its token goes to
#                    `login --token` in the container on stdin (never an argument).
# Test hooks: DCF_CLOUD_FOLDER_LOGIN_PORT (the workstation port, default 53682),
# DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT (rclone's port in the container, default 53682),
# DCF_BROWSER (the command that opens the address), DCF_RCLONE_DOWNLOADS (default
# https://downloads.rclone.org).
# The cloud-folder Feature's rcloneVersion default; test/bootstrap/cloud_folder_login_test.sh checks
# that it matches src/cloud-folder/devcontainer-feature.json.
cf_rclone_default=1.75.2

# The relay: listens on 127.0.0.1:<port> (prints "busy" and exits 3 when it cannot, "listening"
# when it does), and for each request runs `<engine> exec -i <id> bash -c` with a script that
# opens /dev/tcp/127.0.0.1/<container port>, writes the request (made HTTP/1.0, Connection:
# close, so rclone answers and closes) and copies the answer back. Ends after <timeout> seconds,
# or when killed.
cf_relay_py='
import socket, subprocess, sys, time
port, timeout, cport, engine, cid = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
srv = socket.socket()
# Reuse past TIME_WAIT (a second sign-in soon after the first); a socket listening there still refuses.
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
except OSError:
    print("busy", flush=True)
    sys.exit(3)
srv.settimeout(0.5)
print("listening", flush=True)
script = "exec 3<>/dev/tcp/127.0.0.1/%d || exit 1; cat <&3 & cat >&3; wait" % cport
deadline = time.time() + timeout
while time.time() < deadline:
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        continue
    try:
        conn.settimeout(10)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        head = data.split(b"\r\n\r\n", 1)[0].split(b"\r\n")
        first = head[0].split(b" ")
        if len(first) < 2:
            continue
        lines = [first[0] + b" " + first[1] + b" HTTP/1.0"]
        lines += [h for h in head[1:] if h and h.split(b":", 1)[0].strip().lower() not in (b"connection", b"keep-alive")]
        lines.append(b"Connection: close")
        req = b"\r\n".join(lines) + b"\r\n\r\n"
        try:
            out = subprocess.run([engine, "exec", "-i", cid, "bash", "-c", script], input=req,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30).stdout
        except Exception:
            out = b""
        if not out:
            out = b"HTTP/1.0 502 Bad Gateway\r\nContent-Type: text/plain\r\n\r\nThe devcontainer did not answer (is task cloud-folder:login still running?).\n"
        conn.sendall(out)
    except OSError:
        pass
    finally:
        conn.close()
srv.close()
'

# open_browser <url>: the default browser, in the background; else the address is printed.
open_browser() {
  local url="$1" c
  if [ -n "${DCF_BROWSER:-}" ]; then
    # shellcheck disable=SC2086  # DCF_BROWSER is a command line, split on purpose
    $DCF_BROWSER "$url" > /dev/null 2>&1 &
    return 0
  fi
  for c in open xdg-open wslview; do
    if [ "$c" = open ] && [ "$(host_os)" != macos ]; then continue; fi
    if command -v "$c" >/dev/null 2>&1; then "$c" "$url" > /dev/null 2>&1 & return 0; fi
  done
  echo "cloud-folder-login: open this address in your browser: $url"
}

# cf_login_exec <workspace> <login args...>: the in-container login on this terminal; its exit
# code. 127 (no cloud-folder-setup) is explained.
cf_login_exec() {
  local workspace="$1" rc=0; shift
  run_cli exec "$workspace" '' cloud-folder-setup login "$@" || rc=$?
  if [ "$rc" -eq 127 ]; then
    echo "cloud-folder-login: the devcontainer has no cloud-folder-setup: add the cloud-folder Feature (1.3.0 or later) to its devcontainer.json and rebuild." >&2
  fi
  return "$rc"
}

# cf_login_relay <workspace> <container id>: the relay route (see above).
cf_login_relay() {
  local workspace="$1" id="$2" port="${DCF_CLOUD_FOLDER_LOGIN_PORT:-53682}" cport="${DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT:-53682}"
  local timeout="${CLOUD_FOLDER_LOGIN_TIMEOUT:-600}" engine dir relay first='' rc=0 i
  if ! command -v python3 >/dev/null 2>&1; then
    echo "cloud-folder-login: no python3 on this workstation for the sign-in relay; signing in by pasting the address instead."
    cf_login_exec "$workspace"
    return
  fi
  engine="$(engine_name)" || { engine_unreachable; return 2; }
  dir="$(mktemp -d)"
  python3 -I -c "$cf_relay_py" "$port" "$timeout" "$cport" "$engine" "$id" > "$dir/relay" 2>&1 &
  relay=$!
  for ((i = 0; i < 50; i++)); do
    first="$(head -n 1 "$dir/relay" 2>/dev/null || true)"
    [ -n "$first" ] && break
    kill -0 "$relay" 2>/dev/null || break
    sleep 0.1
  done
  if [ "$first" != listening ]; then
    kill "$relay" 2>/dev/null || true; wait "$relay" 2>/dev/null || true; rm -rf "$dir"
    echo "cloud-folder-login: port $port on this workstation is in use (another sign-in, or a local rclone?), so the browser's redirect cannot be relayed; signing in by pasting the address instead."
    cf_login_exec "$workspace"
    return
  fi
  echo "cloud-folder-login: relaying 127.0.0.1:$port on this workstation into the devcontainer for the sign-in (closed when it ends, at the latest after ${timeout}s)."
  local line url
  # The relay never outlives this script, whatever ends it.
  # shellcheck disable=SC2064  # expanded now on purpose: the values are fixed
  trap "kill $relay 2>/dev/null || true; rm -rf '$dir'" EXIT
  # In a list with ||, so a failing login (pipefail, errexit) still reaches the clean-up below.
  { run_cli exec "$workspace" '' env "CLOUD_FOLDER_LOGIN_TIMEOUT=$timeout" cloud-folder-setup login --relay < /dev/null | {
    opened=no
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        *'sign-in URL: http://'*)
          if [ "$opened" = no ]; then
            url="${line##*sign-in URL: }"; url="${url%%[[:space:]]*}"
            url="${url/:$cport\//:$port/}"
            echo "cloud-folder-login: opening the sign-in in your browser: $url"
            open_browser "$url"
            opened=yes
          fi ;;
      esac
    done
  }; rc="${PIPESTATUS[0]}"; } || true
  kill "$relay" 2>/dev/null || true; wait "$relay" 2>/dev/null || true; rm -rf "$dir"
  echo "cloud-folder-login: the relay on 127.0.0.1:$port is closed."
  if [ "$rc" -eq 127 ]; then
    echo "cloud-folder-login: the devcontainer has no cloud-folder-setup: add the cloud-folder Feature (1.3.0 or later) to its devcontainer.json and rebuild." >&2
  fi
  return "$rc"
}

# cf_rclone_version <workspace>: the cloud-folder rcloneVersion in the repository's
# devcontainer.json, else the Feature's default; "latest" resolves through the publisher.
cf_rclone_version() {
  local file v=''
  file="$(config_file "$1")"
  if [ -n "$file" ]; then
    v="$(strip_jsonc < "$file" | tr '\n' ' ' | grep -oE '"rcloneVersion"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/')" || v=''
  fi
  v="${v#v}"
  if [ "$v" = latest ]; then
    load_dcf_curl
    v="$(dcf_curl -fsSL "${DCF_RCLONE_DOWNLOADS:-https://downloads.rclone.org}/version.txt" | sed -n 's/^rclone v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -n 1)" || v=''
    [ -n "$v" ] || die 'cloud-folder-login: rcloneVersion latest: the publisher did not say which version that is.'
  fi
  printf '%s' "${v:-$cf_rclone_default}"
}

# cf_workstation_rclone <version>: the rclone release for this workstation in the cache
# (downloaded once, verified against the release's SHA256SUMS); prints its path.
cf_workstation_rclone() {
  local v="$1" os arch asset dir base tmp sum
  case "$(host_os)" in macos) os=osx ;; *) os=linux ;; esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "cloud-folder-login: no rclone build for $(uname -m) here (amd64, arm64)" ;;
  esac
  dir="$cache_root/rclone/v$v"
  if [ -x "$dir/rclone" ]; then printf '%s' "$dir/rclone"; return 0; fi
  asset="rclone-v$v-$os-$arch.zip"
  base="${DCF_RCLONE_DOWNLOADS:-https://downloads.rclone.org}/v$v"
  command -v unzip >/dev/null 2>&1 || die 'cloud-folder-login: unzip is needed to unpack rclone; install it and retry.'
  load_dcf_curl
  tmp="$(mktemp -d)"
  echo "cloud-folder-login: downloading rclone v$v ($asset, once; cached under $dir)..." >&2
  if ! dcf_curl -fsSL -o "$tmp/$asset" "$base/$asset" || ! dcf_curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"; then
    rm -rf "$tmp"; die "cloud-folder-login: could not download rclone v$v from $base"
  fi
  sum="$(awk -v n="$asset" '$2 == n { print $1; exit }' "$tmp/SHA256SUMS")"
  if [ -z "$sum" ]; then rm -rf "$tmp"; die "cloud-folder-login: $asset is not in the release's SHA256SUMS"; fi
  ( sha256_check "$tmp/$asset" "$sum" ) || { rm -rf "$tmp"; exit 1; }
  mkdir -p "$tmp/x" "$dir"
  unzip -q -j -o "$tmp/$asset" "rclone-v$v-$os-$arch/rclone" -d "$tmp/x" || { rm -rf "$tmp"; die "cloud-folder-login: $asset has no rclone-v$v-$os-$arch/rclone"; }
  chmod 0755 "$tmp/x/rclone" && mv -f "$tmp/x/rclone" "$dir/rclone"
  rm -rf "$tmp"
  printf '%s' "$dir/rclone"
}

# cf_login_workstation <workspace>: the --workstation-rclone route.
cf_login_workstation() {
  local workspace="$1" v rclone tmp token rc=0
  v="$(cf_rclone_version "$workspace")"
  rclone="$(cf_workstation_rclone "$v")" || exit 1
  tmp="$(umask 077; mktemp -d)"
  echo "cloud-folder-login: signing in with rclone v$v on this workstation: rclone authorize \"onedrive\" opens your browser."
  # Its notices (the link) on the terminal; its stdout, which holds the token, into a private file.
  "$rclone" authorize onedrive > "$tmp/out" || rc=$?
  token="$(awk '/^Paste the following into your remote machine --->/ { on = 1; next } /^<---End paste/ { exit } on && NF { print; exit }' "$tmp/out")"
  if [ "$rc" -ne 0 ] || [ -z "$token" ]; then
    rm -rf "$tmp"
    echo "cloud-folder-login: rclone authorize did not give a token (exit $rc; its messages are above)." >&2
    return 1
  fi
  (umask 077; printf '%s\n' "$token" > "$tmp/token")
  token=''
  echo 'cloud-folder-login: handing the token to the devcontainer (on stdin, never as an argument).'
  cf_login_exec "$workspace" --token < "$tmp/token" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# cloud-folder-login <workspace> [--paste | --workstation-rclone]: task devcontainer:cloud-folder-login.
mode_cloud_folder_login() {
  local workspace="$1" route=relay a ids; shift
  for a in "$@"; do
    case "$a" in
      --paste) route="paste" ;;
      --workstation-rclone) route=workstation ;;
      *) die "cloud-folder-login: unknown argument '$a' (--paste, --workstation-rclone)" ;;
    esac
  done
  ids="$(running_ids "$workspace")" || { engine_unreachable; exit 2; }
  if [ -z "$ids" ]; then
    echo "No running devcontainer for $workspace. Start it with: task dc:start" >&2
    exit 1
  fi
  case "$route" in
    paste) cf_login_exec "$workspace" ;;
    workstation) cf_login_workstation "$workspace" ;;
    *) cf_login_relay "$workspace" "$(head -n 1 <<<"$ids")" ;;
  esac
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

  [ "$subcommand" != host ] || { mode_host "$(resolve_workspace "${workspace:-.}")" "$@"; return; }

  if [ "$subcommand" = cloud-folder-login ]; then
    [ -n "$workspace" ] || die 'run: --workspace-folder is required for cloud-folder-login'
    mode_cloud_folder_login "$(resolve_workspace "$workspace")" "$@"
    return
  fi

  if [ "$subcommand" = ssh-key-import ]; then
    [ -n "$workspace" ] || die 'run: --workspace-folder is required for ssh-key-import'
    mode_ssh_key_import "$(resolve_workspace "$workspace")" "${1:-}"
    return
  fi

  case "$subcommand" in
    stop | prepshutdown | running)
      [ -n "$workspace" ] || die "run: --workspace-folder is required for $subcommand"
      workspace="$(resolve_workspace "$workspace")"
      case "$subcommand" in
        stop) mode_stop "$workspace" "$cmd_b64" "$force" ;;
        prepshutdown) mode_stop "$workspace" "$cmd_b64" '' check-only ;;
        *) mode_running "$workspace" ;;
      esac
      return ;;
  esac

  if builds_image "$subcommand" "${1:-}"; then take_build_lock; fi
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
