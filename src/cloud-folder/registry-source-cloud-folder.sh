#!/usr/bin/env bash
# registry-source-cloud-folder: the component registry's `cloud-folder` source. A layer is a
# folder under the cloud folder (the person's own layer in their shared cloud folder, or a team's).
# Installed on PATH by the cloud-folder Feature, which owns the transport; dcf-registry
# (component-registry) calls it, nobody else needs to.
#
#   registry-source-cloud-folder fetch <layer> <dest> remote=<folder>   copy the folder's files
#                                                  into <dest>
#   registry-source-cloud-folder version <layer> remote=<folder>        a fingerprint of its
#                                                  names, sizes and times (tree-<cksum>)
#   registry-source-cloud-folder supports                               the verbs it implements
#
# `remote` is a folder path under the cloud folder's mount point (the Feature's mountPoint option,
# CLOUD_FOLDER_MOUNT_POINT): registry/mine is <mountPoint>/registry/mine. What shows there is the
# Feature's own work in its own mode: the host-synced folder (host), the bisync copy (sync) or the
# live mount (mount); this source reads it and sets up no rclone and holds no credentials. The
# sync marker (.cloud-folder-bisync) is not part of a layer. Not set up (nothing mounted, no
# remote signed in), or the folder is absent: exit 1 with one line; dcf-registry then uses the last
# good copy.
#
# Exit: 0 done, 1 failed, 2 bad use, 3 not supported.
set -uo pipefail

die() { local rc="$1"; shift; printf 'registry-source-cloud-folder: %s\n' "$*" >&2; exit "$rc"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  supports) printf 'fetch\nversion\nsupports\n'; exit 0 ;;
  fetch) [ $# -ge 2 ] || die 2 "usage: fetch <layer> <dest> remote=<folder>"; layer="$1" dest="$2"; shift 2 ;;
  version) [ $# -ge 1 ] || die 2 "usage: version <layer> remote=<folder>"; layer="$1"; shift ;;
  '') die 2 "usage: registry-source-cloud-folder fetch|version|supports ..." ;;
  *) die 3 "verb '$verb' is not supported (fetch, version, supports)" ;;
esac

remote=''
for kv in "$@"; do
  case "$kv" in
    remote=*) remote="${kv#remote=}" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (a cloud-folder source takes remote only)" ;;
  esac
done
[ -n "$remote" ] || die 2 "layer $layer: a cloud-folder source needs remote=<folder under the cloud folder>"
remote="${remote#/}"; remote="${remote%/}"
case "/$remote/" in */../* | */./* | *//*) die 2 "layer $layer: remote '$remote' may not hold .. or . segments" ;; esac

# shellcheck disable=SC1091  # written by the Feature's install.sh at image build
[ -f /usr/local/share/cloud-folder-feature/options.env ] && source /usr/local/share/cloud-folder-feature/options.env
mount_point="${CLOUD_FOLDER_MOUNT_POINT:-${MOUNTPOINT:-/mnt/cloud-folder}}"

# Is the cloud folder set up? Ask the Feature's own status (its first line says why not).
if command -v cloud-folder-setup >/dev/null 2>&1; then
  if ! st="$(cloud-folder-setup status 2>&1)"; then
    die 1 "layer $layer: the cloud folder is not set up: $(printf '%s\n' "$st" | grep -m 1 . | cut -c 1-200)"
  fi
fi
[ -d "$mount_point" ] || die 1 "layer $layer: the cloud folder is not set up: nothing at $mount_point"
folder="$mount_point/$remote"
[ -d "$folder" ] || die 1 "layer $layer: no folder $remote in the cloud folder (not synced yet, or not made)"
[ -r "$folder" ] && [ -x "$folder" ] || die 1 "layer $layer: $folder is not readable by $(id -un)"

case "$verb" in
  version)
    sum="$(cd "$folder" && find . -type f ! -name '.cloud-folder-bisync' -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort | cksum | cut -d' ' -f1)" ||
      die 1 "layer $layer: could not read $folder"
    printf 'tree-%s\n' "$sum" ;;
  fetch)
    [ -d "$dest" ] || die 2 "layer $layer: the destination $dest is not a folder"
    cp -R "$folder/." "$dest/" || die 1 "layer $layer: could not copy $folder"
    rm -f "$dest/.cloud-folder-bisync" ;;
esac
exit 0
