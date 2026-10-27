#!/usr/bin/env bash
# cloud-folder-setup: the cloud-folder Feature's postStartCommand (a host folder is mounted, or
# not, per start), also behind `task cloud-folder:setup`, `task cloud-folder:status` and
# `task cloud-folder:version`.
#
#   cloud-folder-setup                 report on the folder (never fatal: exit 0)
#   cloud-folder-setup status [--json] the same report; exit 0 when the folder is mounted and
#                                      writable (empty or not), 1 when it is missing, not
#                                      mounted, not writable, or the mode is not one this
#                                      version knows. --json prints one JSON object instead.
#   cloud-folder-setup version         the Feature version and the mode and mount point in use
#   cloud-folder-setup link MOUNT_POINT HOST_MOUNT
#                                      install.sh, as root: make MOUNT_POINT a symbolic link to
#                                      HOST_MOUNT (nothing when they are the same path)
#
# This version knows host mode only: the devcontainer-cli launcher bind-mounts the host folder
# named by DCF_HOST_CLOUD_FOLDER at one fixed path, the host mount (/mnt/cloud-folder-host), and
# install.sh links the option mountPoint to it when the two differ, so a consumer names the path
# once. "Mounted" means the path the mount point leads to (through the link) is the target of a
# mount in /proc/self/mountinfo. A folder that exists but is not mounted is a bare folder of the
# container: writing there would put files where no one else sees them, so the status fails
# rather than call it a cloud folder.
#
# Nothing is written into the folder: writability is the access check (test -w), so a status
# never leaves a file behind for a sync client to upload.
# Test hooks (not options): DCF_CLOUD_FOLDER_MOUNTINFO names the mount table to read (default
# /proc/self/mountinfo); DCF_CLOUD_FOLDER_HOST_MOUNT replaces the fixed host mount path.
set -u

# Defaults baked by install.sh from the Feature options; CLOUD_FOLDER_* in the environment
# override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/cloud-folder-feature/options.env ] && source /usr/local/share/cloud-folder-feature/options.env
mode_option="${CLOUD_FOLDER_MODE:-${MODE:-auto}}"
mount_point="${CLOUD_FOLDER_MOUNT_POINT:-${MOUNTPOINT:-/mnt/cloud-folder}}"
feature_version="${FEATURE_VERSION:-unknown}"
host_mount="${DCF_CLOUD_FOLDER_HOST_MOUNT:-${HOST_MOUNT:-/mnt/cloud-folder-host}}"
mountinfo="${DCF_CLOUD_FOLDER_MOUNTINFO:-/proc/self/mountinfo}"
host_source="${DCF_HOST_CLOUD_FOLDER:-}"

# A trailing slash would never match the mount table.
while [ "${#mount_point}" -gt 1 ] && [ "${mount_point%/}" != "$mount_point" ]; do mount_point="${mount_point%/}"; done

say() { echo "cloud-folder: $*"; }

# is_mounted <path>: the path is the target of a mount. The mount table escapes space, tab,
# newline and backslash as octal (\040, \011, \012, \134), so the path is encoded the same way.
is_mounted() {
  local enc="$1"
  [ -r "$mountinfo" ] || return 1
  enc="${enc//\\/\\134}"
  enc="${enc// /\\040}"
  enc="${enc//$'\t'/\\011}"
  enc="${enc//$'\n'/\\012}"
  CF_TARGET="$enc" awk '$5 == ENVIRON["CF_TARGET"] { found = 1 } END { exit !found }' "$mountinfo" 2>/dev/null
}

# real_path <path>: where the path leads, links followed (the last part need not exist).
real_path() { readlink -m -- "$1" 2>/dev/null || readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"; }

# link_mount_point <mount point> <host mount>: the build-time link (install.sh runs it as root).
# Idempotent: an existing link is replaced, an empty folder gives way; a folder with content or
# any other file is refused, since replacing it would lose what is there.
link_mount_point() {
  local mp="$1" hm="$2"
  case "$mp" in /?*) ;; *) echo "cloud-folder: mountPoint '$mp' must be an absolute path." >&2; return 1 ;; esac
  while [ "${#mp}" -gt 1 ] && [ "${mp%/}" != "$mp" ]; do mp="${mp%/}"; done
  if [ "$mp" = "$hm" ]; then say "mountPoint is the host mount $hm itself: no link"; return 0; fi
  if [ -L "$mp" ]; then
    rm -f -- "$mp" || return 1
  elif [ -d "$mp" ]; then
    if [ -n "$(find "$mp" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      echo "cloud-folder: mountPoint $mp is a folder with content in the image; it cannot become the link to $hm. Choose another mountPoint, or empty that folder first." >&2
      return 1
    fi
    rmdir -- "$mp" || return 1
  elif [ -e "$mp" ]; then
    echo "cloud-folder: mountPoint $mp exists in the image and is not a folder or a link; it cannot become the link to $hm." >&2
    return 1
  fi
  mkdir -p -- "$(dirname -- "$mp")" || return 1
  ln -s -- "$hm" "$mp" || return 1
  say "mountPoint $mp links to the host mount $hm"
}

# assess: sets MODE_USED (host | none), WHY, REAL (where the mount point leads), LINKED, PRESENT,
# MOUNTED, IS_DIR, EMPTY (yes | no | unknown), WRITABLE, VERDICT (ok | empty | not-mounted |
# no-source | not-a-folder | unwritable | unknown-mode) and HINT.
assess() {
  PRESENT=no; MOUNTED=no; IS_DIR=no; EMPTY=unknown; WRITABLE=no; HINT=''; LINKED=no
  REAL="$(real_path "$mount_point")"
  [ -L "$mount_point" ] && LINKED=yes
  [ -e "$mount_point" ] && PRESENT=yes
  [ -d "$mount_point" ] && IS_DIR=yes
  is_mounted "$REAL" && MOUNTED=yes
  if [ "$IS_DIR" = yes ] && [ -r "$mount_point" ] && [ -x "$mount_point" ]; then
    if [ -n "$(find -H "$mount_point" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then EMPTY=no; else EMPTY=yes; fi
  fi
  [ "$IS_DIR" = yes ] && [ -w "$mount_point" ] && [ -x "$mount_point" ] && WRITABLE=yes

  case "$mode_option" in
    host)
      MODE_USED=host; WHY='set by the option or CLOUD_FOLDER_MODE' ;;
    auto)
      if [ "$MOUNTED" = yes ]; then MODE_USED=host; WHY="auto: something is mounted at $mount_point"
      else MODE_USED=none; WHY="auto: nothing is mounted at $mount_point, and this version has no other source"; fi ;;
    sync | mount)
      MODE_USED=none; WHY="mode $mode_option is not in this version of the Feature ($feature_version), which knows auto and host; the rclone modes come later"
      VERDICT=unknown-mode; return 0 ;;
    *)
      MODE_USED=none; WHY="mode '$mode_option' is unknown (auto or host)"
      VERDICT=unknown-mode; return 0 ;;
  esac

  if [ "$MOUNTED" = no ]; then
    if [ "$MODE_USED" = none ]; then VERDICT=no-source; else VERDICT=not-mounted; fi
    if [ -n "$host_source" ]; then
      HINT="the launcher was given DCF_HOST_CLOUD_FOLDER=$host_source, but nothing is mounted here: the host folder may not exist (the launcher then skips the mount and says so), HOST_MOUNTS=false may be set, or the container was started without the launcher (task devcontainer:up, devcontainer-cli 1.12.0 or later)."
    else
      HINT="no host folder: set DCF_HOST_CLOUD_FOLDER=<host path> in .devcontainer/.env on the host and start with task devcontainer:up; the launcher then mounts it here (map DCF_HOST_CLOUD_FOLDER with containerEnv so this report can name it)."
    fi
    if [ "$REAL" != "$host_mount" ] && is_mounted "$host_mount"; then
      HINT="$HINT The host mount $host_mount is mounted, but $mount_point does not lead to it (CLOUD_FOLDER_MOUNT_POINT names another path than the option mountPoint, or the image predates the link): use $host_mount, or rebuild."
    fi
    if [ "$PRESENT" = yes ]; then
      HINT="$HINT $mount_point exists but is a bare folder of the container: do not write there."
    fi
    return 0
  fi
  if [ "$IS_DIR" = no ]; then VERDICT=not-a-folder; HINT="$mount_point is mounted but is not a folder"; return 0; fi
  if [ "$WRITABLE" = no ]; then
    VERDICT=unwritable
    HINT="$(id -un 2>/dev/null || id -u) cannot write to $mount_point: check the host folder's permissions (or the mount is read-only)"
    return 0
  fi
  if [ "$EMPTY" = yes ]; then
    VERDICT=empty
    HINT="the folder is mounted and writable but empty: right for a new folder; otherwise check that DCF_HOST_CLOUD_FOLDER names the synced folder and that the sync client has finished"
    return 0
  fi
  VERDICT=ok
}

json_str() { # <text>: a JSON string literal
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
json_bool() { if [ "$1" = yes ]; then printf true; else printf false; fi; }

print_json() {
  local empty
  case "$EMPTY" in yes) empty=true ;; no) empty=false ;; *) empty=null ;; esac
  printf '{"mode_option":%s,"mode":%s,"why":%s,"mount_point":%s,"real_path":%s,"linked":%s,"host_source":%s,' \
    "$(json_str "$mode_option")" "$(json_str "$MODE_USED")" "$(json_str "$WHY")" "$(json_str "$mount_point")" \
    "$(json_str "$REAL")" "$(json_bool "$LINKED")" "$(json_str "$host_source")"
  printf '"present":%s,"mounted":%s,"folder":%s,"empty":%s,"writable":%s,"verdict":%s,"ok":%s,"hint":%s}\n' \
    "$(json_bool "$PRESENT")" "$(json_bool "$MOUNTED")" "$(json_bool "$IS_DIR")" "$empty" "$(json_bool "$WRITABLE")" \
    "$(json_str "$VERDICT")" "$(if verdict_ok; then printf true; else printf false; fi)" "$(json_str "$HINT")"
}

verdict_ok() { [ "$VERDICT" = ok ] || [ "$VERDICT" = empty ]; }

print_report() {
  local state
  say "mode $MODE_USED ($WHY)"
  if [ "$MOUNTED" = yes ]; then state=mounted; elif [ "$PRESENT" = yes ]; then state='present, not mounted'; else state=missing; fi
  if [ "$LINKED" = yes ]; then say "mount point $mount_point -> $REAL: $state"
  else say "mount point $mount_point: $state"; fi
  [ -n "$host_source" ] && say "host folder (DCF_HOST_CLOUD_FOLDER): $host_source"
  if [ "$MOUNTED" = yes ] && [ "$IS_DIR" = yes ]; then
    case "$EMPTY" in yes) state=empty ;; no) state='not empty' ;; *) state='cannot be listed' ;; esac
    say "contents: $state; writable: $WRITABLE"
  fi
  case "$VERDICT" in
    ok) say "ok: the folder is mounted and writable" ;;
    empty) say "ok, but empty: ${HINT#the folder is mounted and writable but empty: }" ;;
    *) say "not usable ($VERDICT): ${HINT:-$WHY}" ;;
  esac
}

cmd="${1:-report}"
[ $# -gt 0 ] && shift
case "$cmd" in
  report)
    assess
    print_report
    exit 0 ;;
  status)
    json=no
    for a in "$@"; do
      case "$a" in
        --json) json=yes ;;
        *) echo "cloud-folder: status: unknown argument '$a' (only --json)" >&2; exit 2 ;;
      esac
    done
    assess
    if [ "$json" = yes ]; then print_json; else print_report; fi
    verdict_ok && exit 0
    exit 1 ;;
  version)
    say "Feature $feature_version; mode option $mode_option; mount point $mount_point; host mount $host_mount"
    if command -v rclone >/dev/null 2>&1; then say "rclone on PATH (not used by this version): $(rclone version 2>/dev/null | head -n 1)"
    else say "rclone: not installed (this version needs none)"; fi
    exit 0 ;;
  link)
    [ $# -eq 2 ] || { echo "usage: cloud-folder-setup link MOUNT_POINT HOST_MOUNT" >&2; exit 2; }
    link_mount_point "$1" "$2"
    exit $? ;;
  *)
    echo "usage: cloud-folder-setup [status [--json] | version | link MOUNT_POINT HOST_MOUNT]" >&2
    exit 2 ;;
esac
