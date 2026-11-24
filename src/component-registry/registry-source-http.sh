#!/usr/bin/env bash
# registry-source-http: the component registry's `http` source. A layer is one .layer file served
# over HTTP(S) (a REST endpoint, a static site, a raw file in a code host). Review and release are
# the endpoint owner's; the registry only pins what to read and how to log in. No manifest and no
# signature are required. Installed on PATH by the component-registry Feature; dcf-registry calls it.
#
#   registry-source-http fetch <layer> <dest> url=<url> [archive=tar.gz|tgz|zip [sha256=<hex>] [path=<folder>]] [allow-insecure=true] [auth.*=...]
#                                         the file into <dest>/<name> (the URL's last path
#                                         segment when it ends in .layer, else <layer>.layer)
#   registry-source-http version <layer> url=<url> [...]
#                                         the ETag, else the Last-Modified, else a hash of the body
#   registry-source-http supports         the verbs it implements
#
# The smallest safe form: one .layer file, at most 1 MiB. With archive=tar.gz (or tgz) or
# archive=zip (1.12.0) the URL is an archive instead, at most 100 MiB (so a GitHub release asset
# such as releases/download/v3/registry.tar.gz is a layer with its @file siblings):
#   sha256=<hex>   pin the archive: a different download is refused, nothing replaced; it is also
#                  the version (no request is needed to ask)
#   max-size=<n>[K|M|G]  the cap on the download and on the extracted total (default 100 MiB;
#                  also valid on a plain file, default 1 MiB); COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE
#                  sets the default for archives, the source's key wins
#   path=<folder>  the folder inside the archive that becomes the layer root (relative, no ..);
#                  without it the archive's top level is the root
# Extraction is checked before anything is written: entries with an absolute path or .., a
# symlink or hardlink whose target is absolute or holds .., a device, fifo or other special
# file, and a total over the cap are refused. A zip
# may hold no symlinks at all. zip needs unzip (installed by the Feature when apt-get is there;
# else a zip layer is refused saying so); tar.gz needs tar.
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

url='' archive='' sha='' apath='' maxs='' atype='' auser='' aheader='' asecret='' insecure=false
for kv in "$@"; do
  case "$kv" in
    url=*) url="${kv#url=}" ;;
    archive=*) archive="${kv#archive=}" ;;
    sha256=*) sha="${kv#sha256=}" ;;
    path=*) apath="${kv#path=}" ;;
    max-size=*) maxs="${kv#max-size=}" ;;
    allow-insecure=*) insecure="${kv#allow-insecure=}" ;;
    auth.type=*) atype="${kv#auth.type=}" ;;
    auth.user=*) auser="${kv#auth.user=}" ;;
    auth.header=*) aheader="${kv#auth.header=}" ;;
    auth.secret=*) asecret="${kv#auth.secret=}" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (url, archive, sha256, path, max-size, allow-insecure, auth.type, auth.user, auth.header, auth.secret)" ;;
  esac
done
[ -n "$url" ] || die 2 "layer $layer: an http source needs url"
case "$url" in http://* | https://*) ;; *) die 2 "layer $layer: url must start with http:// or https://" ;; esac
case "$url" in *[[:space:]]* | *\"* | *\\*) die 2 "layer $layer: url holds a space, a quote or a backslash" ;; esac
case "$insecure" in true | false) ;; *) die 2 "layer $layer: allow-insecure is true or false" ;; esac
case "$archive" in '' | tar.gz | tgz | zip) ;; *) die 2 "layer $layer: archive is tar.gz, tgz or zip" ;; esac
if [ -z "$archive" ]; then
  [ -z "$sha$apath" ] || die 2 "layer $layer: sha256 and path belong to an archive source (set archive: tar.gz, tgz or zip)"
else
  [ -z "$sha" ] || [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || die 2 "layer $layer: sha256 is 64 hex digits"
  sha="${sha,,}"
  if [ -n "$apath" ]; then
    apath="${apath#./}"; apath="${apath%/}"
    case "/$apath/" in
      //* | */../* | *\\* | */./*) die 2 "layer $layer: path '$apath' must be a relative folder without .. (a folder inside the archive)" ;;
    esac
    [ -n "$apath" ] || die 2 "layer $layer: path must be a relative folder inside the archive"
  fi
fi
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

# The cap, in bytes, on the download and (an archive) on the extracted total: max-size on the
# source, else COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE (archives only), else 1 MiB for one file and
# 100 MiB for an archive. A number is bytes; K, M, G are binary.
size_bytes() { # <value> -> bytes, or fails
  [[ "$1" =~ ^[1-9][0-9]*[KMG]?$ ]] || return 1
  local n="${1%[KMG]}"
  case "$1" in *K) echo $((n * 1024)) ;; *M) echo $((n * 1048576)) ;; *G) echo $((n * 1073741824)) ;; *) echo "$n" ;; esac
}
maxsize=1048576; maxlabel='1 MiB'; [ -z "$archive" ] || { maxsize=104857600; maxlabel='100 MiB'; }
if [ -n "$maxs" ]; then
  maxsize="$(size_bytes "$maxs")" || die 2 "layer $layer: max-size is a number of bytes or a number with K, M or G (binary), not 0 or negative: '$maxs'"
  maxlabel="$maxs (max-size)"
elif [ -n "$archive" ] && [ -n "${COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE:-}" ]; then
  maxsize="$(size_bytes "$COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE")" || die 2 "layer $layer: COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE is a number of bytes or a number with K, M or G (binary), not 0 or negative: '$COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE'"
  maxlabel="$COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE (COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE)"
fi
raise="raise it with max-size: on the source or COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE"
max_time="${REGISTRY_SOURCE_HTTP_MAX_TIME:-60}" conn="${REGISTRY_SOURCE_HTTP_CONNECT_TIMEOUT:-10}"
redir=(--location --max-redirs 3 --proto-redir "=http,https")
[ -z "$token" ] || redir=()
# get <out> <hdr> [-I]: one request; -f turns 4xx/5xx into a failure; one retry only (a 404 is
# not worth the helper's default three).
get() {
  local out="$1" hdr="$2"; shift 2
  curl_conf | dcf_curl --silent --show-error --fail --proto =http,https "${redir[@]}" \
    --retry 1 --retry-delay 1 --connect-timeout "$conn" --max-time "$max_time" --max-filesize "$maxsize" \
    -K - -D "$hdr" -o "$out" "$@" "$url" 2>"$tmp/err"
}
hdrval() { sed -n "s/^$2:[[:space:]]*//Ip" "$1" | tail -n 1 | tr -d '\r\t'; }

# extract_archive: check $tmp/body, list it, refuse anything unsafe, extract into $tmp/x, copy the
# chosen folder into $dest. Nothing is written to $dest before every check has passed.
extract_archive() {
  local got cap="$maxsize" n tgt total x="$tmp/x"
  got="$(sha256sum < "$tmp/body" | cut -d' ' -f1)"
  if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
    die 1 "layer $layer: $url does not match its sha256 (pinned $sha, got $got); nothing was replaced"
  fi
  mkdir -p "$x"
  : > "$tmp/names"; : > "$tmp/lines"
  case "$archive" in
    tar.gz | tgz)
      command -v tar >/dev/null 2>&1 || die 1 "layer $layer: tar is not installed"
      tar -tzf "$tmp/body" --quoting-style=escape > "$tmp/names" 2>"$tmp/err" || die 1 "layer $layer: $url is not a readable tar.gz: $(grep -m 1 . "$tmp/err")"
      tar -tvzf "$tmp/body" --quoting-style=escape > "$tmp/lines" 2>"$tmp/err" || die 1 "layer $layer: $url is not a readable tar.gz: $(grep -m 1 . "$tmp/err")" ;;
    zip)
      command -v unzip >/dev/null 2>&1 || die 1 "layer $layer: $url is a zip archive but unzip is not installed (apt-get install unzip); use tar.gz or install unzip"
      unzip -Z1 "$tmp/body" > "$tmp/names" 2>"$tmp/err" || die 1 "layer $layer: $url is not a readable zip: $(grep -m 1 . "$tmp/err")"
      unzip -Zs "$tmp/body" 2>/dev/null | grep -E '^[-dlcbps?]' > "$tmp/lines" ;;
  esac
  [ "$(wc -l < "$tmp/names")" -eq "$(wc -l < "$tmp/lines")" ] || die 1 "layer $layer: $url: could not list the archive entries one for one; refusing it"
  # names: absolute, .., a backslash (an escaped odd character), a drive letter
  if grep -Eq '^/|(^|/)\.\.(/|$)|\\|^[A-Za-z]:' "$tmp/names"; then
    die 1 "layer $layer: $url holds an unsafe entry name ($(grep -E -m 1 '^/|(^|/)\.\.(/|$)|\\|^[A-Za-z]:' "$tmp/names")); refusing the archive"
  fi
  # types: only regular files and folders, and (tar only) links whose target stays inside
  while IFS= read -r l; do
    t="${l:0:1}"
    case "$t" in
      - | d | \?) ;;   # ? : a zip written without unix modes (a plain file or folder)
      l | h)
        [ "$archive" != zip ] || die 1 "layer $layer: $url holds a symlink; a zip layer may hold none"
        case "$t" in l) tgt="${l##* -> }" ;; *) tgt="${l##* link to }" ;; esac
        case "$tgt" in
          /* | ../* | */../* | */.. | ..) die 1 "layer $layer: $url holds a link pointing outside ($tgt); refusing the archive" ;;
        esac ;;
      *) die 1 "layer $layer: $url holds a device, fifo or other special file; refusing the archive" ;;
    esac
  done < "$tmp/lines"
  if [ "$archive" = zip ]; then
    total="$(awk '{ s += $4 } END { print s + 0 }' "$tmp/lines")"
  else
    total="$(awk '{ s += $3 } END { print s + 0 }' "$tmp/lines")"
  fi
  [ "$total" -le "$cap" ] || die 1 "layer $layer: $url would extract to $total bytes, over the $maxlabel cap; $raise; refusing the archive"
  case "$archive" in
    tar.gz | tgz) tar -xzf "$tmp/body" -C "$x" --no-same-owner --no-same-permissions 2>"$tmp/err" ;;
    zip) unzip -q "$tmp/body" -d "$x" 2>"$tmp/err" ;;
  esac || die 1 "layer $layer: could not extract $url: $(grep -m 1 . "$tmp/err")"
  chmod -R u+rwX "$x" 2>/dev/null || true   # an archive of folders without x or r is still a layer
  # after: nothing but files, folders and inside links; the size as written
  if [ -n "$(find "$x" ! -type f ! -type d ! -type l -print -quit)" ]; then die 1 "layer $layer: $url extracted a special file; refusing the archive"; fi
  while IFS= read -r l; do
    case "$(readlink -f "$l")" in "$(readlink -f "$x")"/*) ;; *) die 1 "layer $layer: $url holds a link pointing outside; refusing the archive" ;; esac
  done < <(find "$x" -type l)
  n="$(du -sb "$x" | cut -f1)"
  [ "$n" -le "$cap" ] || die 1 "layer $layer: $url extracted to $n bytes, over the $maxlabel cap; $raise; refusing the archive"
  if [ -n "$apath" ]; then
    # the folder must be a real folder inside the extraction (a link may not lead out of it)
    case "$(readlink -f "$x/$apath")" in "$(readlink -f "$x")"/*) ;; *) die 1 "layer $layer: $url has no folder '$apath' inside the archive" ;; esac
    [ -d "$x/$apath" ] || die 1 "layer $layer: $url has no folder '$apath' inside the archive"
    x="$x/$apath"
  fi
  cp -R "$x/." "$dest/" || die 1 "layer $layer: could not write into $dest"
}

case "$verb" in
  version)
    # An archive pinned by sha256: that is the version, no request.
    [ -z "$sha" ] || { printf 'sha256:%s\n' "$sha"; exit 0; }
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
    if ! get "$tmp/body" "$tmp/h"; then
      if grep -qi 'maximum file size\|exceeded' "$tmp/err"; then die 1 "layer $layer: $url is over the $maxlabel cap; $raise"; fi
      die 1 "layer $layer: cannot read $url: $(grep -m 1 . "$tmp/err")"
    fi
    if [ -n "$archive" ]; then
      extract_archive
      exit 0
    fi
    name="${url%%[?#]*}"; name="${name##*/}"
    case "$name" in
      *.tar.gz | *.tgz | *.zip) die 1 "layer $layer: $url is an archive; set archive: tar.gz, tgz or zip on the source to read it" ;;
      *.layer) [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || name="$layer.layer" ;;
      *) name="$layer.layer" ;;
    esac
    [ -s "$tmp/body" ] || die 1 "layer $layer: $url answered with an empty body"
    cp "$tmp/body" "$dest/$name" || die 1 "layer $layer: could not write into $dest" ;;
esac
exit 0
