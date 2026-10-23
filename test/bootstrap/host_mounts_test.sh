#!/usr/bin/env bash
# Docker-free tests of the host mounts the bash twin (src/devcontainer-cli/devcontainer-cli.sh)
# adds to `devcontainer up` (slice 3 of the host-profile proposal), the counterpart of the Pester
# tests 'Host mounts' in DevcontainerCli.Tests.ps1: the --mount argument per host type (linux,
# macos, windows-wsl-docker), the source folder created, a mount skipped when the repository's
# devcontainer.json already declares its target (JSONC: comments, trailing commas, objects,
# --config), HOST_MOUNTS=false, no mount for build/exec/read-configuration, and what `host`
# lists. A stub `devcontainer` first on PATH records its arguments, one per line.
# Part of `task lint` (`task test:host-mounts`). CLI_SH points the tests at another copy of the
# script (used to show a test fails when the code it covers is broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cli_sh="${CLI_SH:-$here/../../src/devcontainer-cli/devcontainer-cli.sh}"
bash_bin="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

bin="$T/bin"; mkdir -p "$bin" "$T/cache"
for tool in uname grep cat dirname mkdir id awk tr sed; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
printf '#!/bin/sh\nexit 0\n' > "$bin/docker"
# shellcheck disable=SC2016  # the stub's own "$@", not ours
printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done > "$DCF_TEST_RECORD"\n' > "$bin/devcontainer"
chmod +x "$bin/docker" "$bin/devcontainer"
echo 'Linux version 6.1.0 (builder@host) (gcc) #1 SMP' > "$T/proc-linux"
echo 'Linux version 6.6.0-microsoft-standard-WSL2 (root@host) #1 SMP' > "$T/proc-wsl"

new_ws() { # <devcontainer.json text, or empty for none>: prints a fresh workspace folder
  local ws; ws="$(mktemp -d "$T/ws.XXXXXX")"; mkdir -p "$ws/.devcontainer"
  if [ -n "$1" ]; then printf '%s\n' "$1" > "$ws/.devcontainer/devcontainer.json"; fi
  printf '%s' "$ws"
}
# run <os> <workspace> [VAR=value ...] -- <script args>: out = stdout+stderr, args = recorded CLI arguments, home = fresh HOME.
run() {
  local os="$1" ws="$2" uname proc; shift 2
  case "$os" in
    macos) uname=Darwin; proc="$T/proc-linux" ;;
    wsl) uname=Linux; proc="$T/proc-wsl" ;;
    *) uname=Linux; proc="$T/proc-linux" ;;
  esac
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  home="$(mktemp -d "$T/home.XXXXXX")"
  rm -f "$T/rec"
  out="$(env -i PATH="$bin" HOME="$home" XDG_CACHE_HOME="$T/cache" DCF_HOST_UNAME="$uname" DCF_HOST_PROC_VERSION="$proc" DCF_TEST_RECORD="$T/rec" \
    "${envs[@]}" "$bash_bin" "$cli_sh" run "$1" --workspace-folder "$ws" "${@:2}" 2>&1)"
  args="$(cat "$T/rec" 2>/dev/null)"
}
mount_value() { grep -A1 -x -- '--mount' <<<"$1" | sed -n 2p; } # the argument after --mount

plain='{ "name": "plain" }'
# shellcheck disable=SC2016  # ${localEnv:...} is JSON text, not ours to expand
own='{
  // the repository own line
  "name": "https://example.invalid/not-a-comment", /* block
  comment */
  "mounts": [
    "source=${localEnv:USERPROFILE}/.git-dirs,target=/git-dirs,type=bind", // trailing comma follows
  ],
}'

# --- --mount per host type
for os in linux macos wsl; do
  ws="$(new_ws "$plain")"; run "$os" "$ws" -- up
  check "$os: up passes --mount with the home's .git-dirs" "type=bind,source=$home/.git-dirs,target=/git-dirs" "$(mount_value "$args")"
  check "$os: --mount comes after --workspace-folder, before extra arguments" 1 "$(grep -c -- '^--workspace-folder$' <<<"$args")"
  check "$os: the .git-dirs folder was created" yes "$([ -d "$home/.git-dirs" ] && echo yes || echo no)"
  check "$os: up is the first argument" up "$(head -n1 <<<"$args")"
done
ws="$(new_ws "$plain")"; run linux "$ws" -- up -- --remove-existing-container
check 'extra up flags still follow the mount' '--remove-existing-container' "$(tail -n1 <<<"$args")"

# --- skipped when the repository already mounts the target
ws="$(new_ws "$own")"; run linux "$ws" -- up
check 'configured: no --mount' 0 "$(grep -c -x -- '--mount' <<<"$args")"
check 'configured: one line says it was skipped' "host mount skipped: /git-dirs is already mounted by this repository's devcontainer.json" "$(grep 'host mount skipped' <<<"$out")"
check 'configured: the source folder is not created' no "$([ -d "$home/.git-dirs" ] && echo yes || echo no)"
ws="$(new_ws '{ "mounts": [ { "type": "bind", "source": "a", "target": "/git-dirs/" } ] }')"; run linux "$ws" -- up
check 'configured as an object with a trailing slash: skipped' 0 "$(grep -c -x -- '--mount' <<<"$args")"
ws="$(new_ws '{ "mounts": ["source=a,target=/git-dirs-other,type=bind"] }')"; run linux "$ws" -- up
check 'another target does not skip' 1 "$(grep -c -x -- '--mount' <<<"$args")"
ws="$(new_ws '{
  // "mounts": ["source=a,target=/git-dirs,type=bind"]
  "containerEnv": { "X": "target=/git-dirs" }
}')"; run linux "$ws" -- up
check 'a commented-out mount and a target outside mounts do not skip' 1 "$(grep -c -x -- '--mount' <<<"$args")"
ws="$(new_ws "$plain")"; printf '%s\n' "$own" > "$ws/other.json"; run linux "$ws" -- up -- --config "$ws/other.json"
check '--config names the file that is read' 0 "$(grep -c -x -- '--mount' <<<"$args")"
ws="$(mktemp -d "$T/ws.XXXXXX")"; run linux "$ws" -- up
check 'no devcontainer.json at all: the mount is added' 1 "$(grep -c -x -- '--mount' <<<"$args")"

# --- HOST_MOUNTS
for v in false 0 no; do
  ws="$(new_ws "$plain")"; run linux "$ws" HOST_MOUNTS="$v" -- up
  check "HOST_MOUNTS=$v: no --mount" 0 "$(grep -c -x -- '--mount' <<<"$args")"
  check "HOST_MOUNTS=$v: nothing created" no "$([ -d "$home/.git-dirs" ] && echo yes || echo no)"
done
ws="$(new_ws "$plain")"; run linux "$ws" HOST_MOUNTS=true -- up
check 'HOST_MOUNTS=true: mounts as by default' 1 "$(grep -c -x -- '--mount' <<<"$args")"

# --- only `up`
for sub in build exec read-configuration; do
  ws="$(new_ws "$plain")"; run linux "$ws" -- "$sub"
  check "$sub: no --mount" 0 "$(grep -c -x -- '--mount' <<<"$args")"
done

# --- host lists the mounts
ws="$(new_ws "$plain")"; run linux "$ws" -- host
check 'host: lists the mount it would add' "host mount (add)   : git-dirs: type=bind,source=$home/.git-dirs,target=/git-dirs" "$(grep 'host mount (add)' <<<"$out")"
check 'host: starts nothing and creates nothing' no "$([ -d "$home/.git-dirs" ] && echo yes || echo no)"
ws="$(new_ws "$own")"; run linux "$ws" -- host
check 'host: lists the mount it would skip' 'host mount (skip)  : git-dirs: /git-dirs is already mounted by devcontainer.json' "$(grep 'host mount (skip)' <<<"$out")"
ws="$(new_ws "$plain")"; run linux "$ws" HOST_MOUNTS=false -- host
check 'host: says the mounts are off' 'host mounts        : off (HOST_MOUNTS=false)' "$(grep '^host mounts' <<<"$out")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
