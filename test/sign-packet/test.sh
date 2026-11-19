#!/bin/bash
# Auto-generated scenario: the sign-packet Feature alone with its default options on the base image.
# Run with:
#   devcontainer features test -f sign-packet --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the command is installed" sign-packet version
check "the command is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/sign-packet)\" = root ]"
check "the format is version 2" bash -c 'sign-packet version | grep -q "format v2"'
check "the Taskfile is in the go-task includes" test -f /usr/local/share/go-task/includes.d/sign-packet.yml
check "setup is never fatal" sign-packet-setup
check "check is ready" sign-packet check
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "a packet signed with the library verifies with the command" bash -c '
  set -e
  d="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N "" -C test -f "$d/key"
  python3 -I -c "
import sys; sys.path.insert(0, \"/usr/local/lib/sign-packet\")
import signpacket as sp, json, pathlib
pub = pathlib.Path(sys.argv[1] + \".pub\").read_text().split()[:2]
body = {\"v\": 2, \"reg\": \"notes\", \"as\": \"tester\", \"key\": \" \".join(pub), \"seq\": 1, \"prev\": None,
        \"saw\": [], \"at\": \"2026-11-19T00:00:00Z\", \"kind\": \"note\", \"data\": {\"text\": \"x\"}}
pathlib.Path(sys.argv[2]).write_bytes(sp.sign(body, sys.argv[1]))
" "$d/key" "$d/p.packet"
  sign-packet verify --domain notes "$d/p.packet"'

reportResults
