#!/usr/bin/env bash
# Docker-free tests of HOST_TYPE resolution in the bash twin
# (src/devcontainer-cli/devcontainer-cli.sh), the counterpart of the Pester tests
# 'Host type' in DevcontainerCli.Tests.ps1: explicit id, unknown id, auto and the
# priority list, an organisation list overriding the default, the DCF_HOST_*
# variables the launcher hands to the CLI, and DEVCONTAINER_DOCKER_PATH still
# naming the engine. Evidence is faked with DCF_HOST_UNAME and
# DCF_HOST_PROC_VERSION (instead of `uname -s` and /proc/version), a fake docker
# and a fake devcontainer CLI on PATH. Part of `task lint` (`task test:shutdown`).
# CLI_SH and TEMPLATE point the tests at another copy of the script (used to show a test
# fails when the code it covers is broken).
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

# A PATH with only fakes (plus the tools the script needs, linked in).
bin="$T/bin"; mkdir -p "$bin" "$T/ws" "$T/cache"
for tool in uname grep cat dirname mkdir id; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
printf '#!/bin/sh\nexit 0\n' > "$bin/docker"
# shellcheck disable=SC2016  # the fake's own $*, not ours
printf '#!/bin/sh\necho "args: $*"\necho "DCF_HOST_TYPE=${DCF_HOST_TYPE-unset}"\necho "DCF_HOST_HOME=${DCF_HOST_HOME-unset}"\necho "DCF_HOST_SSH_AGENT=${DCF_HOST_SSH_AGENT-unset}"\n' > "$bin/devcontainer"
chmod +x "$bin/docker" "$bin/devcontainer"
echo 'Linux version 6.1.0 (builder@host) (gcc) #1 SMP' > "$T/proc-linux"
echo 'Linux version 6.6.0-microsoft-standard-WSL2 (root@host) #1 SMP' > "$T/proc-wsl"

# host <os: linux|macos|wsl> [VAR=value ...] -- <script args>: runs the script in a clean environment.
host() {
  local os="$1" uname proc; shift
  case "$os" in
    macos) uname=Darwin; proc="$T/proc-linux" ;;
    wsl) uname=Linux; proc="$T/proc-wsl" ;;
    *) uname=Linux; proc="$T/proc-linux" ;;
  esac
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -i PATH="$bin" HOME=/home/tester XDG_CACHE_HOME="$T/cache" DCF_HOST_UNAME="$uname" DCF_HOST_PROC_VERSION="$proc" \
    "${envs[@]}" "$bash_bin" "$cli_sh" "$@" 2>&1
}
field() { sed -n "s/^$1 *: //p" <<<"$2"; } # field 'HOST_TYPE' "$output"

out="$(host linux -- run host)"
check 'linux: auto picks linux' linux "$(field 'HOST_TYPE' "$out")"
check 'linux: default priority' linux "$(field 'priority list' "$out")"
check 'linux: DCF_HOST_HOME is HOME' /home/tester "$(field 'DCF_HOST_HOME' "$out")"
check 'linux: DCF_HOST_SSH_AGENT is none' none "$(field 'DCF_HOST_SSH_AGENT' "$out")"
check 'linux: engine is docker' docker "$(field 'engine command' "$out")"

out="$(host macos -- run host)"
check 'macos: auto picks macos' macos "$(field 'HOST_TYPE' "$out")"
check 'macos: DCF_HOST_TYPE' macos "$(field 'DCF_HOST_TYPE' "$out")"

out="$(host wsl -- run host)"
check 'wsl (kernel string): auto picks windows-wsl-docker' windows-wsl-docker "$(field 'HOST_TYPE' "$out")"
out="$(host linux WSL_DISTRO_NAME=Debian -- run host)"
check 'wsl (WSL_DISTRO_NAME): auto picks windows-wsl-docker' windows-wsl-docker "$(field 'HOST_TYPE' "$out")"

out="$(host wsl HOST_TYPE=linux -- run host)"
check 'explicit id skips detection (linux inside WSL)' linux "$(field 'HOST_TYPE' "$out")"
check 'explicit id says so' 'HOST_TYPE set explicitly (detection skipped)' "$(field 'why' "$out")"

out="$(host linux HOST_TYPE=solaris -- run host)"
case "$out" in *"HOST_TYPE 'solaris' is unknown. Known ids: auto, windows-docker, windows-wsl-docker, windows-wslc, linux, macos"*) r=listed ;; *) r="$out" ;; esac
check 'unknown HOST_TYPE is an error listing the ids' listed "$r"
host linux HOST_TYPE=solaris -- run host >/dev/null; check 'unknown HOST_TYPE exits non-zero' 1 "$?"

out="$(host linux HOST_TYPE_PRIORITY=linux,bogus -- run host)"
case "$out" in *"HOST_TYPE_PRIORITY has an unknown host type 'bogus'. Known ids:"*) r=listed ;; *) r="$out" ;; esac
check 'unknown id in HOST_TYPE_PRIORITY is an error' listed "$r"

out="$(host linux HOST_TYPE=windows-docker -- run host)"
case "$out" in *"cannot run from this launcher"*) r=refused ;; *) r="$out" ;; esac
check 'a Windows id cannot be taken by the bash twin' refused "$r"

# Priority: auto takes the first id of the list that passes (those that do not fit are skipped).
out="$(host linux HOST_TYPE_PRIORITY=macos,linux -- run host)"
check 'priority: macos skipped on Linux, linux taken' linux "$(field 'HOST_TYPE' "$out")"
check 'priority: the list is reported' macos,linux "$(field 'priority list' "$out")"
out="$(host wsl HOST_TYPE_PRIORITY=linux,windows-wsl-docker -- run host)"
check 'org priority overrides the default (WSL: linux first)' linux "$(field 'HOST_TYPE' "$out")"
out="$(host wsl HOST_TYPE_PRIORITY='windows-wsl-docker, linux' -- run host)"
check 'org priority, spaces trimmed (WSL: windows-wsl-docker first)' windows-wsl-docker "$(field 'HOST_TYPE' "$out")"
out="$(host linux HOST_TYPE_PRIORITY=macos -- run host)"
case "$out" in *"no host type in [macos] passed"*) r=error ;; *) r="$out" ;; esac
check 'auto with nothing passing is an error naming the list' error "$r"

# DEVCONTAINER_DOCKER_PATH names the engine whatever the host type.
printf '#!/bin/sh\nexit 0\n' > "$T/podman"; chmod +x "$T/podman"
out="$(host linux DEVCONTAINER_DOCKER_PATH="$T/podman" HOST_TYPE=linux -- run host)"
check 'DEVCONTAINER_DOCKER_PATH wins for the engine' "$T/podman" "$(field 'engine command' "$out")"

# The launcher exports DCF_HOST_* to the CLI it runs, and --docker-path.
for os in linux macos wsl; do
  case "$os" in linux) want=linux ;; macos) want=macos ;; wsl) want=windows-wsl-docker ;; esac
  out="$(host "$os" -- run up --workspace-folder "$T/ws")"
  check "$os: CLI sees DCF_HOST_TYPE" "DCF_HOST_TYPE=$want" "$(grep '^DCF_HOST_TYPE=' <<<"$out")"
  check "$os: CLI sees DCF_HOST_HOME" "DCF_HOST_HOME=/home/tester" "$(grep '^DCF_HOST_HOME=' <<<"$out")"
  check "$os: CLI sees DCF_HOST_SSH_AGENT" "DCF_HOST_SSH_AGENT=none" "$(grep '^DCF_HOST_SSH_AGENT=' <<<"$out")"
done
out="$(host linux DEVCONTAINER_DOCKER_PATH="$T/podman" -- run up --workspace-folder "$T/ws")"
check 'up passes DEVCONTAINER_DOCKER_PATH as --docker-path' 1 "$(grep -c -- "--docker-path $T/podman" <<<"$out")"

# stop and running do not need a host type: an unknown HOST_TYPE does not break them.
out="$(host linux HOST_TYPE=solaris -- run running --workspace-folder "$T/ws")"
check 'running ignores the host type' '' "$(grep -c "HOST_TYPE" <<<"$out" | sed 's/^0$//')"

# The starter devcontainer.json: the launcher adds the .git-dirs mount (host-mounts), so no live
# mount line may use DCF_HOST_HOME (empty when VS Code bypasses the launcher); the commented
# fallback names the variables VS Code sees; and the three variables are mapped with containerEnv.
tpl="${TEMPLATE:-$here/../../bootstrap/devcontainer.json}"
check 'template: no .git-dirs mount line uses DCF_HOST_HOME' 0 "$(grep -F '.git-dirs,target=/git-dirs' "$tpl" | grep -c 'DCF_HOST_HOME')"
check 'template: the .git-dirs fallback is commented out' 0 "$(grep -F '.git-dirs,target=/git-dirs' "$tpl" | grep -vc '^[[:space:]]*//')"
check 'template: the fallback uses USERPROFILE (Windows host)' 1 "$(grep -F '.git-dirs,target=/git-dirs' "$tpl" | grep -c 'localEnv:USERPROFILE')"
check 'template: says plainly DCF_HOST_HOME is empty without the launcher and names HOME' 2 "$(grep -c -e 'leaves DCF_HOST_HOME empty' -e 'localEnv:HOME}' "$tpl")"
for v in DCF_HOST_TYPE DCF_HOST_HOME DCF_HOST_SSH_AGENT; do
  check "template: containerEnv maps $v" 1 "$(grep -c "^    \"$v\": \"\${localEnv:$v}\"" "$tpl")"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
