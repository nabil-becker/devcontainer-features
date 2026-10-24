#!/usr/bin/env bash
# dcf-persist: make a tool's state directory usable by the current user and
# say where it lives. The one helper behind every <id>-setup post-create hook
# of this collection (claude-code, git, gh, az), so they all behave the same:
#
#   dcf-persist [--label <name>] <dir>...
#
# For each <dir>: create it (with sudo when the parent is not writable), hand
# it to the current user when its top level is owned by someone else (named
# volumes and bind mounts arrive owned by root or by the host's uid), and
# print one line: label, path, what backs it, and whether it is writable.
# Backing is one of
#   volume  a named volume: survives rebuilds, deleted by a container-engine
#           storage reset or a move to another engine;
#   bind    a folder from the host disk: survives all of that;
#   image   the container filesystem: gone at the next rebuild.
# Never fatal (exit 0 always): a problem is reported, and the rest of
# post-create goes on. Canonical copy: src/common/dcf-persist.sh; the other
# Features carry a verbatim copy, checked by `task lint`.
set -u

label=""
if [ "${1:-}" = "--label" ]; then label="$2"; shift 2; fi
[ $# -gt 0 ] || { echo "usage: dcf-persist [--label <name>] <dir>..." >&2; exit 0; }

me="$(id -u):$(id -g)"
as_root() { # run a command as root: directly, or through passwordless sudo
  if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@"; else return 1; fi
}

backing_of() { # <dir> -> volume | bind | image
  local src fstype
  src="$(findmnt -no SOURCE --target "$1" 2>/dev/null || true)"
  fstype="$(findmnt -no FSTYPE --target "$1" 2>/dev/null || true)"
  # The container's own filesystem is the overlay root. A named volume shows
  # the engine's volume store as its source (/var/lib/docker/volumes/<name>/
  # _data, or the podman equivalent); any other mount came from outside.
  case "$fstype" in overlay | "") echo image ;; *) case "$src" in *"/volumes/"*) echo volume ;; *) echo bind ;; esac ;; esac
}

for dir in "$@"; do
  name="${label:-$(basename "$dir")}"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || as_root mkdir -p "$dir" || { echo "$name: cannot create $dir" >&2; continue; }
  fi
  if [ "$(stat -c %u:%g "$dir" 2>/dev/null)" != "$me" ]; then
    # Only the top level is checked, so a large folder is not walked on every
    # start; -R because the contents came along with the same owner.
    as_root chown -R "$me" "$dir" 2>/dev/null || true
  fi
  backing="$(backing_of "$dir")"
  if [ -w "$dir" ]; then state=writable; else state="NOT writable by $(id -un)"; fi
  echo "$name: $dir ($backing, $state)"
  case "$backing" in
    volume) echo "$name: a named volume is deleted by a container-engine storage reset; for the host disk, bind-mount the same target in devcontainer.json (see the Feature README)." ;;
    image) echo "$name: inside the image, lost at the next rebuild; add the Feature's mount or set the directory variable to a mounted path." ;;
  esac
done
exit 0
