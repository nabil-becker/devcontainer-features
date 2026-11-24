#!/bin/bash
# shellcheck disable=SC2016  # the single-quoted bodies expand inside the inner bash
# Auto-generated scenario: the facilitator Feature alone with its default options on the base image.
# What it installs, the infrastructure up on loopback (twice: idempotent), check ready, then down.
# Run with:
#   devcontainer features test -f facilitator --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the command is installed" facilitator version
check "the command is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/facilitator)\" = root ]"
check "dirctl 1.9.1" bash -c 'dirctl version 2>&1 | grep -q "v1.9.1"'
check "slimctl 3.4.6" bash -c 'slimctl version 2>&1 | grep -q "3.4.6"'
check "slim-bindings in the bundle" bash -c 'facilitator version | grep -q "^slim-bindings: 3.4.6"'
check "the bundle is root-owned" bash -c 'test "$(stat -c %u /opt/facilitator)" = 0 && test "$(stat -c %u /opt/facilitator/python/bin/python3)" = 0'
check "its own register-engine and sign-packet" test -f /opt/facilitator/lib/registerengine/core.py
check "the conversation type" test -f /opt/facilitator/lib/types.d/facilitator.py
check "the options as installed" grep -q '^FACILITATOR_BACKEND=agntcy$' /opt/facilitator/lib/options.env
check "the Taskfile is in the go-task includes" test -f /usr/local/share/go-task/includes.d/facilitator.yml
export FACILITATOR_HOME="${FACILITATOR_HOME:-/var/lib/devcontainer-features/facilitator}"
check "infra up" facilitator infra up
check "infra up again: running, the same processes" bash -c 'a=$(cat "$FACILITATOR_HOME"/run/dir.pid "$FACILITATOR_HOME"/run/slim.pid); facilitator infra up | grep -c running | grep -qx 3 && [ "$a" = "$(cat "$FACILITATOR_HOME"/run/dir.pid "$FACILITATOR_HOME"/run/slim.pid)" ]'
check "every port on loopback" bash -c '! grep -E ":(22B8|15B3|2327|22B9|B515) " /proc/net/tcp | awk "\$4==\"0A\"" | grep -v "0100007F:"'
check "check is ready" facilitator check
check "check names the mesh: solo, standalone, nothing open" bash -c 'facilitator check | grep -q "mesh .*preset solo, role standalone" && facilitator check | grep -q "open ports .*none beyond loopback"'
check "check lints a mesh.yml (NFR-11)" bash -c 'out="$(printf "preset: wide\n" | facilitator check -)"; rc=$?; [ "$rc" = 1 ] && echo "$out" | grep -q "^-:1: bad-value: preset"'
check "node approve: only where a public domain is issued" bash -c 'env -u CLAUDECODE facilitator node approve 2>&1 | grep -q "issues no public domain"'
check "node invite only on a hub" bash -c 'env -u CLAUDECODE facilitator node invite 2>&1 | grep -q "only a hub or a peer invites"'
check "infra down" bash -c 'facilitator infra down && ! facilitator infra status >/dev/null'

reportResults
