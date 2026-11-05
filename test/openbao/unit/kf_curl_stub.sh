#!/bin/bash
# A stub curl for keyfile_test.sh, copied to $T/bin/curl: it plays the part of OpenBao's HTTP API
# that openbao-keyfile uses, as a real 2.7.2 server answers it (checked against one while this was
# written), with a small state in $STUB_DIR, so no test ever reaches a real server (the devhost's own
# listens on the default address). Every call is logged to $STUB_LOG as "curl <arguments>" (no share,
# secret id or token may ever be in one); the token of the call (read from the -K config, as the
# server would read the header) goes to $STUB_DIR/tokens.log as "<method> <path> <token or ->", the
# body to $STUB_DIR/bodies.log.
#
# State files in $STUB_DIR: inited (true|false), sealed (true|false), progress, shares (the valid
# unseal shares, one per line), cluster (the cluster id), live (live tokens, "token period" lines),
# sid (the valid secret id of the operator AppRole), renew_fail (present: every renewal is refused),
# down (present: nothing answers).
a="$*"
printf 'curl %s\n' "${a//$'\n'/\\n}" >> "$STUB_LOG"
method=GET url="" kfile="" has_data=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -K) kfile="$2"; shift ;;
    --data-binary) has_data=1; shift ;;
    http://* | https://*) url="$1" ;;
  esac
  shift
done
[ ! -e "$STUB_DIR/down" ] || { printf '\n000'; exit 7; }
tok=""
[ -z "$kfile" ] || tok="$(sed -n 's/^header = "X-Vault-Token: \(.*\)"$/\1/p' "$kfile" 2>/dev/null)"
body=""
[ "$has_data" -eq 0 ] || body="$(cat)"
path="${url#*/v1/}"
echo "$method $path ${tok:--}" >> "$STUB_DIR/tokens.log"
printf '%s\n' "$body" >> "$STUB_DIR/bodies.log"
echo "$url" >> "$STUB_DIR/urls.log"
S="$STUB_DIR"
get() { cat "$S/$1" 2>/dev/null; }
reply() { printf '%s\n%s' "$2" "$1"; exit 0; } # <code> <body>
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$body" | head -n 1; }
live() { [ -n "$tok" ] && grep -q "^$tok " "$S/live" 2>/dev/null; }
root() { [ "$tok" = s.GENROOT ] && [ -e "$S/root_live" ]; }
sealed="$(get sealed)"
inited="$(get inited)"

case "$method $path" in
  "GET sys/seal-status")
    if [ "$sealed" = false ]; then
      reply 200 "{\"type\":\"shamir\",\"initialized\":$inited,\"sealed\":false,\"t\":2,\"n\":$(get n || echo 5),\"progress\":0,\"cluster_id\":\"$(get cluster)\"}"
    fi
    reply 200 "{\"type\":\"shamir\",\"initialized\":$inited,\"sealed\":true,\"t\":2,\"n\":$(get n || echo 5),\"progress\":$(get progress || echo 0)}" ;;
  "GET sys/health")
    [ "$sealed" = false ] && reply 200 '{"initialized":true,"sealed":false,"standby":false}'
    reply 503 '{"initialized":true,"sealed":true}' ;;
  "PUT sys/unseal")
    [ "$sealed" = true ] || reply 400 '{"errors":["vault is unsealed"]}'
    if grep -q '"reset":true' <<<"$body"; then echo 0 > "$S/progress"; reply 200 '{"sealed":true,"progress":0}'; fi
    k="$(field key)"
    if ! grep -qxF "$k" "$S/shares"; then
      echo 0 > "$S/progress"
      reply 400 '{"errors":["unable to retrieve stored keys: invalid key: failed to decrypt keys from storage: cipher: message authentication failed"]}'
    fi
    n=$(($(get progress || echo 0) + 1))
    if [ "$n" -ge 2 ]; then
      echo 0 > "$S/progress"; echo false > "$S/sealed"
      reply 200 "{\"sealed\":false,\"progress\":0,\"cluster_id\":\"$(get cluster)\"}"
    fi
    echo "$n" > "$S/progress"
    reply 200 "{\"sealed\":true,\"progress\":$n}" ;;
  "PUT sys/init")
    [ "$inited" = false ] || reply 400 '{"errors":["Vault is already initialized"]}'
    echo true > "$S/inited"
    printf '%s\n' INIT1AAA INIT2BBB INIT3CCC INIT4DDD INIT5EEE > "$S/shares"
    echo 5 > "$S/n"
    touch "$S/root_live"
    reply 200 '{"keys":["a","b","c","d","e"],"keys_base64":["INIT1AAA","INIT2BBB","INIT3CCC","INIT4DDD","INIT5EEE"],"root_token":"s.GENROOT"}' ;;
  "POST auth/approle/login")
    [ "$sealed" = false ] || reply 503 '{"errors":["Vault is sealed"]}'
    if [ "$(field role_id)" = ROLEID-op1 ] && [ "$(field secret_id)" = "$(get sid)" ]; then
      n=$(($(get tokn || echo 0) + 1)); echo "$n" > "$S/tokn"
      echo "s.LOGIN$n $(get period || echo 3600)" >> "$S/live"
      reply 200 "{\"auth\":{\"client_token\":\"s.LOGIN$n\",\"accessor\":\"acc$n\",\"lease_duration\":3600,\"renewable\":true}}"
    fi
    reply 400 '{"errors":["invalid role or secret ID"]}' ;;
  "GET auth/token/lookup-self")
    live || root || reply 403 '{"errors":["permission denied"]}'
    per="$(grep "^$tok " "$S/live" 2>/dev/null | cut -d' ' -f2 | head -n 1)"
    reply 200 "{\"data\":{\"period\":${per:-0},\"ttl\":10}}" ;;
  "POST auth/token/renew-self")
    { [ ! -e "$S/renew_fail" ] && live; } || reply 403 '{"errors":["permission denied"]}'
    echo renewed >> "$S/renewals"
    reply 200 '{"auth":{"lease_duration":3}}' ;;
  "POST auth/token/revoke-self")
    if root; then rm -f "$S/root_live"; echo root >> "$S/revoked"; reply 204 ''; fi
    live || reply 403 '{"errors":["permission denied"]}'
    grep -v "^$tok " "$S/live" > "$S/live.new"; mv "$S/live.new" "$S/live"
    echo "$tok" >> "$S/revoked"
    reply 204 '' ;;
  "PUT sys/generate-root/attempt")
    [ ! -e "$S/gr.attempt" ] || reply 400 '{"errors":["root generation already in progress for this namespace"]}'
    echo 0 > "$S/gr.attempt"
    reply 200 '{"nonce":"n1","started":true,"progress":0,"required":2,"complete":false,"otp":"OTPSTUB12","otp_length":9}' ;;
  "DELETE sys/generate-root/attempt") rm -f "$S/gr.attempt"; echo cancelled >> "$S/gr.cancelled"; reply 204 '' ;;
  "PUT sys/generate-root/update")
    [ -e "$S/gr.attempt" ] || reply 400 '{"errors":["no root generation in progress"]}'
    grep -qxF "$(field key)" "$S/shares" || { rm -f "$S/gr.attempt"; reply 400 '{"errors":["root generation aborted: unable to authenticate"]}'; }
    n=$(($(get gr.attempt) + 1)); echo "$n" > "$S/gr.attempt"
    if [ "$n" -ge 2 ]; then
      rm -f "$S/gr.attempt"; touch "$S/root_live"
      reply 200 '{"nonce":"n1","started":true,"progress":2,"required":2,"complete":true,"encoded_token":"PHoXFhoHDX5m"}'
    fi
    reply 200 '{"nonce":"n1","started":true,"progress":1,"required":2,"complete":false,"encoded_token":""}' ;;
esac

# everything below needs the root token
root || reply 403 '{"errors":["permission denied"]}'
echo "$method $path" >> "$S/root.calls"
case "$method $path" in
  "GET sys/mounts/dcf") reply 200 '{"type":"kv"}' ;;
  "GET sys/auth") reply 200 '{"data":{"approle/":{},"userpass/":{},"token/":{}}}' ;;
  "PUT sys/policies/acl/"*) printf '%s' "$body" > "$S/policy.${path##*/}"; reply 204 '' ;;
  "POST auth/approle/role/operator") printf '%s' "$body" > "$S/role.operator"; reply 204 '' ;;
  "POST auth/approle/role/backup") reply 204 '' ;;
  "LIST auth/approle/role") reply 200 '{"data":{"keys":["backup","operator","scribe"]}}' ;;
  "LIST auth/approle/role/"*"/secret-id")
    r="${path#auth/approle/role/}"; r="${r%/secret-id}"
    [ -s "$S/acc.$r" ] || reply 404 '{"errors":[]}'
    reply 200 "{\"data\":{\"keys\":$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$S/acc.$r")}}" ;;
  "POST auth/approle/role/"*"/secret-id-accessor/destroy")
    r="${path#auth/approle/role/}"; r="${r%%/*}"
    grep -vxF "$(field secret_id_accessor)" "$S/acc.$r" > "$S/acc.new" 2>/dev/null; mv "$S/acc.new" "$S/acc.$r"
    reply 204 '' ;;
  "POST auth/approle/role/"*"/secret-id")
    r="${path#auth/approle/role/}"; r="${r%/secret-id}"
    n=$(($(get sidn || echo 0) + 1)); echo "$n" > "$S/sidn"
    echo "ACC-$r-$n" >> "$S/acc.$r"
    [ "$r" != operator ] || echo "SECRETID-$n" > "$S/sid"
    reply 200 "{\"data\":{\"secret_id\":\"SECRETID-$n\",\"secret_id_accessor\":\"ACC-$r-$n\"}}" ;;
  "GET auth/approle/role/"*"/role-id")
    r="${path#auth/approle/role/}"; r="${r%/role-id}"
    reply 200 "{\"data\":{\"role_id\":\"ROLEID-${r:0:2}1\"}}" ;;
  "DELETE sys/rotate/root/init") reply 204 '' ;;
  "PUT sys/rotate/root/init") echo 0 > "$S/rot"; reply 200 '{"data":{"nonce":"r1","started":true,"n":5,"t":2}}' ;;
  "PUT sys/rotate/root/update")
    [ -z "${STUB_ROTATE_FAIL:-}" ] || reply 500 '{"errors":["stub rotation failure"]}'
    grep -qxF "$(field key)" "$S/shares" || reply 400 '{"errors":["invalid key"]}'
    n=$(($(get rot) + 1)); echo "$n" > "$S/rot"
    if [ "$n" -ge 2 ]; then
      printf '%s\n' NEW1AAAA NEW2BBBB NEW3CCCC NEW4DDDD NEW5EEEE > "$S/shares"; echo 5 > "$S/n"
      reply 200 '{"data":{"complete":true,"keys_base64":["NEW1AAAA","NEW2BBBB","NEW3CCCC","NEW4DDDD","NEW5EEEE"]}}'
    fi
    reply 200 '{"data":{"complete":false,"progress":1}}' ;;
  "DELETE auth/userpass/users/operator") echo deleted > "$S/userpass.deleted"; reply 204 '' ;;
  "PUT sys/leases/revoke-prefix/"*) echo "${path#sys/leases/revoke-prefix/}" >> "$S/revoked.prefix"; reply 204 '' ;;
esac
echo "stub curl: unexpected call: $method $path" >&2
reply 404 '{"errors":["stub: no handler"]}'
