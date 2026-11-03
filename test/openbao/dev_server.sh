#!/bin/bash
# Scenario 'dev_server' (see scenarios.json): dcf-secret against a real `bao server -dev` (in
# memory, unsealed, KV v2 at `secret/`), remoteUser=vscode. This is what shows the real bao gives
# the signals the Docker-free tests (test/openbao/unit) only stub: `bao status` exit codes, the
# capabilities words, kv get and put through stdin, and a login written through the link into
# the volume. A dev server is not the server mode of a later version; it exists for this test.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:18200
root=dev-root-token
log="$(mktemp)"
bao server -dev -dev-root-token-id="$root" -dev-listen-address=127.0.0.1:18200 >"$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  bao status >/dev/null 2>&1 && break
  sleep 0.5
done

# A home with no saved login, and the Feature's setup run into a scratch state folder, so the
# checks do not depend on the order of the volume's own state.
home="$(mktemp -d)"
state="$(mktemp -d)"
as_nobody() { env -u BAO_TOKEN HOME="$home" OPENBAO_STATE_DIR="$state" "$@"; }

rc=0; as_nobody dcf-secret get ssh/x >/dev/null 2>&1 || rc=$?
check "no token is exit 12" [ "$rc" = 12 ]
rc=0; out="$(as_nobody dcf-secret status 2>/dev/null)" || rc=$?
check "status without a login is logged-out (exit 12)" [ "$rc:$out" = 12:logged-out ]

BAO_TOKEN="$root" bao secrets enable -path=dcf -version=2 kv >/dev/null

export BAO_TOKEN="$root"
rc=0; printf '%s' 'abc def' | dcf-secret put ssh/key --field private_key || rc=$?
check "put is exit 0" [ "$rc" = 0 ]
out="$(dcf-secret get ssh/key --field private_key)"
check "get returns what put stored, alone" [ "$out" = 'abc def' ]
# Two fields under one name survive two puts (merge is the default); --replace drops the others.
printf '%s' 'the-public-part' | dcf-secret put ssh/key --field public_key
check "a second put keeps the first field" [ "$(dcf-secret get ssh/key --field private_key)" = 'abc def' ]
check "and stores the second" [ "$(dcf-secret get ssh/key --field public_key)" = the-public-part ]
printf '%s' 'abc def2' | dcf-secret put ssh/key --field private_key
check "a put of an existing field replaces only that field" [ "$(dcf-secret get ssh/key --field private_key):$(dcf-secret get ssh/key --field public_key)" = 'abc def2:the-public-part' ]
printf '%s' 'only' | dcf-secret put ssh/key --field private_key --replace
check "--replace keeps the one field" [ "$(dcf-secret get ssh/key --field private_key)" = only ]
rc=0; dcf-secret get ssh/key --field public_key >/dev/null 2>&1 || rc=$?
check "--replace dropped the other field (exit 14)" [ "$rc" = 14 ]
rc=0; dcf-secret get ssh/missing >/dev/null 2>&1 || rc=$?
check "a missing secret is exit 14" [ "$rc" = 14 ]
rc=0; dcf-secret get ssh/key --field nofield >/dev/null 2>&1 || rc=$?
check "a missing field is exit 14" [ "$rc" = 14 ]
check "status is ready" [ "$(dcf-secret status)" = ready ]

printf 'path "dcf/data/ok" { capabilities = ["read"] }\n' | bao policy write dcf-ok - >/dev/null
printf '%s' 'fine' | dcf-secret put ok --field value
limited="$(bao token create -policy=dcf-ok -field=token)"
rc=0; BAO_TOKEN="$limited" dcf-secret get ssh/key >/dev/null 2>&1 || rc=$?
check "a token without the policy is exit 13" [ "$rc" = 13 ]
check "the token may read its own name" [ "$(BAO_TOKEN="$limited" dcf-secret get ok)" = fine ]
rc=0; printf 'x' | BAO_TOKEN="$limited" dcf-secret put ok --field value >/dev/null 2>&1 || rc=$?
check "a read-only token may not put (exit 13)" [ "$rc" = 13 ]
printf 'path "dcf/data/cu" { capabilities = ["create", "update"] }\n' | bao policy write dcf-cu - >/dev/null
cu="$(bao token create -policy=dcf-cu -field=token)"
rc=0; printf 'x' | BAO_TOKEN="$cu" dcf-secret put cu --field value >/dev/null 2>&1 || rc=$?
check "a token without the patch capability may not merge (exit 13, nothing written)" [ "$rc" = 13 ]
rc=0; printf 'x' | BAO_TOKEN="$cu" dcf-secret put cu --field value --replace >/dev/null 2>&1 || rc=$?
check "the same token may --replace" [ "$rc" = 0 ]
check "status denied for a name it may not read" [ "$(BAO_TOKEN="$limited" dcf-secret status ssh/key 2>/dev/null || true)" = denied ]

rc=0; BAO_TOKEN=not-a-token dcf-secret get ok >/dev/null 2>&1 || rc=$?
check "a bad token is exit 12" [ "$rc" = 12 ]

# bao login writes through the link into the volume, and the saved login is then used
unset BAO_TOKEN
as_nobody openbao-setup >/dev/null
as_nobody bao login -no-print "$root" >/dev/null
check "the home token file is still the link" [ "$(readlink "$home/.vault-token")" = "$state/token" ]
check "the login landed in the state dir" [ -s "$state/token" ]
check "dcf-secret uses the saved login" [ "$(as_nobody dcf-secret get ok)" = fine ]

rc=0; BAO_ADDR=http://127.0.0.1:1 dcf-secret get ok >/dev/null 2>&1 || rc=$?
check "a closed port is exit 10" [ "$rc" = 10 ]

# Sealed is last: a dev server cannot be unsealed again without its key.
BAO_TOKEN="$root" bao operator seal >/dev/null
rc=0; out="$(as_nobody dcf-secret get ok 2>/dev/null)" || rc=$?
check "a sealed server is exit 11 and prints nothing" [ "$rc:$out" = 11: ]
check "status says sealed" [ "$(as_nobody dcf-secret status 2>/dev/null || true)" = sealed ]

reportResults
