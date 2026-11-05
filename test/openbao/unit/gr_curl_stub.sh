#!/bin/bash
# A stub curl for the openbao unit tests, copied to $T/bin/curl: it plays OpenBao's unauthenticated
# root-token endpoints (sys/generate-root/attempt and /update) as a real 2.7.2 server answers them on
# a listener with disable_unauthed_generate_root_endpoints = false, so no test ever reaches a real
# server (the devhost's own listens on the default address). Every call is logged to $STUB_LOG as
# "curl <arguments>" (a share must never be in one) and its body appended to $STUB_DIR/curl.stdin.
# The attempt's state is $STUB_DIR/gr.attempt (shares so far), a cancel appends to gr.cancelled.
#   STUB_GR_OFF=1     the listener has the endpoints off: every call is a 405
#   a share BADSHARE  refused (400), as the server refuses a key that does not open the store
# The one-time password is OTPSTUB12 and the encoded token decodes with it to s.GENROOT.
a="$*"
printf 'curl %s\n' "${a//$'\n'/\\n}" >> "$STUB_LOG" # one line per call (-w carries a newline)
method=GET url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    http://* | https://*) url="$1" ;;
  esac
  shift
done
body="$(cat)"
printf '%s\n' "$body" >> "$STUB_DIR/curl.stdin"
reply() { printf '%s\n%s' "$2" "$1"; exit 0; } # <code> <body>: the body, then -w's code line
[ -z "${STUB_GR_OFF:-}" ] || reply 405 '{"errors":["unsupported operation"]}'
case "$method ${url#*/v1/}" in
  "PUT sys/generate-root/attempt")
    [ ! -e "$STUB_DIR/gr.attempt" ] || reply 400 '{"errors":["root generation already in progress for this namespace"]}'
    echo 0 > "$STUB_DIR/gr.attempt"
    reply 200 '{"nonce":"n1","started":true,"progress":0,"required":2,"complete":false,"encoded_token":"","encoded_root_token":"","pgp_fingerprint":"","otp":"OTPSTUB12","otp_length":9}' ;;
  "DELETE sys/generate-root/attempt")
    rm -f "$STUB_DIR/gr.attempt"
    echo cancelled >> "$STUB_DIR/gr.cancelled"
    reply 204 '' ;;
  "PUT sys/generate-root/update")
    [ -e "$STUB_DIR/gr.attempt" ] || reply 400 '{"errors":["no root generation in progress"]}'
    grep -q '"nonce":"n1"' <<<"$body" || reply 400 '{"errors":["incorrect nonce supplied"]}'
    ! grep -q '"key":"BADSHARE"' <<<"$body" || reply 400 '{"errors":["root generation aborted: unable to authenticate"]}'
    n=$(($(cat "$STUB_DIR/gr.attempt") + 1))
    echo "$n" > "$STUB_DIR/gr.attempt"
    if [ "$n" -ge 2 ]; then
      rm -f "$STUB_DIR/gr.attempt"
      reply 200 '{"nonce":"n1","started":true,"progress":2,"required":2,"complete":true,"encoded_token":"PHoXFhoHDX5m","encoded_root_token":"PHoXFhoHDX5m","pgp_fingerprint":"","otp":"","otp_length":0}'
    fi
    reply 200 '{"nonce":"n1","started":true,"progress":1,"required":2,"complete":false,"encoded_token":"","encoded_root_token":"","pgp_fingerprint":"","otp":"","otp_length":0}' ;;
esac
echo "stub curl: unexpected call: $method $url" >&2
exit 99
