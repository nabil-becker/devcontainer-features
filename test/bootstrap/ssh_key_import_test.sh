#!/usr/bin/env bash
# Docker-free tests of `ssh-key-import` in the bash twin (src/devcontainer-cli/devcontainer-cli.sh), the
# counterpart of the Pester tests 'ssh-key-import' in DevcontainerCli.Tests.ps1: the key file of the host
# reaches `devcontainer exec` on stdin and never in its arguments, the .pub follows when it exists, the
# Feature's key load runs last, and the refusals (no file, no running container, the container refusing
# because key mode is off) are clear and start nothing else. A stub `devcontainer` records each call's
# arguments and stdin; a stub `docker` answers `ps -q`. Part of `task lint` (`task test:ssh-key-import`).
# CLI_SH points the tests at another copy of the script (used to show a test fails when the code is broken).
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

bin="$T/bin"; mkdir -p "$bin" "$T/cache" "$T/ws" "$T/calls"
for tool in uname grep cat dirname mkdir id awk tr sed basename env ls; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
# docker: `ps -q` prints a container id when $DCF_TEST_RUNNING is 1.
# shellcheck disable=SC2016  # the stub's own variables
printf '#!/bin/sh\n[ "$1" = ps ] && [ "${DCF_TEST_RUNNING:-}" = 1 ] && echo abc123\nexit 0\n' > "$bin/docker"
# devcontainer: call N's arguments (one per line) and stdin; exit 1 on the key-stdin call when DCF_TEST_REFUSE=1.
# shellcheck disable=SC2016
printf '#!/bin/sh\nn=$(ls "$DCF_TEST_CALLS" | grep -c args)\nfor a in "$@"; do echo "$a"; done > "$DCF_TEST_CALLS/$n.args"\ncat > "$DCF_TEST_CALLS/$n.stdin"\ncase "$*" in *key-stdin*) [ "${DCF_TEST_REFUSE:-}" = 1 ] && { echo "ssh-agent: key mode is off in this container" >&2; exit 1; } ;; esac\nexit 0\n' > "$bin/devcontainer"
chmod +x "$bin/docker" "$bin/devcontainer"
echo 'Linux version 6.1.0 (builder@host) (gcc) #1 SMP' > "$T/proc-linux"

secret='SECRET-KEY-BYTES-0123456789'
# The marker lines are built, so no private-key-looking block sits in the repository (the secrets guard).
begin='-----BEGIN OPENSSH '"PRIVATE KEY-----"
end='-----END OPENSSH '"PRIVATE KEY-----"
printf '%s\n%s\n%s\n' "$begin" "$secret" "$end" > "$T/id_test"
printf 'ssh-ed25519 AAAAPUBLIC test\n' > "$T/id_test.pub"
printf '%s\n%s\n%s\n' "$begin" "$secret" "$end" > "$T/id_nopub"

# imp <file> [VAR=value ...]: out = stdout+stderr, rc = exit status, calls recorded in $T/calls.
imp() {
  local f="$1"; shift
  rm -f "$T/calls"/*
  out="$(env -i PATH="$bin" HOME="$T" XDG_CACHE_HOME="$T/cache" DCF_HOST_UNAME=Linux DCF_HOST_PROC_VERSION="$T/proc-linux" \
    DCF_TEST_CALLS="$T/calls" "$@" "$bash_bin" "$cli_sh" run ssh-key-import --workspace-folder "$T/ws" -- "$f" 2>&1 </dev/null)"
  rc=$?
  ncalls="$(find "$T/calls" -name '*.args' | wc -l)"
}

imp "$T/id_test" DCF_TEST_RUNNING=1
check 'import exits 0' 0 "$rc"
check 'three exec calls: the key, the .pub, the load' 3 "$ncalls"
check 'call 0 is an exec of ssh-agent-setup key-stdin with the file name' 'exec --workspace-folder '"$T/ws"' ssh-agent-setup key-stdin id_test' "$(tr '\n' ' ' < "$T/calls/0.args" | sed 's/ *$//')"
check 'the key bytes reached stdin of call 0' "$(cat "$T/id_test")" "$(cat "$T/calls/0.stdin")"
check 'call 1 stores the .pub through stdin' 'ssh-agent-setup key-stdin id_test.pub' "$(tail -n 3 "$T/calls/1.args" | tr '\n' ' ' | sed 's/ *$//')"
check 'the .pub reached stdin of call 1' "$(cat "$T/id_test.pub")" "$(cat "$T/calls/1.stdin")"
check 'call 2 is the Feature key load' 'ssh-agent-setup key-load' "$(tail -n 2 "$T/calls/2.args" | tr '\n' ' ' | sed 's/ *$//')"
check 'the key never appears in any argument' 0 "$(grep -c -F "$secret" "$T/calls"/*.args | awk -F: '{s+=$2} END {print s+0}')"
check 'the key never appears in the output' 0 "$(grep -c -F "$secret" <<<"$out")"

imp "$T/id_nopub" DCF_TEST_RUNNING=1
check 'a key with no .pub beside it: two calls' 2 "$ncalls"

imp "$T/missing" DCF_TEST_RUNNING=1
check 'a missing file is refused' 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check 'the refusal names FILE' 1 "$(grep -c 'FILE=<path of a private key on this host>' <<<"$out")"
check 'nothing was started for a missing file' 0 "$ncalls"

imp "$T/id_test"
check 'no running container is refused with exit 1' 1 "$rc"
check 'it says how to start it' 1 "$(grep -c 'task dc:start' <<<"$out")"
check 'no exec was attempted' 0 "$ncalls"

imp "$T/id_test" DCF_TEST_RUNNING=1 DCF_TEST_REFUSE=1
check 'a container that refuses fails the import' 1 "$rc"
check 'the message says key mode must be on' 1 "$(grep -c 'keyMode: true' <<<"$out")"
check 'after a refusal neither the .pub nor the load runs' 1 "$ncalls"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
