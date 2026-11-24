#!/usr/bin/env bash
# registry-source-http: the component registry's `http` source. A layer is one .layer file served
# over HTTP(S) (a REST endpoint, a static site, a raw file in a code host). Review and release are
# the endpoint owner's; the registry only pins what to read and how to log in. No manifest and no
# signature are required. Installed on PATH by the component-registry Feature; dcf-registry calls it.
#
#   registry-source-http fetch <layer> <dest> url=<url> [allow-insecure=true] [auth.*=...]
#                                         the file into <dest>/<name> (the URL's last path
#                                         segment when it ends in .layer, else <layer>.layer)
#   registry-source-http version <layer> url=<url> [...]
#                                         the ETag, else the Last-Modified, else a hash of the body
#   registry-source-http supports         the verbs it implements
#
# The smallest safe form: one .layer file, at most 1 MiB. An archive (.tar.gz, .zip) and @file
# siblings are not read: unpacking untrusted archives is a risk this release does not take.
#
# Log-in: auth.type=none (the default without a secret: an open endpoint, the layer owner's
# choice), bearer (Authorization: Bearer), header (auth.header names it; the secret is its value)
# or basic (auth.user, auth.secret). auth.secret is read with dcf-secret (the openbao Feature) and
# handed to curl as a config on its standard input, never an argument, never a file, never logged.
# A secret is never sent over plain http:// unless allow-insecure=true is set on the source (plain
# http sends it in the clear); with a secret redirects are not followed, so it never goes to
# another host. Without a secret, at most 3 redirects. Timeouts: 10 s to connect, 60 s in all.
# Without dcf-secret on PATH the source says so and goes on without a secret.
#
# Test hooks: REGISTRY_SOURCE_HTTP_MAX_TIME, REGISTRY_SOURCE_HTTP_CONNECT_TIMEOUT (seconds).
#
# Exit: 0 done, 1 failed (unreachable, 4xx/5xx, too large, no curl), 2 bad use, 3 not supported.
set -uo pipefail

die() { local rc="$1"; shift; printf 'registry-source-http: %s\n' "$*" >&2; exit "$rc"; }

# shellcheck source=src/component-registry/dcf-curl.sh
. "${COMPONENT_REGISTRY_SHARE_DIR:-/usr/local/share/component-registry-feature}/dcf-curl.sh" 2>/dev/null ||
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dcf-curl.sh" 2>/dev/null ||
  die 1 "dcf-curl.sh is not installed (reinstall the component-registry Feature)"

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  supports) printf 'fetch\nversion\nsupports\n'; exit 0 ;;
  fetch) [ $# -ge 2 ] || die 2 "usage: fetch <layer> <dest> url=<url>"; layer="$1" dest="$2"; shift 2 ;;
  version) [ $# -ge 1 ] || die 2 "usage: version <layer> url=<url>"; layer="$1"; shift ;;
  '') die 2 "usage: registry-source-http fetch|version|supports ..." ;;
  *) die 3 "verb '$verb' is not supported (fetch, version, supports)" ;;
esac

url='' atype='' auser='' aheader='' asecret='' insecure=false
for kv in "$@"; do
  case "$kv" in
    url=*) url="${kv#url=}" ;;
    allow-insecure=*) insecure="${kv#allow-insecure=}" ;;
    auth.type=*) atype="${kv#auth.type=}" ;;
    auth.user=*) auser="${kv#auth.user=}" ;;
    auth.header=*) aheader="${kv#auth.header=}" ;;
    auth.secret=*) asecret="${kv#auth.secret=}" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (url, allow-insecure, auth.type, auth.user, auth.header, auth.secret)" ;;
  esac
done
[ -n "$url" ] || die 2 "layer $layer: an http source needs url"
case "$url" in http://* | https://*) ;; *) die 2 "layer $layer: url must start with http:// or https://" ;; esac
case "$url" in *[[:space:]]* | *\"* | *\\*) die 2 "layer $layer: url holds a space, a quote or a backslash" ;; esac
case "$insecure" in true | false) ;; *) die 2 "layer $layer: allow-insecure is true or false" ;; esac
[ -n "$atype" ] || { [ -n "$asecret" ] && atype=bearer || atype=none; }
case "$atype" in
  none) [ -z "$asecret" ] || die 2 "layer $layer: auth.type none takes no auth.secret" ;;
  bearer) [ -n "$asecret" ] || die 2 "layer $layer: auth.type bearer needs auth.secret" ;;
  header)
    [ -n "$asecret" ] || die 2 "layer $layer: auth.type header needs auth.secret"
    [[ "$aheader" =~ ^[A-Za-z0-9-]+$ ]] || die 2 "layer $layer: auth.type header needs auth.header, a header name" ;;
  basic)
    [ -n "$asecret" ] || die 2 "layer $layer: auth.type basic needs auth.secret"
    [ -n "$auser" ] || die 2 "layer $layer: auth.type basic needs auth.user"
    case "$auser" in *:* | *\"* | *\\*) die 2 "layer $layer: auth.user may not hold a colon, a quote or a backslash" ;; esac ;;
  *) die 2 "layer $layer: auth.type is none, bearer, header or basic" ;;
esac
if [ -n "$asecret" ]; then
  case "$url" in
    http://*) [ "$insecure" = true ] || die 2 "layer $layer: refusing to send a secret over plain http:// (it would travel in the clear); use https:// or set allow-insecure: true on the source" ;;
  esac
fi
command -v curl >/dev/null 2>&1 || die 1 "layer $layer: curl is not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

token=''
if [ -n "$asecret" ]; then
  if ! command -v dcf-secret >/dev/null 2>&1; then
    echo "registry-source-http: layer $layer: auth.secret is set but dcf-secret (the openbao Feature) is not installed; reading without a secret" >&2
    atype=none
  else
    token="$(dcf-secret get "$asecret")" || die 1 "layer $layer: dcf-secret could not read $asecret (exit $?)"
    case "$token" in *$'\n'* | *\"* | *\\*) die 1 "layer $layer: the secret $asecret holds a newline, a quote or a backslash, which a curl config cannot carry" ;; esac
  fi
fi

# curl_conf: the log-in as a curl config on standard input (-K -): nothing on the command line.
curl_conf() {
  case "$atype" in
    bearer) printf 'header = "Authorization: Bearer %s"\n' "$token" ;;
    header) printf 'header = "%s: %s"\n' "$aheader" "$token" ;;
    basic) printf 'user = "%s:%s"\n' "$auser" "$token" ;;
    *) : ;;
  esac
}

max_time="${REGISTRY_SOURCE_HTTP_MAX_TIME:-60}" conn="${REGISTRY_SOURCE_HTTP_CONNECT_TIMEOUT:-10}"
redir=(--location --max-redirs 3 --proto-redir "=http,https")
[ -z "$token" ] || redir=()
# get <out> <hdr> [-I]: one request; -f turns 4xx/5xx into a failure; one retry only (a 404 is
# not worth the helper's default three).
get() {
  local out="$1" hdr="$2"; shift 2
  curl_conf | dcf_curl --silent --show-error --fail --proto =http,https "${redir[@]}" \
    --retry 1 --retry-delay 1 --connect-timeout "$conn" --max-time "$max_time" --max-filesize 1048576 \
    -K - -D "$hdr" -o "$out" "$@" "$url" 2>"$tmp/err"
}
hdrval() { sed -n "s/^$2:[[:space:]]*//Ip" "$1" | tail -n 1 | tr -d '\r\t'; }

case "$verb" in
  version)
    # A HEAD request first (a header says it without the body); the body's hash when the server gives no validator.
    if get /dev/null "$tmp/h" -I; then
      v="$(hdrval "$tmp/h" etag)"; [ -n "$v" ] && { printf 'etag:%s\n' "$v"; exit 0; }
      v="$(hdrval "$tmp/h" last-modified)"; [ -n "$v" ] && { printf 'modified:%s\n' "$v"; exit 0; }
    fi
    get "$tmp/body" "$tmp/h" || die 1 "layer $layer: cannot read $url: $(grep -m 1 . "$tmp/err")"
    v="$(hdrval "$tmp/h" etag)"; [ -n "$v" ] && { printf 'etag:%s\n' "$v"; exit 0; }
    v="$(hdrval "$tmp/h" last-modified)"; [ -n "$v" ] && { printf 'modified:%s\n' "$v"; exit 0; }
    printf 'sha256:%s\n' "$(sha256sum < "$tmp/body" | cut -d' ' -f1)" ;;
  fetch)
    [ -d "$dest" ] || die 2 "layer $layer: the destination $dest is not a folder"
    get "$tmp/body" "$tmp/h" || die 1 "layer $layer: cannot read $url: $(grep -m 1 . "$tmp/err")"
    name="${url%%[?#]*}"; name="${name##*/}"
    case "$name" in
      *.tar.gz | *.tgz | *.zip) die 1 "layer $layer: $url is an archive; this release reads one .layer file" ;;
      *.layer) [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || name="$layer.layer" ;;
      *) name="$layer.layer" ;;
    esac
    [ -s "$tmp/body" ] || die 1 "layer $layer: $url answered with an empty body"
    cp "$tmp/body" "$dest/$name" || die 1 "layer $layer: could not write into $dest" ;;
esac
exit 0
