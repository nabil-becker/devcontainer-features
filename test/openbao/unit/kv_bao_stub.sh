#!/usr/bin/env bash
# A stub `bao` with a small KV v2 store in a folder, for the Docker-free tests of openbao-ssh
# (ssh_test.sh) and of ssh-agent's key:load from OpenBao (test/ssh-agent/unit/bao_load_test.sh).
# Copied onto PATH as `bao` by those tests. It plays only the calls they make, with the shapes the
# real CLI gives (the exit codes, the -format=json fields the scripts read); that the real bao does
# is the container tests' (test/openbao/server_mode.sh in CI).
#
# The store: $BAO_STORE/<mount>/<name>/cur (the current version), v<N>/<field> (one file per
# field), destroyed (destroyed versions, one per line), ctime, meta.<key> (custom metadata).
# Every call is logged with its arguments to $BAO_STUB_LOG (stdin is never logged).
# STUB_STATUS_RC (0 unsealed, 2 sealed, 1 unreachable), STUB_LOOKUP_RC and STUB_TTL (the token's
# seconds left) choose the answers; STUB_FAIL_CMD makes `bao <that word> ...` fail with exit 2.
set -u
S="${BAO_STORE:?BAO_STORE is not set}"
echo "$*" >>"${BAO_STUB_LOG:-/dev/null}"

case "${1:-} ${2:-}" in
  "status -format=json")
    case "${STUB_STATUS_RC:-0}" in
      0) echo '{"initialized": true, "sealed": false}' ;;
      2) echo '{"initialized": true, "sealed": true}' ;;
    esac
    exit "${STUB_STATUS_RC:-0}" ;;
  "token capabilities")
    [ "${STUB_LOOKUP_RC:-0}" -eq 0 ] || { echo "permission denied" >&2; exit 2; }
    echo "${STUB_CAPS:-root}"
    exit 0 ;;
  "token lookup")
    [ "${STUB_LOOKUP_RC:-0}" -eq 0 ] || { echo "permission denied" >&2; exit 2; }
    printf '{\n  "data": {\n    "creation_ttl": 14400,\n    "ttl": %s\n  }\n}\n' "${STUB_TTL:-14400}"
    exit 0 ;;
esac

[ "${1:-}" = kv ] || { echo "kv stub: unexpected call: $*" >&2; exit 99; }
shift
sub="$1"
shift
if [ "$sub" = metadata ]; then sub="metadata-$1"; shift; fi
[ -z "${STUB_FAIL_CMD:-}" ] || [ "$sub" != "$STUB_FAIL_CMD" ] || { echo "Error: stub failure" >&2; exit 2; }
[ "${STUB_STATUS_RC:-0}" -eq 0 ] || { echo "Error: server not ready" >&2; exit 2; }

mount="" field="" cas="" versions="" name=""
meta=() pairs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -mount=*) mount="${1#-mount=}" ;;
    -field=*) field="${1#-field=}" ;;
    -format=*) ;;
    -cas=*) cas="${1#-cas=}" ;;
    -versions=*) versions="${1#-versions=}" ;;
    -custom-metadata=*) meta+=("${1#-custom-metadata=}") ;;
    -*) echo "kv stub: unknown flag $1" >&2; exit 99 ;;
    *) if [ -z "$name" ]; then name="$1"; else pairs+=("$1"); fi ;;
  esac
  shift
done
d="$S/$mount/$name"
cur() { cat "$d/cur" 2>/dev/null || echo 0; }
destroyed() { grep -qx "$1" "$d/destroyed" 2>/dev/null; }
write_version() { # <new version> <copy from version or 0>
  local v="$1" from="$2" p k val
  mkdir -p "$d/v$v"
  [ "$from" -eq 0 ] || cp "$d/v$from"/* "$d/v$v"/ 2>/dev/null || true
  for p in "${pairs[@]}"; do
    k="${p%%=*}"
    val="${p#*=}"
    case "$val" in
      -) cat >"$d/v$v/$k" ;;
      @*) cat "${val#@}" >"$d/v$v/$k" ;;
      *) printf '%s' "$val" >"$d/v$v/$k" ;;
    esac
  done
  echo "$v" >"$d/cur"
  [ -f "$d/ctime" ] || echo "${STUB_CTIME:-2026-01-02T03:04:05.000000Z}" >"$d/ctime"
}

case "$sub" in
  get)
    v="$(cur)"
    { [ "$v" -gt 0 ] && ! destroyed "$v"; } || { echo "No value found at $mount/data/$name" >&2; exit 2; }
    [ -f "$d/v$v/$field" ] || { echo "Field \"$field\" not present in secret" >&2; exit 1; }
    cat "$d/v$v/$field"
    ;;
  put)
    v="$(cur)"
    if [ -n "$cas" ] && [ "$cas" != "$v" ]; then echo "Error writing data: check-and-set parameter did not match the current version" >&2; exit 2; fi
    write_version $((v + 1)) 0
    ;;
  patch)
    v="$(cur)"
    [ "$v" -gt 0 ] || { echo "No value found" >&2; exit 2; }
    write_version $((v + 1)) "$v"
    ;;
  destroy)
    [ -f "$d/cur" ] || { echo "No value found" >&2; exit 2; }
    tr ',' '\n' <<<"$versions" >>"$d/destroyed"
    ;;
  list)
    [ -d "$d" ] || { echo "No value found at $mount/metadata/$name" >&2; exit 2; }
    out=""
    for e in "$d"/*/; do
      [ -d "$e" ] || continue
      e="${e%/}"
      n="${e##*/}"
      if [ -f "$e/cur" ]; then out="$out\"$n\","; else out="$out\"$n/\","; fi
    done
    [ -n "$out" ] || { echo "No value found" >&2; exit 2; }
    echo "[${out%,}]"
    ;;
  metadata-get)
    [ -f "$d/cur" ] || { echo "No value found at $mount/metadata/$name" >&2; exit 2; }
    cm=""
    for m in "$d"/meta.*; do
      [ -f "$m" ] || continue
      cm="$cm      \"${m##*/meta.}\": \"$(cat "$m")\",
"
    done
    if [ -n "$cm" ]; then cm="{
${cm%,
}
    }"; else cm=null; fi
    printf '{\n  "data": {\n    "created_time": "%s",\n    "current_version": %s,\n    "custom_metadata": %s\n  }\n}\n' "$(cat "$d/ctime")" "$(cur)" "$cm"
    ;;
  metadata-patch)
    [ -f "$d/cur" ] || { echo "No value found" >&2; exit 2; }
    for m in "${meta[@]}"; do printf '%s' "${m#*=}" >"$d/meta.${m%%=*}"; done
    ;;
  *) echo "kv stub: unexpected kv $sub" >&2; exit 99 ;;
esac
exit 0
