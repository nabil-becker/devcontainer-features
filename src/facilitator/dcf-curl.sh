# shellcheck shell=bash
# dcf-curl.sh: the collection's download helper, sourced (never run) by a
# Feature's install.sh, which carries a verbatim copy (`task common:sync`).
#
#   dcf_curl <curl arguments>   curl with the retry flags added; the caller's
#                               -f/-s/-S/-L/-o/-w are passed through unchanged.
#
# The retry flags: --retry 3 --retry-delay 2 --retry-connrefused, and
# --retry-all-errors when curl has it (7.71+). Plain --retry does not retry a
# TLS reset in mid-handshake ("curl: (35) ... unexpected eof") or a connection
# cut mid-transfer ("curl: (56) Recv failure"); --retry-all-errors does. An
# older curl keeps plain --retry. Support is read from curl's own help into a
# variable: a `| grep -q` would close the pipe early, curl would get SIGPIPE,
# and under pipefail the answer would be "unsupported" by luck.
# test/common/unit/dcf_curl_test.sh; `task common:curl-check` fails on a
# download that does not go through dcf_curl.

# Fills DCF_CURL_RETRY with the retry flags for the curl on PATH.
dcf_curl_retry_flags() {
  local help
  help="$(curl --help all 2>&1 || true)"
  DCF_CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused)
  case "$help" in
    *--retry-all-errors*) DCF_CURL_RETRY+=(--retry-all-errors) ;;
  esac
}

dcf_curl() {
  [ -n "${DCF_CURL_RETRY+set}" ] || dcf_curl_retry_flags
  curl "${DCF_CURL_RETRY[@]}" "$@"
}
