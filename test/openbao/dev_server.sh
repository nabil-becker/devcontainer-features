#!/bin/bash
# Scenario 'dev_server' (see scenarios.json): dcf-secret against a real `bao server -dev` (in
# memory, unsealed, KV v2 at `secret/`), remoteUser=vscode. This is what shows the real bao gives
# the signals the Docker-free tests (test/openbao/unit) only stub: `bao status` exit codes, the
# capabilities words, kv get and put through stdin, and a login kept by the token helper in the
# volume. A dev server is not the server mode of a later version; it exists for this test.
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
as_nobody() { env -u BAO_TOKEN HOME="$home" OPENBAO_STATE_DIR="$state" BAO_CONFIG_PATH=/usr/local/share/openbao-feature/bao-config.hcl "$@"; }

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

# bao login goes through the token helper into the state dir (the helper is the CLI's own way to
# keep the token elsewhere: its internal one writes ~/.vault-token by a rename), and the saved
# login is then used; revoking it erases it.
unset BAO_TOKEN
check "BAO_CONFIG_PATH is the Feature's, from containerEnv" [ "$BAO_CONFIG_PATH" = /usr/local/share/openbao-feature/bao-config.hcl ]
as_nobody openbao-setup >/dev/null
as_nobody bao login -no-print "$limited" >/dev/null
check "the login landed in the state dir" [ -s "$state/token" ]
check "the token file is mode 600" [ "$(stat -c %a "$state/token")" = 600 ]
check "nothing was written to the home folder" [ -z "$(ls -A "$home")" ]
check "the state dir holds the token bao was given" [ "$(cat "$state/token")" = "$limited" ]
check "dcf-secret uses the saved login" [ "$(as_nobody dcf-secret get ok)" = fine ]
check "status is ready with the saved login" [ "$(as_nobody dcf-secret status ok)" = ready ]
# bao token revoke -self revokes on the server and never calls the helper (OpenBao's token_revoke
# command only calls the API): the dead token stays stored, and dcf-secret says to log in.
as_nobody bao token revoke -self >/dev/null
check "revoke -self leaves the (now dead) token stored" [ -s "$state/token" ]
rc=0; err="$(as_nobody dcf-secret get ok 2>&1 >/dev/null)" || rc=$?
check "after the revoke dcf-secret is exit 12" [ "$rc" = 12 ]
check "with the no-login line, naming login and logout" [ "$(grep -c 'task openbao:login.*task openbao:logout' <<<"$err")" = 1 ]

# task openbao:logout revokes and erases, leaving nothing, and is no error on a dead token
again="$(bao token create -policy=dcf-ok -field=token)"
as_nobody bao login -no-print "$again" >/dev/null
check "a new login is stored" [ "$(cat "$state/token")" = "$again" ]
logout() { as_nobody task -t /usr/local/share/go-task/includes.d/openbao.yml logout; }
rc=0; logout >/dev/null 2>&1 || rc=$?
check "task openbao:logout is exit 0" [ "$rc" = 0 ]
check "logout erased the saved token" [ ! -e "$state/token" ]
rc=0; BAO_TOKEN="$again" bao token lookup >/dev/null 2>&1 || rc=$?
check "logout revoked the token on the server" [ "$rc" != 0 ]
rc=0; logout >/dev/null 2>&1 || rc=$?
check "logout again, with nothing stored, is still exit 0" [ "$rc" = 0 ]
rc=0; as_nobody dcf-secret get ok >/dev/null 2>&1 || rc=$?
check "after logout there is no login (exit 12)" [ "$rc" = 12 ]

rc=0; BAO_ADDR=http://127.0.0.1:1 dcf-secret get ok >/dev/null 2>&1 || rc=$?
check "a closed port is exit 10" [ "$rc" = 10 ]

# Sealed is last: a dev server cannot be unsealed again without its key.
BAO_TOKEN="$root" bao operator seal >/dev/null
rc=0; out="$(as_nobody dcf-secret get ok 2>/dev/null)" || rc=$?
check "a sealed server is exit 11 and prints nothing" [ "$rc:$out" = 11: ]
check "status says sealed" [ "$(as_nobody dcf-secret status 2>/dev/null || true)" = sealed ]

reportResults
