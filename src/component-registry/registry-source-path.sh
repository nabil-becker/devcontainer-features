#!/usr/bin/env bash
# registry-source-path: the component registry's `path` source. A layer is a folder: in the
# repository (git-ignored, the person's own), anywhere in the container, or a file share the
# launcher mounts from the host (DCF_HOST_*). Installed on PATH by the component-registry Feature;
# dcf-registry calls it, nobody else needs to.
#
#   registry-source-path fetch <layer> <dest> path=<folder>    copy the folder's files into <dest>
#   registry-source-path version <layer> path=<folder>         a fingerprint of its names, sizes
#                                                              and times (tree-<cksum>)
#   registry-source-path supports                              the verbs it implements
#
# dcf-registry hands a repository-relative path over absolute. The folder's own permissions are
# its log-in. A folder that is not there is "unreachable" (exit 1): dcf-registry then uses the
# last good layer copy.
#
# Exit: 0 done, 1 failed, 2 bad use, 3 not supported.
set -uo pipefail

die() { local rc="$1"; shift; printf 'registry-source-path: %s\n' "$*" >&2; exit "$rc"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  supports) printf 'fetch\nversion\nsupports\n'; exit 0 ;;
  fetch) [ $# -ge 2 ] || die 2 "usage: fetch <layer> <dest> path=<folder>"; layer="$1" dest="$2"; shift 2 ;;
  version) [ $# -ge 1 ] || die 2 "usage: version <layer> path=<folder>"; layer="$1"; shift ;;
  '') die 2 "usage: registry-source-path fetch|version|supports ..." ;;
  *) die 3 "verb '$verb' is not supported (fetch, version, supports)" ;;
esac

path=''
for kv in "$@"; do
  case "$kv" in
    path=*) path="${kv#path=}" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (a path source takes path only)" ;;
  esac
done
[ -n "$path" ] || die 2 "layer $layer: a path source needs path=<folder>"
[ -d "$path" ] || die 1 "layer $layer: no folder $path (not mounted, or not made yet)"
[ -r "$path" ] && [ -x "$path" ] || die 1 "layer $layer: $path is not readable by $(id -un)"

case "$verb" in
  version)
    # Names, sizes and modification times: a change to any file changes the fingerprint.
    sum="$(cd "$path" && find . -type f -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort | cksum | cut -d' ' -f1)" ||
      die 1 "layer $layer: could not read $path"
    printf 'tree-%s\n' "$sum" ;;
  fetch)
    [ -d "$dest" ] || die 2 "layer $layer: the destination $dest is not a folder"
    cp -R "$path/." "$dest/" || die 1 "layer $layer: could not copy $path" ;;
esac
exit 0
