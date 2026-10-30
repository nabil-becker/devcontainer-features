#!/usr/bin/env bash
# cloud-folder-setup: the cloud-folder Feature's postStartCommand (a host folder is mounted, or
# not, per start; the sync timer is started per start), also behind every `task cloud-folder:*`.
#
#   cloud-folder-setup                 post-start: make the state volume usable, start the rclone
#                                      mount in mount mode, report on the folder, start the sync
#                                      timer in sync mode (never fatal)
#   cloud-folder-setup status [--json] the report; exit 0 when the folder is usable, 1 when not
#                                      (host: missing, not mounted, not writable; sync: no
#                                      remote, never synced, last sync failed, not writable;
#                                      mount: no remote, no FUSE, not mounted, uploads failed; or
#                                      a mode this version does not know). --json: one object.
#   cloud-folder-setup version         the Feature version, the mode, the mount point, rclone
#   cloud-folder-setup login [--relay | --token]
#                                      sign in (interactive: rclone's browser flow in the
#                                      container, the browser's address pasted back or relayed by
#                                      the launcher (--relay), or a token from `rclone authorize
#                                      "onedrive"` elsewhere (--token: only that); or client
#                                      credentials from CLOUD_FOLDER_CLIENT_* without a prompt) and
#                                      write the remote into the Feature's rclone.conf; then start
#                                      the timer
#   cloud-folder-setup sync [--resync] [--force]
#                                      one `rclone bisync` between the remote and the folder
#                                      (the first run of a folder is a --resync on its own)
#   cloud-folder-setup start | stop    sync mode: the sync timer (one supervised loop, PID file in
#                                      the volume; start is idempotent, stop waits for a running
#                                      sync). mount mode: the rclone mount (stop = unmount)
#   cloud-folder-setup unmount [--force]
#                                      mount mode: unmount once the VFS upload queue is empty
#                                      (waits up to CLOUD_FOLDER_STOP_WAIT seconds); --force
#                                      unmounts anyway (queued files upload at the next mount)
#   cloud-folder-setup fuse-check      whether FUSE is usable here, and why not: exit 0 or 1
#   cloud-folder-setup run             the timer loop itself (start runs it detached)
#   cloud-folder-setup shutdown-check [SECONDS]
#                                      for a repository's shutdown:check: exit 1 while a sync
#                                      runs (after waiting up to SECONDS, default 60) or while
#                                      local files changed since the last successful sync
#   cloud-folder-setup link MOUNT_POINT HOST_MOUNT
#                                      install.sh, as root: make MOUNT_POINT a symbolic link to
#                                      HOST_MOUNT (nothing when they are the same path)
#   cloud-folder-setup folder MOUNT_POINT
#                                      install.sh, as root, mode sync or mount: make MOUNT_POINT a
#                                      folder
#
# Host mode: the devcontainer-cli launcher bind-mounts the host folder named by
# DCF_HOST_CLOUD_FOLDER at one fixed path, the host mount (/mnt/cloud-folder-host), and
# install.sh links the option mountPoint to it when the two differ. "Mounted" means the path the
# mount point leads to (through the link) is the target of a mount in /proc/self/mountinfo. A
# folder that exists but is not mounted is a bare folder of the container: the status fails
# rather than call it a cloud folder.
#
# Sync mode: no link and no mount; `rclone bisync` fills the folder the mount point leads to
# (path 1 the remote cloud-folder:<remotePath>, path 2 that folder). The rclone config (and so the
# token), the bisync listings, the PID files, the last-sync record and the logs live in the
# Feature's volume (STATE_DIR), never in the workspace or the image; the token is never put on a
# command line and never printed. rclone reads it from the config file (RCLONE_CONFIG).
#
# Mount mode: `rclone mount` of the remote on the folder the mount point leads to, with a VFS
# cache of mode writes in the volume and rclone's remote control (--rc) on localhost only, with no
# credentials, so only its read-only methods answer; status asks vfs/stats for the upload queue.
# It needs FUSE, which only the launcher grants (DCF_HOST_FUSE=1, ADR 0031): /dev/fuse usable,
# CAP_SYS_ADMIN in the bounding set, no AppArmor profile that denies mount, and fusermount3. auto
# takes host, then mount, then sync (proposal section 10, decision 2).
#
# Nothing is written into the folder by a status: writability is the access check (test -w).
# The sync writes one hidden marker there (.cloud-folder-bisync, excluded from the sync) that
# tells a folder already synced from a new one (after a rebuild), which gets a --resync.
# Test hooks (not options): DCF_CLOUD_FOLDER_MOUNTINFO names the mount table to read (default
# /proc/self/mountinfo); DCF_CLOUD_FOLDER_HOST_MOUNT replaces the fixed host mount path;
# DCF_CLOUD_FOLDER_STATE_DIR replaces the state volume's path; DCF_CLOUD_FOLDER_GRACE the
# seconds a sync gets to stop gracefully (default 100); DCF_CLOUD_FOLDER_FUSE_DEV,
# DCF_CLOUD_FOLDER_PROC_STATUS, DCF_CLOUD_FOLDER_APPARMOR and DCF_CLOUD_FOLDER_FUSERMOUNT replace
# /dev/fuse, /proc/self/status, /proc/self/attr/current and the fusermount names the FUSE check
# reads; DCF_CLOUD_FOLDER_RC_ADDR the remote control's address (default 127.0.0.1:5572);
# DCF_CLOUD_FOLDER_MOUNT_WAIT the seconds a mount gets to appear (default 15);
# DCF_CLOUD_FOLDER_AUTH_WAIT the seconds rclone authorize gets to print its link (default 15).
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
remote_type="${CLOUD_FOLDER_REMOTE_TYPE:-${REMOTETYPE:-sharepoint}}"
drive_type="${CLOUD_FOLDER_DRIVE_TYPE:-${DRIVETYPE:-documentLibrary}}"
site_url="${CLOUD_FOLDER_SITE_URL:-${SITEURL:-}}"
remote_path="${CLOUD_FOLDER_REMOTE_PATH:-${REMOTEPATH:-}}"
sync_interval="${CLOUD_FOLDER_SYNC_INTERVAL:-${SYNCINTERVAL:-15m}}"
rclone_version_option="${RCLONEVERSION:-}"
state_dir="${DCF_CLOUD_FOLDER_STATE_DIR:-${STATE_DIR:-/var/lib/devcontainer-features/cloud-folder}}"
grace="${DCF_CLOUD_FOLDER_GRACE:-100}"
fuse_dev="${DCF_CLOUD_FOLDER_FUSE_DEV:-/dev/fuse}"
proc_status="${DCF_CLOUD_FOLDER_PROC_STATUS:-/proc/self/status}"
apparmor_attr="${DCF_CLOUD_FOLDER_APPARMOR:-/proc/self/attr/current}"
fusermount_names="${DCF_CLOUD_FOLDER_FUSERMOUNT:-fusermount3 fusermount}"
# Localhost only: rclone's remote control must never answer from outside the container.
rc_addr="${DCF_CLOUD_FOLDER_RC_ADDR:-127.0.0.1:5572}"
mount_wait="${DCF_CLOUD_FOLDER_MOUNT_WAIT:-15}"

conf="$state_dir/rclone.conf"
run_dir="$state_dir/run"
remote_name=cloud-folder
remote="$remote_name:$remote_path"
marker_name=.cloud-folder-bisync
self="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")"

# A trailing slash would never match the mount table.
while [ "${#mount_point}" -gt 1 ] && [ "${mount_point%/}" != "$mount_point" ]; do mount_point="${mount_point%/}"; done

say() { echo "cloud-folder: $*"; }

# rcl <args>: rclone with the Feature's config and cache in the volume. Only paths and flags go
# on its command line, never a secret.
rcl() { RCLONE_CONFIG="$conf" RCLONE_CACHE_DIR="$state_dir/cache" rclone "$@"; }

as_root() { # run a command as root: directly, or through passwordless sudo
  if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@"; else return 1; fi
}

# is_mounted <path>: the path is the target of a mount. The mount table escapes space, tab,
# newline and backslash as octal (\040, \011, \012, \134), so the path is encoded the same way.
mount_enc() {
  local enc="$1"
  enc="${enc//\\/\\134}"
  enc="${enc// /\\040}"
  enc="${enc//$'\t'/\\011}"
  enc="${enc//$'\n'/\\012}"
  printf '%s' "$enc"
}
is_mounted() {
  [ -r "$mountinfo" ] || return 1
  CF_TARGET="$(mount_enc "$1")" awk '$5 == ENVIRON["CF_TARGET"] { found = 1 } END { exit !found }' "$mountinfo" 2>/dev/null
}
# mount_fstype <path>: the file system type of the last mount on the path (the one on top), from
# the field after the separator "-" of its mountinfo line; empty when nothing is mounted there.
# rclone's mount is fuse.rclone.
mount_fstype() {
  [ -r "$mountinfo" ] || return 0
  CF_TARGET="$(mount_enc "$1")" awk '$5 == ENVIRON["CF_TARGET"] { t = ""; for (i = 7; i < NF; i++) if ($i == "-") { t = $(i + 1); break } }
    END { print t }' "$mountinfo" 2>/dev/null
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

# make_folder <mount point>: the build-time folder of mode sync (install.sh runs it as root). A
# link (left by an earlier layout) gives way; a folder stays as it is; any other file is refused.
make_folder() {
  local mp="$1"
  case "$mp" in /?*) ;; *) echo "cloud-folder: mountPoint '$mp' must be an absolute path." >&2; return 1 ;; esac
  while [ "${#mp}" -gt 1 ] && [ "${mp%/}" != "$mp" ]; do mp="${mp%/}"; done
  if [ -L "$mp" ]; then rm -f -- "$mp" || return 1; fi
  if [ -e "$mp" ] && [ ! -d "$mp" ]; then
    echo "cloud-folder: mountPoint $mp exists in the image and is not a folder; the sync mode needs a folder there." >&2
    return 1
  fi
  mkdir -p -- "$mp" || return 1
  # Hand it to the remote user now when the build names one; the post-start report does it again.
  if [ -n "${_REMOTE_USER:-}" ] && [ "${_REMOTE_USER}" != root ] && id -u "$_REMOTE_USER" >/dev/null 2>&1; then
    chown "$_REMOTE_USER:$(id -gn "$_REMOTE_USER")" "$mp" || return 1
  fi
  say "mountPoint $mp is a folder, filled by the sync or the rclone mount (it is handed to the remote user at start)"
}

# ------------------------------------------------------------- processes ----
# alive <pid>: a running process (a zombie, gone but not yet reaped, does not count).
alive() {
  local st
  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
  st="${st##*) }"
  [ "${st%% *}" != Z ]
}
# ours <pid>: alive and a cloud-folder-setup process (a PID file may outlive its process, and the
# number be reused).
ours() {
  alive "${1:-}" || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q cloud-folder-setup
}
pid_of() { local p=''; [ -f "$1" ] && read -r p < "$1" 2>/dev/null; case "$p" in '' | *[!0-9]*) echo '' ;; *) echo "$p" ;; esac; }
# take_lock <pid file>: write this shell's PID atomically; a file whose process is gone is stale
# and replaced. Exit 1 when another live process holds it.
take_lock() {
  if (set -o noclobber; echo "$$" > "$1") 2>/dev/null; then return 0; fi
  ours "$(pid_of "$1")" && return 1
  rm -f -- "$1"
  (set -o noclobber; echo "$$" > "$1") 2>/dev/null
}
# shellcheck disable=SC2329  # called from the EXIT traps
drop_lock() { [ "$(pid_of "$1")" = "$$" ] && rm -f -- "$1"; return 0; }

# interval_seconds: syncInterval in seconds (15m, 900s, 900, 1h; 0 = on demand only).
interval_seconds() {
  local n u
  [[ "$sync_interval" =~ ^([0-9]+)([smh]?)$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  n=$((10#$n))
  case "$u" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; esac
  echo "$n"
}

# ----------------------------------------------------------------- state ----
# prepare_state: the volume usable by this user (dcf-persist, as every Feature of the collection
# does), the folders inside it private, the config mode 600. Quiet unless asked (report).
prepare_state() {
  local verbose="${1:-quiet}"
  if command -v dcf-persist >/dev/null 2>&1; then
    if [ "$verbose" = verbose ]; then dcf-persist --label 'cloud-folder state' "$state_dir"; else dcf-persist "$state_dir" >/dev/null 2>&1; fi
  elif [ ! -d "$state_dir" ]; then
    mkdir -p -- "$state_dir" 2>/dev/null || { as_root mkdir -p -- "$state_dir" && as_root chown "$(id -u):$(id -g)" "$state_dir"; }
  fi
  [ -w "$state_dir" ] || return 1
  chmod 0700 "$state_dir" 2>/dev/null
  (umask 077; mkdir -p -- "$run_dir" "$state_dir/bisync" "$state_dir/cache") || return 1
  [ -f "$conf" ] && chmod 0600 "$conf" 2>/dev/null
  return 0
}

# conf_state: CONF (missing | unreadable | no-remote | no-token | ok), CONF_TYPE and CONF_AUTH
# (token | client-credentials | none), read from the config without printing any value.
conf_state() {
  local out found tok cc
  CONF=missing; CONF_TYPE=''; CONF_AUTH=none
  [ -e "$conf" ] || return 0
  if [ ! -r "$conf" ]; then CONF=unreadable; return 0; fi
  out="$(awk -v sec="[$remote_name]" '
    /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); in_s = (s == sec); if (in_s) found = 1; next }
    in_s && /^[[:space:]]*type[[:space:]]*=/ { t = $0; sub(/^[^=]*=[[:space:]]*/, "", t); sub(/[[:space:]]*$/, "", t); type = t }
    in_s && /^[[:space:]]*token[[:space:]]*=[[:space:]]*[^[:space:]]/ { tok = 1 }
    in_s && /^[[:space:]]*client_credentials[[:space:]]*=[[:space:]]*true/ { cc = 1 }
    END { printf "%d %s %d %d\n", found, (type == "" ? "-" : type), tok, cc }' "$conf" 2>/dev/null)"
  read -r found CONF_TYPE tok cc <<<"$out"
  [ "$CONF_TYPE" = - ] && CONF_TYPE=''
  if [ "${found:-0}" != 1 ]; then CONF=no-remote; return 0; fi
  if [ "${cc:-0}" = 1 ]; then CONF_AUTH=client-credentials; elif [ "${tok:-0}" = 1 ]; then CONF_AUTH=token; fi
  if [ "$CONF_TYPE" = onedrive ] && [ "$CONF_AUTH" = none ]; then CONF=no-token; return 0; fi
  CONF=ok
}

# read_record: the last sync, from the record the sync writes (key=value lines, never sourced).
read_record() {
  local k v
  LAST_TIME=''; LAST_RESULT=''; LAST_RC=''; LAST_RESYNC=''; LAST_SECONDS=''; LAST_NOTE=''
  [ -r "$state_dir/last-sync" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      time) LAST_TIME="$v" ;; result) LAST_RESULT="$v" ;; rc) LAST_RC="$v" ;;
      resync) LAST_RESYNC="$v" ;; seconds) LAST_SECONDS="$v" ;; note) LAST_NOTE="$v" ;;
    esac
  done < "$state_dir/last-sync"
}

# pending_count <folder>: files changed in the folder since the last successful sync started
# (all files when there was none). Deletions and files arriving with an old modification time
# are not seen; see the NOTES.
pending_count() {
  local dir="$1"
  [ -d "$dir" ] && [ -r "$dir" ] || { echo 0; return; }
  if [ -f "$state_dir/last-ok" ]; then
    find -H "$dir" -type f ! -name "$marker_name" -newer "$state_dir/last-ok" -print 2>/dev/null | head -n 10000 | wc -l | tr -d ' '
  else
    find -H "$dir" -type f ! -name "$marker_name" -print 2>/dev/null | head -n 10000 | wc -l | tr -d ' '
  fi
}

# ------------------------------------------------------------------ FUSE ----
# fuse_check: FUSE (yes | no), FUSE_WHY and FUSERMOUNT, from what the container was given: the
# device (a character device this user can open for reading and writing; the device rules of the
# engine refuse the open otherwise), CAP_SYS_ADMIN (bit 21) in the capability bounding set (what
# the setuid fusermount3 needs to mount), an AppArmor profile that does not deny mount (Docker's
# docker-default does), and fusermount3 (or fusermount) on PATH. Reads only; the device is opened
# and closed. All four come from the launcher (DCF_HOST_FUSE=1) and the fuse3 package.
fuse_check() {
  local capbnd='' k v prof='' f
  FUSE=no; FUSE_WHY=''; FUSERMOUNT=''
  if [ ! -e "$fuse_dev" ]; then
    FUSE_WHY="no $fuse_dev in the container (the launcher grants FUSE when the project sets DCF_HOST_FUSE=1)"; return 0
  fi
  if [ ! -c "$fuse_dev" ]; then FUSE_WHY="$fuse_dev is not a character device"; return 0; fi
  if ! (exec 3<>"$fuse_dev") 2>/dev/null; then
    FUSE_WHY="$fuse_dev cannot be opened for reading and writing (the engine's device rules deny it: --device=/dev/fuse)"; return 0
  fi
  if [ -r "$proc_status" ]; then
    while read -r k v; do [ "$k" = CapBnd: ] && capbnd="$v"; done < "$proc_status"
  fi
  if [[ "$capbnd" =~ ^[0-9a-fA-F]{1,16}$ ]] && [ $(( (16#$capbnd >> 21) & 1 )) -eq 0 ]; then
    FUSE_WHY="no CAP_SYS_ADMIN in the container's capability bounding set (--cap-add=SYS_ADMIN), which mounting needs"; return 0
  fi
  [ -r "$apparmor_attr" ] && read -r prof < "$apparmor_attr" 2>/dev/null
  case "$prof" in
    *-default*'(enforce)'*)
      FUSE_WHY="the AppArmor profile ${prof%% *} denies mount (--security-opt=apparmor=unconfined)"; return 0 ;;
  esac
  for f in $fusermount_names; do
    if command -v "$f" >/dev/null 2>&1; then FUSERMOUNT="$f"; break; fi
  done
  if [ -z "$FUSERMOUNT" ]; then
    FUSE_WHY="no fusermount3 on PATH (the fuse3 package, which the Feature installs in mode auto and mount)"; return 0
  fi
  FUSE=yes; FUSE_WHY="$fuse_dev opens, CAP_SYS_ADMIN is in the bounding set, $FUSERMOUNT is on PATH"
}

# parse_vfs_stats: reads the reply of `rclone rc vfs/stats` (rclone's indented JSON) on stdin and
# sets VFS_OK (yes when it is a vfs/stats reply), VFS_CACHE (off | minimal | writes | full, from
# opt.CacheMode, a number in rclone 1.75 and a name in older releases), VFS_INPROG, VFS_QUEUED and
# VFS_ERRORED (diskCache.uploadsInProgress, uploadsQueued and erroredFiles; empty when there is no
# disk cache, which is cache mode off: no queue to read) and VFS_PENDING (in progress + queued).
parse_vfs_stats() {
  local out ok mode inprog queued errored
  out="$(awk '
    function num(s) { sub(/^[^:]*:[[:space:]]*/, "", s); gsub(/[^0-9]/, "", s); return s }
    /^[[:space:]]*"fs"[[:space:]]*:/ { fs = 1 }
    /^[[:space:]]*"uploadsInProgress"[[:space:]]*:/ { inprog = num($0) }
    /^[[:space:]]*"uploadsQueued"[[:space:]]*:/ { queued = num($0) }
    /^[[:space:]]*"erroredFiles"[[:space:]]*:/ { errored = num($0) }
    /^[[:space:]]*"CacheMode"[[:space:]]*:/ { m = $0; sub(/^[^:]*:[[:space:]]*/, "", m); gsub(/[",[:space:]]/, "", m); mode = m }
    END { printf "%d %s %s %s %s\n", fs, (mode == "" ? "-" : mode), (inprog == "" ? "-" : inprog), (queued == "" ? "-" : queued), (errored == "" ? "-" : errored) }')"
  read -r ok mode inprog queued errored <<<"$out"
  VFS_OK=no; VFS_CACHE=''; VFS_INPROG=''; VFS_QUEUED=''; VFS_ERRORED=''; VFS_PENDING=''
  [ "${ok:-0}" = 1 ] || return 0
  VFS_OK=yes
  case "$mode" in 0) VFS_CACHE=off ;; 1) VFS_CACHE=minimal ;; 2) VFS_CACHE=writes ;; 3) VFS_CACHE=full ;; -) VFS_CACHE=unknown ;; *) VFS_CACHE="$mode" ;; esac
  [ "$inprog" = - ] || VFS_INPROG="$inprog"
  [ "$queued" = - ] || VFS_QUEUED="$queued"
  [ "$errored" = - ] || VFS_ERRORED="$errored"
  if [ -n "$VFS_INPROG" ] && [ -n "$VFS_QUEUED" ]; then VFS_PENDING=$((10#$VFS_INPROG + 10#$VFS_QUEUED)); fi
}

# vfs_query: ask the running mount's remote control for vfs/stats (no credentials: a read-only
# method) and parse it. VFS_OK=no when it does not answer.
vfs_query() {
  local out
  if out="$(timeout 10 rclone rc vfs/stats --url "http://$rc_addr/" 2>/dev/null)"; then
    parse_vfs_stats <<<"$out"
  else
    parse_vfs_stats </dev/null
  fi
}

# wait_uploads <seconds>: query until the upload queue is empty or the time is up; returns 0 when
# it is empty, 1 when files are still pending, 2 when the queue cannot be read.
wait_uploads() {
  local max="$1" waited=0
  while :; do
    vfs_query
    [ "$VFS_OK" = yes ] && [ -n "$VFS_PENDING" ] || return 2
    [ "$VFS_PENDING" -eq 0 ] && return 0
    [ "$waited" -ge "$max" ] && return 1
    sleep 1; waited=$((waited + 1))
  done
}

# mount_ours <pid>: alive and an `rclone mount` (the PID file may outlive its process).
mount_ours() {
  alive "${1:-}" || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'rclone mount '
}

# ---------------------------------------------------------------- assess ----
# resolve: sets the host facts (REAL, LINKED, PRESENT, MOUNTED, RCLONE_MOUNTED, IS_DIR, EMPTY,
# WRITABLE), the FUSE facts (fuse_check) and the mode: MODE_USED (host | mount | sync | none) and
# WHY, or VERDICT=unknown-mode.
resolve() {
  PRESENT=no; MOUNTED=no; RCLONE_MOUNTED=no; IS_DIR=no; EMPTY=unknown; WRITABLE=no; HINT=''; LINKED=no; VERDICT=''
  REAL="$(real_path "$mount_point")"
  [ -L "$mount_point" ] && LINKED=yes
  [ -e "$mount_point" ] && PRESENT=yes
  [ -d "$mount_point" ] && IS_DIR=yes
  is_mounted "$REAL" && MOUNTED=yes
  [ "$MOUNTED" = yes ] && [ "$(mount_fstype "$REAL")" = fuse.rclone ] && RCLONE_MOUNTED=yes
  if [ "$IS_DIR" = yes ] && [ -r "$mount_point" ] && [ -x "$mount_point" ]; then
    if [ -n "$(find -H "$mount_point" -mindepth 1 -maxdepth 1 ! -name "$marker_name" -print -quit 2>/dev/null)" ]; then EMPTY=no; else EMPTY=yes; fi
  fi
  [ "$IS_DIR" = yes ] && [ -w "$mount_point" ] && [ -x "$mount_point" ] && WRITABLE=yes
  conf_state
  fuse_check

  case "$mode_option" in
    host | sync | mount)
      MODE_USED="$mode_option"; WHY='set by the option or CLOUD_FOLDER_MODE' ;;
    auto)
      # host, then mount, then sync (decision 2). A folder that already holds a sync copy stays
      # with sync: rclone would not mount over it, and its unsynced changes would be hidden.
      if [ "$RCLONE_MOUNTED" = yes ]; then MODE_USED=mount; WHY="auto: rclone is mounted at $mount_point"
      elif [ "$MOUNTED" = yes ]; then MODE_USED=host; WHY="auto: something is mounted at $mount_point"
      elif [ "$CONF" != ok ]; then
        MODE_USED=none; WHY="auto: nothing is mounted at $mount_point, and no remote is configured"
        [ "$FUSE" = yes ] && WHY="$WHY (FUSE is usable, so a sign-in gives mount mode)"
      elif [ "$FUSE" = yes ] && [ -f "$REAL/$marker_name" ]; then
        MODE_USED=sync; WHY="auto: nothing is mounted at $mount_point and a remote is configured; FUSE is usable, but $REAL holds a sync copy, so sync stays (stop the timer, sync, empty the folder and run task cloud-folder:setup to move to mount)"
      elif [ "$FUSE" = yes ]; then MODE_USED=mount; WHY="auto: nothing is mounted at $mount_point, a remote is configured and FUSE is usable"
      else MODE_USED=sync; WHY="auto: nothing is mounted at $mount_point and a remote is configured; FUSE is not usable ($FUSE_WHY)"; fi ;;
    *)
      MODE_USED=none; WHY="mode '$mode_option' is unknown (auto, host, mount or sync)"
      VERDICT=unknown-mode ;;
  esac
}

# assess [remote]: resolve, then the verdict (ok | empty | not-mounted | no-source | not-a-folder
# | unwritable | unknown-mode, and in sync mode not-configured | no-rclone | never-synced |
# syncing | needs-resync | sync-failed) and HINT. With "remote", sync mode asks the remote
# whether it answers (REACHABLE yes | no | unknown).
assess() {
  resolve
  [ "$VERDICT" = unknown-mode ] && return 0
  if [ "$MODE_USED" = sync ]; then assess_sync "${1:-}"; return 0; fi
  if [ "$MODE_USED" = mount ]; then assess_mount "${1:-}"; return 0; fi

  if [ "$MOUNTED" = no ]; then
    if [ "$MODE_USED" = none ]; then VERDICT=no-source; else VERDICT=not-mounted; fi
    if [ -n "$host_source" ]; then
      HINT="the launcher was given DCF_HOST_CLOUD_FOLDER=$host_source, but nothing is mounted here: the host folder may not exist (the launcher then skips the mount and says so), HOST_MOUNTS=false may be set, or the container was started without the launcher (task devcontainer:up, devcontainer-cli 1.12.0 or later)."
    else
      HINT="no host folder: set DCF_HOST_CLOUD_FOLDER=<host path> in .devcontainer/.env on the host and start with task devcontainer:up; the launcher then mounts it here (map DCF_HOST_CLOUD_FOLDER with containerEnv so this report can name it)."
    fi
    if [ "$MODE_USED" = none ]; then
      HINT="$HINT Or sync it with rclone: task cloud-folder:login, then the timer (or task cloud-folder:sync) fills it."
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

# check_reachable: REACHABLE yes | no (REACH_ERR) when a remote is configured and rclone is here.
check_reachable() {
  local err
  [ "$CONF" = ok ] && [ "$RCLONE_OK" = yes ] || return 0
  if err="$(timeout 30 env RCLONE_CONFIG="$conf" RCLONE_CACHE_DIR="$state_dir/cache" rclone lsjson --stat --contimeout 10s --timeout 15s --low-level-retries 1 --retries 1 "$remote" 2>&1 >/dev/null)"; then
    REACHABLE=yes
  else
    REACHABLE=no; REACH_ERR="$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-300)"
  fi
}

# assess_mount [remote]: the verdict in mount mode (not-configured | no-rclone | no-fuse | mounting
# | not-mounted | not-a-folder | unwritable | upload-errors | empty | ok). With "remote", the
# remote is asked whether it answers; when rclone is mounted, vfs/stats is read.
assess_mount() {
  local p
  MOUNT_PID=''; REACHABLE=unknown; REACH_ERR=''
  parse_vfs_stats </dev/null
  p="$(pid_of "$run_dir/mount.pid")"; mount_ours "$p" && MOUNT_PID="$p"
  RCLONE_OK=no; command -v rclone >/dev/null 2>&1 && RCLONE_OK=yes
  [ "${1:-}" = remote ] && check_reachable
  [ "$RCLONE_MOUNTED" = yes ] && [ "$RCLONE_OK" = yes ] && vfs_query
  case "$CONF" in
    ok) ;;
    unreadable) VERDICT=not-configured; HINT="$conf cannot be read by $(id -un 2>/dev/null || id -u): run task cloud-folder:setup (it hands the volume to this user)"; return 0 ;;
    *) VERDICT=not-configured; HINT="no remote '$remote_name' with a sign-in in $conf: run task cloud-folder:login"; return 0 ;;
  esac
  if [ "$RCLONE_OK" = no ]; then VERDICT=no-rclone; HINT='rclone is not on PATH: rebuild with the Feature in mode auto or mount'; return 0; fi
  if [ "$RCLONE_MOUNTED" = no ]; then
    if [ "$MOUNTED" = yes ]; then
      VERDICT=not-mounted; HINT="something other than rclone is mounted at $REAL (a host folder?): use mode host, or remove that mount"
    elif [ "$FUSE" = no ]; then
      VERDICT=no-fuse
      HINT="$FUSE_WHY. Mount mode needs FUSE, which the launcher grants per machine: set DCF_HOST_FUSE=1 in .devcontainer/.env on the host (the repository's devcontainer.json needs the DCF_HOST_FUSE_* runArgs of the bootstrap template) and rebuild with task devcontainer:rebuild; or use mode sync, which needs nothing privileged"
    elif [ -n "$MOUNT_PID" ]; then
      VERDICT=mounting; HINT="rclone mount (pid $MOUNT_PID) is starting; log: $state_dir/mount.log"
    elif [ "$IS_DIR" = yes ] && [ -n "$(find -H "$REAL" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
      VERDICT=not-mounted; HINT="$REAL holds files (a sync copy?) and rclone will not mount over them: sync them, move them away, then task cloud-folder:start"
    else
      VERDICT=not-mounted; HINT="rclone is not mounted at $REAL: task cloud-folder:start mounts it (the post-start hook does at each start); log: $state_dir/mount.log"
    fi
    return 0
  fi
  if [ "$IS_DIR" = no ]; then VERDICT=not-a-folder; HINT="$mount_point does not lead to a folder"; return 0; fi
  if [ "$WRITABLE" = no ]; then VERDICT=unwritable; HINT="$(id -un 2>/dev/null || id -u) cannot write to $mount_point: the mount was made by another user; task cloud-folder:stop, then task cloud-folder:start as this user"; return 0; fi
  if [ -n "$VFS_ERRORED" ] && [ "$VFS_ERRORED" -gt 0 ]; then
    VERDICT=upload-errors; HINT="$VFS_ERRORED file(s) failed to upload to the remote; they stay in the VFS cache ($state_dir/cache): read $state_dir/mount.log"; return 0
  fi
  if [ "$EMPTY" = yes ]; then VERDICT=empty; HINT="mounted, but the folder is empty: right for an empty remote folder; otherwise check remotePath"; return 0; fi
  VERDICT=ok
}

assess_sync() {
  local check_remote="${1:-}" p
  read_record
  SYNC_PID=''; LOOP_PID=''; REACHABLE=unknown; REACH_ERR=''
  p="$(pid_of "$run_dir/sync.pid")"; ours "$p" && SYNC_PID="$p"
  p="$(pid_of "$run_dir/loop.pid")"; ours "$p" && LOOP_PID="$p"
  RCLONE_OK=no; command -v rclone >/dev/null 2>&1 && RCLONE_OK=yes
  MARKER=no; [ -f "$REAL/$marker_name" ] && MARKER=yes
  PENDING="$(pending_count "$REAL")"
  NEEDS_RESYNC=no
  [ -n "$(find "$state_dir/bisync" -maxdepth 1 -name '*.lst-err' -print -quit 2>/dev/null)" ] && NEEDS_RESYNC=yes
  [ "$check_remote" = remote ] && check_reachable

  case "$CONF" in
    ok) ;;
    unreadable) VERDICT=not-configured; HINT="$conf cannot be read by $(id -un 2>/dev/null || id -u): run task cloud-folder:setup (it hands the volume to this user)"; return 0 ;;
    *) VERDICT=not-configured; HINT="no remote '$remote_name' with a sign-in in $conf: run task cloud-folder:login"; return 0 ;;
  esac
  if [ "$RCLONE_OK" = no ]; then VERDICT=no-rclone; HINT='rclone is not on PATH: rebuild with the Feature in mode auto or sync'; return 0; fi
  if [ "$PRESENT" = yes ] && [ "$IS_DIR" = no ]; then VERDICT=not-a-folder; HINT="$mount_point is not a folder"; return 0; fi
  if [ "$IS_DIR" = yes ] && [ "$WRITABLE" = no ]; then
    VERDICT=unwritable; HINT="$(id -un 2>/dev/null || id -u) cannot write to $mount_point: run task cloud-folder:setup (it hands the folder to this user)"; return 0
  fi
  if [ "$NEEDS_RESYNC" = yes ]; then
    VERDICT=needs-resync; HINT="bisync stopped on a critical error and keeps its listings aside (.lst-err in $state_dir/bisync): read $state_dir/sync.log, then task cloud-folder:sync -- --resync"; return 0
  fi
  if [ -z "$LAST_RESULT" ] || [ "$MARKER" = no ]; then
    if [ -n "$SYNC_PID" ]; then VERDICT=syncing; HINT="the first sync of $REAL is running (pid $SYNC_PID): wait for it"
    else
      VERDICT=never-synced
      if [ -n "$LAST_RESULT" ]; then HINT="$REAL has not been synced yet (a new folder, after a rebuild?): task cloud-folder:sync (or wait for the timer) fills it"
      else HINT="no sync yet: task cloud-folder:sync (or wait for the timer)"; fi
    fi
    return 0
  fi
  if [ "$LAST_RESULT" != ok ]; then
    VERDICT=sync-failed
    HINT="the last sync ($LAST_TIME) ended $LAST_RESULT (rclone exit $LAST_RC)${LAST_NOTE:+: $LAST_NOTE}; log: $state_dir/sync.log"
    case "$LAST_NOTE" in
      *'too many deletes'*) HINT="$HINT. bisync's delete guard stopped it (more than half the files of one side are gone): restore them, or, if the deletion is meant, task cloud-folder:sync -- --force" ;;
      *'Empty current Path'*) HINT="$HINT. One side is empty and bisync will not empty the other: if the folder was emptied by mistake, task cloud-folder:sync -- --resync brings the files back" ;;
    esac
    return 0
  fi
  if [ "$EMPTY" = yes ]; then VERDICT=empty; HINT="synced, but the folder is empty: right for an empty remote folder; otherwise check remotePath"; return 0; fi
  VERDICT=ok
}

json_str() { # <text>: a JSON string literal
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
json_bool() { if [ "$1" = yes ]; then printf true; else printf false; fi; }
json_tri() { case "$1" in yes) printf true ;; no) printf false ;; *) printf null ;; esac; }

verdict_ok() { [ "$VERDICT" = ok ] || [ "$VERDICT" = empty ]; }

print_json() {
  printf '{"mode_option":%s,"mode":%s,"why":%s,"mount_point":%s,"real_path":%s,"linked":%s,"host_source":%s,' \
    "$(json_str "$mode_option")" "$(json_str "$MODE_USED")" "$(json_str "$WHY")" "$(json_str "$mount_point")" \
    "$(json_str "$REAL")" "$(json_bool "$LINKED")" "$(json_str "$host_source")"
  printf '"present":%s,"mounted":%s,"folder":%s,"empty":%s,"writable":%s,' \
    "$(json_bool "$PRESENT")" "$(json_bool "$MOUNTED")" "$(json_bool "$IS_DIR")" "$(json_tri "$EMPTY")" "$(json_bool "$WRITABLE")"
  if [ "$MODE_USED" = sync ]; then
    printf '"remote":%s,"remote_type":%s,"configured":%s,"auth":%s,"remote_reachable":%s,"last_sync":%s,"last_result":%s,"last_rc":%s,"sync_running":%s,"sync_pid":%s,"timer_running":%s,"timer_pid":%s,"interval":%s,"pending":%s,' \
      "$(json_str "$remote")" "$(json_str "$remote_type")" "$(json_bool "$([ "$CONF" = ok ] && echo yes)")" "$(json_str "$CONF_AUTH")" \
      "$(json_tri "$REACHABLE")" "$(json_str "$LAST_TIME")" "$(json_str "$LAST_RESULT")" "${LAST_RC:-null}" \
      "$(json_bool "$([ -n "$SYNC_PID" ] && echo yes)")" "${SYNC_PID:-null}" "$(json_bool "$([ -n "$LOOP_PID" ] && echo yes)")" "${LOOP_PID:-null}" \
      "$(json_str "$sync_interval")" "${PENDING:-0}"
  fi
  if [ "$MODE_USED" = mount ]; then
    printf '"remote":%s,"remote_type":%s,"configured":%s,"auth":%s,"remote_reachable":%s,"rclone_mounted":%s,"mount_pid":%s,"rc_addr":%s,"rc_answers":%s,"cache_mode":%s,"uploads_in_progress":%s,"uploads_queued":%s,"uploads_pending":%s,"errored_files":%s,' \
      "$(json_str "$remote")" "$(json_str "$remote_type")" "$(json_bool "$([ "$CONF" = ok ] && echo yes)")" "$(json_str "$CONF_AUTH")" \
      "$(json_tri "$REACHABLE")" "$(json_bool "$RCLONE_MOUNTED")" "${MOUNT_PID:-null}" "$(json_str "$rc_addr")" "$(json_bool "$VFS_OK")" \
      "$(if [ -n "$VFS_CACHE" ]; then json_str "$VFS_CACHE"; else printf null; fi)" "${VFS_INPROG:-null}" "${VFS_QUEUED:-null}" "${VFS_PENDING:-null}" "${VFS_ERRORED:-null}"
  fi
  printf '"fuse":%s,"fuse_why":%s,' "$(json_bool "$FUSE")" "$(json_str "$FUSE_WHY")"
  printf '"verdict":%s,"ok":%s,"hint":%s}\n' \
    "$(json_str "$VERDICT")" "$(if verdict_ok; then printf true; else printf false; fi)" "$(json_str "$HINT")"
}

print_report() {
  local state
  say "mode $MODE_USED ($WHY)"
  if [ "$MODE_USED" = sync ]; then print_sync_report; return; fi
  if [ "$MODE_USED" = mount ]; then print_mount_report; return; fi
  if [ "$MOUNTED" = yes ]; then state=mounted; elif [ "$PRESENT" = yes ]; then state='present, not mounted'; else state=missing; fi
  if [ "$LINKED" = yes ]; then say "mount point $mount_point -> $REAL: $state"
  else say "mount point $mount_point: $state"; fi
  [ -n "$host_source" ] && say "host folder (DCF_HOST_CLOUD_FOLDER): $host_source"
  if [ "$MOUNTED" = yes ] && [ "$IS_DIR" = yes ]; then
    case "$EMPTY" in yes) state=empty ;; no) state='not empty' ;; *) state='cannot be listed' ;; esac
    say "contents: $state; writable: $WRITABLE"
  fi
  print_verdict
}

print_sync_report() {
  local state auth reach timer
  case "$CONF_AUTH" in token) auth='signed in with a token' ;; client-credentials) auth='client credentials' ;; *) auth='no sign-in' ;; esac
  case "$CONF" in ok) state="configured, $auth" ;; *) state="not configured ($CONF)" ;; esac
  case "$REACHABLE" in yes) reach=reachable ;; no) reach="NOT reachable${REACH_ERR:+: $REACH_ERR}" ;; *) reach='reachability not checked' ;; esac
  say "remote $remote (remoteType $remote_type${site_url:+, site $site_url}): $state; $reach"
  if [ "$PRESENT" = yes ]; then state=present; else state='missing (made at the first sync)'; fi
  if [ "$LINKED" = yes ]; then say "local copy $mount_point -> $REAL: $state"; else say "local copy $mount_point: $state"; fi
  if [ "$IS_DIR" = yes ]; then
    case "$EMPTY" in yes) state=empty ;; no) state='not empty' ;; *) state='cannot be listed' ;; esac
    say "contents: $state; writable: $WRITABLE; files changed since the last sync: ${PENDING:-0}"
  fi
  if [ -n "$LAST_RESULT" ]; then say "last sync: $LAST_TIME, $LAST_RESULT (rclone exit $LAST_RC${LAST_SECONDS:+, ${LAST_SECONDS}s}${LAST_RESYNC:+, resync $LAST_RESYNC})"
  else say "last sync: never"; fi
  if [ -n "$LOOP_PID" ]; then timer="running (pid $LOOP_PID, every $sync_interval)"
  elif [ "$(interval_seconds 2>/dev/null)" = 0 ]; then timer='off (syncInterval 0: on demand only)'
  else timer='not running'; fi
  if [ -n "$SYNC_PID" ]; then say "sync: running now (pid $SYNC_PID); timer: $timer"; else say "sync: not running; timer: $timer"; fi
  print_verdict
}

print_mount_report() {
  local state auth reach q
  case "$CONF_AUTH" in token) auth='signed in with a token' ;; client-credentials) auth='client credentials' ;; *) auth='no sign-in' ;; esac
  case "$CONF" in ok) state="configured, $auth" ;; *) state="not configured ($CONF)" ;; esac
  case "$REACHABLE" in yes) reach=reachable ;; no) reach="NOT reachable${REACH_ERR:+: $REACH_ERR}" ;; *) reach='reachability not checked' ;; esac
  say "remote $remote (remoteType $remote_type${site_url:+, site $site_url}): $state; $reach"
  if [ "$FUSE" = yes ]; then say "FUSE: usable ($FUSE_WHY)"; else say "FUSE: not usable ($FUSE_WHY)"; fi
  if [ "$RCLONE_MOUNTED" = yes ]; then state="rclone mount${MOUNT_PID:+ (pid $MOUNT_PID)}"
  elif [ -n "${MOUNT_PID:-}" ]; then state="rclone mount starting (pid $MOUNT_PID)"
  else state='not mounted'; fi
  if [ "$LINKED" = yes ]; then say "mount point $mount_point -> $REAL: $state"; else say "mount point $mount_point: $state"; fi
  if [ "$RCLONE_MOUNTED" = yes ]; then
    case "$EMPTY" in yes) state=empty ;; no) state='not empty' ;; *) state='cannot be listed' ;; esac
    say "contents: $state; writable: $WRITABLE"
    if [ "$VFS_OK" = yes ] && [ -n "$VFS_PENDING" ]; then
      say "VFS cache ($VFS_CACHE): uploads in progress $VFS_INPROG, queued $VFS_QUEUED, failed ${VFS_ERRORED:-0}"
    elif [ "$VFS_OK" = yes ]; then
      say "VFS cache ($VFS_CACHE): no upload queue to read (cache mode off?): pending uploads unknown"
    else
      q="remote control on $rc_addr does not answer"
      say "VFS cache: $q: pending uploads unknown"
    fi
  fi
  print_verdict
}

print_verdict() {
  case "$VERDICT" in
    ok) case "$MODE_USED" in
          sync) say "ok: the folder is synced and writable" ;;
          mount) say "ok: the remote is mounted and writable${VFS_PENDING:+ ($VFS_PENDING upload(s) pending)}" ;;
          *) say "ok: the folder is mounted and writable" ;;
        esac ;;
    empty) say "ok, but empty: ${HINT#*: }" ;;
    *) say "not usable ($VERDICT): ${HINT:-$WHY}" ;;
  esac
}

# ------------------------------------------------------------------ sync ----
# ensure_local <folder>: the sync's local folder exists and this user can write it.
ensure_local() {
  local d="$1"
  if [ ! -d "$d" ]; then
    mkdir -p -- "$d" 2>/dev/null || as_root mkdir -p -- "$d" || { say "cannot create $d"; return 1; }
  fi
  if [ ! -w "$d" ] || [ "$(stat -c %u "$d" 2>/dev/null)" != "$(id -u)" ]; then
    as_root chown "$(id -u):$(id -g)" "$d" 2>/dev/null || true
  fi
  [ -w "$d" ] || { say "$(id -un 2>/dev/null || id -u) cannot write to $d"; return 1; }
}

# do_sync [--resync] [--force] [--timer]: one bisync. Exit 0 ok; 1 failed (a later run may
# succeed); 7 critical (bisync wants a --resync); 2 usage; 3 cannot sync here (mode, sign-in,
# rclone, folder); 4 another sync is running.
do_sync() {
  local resync=no force=no timer=no why_resync='' a child rc start secs result note pair stopping=no i
  for a in "$@"; do
    case "$a" in
      --resync) resync=yes; why_resync='asked for' ;;
      --force) force=yes ;;
      --timer) timer=yes ;;
      *) echo "cloud-folder: sync: unknown argument '$a' (--resync, --force)" >&2; return 2 ;;
    esac
  done
  resolve
  if [ "$MODE_USED" != sync ]; then say "nothing to sync: mode $MODE_USED ($WHY)"; return 3; fi
  if [ "$CONF" != ok ]; then say "no remote to sync with ($CONF): run task cloud-folder:login"; return 3; fi
  command -v rclone >/dev/null 2>&1 || { say 'rclone is not on PATH'; return 3; }
  prepare_state || { say "the state folder $state_dir is not writable"; return 3; }
  ensure_local "$REAL" || return 3
  if ! take_lock "$run_dir/sync.pid"; then
    if [ "$timer" = yes ]; then say "timer: skipped, a sync is already running (pid $(pid_of "$run_dir/sync.pid"))"
    else say "a sync is already running (pid $(pid_of "$run_dir/sync.pid")); try again when it ends (task cloud-folder:status)"; fi
    return 4
  fi
  # shellcheck disable=SC2064  # the lock path is fixed now
  trap "drop_lock '$run_dir/sync.pid'" EXIT

  pair="$remote -> $REAL"
  if [ "$resync" = no ]; then
    if [ ! -f "$REAL/$marker_name" ]; then resync=yes; why_resync="first sync of $REAL"
    elif [ "$(cat "$state_dir/bisync-pair" 2>/dev/null)" != "$pair" ]; then resync=yes; why_resync='the remote or the folder changed'; fi
  fi

  local -a args=(bisync "$remote" "$REAL" --workdir "$state_dir/bisync" --max-lock 5m --resilient --recover
    --max-delete 50 --exclude "/$marker_name" --log-file "$state_dir/sync.log" --log-level INFO)
  [ "$resync" = yes ] && args+=(--resync)
  [ "$force" = yes ] && args+=(--force)

  (umask 077; [ -f "$state_dir/sync.log" ] && mv -f "$state_dir/sync.log" "$state_dir/sync.log.1"; : > "$state_dir/sync.log")
  touch "$run_dir/sync.started"
  start="$(date +%s)"
  say "sync: $remote <-> $REAL${why_resync:+ (--resync: $why_resync)}"
  RCLONE_CONFIG="$conf" RCLONE_CACHE_DIR="$state_dir/cache" rclone "${args[@]}" </dev/null >>"$state_dir/sync.log" 2>&1 &
  child=$!
  # A stop (the timer's TERM, or Ctrl-C) asks bisync for its graceful shutdown (SIGINT), then
  # after the grace period ends it with SIGTERM.
  trap 'stopping=yes; kill -INT "$child" 2>/dev/null' TERM INT
  wait "$child" 2>/dev/null; rc=$?
  while alive "$child"; do
    if [ "$stopping" = yes ]; then
      i=0
      while alive "$child" && [ "$i" -lt $((grace * 2)) ]; do sleep 0.5; i=$((i + 1)); done
      alive "$child" && kill -TERM "$child" 2>/dev/null
    fi
    wait "$child" 2>/dev/null; rc=$?
  done
  trap - TERM INT
  secs=$(( $(date +%s) - start ))

  if [ "$rc" -eq 0 ] && [ "$stopping" = no ]; then result=ok
  elif [ "$stopping" = yes ]; then result=interrupted
  elif [ "$rc" -eq 7 ]; then result=critical
  else result=failed; fi
  # The first error that names a cause (not bisync's closing "aborted" lines), else the last one.
  note="$(grep -E 'ERROR|Safety abort' "$state_dir/sync.log" 2>/dev/null | grep -v -E 'retryable|Bisync aborted' | head -n 1)"
  [ -n "$note" ] || note="$(grep -E 'ERROR|Failed' "$state_dir/sync.log" 2>/dev/null | tail -n 1)"
  note="$(printf '%s' "$note" | sed -E 's/^[0-9\/]+ [0-9:]+ //' | tr -d '\r' | cut -c1-300)"
  [ "$result" = ok ] && note=''
  (umask 077
    {
      printf 'time=%s\n' "$(date -u -d "@$start" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'result=%s\nrc=%s\nresync=%s\nseconds=%s\nnote=%s\n' "$result" "$rc" "$resync" "$secs" "$note"
    } > "$state_dir/last-sync.tmp" && mv -f "$state_dir/last-sync.tmp" "$state_dir/last-sync")
  if [ "$result" = ok ]; then
    touch -r "$run_dir/sync.started" "$state_dir/last-ok"
    printf '%s\n' "$pair" > "$REAL/$marker_name"
    printf '%s\n' "$pair" > "$state_dir/bisync-pair"
    say "sync ok in ${secs}s${why_resync:+ (resync)}"
    return 0
  fi
  say "sync $result (rclone exit $rc)${note:+: $note}; log: $state_dir/sync.log"
  case "$note" in
    *'too many deletes'*) say "bisync's delete guard: restore the files, or if the deletion is meant, task cloud-folder:sync -- --force" ;;
    *'Empty current Path'*) say 'one side is empty and bisync will not empty the other: if the folder was emptied by mistake, task cloud-folder:sync -- --resync brings the files back' ;;
  esac
  [ "$rc" -eq 7 ] && return 7
  return 1
}

# ----------------------------------------------------------------- timer ----
start_timer() {
  local secs p i
  resolve
  if [ "$MODE_USED" != sync ]; then say "timer: not started (mode $MODE_USED)"; return 0; fi
  if [ "$CONF" != ok ]; then say 'timer: not started, no remote is configured yet (task cloud-folder:login starts it)'; return 0; fi
  if ! secs="$(interval_seconds)"; then say "timer: not started, syncInterval '$sync_interval' is not a duration (15m, 900s, 1h, 0)"; return 1; fi
  if [ "$secs" -eq 0 ]; then say 'timer: off (syncInterval 0): sync on demand with task cloud-folder:sync'; return 0; fi
  p="$(pid_of "$run_dir/loop.pid")"
  if ours "$p"; then say "timer: already running (pid $p, every $sync_interval)"; return 0; fi
  prepare_state || { say "timer: not started, the state folder $state_dir is not writable"; return 1; }
  if [ -f "$state_dir/timer.log" ] && [ "$(stat -c %s "$state_dir/timer.log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$state_dir/timer.log" "$state_dir/timer.log.1"
  fi
  if command -v setsid >/dev/null 2>&1; then
    (umask 077; setsid bash "$self" run </dev/null >>"$state_dir/timer.log" 2>&1 &)
  else
    (umask 077; nohup bash "$self" run </dev/null >>"$state_dir/timer.log" 2>&1 &)
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p="$(pid_of "$run_dir/loop.pid")"
    ours "$p" && break
    sleep 0.3
  done
  if ours "$p"; then say "timer: started (pid $p, every $sync_interval; the first sync runs now); log: $state_dir/timer.log"; return 0; fi
  say "timer: did not start; see $state_dir/timer.log"
  return 1
}

wait_child() { # the loop's child: wait through signals until it is gone
  wait "$1" 2>/dev/null
  while alive "$1"; do wait "$1" 2>/dev/null; done
}

run_loop() {
  local secs child='' stopping=no
  secs="$(interval_seconds)" || { say "timer: syncInterval '$sync_interval' is not a duration"; return 1; }
  [ "$secs" -eq 0 ] && { say 'timer: syncInterval 0, no timer'; return 0; }
  prepare_state || return 1
  if ! take_lock "$run_dir/loop.pid"; then say "timer: already running (pid $(pid_of "$run_dir/loop.pid"))"; return 0; fi
  # shellcheck disable=SC2064  # the lock path is fixed now
  trap "drop_lock '$run_dir/loop.pid'" EXIT
  trap 'stopping=yes; [ -n "$child" ] && kill -TERM "$child" 2>/dev/null' TERM INT HUP
  say "timer: started $(date -u +%Y-%m-%dT%H:%M:%SZ), pid $$, every $sync_interval"
  while [ "$stopping" = no ]; do
    bash "$self" sync --timer &
    child=$!; wait_child "$child"; child=''
    [ "$stopping" = yes ] && break
    sleep "$secs" &
    child=$!; wait_child "$child"; child=''
  done
  say "timer: stopped $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

stop_timer() {
  local p i max
  max="${CLOUD_FOLDER_STOP_WAIT:-120}"
  p="$(pid_of "$run_dir/loop.pid")"
  if ! ours "$p"; then
    [ -n "$p" ] && rm -f -- "$run_dir/loop.pid"
    say 'timer: not running'
    return 0
  fi
  kill -TERM "$p" 2>/dev/null
  i=0
  while ours "$p" && [ "$i" -lt $((max * 2)) ]; do sleep 0.5; i=$((i + 1)); done
  if ours "$p"; then say "timer: still finishing a sync after ${max}s (pid $p); task cloud-folder:status shows when it ends"; return 1; fi
  say 'timer: stopped'
}

# ----------------------------------------------------------------- mount ----
# start_mount: `rclone mount` of the remote on the folder, detached (its own session), PID file in
# the volume; idempotent. The VFS cache (mode writes, so the upload queue can be read; finding 5)
# lives in the volume; the remote control listens on localhost only and has no credentials, so
# only read-only methods such as vfs/stats answer. The config and token are read from the file.
start_mount() {
  local p i
  resolve
  if [ "$MODE_USED" != mount ]; then say "mount: not started (mode $MODE_USED)"; return 0; fi
  if [ "$CONF" != ok ]; then say 'mount: not started, no remote is configured yet (task cloud-folder:login starts it)'; return 0; fi
  command -v rclone >/dev/null 2>&1 || { say 'mount: not started, rclone is not on PATH'; return 3; }
  if [ "$RCLONE_MOUNTED" = yes ]; then say "mount: already mounted at $REAL"; return 0; fi
  p="$(pid_of "$run_dir/mount.pid")"
  if mount_ours "$p"; then say "mount: rclone (pid $p) is already starting; task cloud-folder:status shows when it is up"; return 0; fi
  if [ "$FUSE" = no ]; then say "mount: not started, FUSE is not usable: $FUSE_WHY"; return 1; fi
  if [ "$MOUNTED" = yes ]; then say "mount: not started, something else is mounted at $REAL"; return 1; fi
  prepare_state || { say "mount: not started, the state folder $state_dir is not writable"; return 1; }
  ensure_local "$REAL" || return 1
  if [ -n "$(find -H "$REAL" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    say "mount: not started, $REAL is not empty and rclone does not mount over files (a sync copy? sync it, then move it away)"
    return 1
  fi
  if [ -f "$state_dir/mount.log" ] && [ "$(stat -c %s "$state_dir/mount.log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$state_dir/mount.log" "$state_dir/mount.log.1"
  fi
  local -a args=(mount "$remote" "$REAL" --vfs-cache-mode writes --cache-dir "$state_dir/cache"
    --rc --rc-addr "$rc_addr" --log-file "$state_dir/mount.log" --log-level INFO)
  # Not --daemon: the PID must be this process's, for the PID file and the stop.
  if command -v setsid >/dev/null 2>&1; then
    (umask 077; RCLONE_CONFIG="$conf" setsid rclone "${args[@]}" </dev/null >/dev/null 2>&1 & echo "$!" > "$run_dir/mount.pid")
  else
    (umask 077; RCLONE_CONFIG="$conf" nohup rclone "${args[@]}" </dev/null >/dev/null 2>&1 & echo "$!" > "$run_dir/mount.pid")
  fi
  p="$(pid_of "$run_dir/mount.pid")"
  i=0
  while [ "$i" -lt $((mount_wait * 4)) ]; do
    [ "$(mount_fstype "$REAL")" = fuse.rclone ] && { say "mount: $remote mounted at $REAL (pid $p, VFS cache writes, remote control $rc_addr); log: $state_dir/mount.log"; return 0; }
    alive "$p" || break
    sleep 0.25; i=$((i + 1))
  done
  if alive "$p"; then say "mount: rclone (pid $p) has not mounted $REAL after ${mount_wait}s; task cloud-folder:status shows when it does; log: $state_dir/mount.log"; return 1; fi
  rm -f -- "$run_dir/mount.pid"
  say "mount: rclone exited without mounting: $(grep -E 'ERROR|CRITICAL|Fatal' "$state_dir/mount.log" 2>/dev/null | tail -n 1 | sed -E 's/^[0-9\/]+ [0-9:]+ //' | cut -c1-300); log: $state_dir/mount.log"
  return 1
}

# stop_mount [--force]: unmount once the upload queue is empty (waiting up to
# CLOUD_FOLDER_STOP_WAIT seconds, default 120); refuse while files are pending or the queue cannot
# be read, unless --force (rclone uploads what is left in the VFS cache at the next mount).
stop_mount() {
  local force=no a p i max rc=0
  max="${CLOUD_FOLDER_STOP_WAIT:-120}"
  for a in "$@"; do
    case "$a" in --force) force=yes ;; *) echo "cloud-folder: unmount: unknown argument '$a' (--force)" >&2; return 2 ;; esac
  done
  resolve
  p="$(pid_of "$run_dir/mount.pid")"; mount_ours "$p" || p=''
  if [ "$RCLONE_MOUNTED" = no ] && [ -z "$p" ]; then
    rm -f -- "$run_dir/mount.pid"
    say 'mount: not mounted'
    return 0
  fi
  if [ "$force" = no ] && [ "$RCLONE_MOUNTED" = yes ]; then
    wait_uploads "$max" || rc=$?
    if [ "$rc" -eq 2 ]; then
      say "mount: not unmounted, the upload queue cannot be read (remote control on $rc_addr does not answer); task cloud-folder:unmount -- --force unmounts anyway (queued files upload at the next mount)"
      return 1
    fi
    if [ "$rc" -eq 1 ]; then
      say "mount: not unmounted, $VFS_PENDING upload(s) still pending after ${max}s; wait and try again, or task cloud-folder:unmount -- --force (they upload at the next mount)"
      return 1
    fi
  fi
  if [ "$RCLONE_MOUNTED" = yes ]; then
    if [ -n "$FUSERMOUNT" ]; then "$FUSERMOUNT" -u "$REAL" 2>/dev/null || as_root umount "$REAL" 2>/dev/null
    else as_root umount "$REAL" 2>/dev/null; fi
  fi
  if [ -n "$p" ]; then
    i=0
    while alive "$p" && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    alive "$p" && kill -TERM "$p" 2>/dev/null
    i=0
    while alive "$p" && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
  fi
  if [ "$(mount_fstype "$REAL")" = fuse.rclone ]; then say "mount: $REAL is still mounted (busy? a shell or editor inside it)"; return 1; fi
  rm -f -- "$run_dir/mount.pid"
  say "mount: unmounted $REAL"
}

# start_any / stop_any: what `start` and `stop` mean in the mode in use.
start_any() { resolve; if [ "$MODE_USED" = mount ]; then start_mount; else start_timer; fi; }
stop_any() { resolve; if [ "$MODE_USED" = mount ]; then stop_mount "$@"; else stop_timer; fi; }

# shutdown_check [SECONDS]: exit 1 while a sync runs (after waiting) or local changes wait; in
# mount mode, while uploads are pending (after waiting) or the queue cannot be read.
shutdown_check() {
  local max="${1:-${CLOUD_FOLDER_SHUTDOWN_WAIT:-60}}" waited=0 p rc=0
  case "$max" in '' | *[!0-9]*) echo "cloud-folder: shutdown-check: SECONDS must be a number" >&2; return 2 ;; esac
  resolve
  if [ "$MODE_USED" = mount ]; then shutdown_check_mount "$max"; return $?; fi
  if [ "$MODE_USED" != sync ]; then say "shutdown check: mode $MODE_USED, no sync in flight"; return 0; fi
  p="$(pid_of "$run_dir/sync.pid")"
  if ours "$p"; then
    say "shutdown check: a sync is running (pid $p); waiting up to ${max}s for it to end"
    while ours "$p" && [ "$waited" -lt "$max" ]; do sleep 1; waited=$((waited + 1)); done
  fi
  if ours "$p"; then
    say "REFUSE: a sync is still running (pid $p) after ${max}s; a stop now would cut it short. Wait and run the check again (task cloud-folder:status), or stop with FORCE=1."
    rc=1
  fi
  read_record
  local n
  n="$(pending_count "$REAL")"
  if [ "$CONF" = ok ] && [ "$n" -gt 0 ]; then
    if [ -n "$LAST_TIME" ]; then
      say "REFUSE: $n file(s) in $REAL changed since the last successful sync started; run task cloud-folder:sync first, or stop with FORCE=1."
    else
      say "REFUSE: $REAL has $n file(s) and has never been synced; run task cloud-folder:sync first, or stop with FORCE=1."
    fi
    rc=1
  elif [ "$CONF" != ok ] && [ "$n" -gt 0 ]; then
    say "note: $REAL has $n file(s) and no remote is configured; they live only in this container."
  fi
  if [ -n "$LAST_RESULT" ] && [ "$LAST_RESULT" != ok ]; then say "note: the last sync ended $LAST_RESULT (task cloud-folder:status)."; fi
  [ "$rc" -eq 0 ] && say "shutdown check: no sync running, nothing changed since the last sync${LAST_TIME:+ ($LAST_TIME)}: safe to stop"
  return "$rc"
}

shutdown_check_mount() {
  local max="$1" rc=0
  if [ "$RCLONE_MOUNTED" = no ]; then say "shutdown check: mode mount, nothing mounted: no upload in flight"; return 0; fi
  if command -v rclone >/dev/null 2>&1; then
    vfs_query
    if [ "$VFS_OK" = yes ] && [ -n "$VFS_PENDING" ] && [ "$VFS_PENDING" -gt 0 ]; then
      say "shutdown check: $VFS_PENDING upload(s) pending; waiting up to ${max}s for them"
    fi
    wait_uploads "$max" || rc=$?
  else
    rc=2
  fi
  case "$rc" in
    2) say "REFUSE: the upload queue cannot be read (rclone's remote control on $rc_addr does not answer), so a stop could cut uploads short; task cloud-folder:status, or stop with FORCE=1."; return 1 ;;
    1) say "REFUSE: $VFS_PENDING upload(s) still pending after ${max}s; wait and run the check again (task cloud-folder:status), or stop with FORCE=1 (they upload at the next mount)."; return 1 ;;
  esac
  [ -n "$VFS_ERRORED" ] && [ "$VFS_ERRORED" -gt 0 ] && say "note: $VFS_ERRORED file(s) failed to upload (task cloud-folder:status)."
  say "shutdown check: mode mount, no upload pending: safe to stop"
  return 0
}

# ----------------------------------------------------------------- login ----
json_field() { # <name> <text>: the first "name": "string" value of rclone's pretty JSON
  sed -n 's/^[[:space:]]*"'"$1"'":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' <<<"$2" | head -n 1
}

# section_write <line>...: replace the [cloud-folder] section of the config with these lines
# (other remotes kept). Written with shell builtins into a private file; nothing reaches argv.
section_write() {
  local tmp="$conf.tmp.$$" line
  (umask 077
    if [ -f "$conf" ]; then
      awk -v sec="[$remote_name]" '/^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); skip = (s == sec) } !skip' "$conf" > "$tmp" || exit 1
    else
      : > "$tmp" || exit 1
    fi) || return 1
  {
    printf '[%s]\n' "$remote_name"
    for line in "$@"; do printf '%s\n' "$line"; done
  } >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f -- "$tmp" "$conf"
}

# drive_lookup <secret> <answers...>: run rclone's own non-interactive config for the remote,
# answering its questions, so it finds the drive (drive_id and drive_type) from the site. The
# answers are paths and choices, never a secret; rclone's replies are parsed, never shown whole.
drive_lookup() {
  local secret="$1" out state name err result n i choice
  shift
  local -a values helps
  out="$(rcl config update "$remote_name" "$@" --non-interactive 2>&1)"
  for _ in 1 2 3 4 5 6 7 8; do
    state="$(json_field State "$out")"
    err="$(json_field Error "$out")"
    name="$(json_field Name "$out")"
    if [ -n "$err" ]; then
      [ -n "$secret" ] && err="${err//"$secret"/[secret]}"
      say "the drive lookup failed: $err"
      return 1
    fi
    if [ -z "$state" ]; then
      if grep -q '"State"' <<<"$out"; then return 0; fi
      out="$(printf '%s\n' "$out" | tail -n 3)"
      [ -n "$secret" ] && out="${out//"$secret"/[secret]}"
      say "the drive lookup gave no answer rclone understood: $out"
      return 1
    fi
    case "$name" in
      config_driveid)
        mapfile -t values < <(sed -n 's/^[[:space:]]*"Value":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' <<<"$out")
        mapfile -t helps < <(sed -n 's/^[[:space:]]*"Help":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' <<<"$out")
        n="${#values[@]}"
        if [ "$n" -eq 0 ]; then say 'the site has no drive (document library) this sign-in can see'; return 1; fi
        if [ "$n" -eq 1 ]; then result="${values[0]}"; say "drive: ${helps[0]:-${values[0]}}"
        else
          say "the site has $n drives (document libraries):"
          for ((i = 0; i < n; i++)); do echo "  $((i + 1))) ${helps[$i]:-} [${values[$i]}]"; done
          if [ ! -t 0 ] && [ -z "${CLOUD_FOLDER_DRIVE_CHOICE:-}" ]; then
            say 'choose one: set CLOUD_FOLDER_DRIVE_ID to its id (in brackets) and run login again'
            return 1
          fi
          choice="${CLOUD_FOLDER_DRIVE_CHOICE:-}"
          if [ -z "$choice" ]; then printf 'cloud-folder: which one (1-%s)? ' "$n"; read -r choice || choice=''; fi
          case "$choice" in '' | *[!0-9]*) say "not a number: '$choice'"; return 1 ;; esac
          if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then say "not between 1 and $n: $choice"; return 1; fi
          result="${values[$((choice - 1))]}"
        fi ;;
      config_drive_ok) result=true ;;
      *) say "rclone asked a question this login does not know ($name); finish with: rclone config reconnect $remote_name: (RCLONE_CONFIG=$conf)"; return 1 ;;
    esac
    out="$(rcl config update "$remote_name" "$@" --non-interactive --continue --state "$state" --result "$result" 2>&1)"
  done
  say 'the drive lookup did not finish'
  return 1
}

# ------------------------------------------------------------- sign-in ----
# The sign-in runs rclone's own browser flow in the container: `rclone authorize "onedrive"
# --auth-no-open-browser` listens on 127.0.0.1:53682 (fixed: rclone's app registration allows only
# the redirect http://localhost:53682/) and prints a link to its /auth page, which redirects to
# Microsoft's sign-in; after the sign-in Microsoft sends the browser to
# http://localhost:53682/?code=...&state=..., rclone takes the code, gets the token and prints it
# between "Paste the following into your remote machine --->" and "<---End paste". Three ways the
# browser's redirect reaches rclone (task cloud-folder:login picks one):
#   relay   the devcontainer-cli launcher listens on the workstation's 127.0.0.1:53682 for the
#           sign-in only and relays each request into the container (docker exec, bash /dev/tcp);
#           here the login just prints the link and waits (login --relay).
#   paste   the person opens Microsoft's sign-in address in any browser; the redirect fails
#           ("cannot be reached"); they paste that address here and the login requests it on
#           127.0.0.1:53682 itself, so rclone receives the code.
#   token   `rclone authorize "onedrive"` ran on a machine with a browser (the launcher's
#           --workstation-rclone, or by hand) and its one-line token is pasted (login --token,
#           or at the paste prompt).
# The token never reaches a command line: rclone writes it into a private file in the volume's
# run folder, read and removed at once.
AUTH_PID='' AUTH_DIR='' AUTH_LINK='' AUTH_HOST='' AUTH_PORT='' LOGIN_TOKEN='' PASTE_KIND='' PASTE_PATH=''

# shellcheck disable=SC2329  # called from the EXIT trap
auth_stop() {
  if [ -n "$AUTH_PID" ]; then kill -TERM "$AUTH_PID" 2>/dev/null; wait "$AUTH_PID" 2>/dev/null; AUTH_PID=''; fi
  if [ -n "$AUTH_DIR" ]; then rm -rf -- "$AUTH_DIR"; AUTH_DIR=''; fi
  return 0
}

# auth_start: rclone authorize in the background; AUTH_LINK (its /auth link), AUTH_HOST and
# AUTH_PORT (where it listens). Waits up to DCF_CLOUD_FOLDER_AUTH_WAIT seconds (default 15) for
# the link. Exit 1, with AUTH_ERROR set, when it does not start.
auth_start() {
  local i max="${DCF_CLOUD_FOLDER_AUTH_WAIT:-15}" text
  AUTH_ERROR=''
  AUTH_DIR="$(umask 077; mktemp -d "$run_dir/login.XXXXXX")" || { AUTH_ERROR="cannot make a private folder in $run_dir"; return 1; }
  trap auth_stop EXIT
  trap 'auth_stop; exit 130' INT TERM HUP
  # A plain command, not rcl: the background job is rclone itself, so auth_stop's signal reaches it.
  RCLONE_CONFIG="$conf" RCLONE_CACHE_DIR="$state_dir/cache" rclone authorize onedrive --auth-no-open-browser > "$AUTH_DIR/out" 2> "$AUTH_DIR/err" < /dev/null &
  AUTH_PID=$!
  for ((i = 0; i < max * 10; i++)); do
    text="$(cat "$AUTH_DIR/err" "$AUTH_DIR/out" 2>/dev/null)"
    if [[ "$text" =~ (http://(127\.0\.0\.1|localhost):([0-9]+)/auth\?state=[A-Za-z0-9_.~-]+) ]]; then
      AUTH_LINK="${BASH_REMATCH[1]}"; AUTH_HOST="${BASH_REMATCH[2]}"; AUTH_PORT="${BASH_REMATCH[3]}"
      return 0
    fi
    if ! kill -0 "$AUTH_PID" 2>/dev/null; then
      wait "$AUTH_PID" 2>/dev/null; i=$?; AUTH_PID=''
      AUTH_ERROR="exit $i: $(tail -n 1 "$AUTH_DIR/err" 2>/dev/null | sed 's/^[0-9\/: ]*//')"
      auth_stop
      return 1
    fi
    sleep 0.1
  done
  AUTH_ERROR="rclone authorize printed no sign-in link within ${max}s"
  auth_stop
  return 1
}

# auth_error_line: rclone's last error line (never a token: those lines are on stdout).
auth_error_line() {
  grep -E 'ERROR|Failed|failed|error' "$AUTH_DIR/err" 2>/dev/null | tail -n 1 | sed 's/^[0-9\/: ]*//'
}

# http_get <host> <port> <path>: one HTTP/1.0 GET over bash's /dev/tcp; the response on stdout.
http_get() {
  local fd
  exec {fd}<>"/dev/tcp/$1/$2" || return 1
  printf 'GET %s HTTP/1.0\r\nHost: localhost:53682\r\nConnection: close\r\n\r\n' "$3" >&"$fd"
  cat <&"$fd"
  exec {fd}>&-
}

# parse_paste <text>: PASTE_KIND token (one line of JSON with access_token), code (the address the
# browser shows after the sign-in, http://localhost:53682/?code=..., with or without the scheme;
# PASTE_PATH is its path and query) or bad.
parse_paste() {
  local t="$1" rest
  PASTE_KIND=bad PASTE_PATH=''
  case "$t" in '{'*'"access_token"'*'}') PASTE_KIND=token; return 0 ;; esac
  rest="${t#http://}"; rest="${rest#https://}"
  case "$rest" in
    localhost:53682/* | 127.0.0.1:53682/* | localhost/* | 127.0.0.1/*) rest="/${rest#*/}" ;;
    localhost:53682\?* | 127.0.0.1:53682\?* | localhost\?* | 127.0.0.1\?*) rest="/?${rest#*\?}" ;;
    *) return 0 ;;
  esac
  [[ "$rest" =~ ^/[^[:space:]]*\?([^[:space:]]*&)?(code|error)=[^[:space:]]+$ ]] || return 0
  PASTE_KIND=code PASTE_PATH="$rest"
}

# deliver_code <path>: request it on rclone's listener, as the browser would have. Exit 0 when
# rclone took it (HTTP 200), 1 otherwise (AUTH_ERROR: its status line).
deliver_code() {
  local resp status
  resp="$(http_get "$AUTH_HOST" "$AUTH_PORT" "$1" 2>/dev/null)" || { AUTH_ERROR='rclone is no longer listening'; return 1; }
  status="$(head -n 1 <<<"$resp" | tr -d '\r')"
  case "$status" in 'HTTP/'*' 200'*) return 0 ;; esac
  AUTH_ERROR="${status:-no answer}"
  return 1
}

# auth_token: the token rclone printed between its paste markers, into LOGIN_TOKEN.
auth_token() {
  LOGIN_TOKEN="$(awk '/^Paste the following into your remote machine --->/ { on = 1; next } /^<---End paste/ { exit } on && NF { print; exit }' "$AUTH_DIR/out" 2>/dev/null)"
  [ -n "$LOGIN_TOKEN" ]
}

# read_line_from_stdin: one line (no echo on a terminal), in LINE, waiting up to 1 s. Exit 0 with
# a line, 1 at the end of input, 2 when nothing came yet.
read_line_from_stdin() {
  local part='' rc
  if [ -t 0 ]; then IFS= read -r -s -t 1 part; else IFS= read -r -t 1 part; fi
  rc=$?
  if [ "$rc" -eq 0 ]; then LINE="$LINE_BUF$part"; LINE_BUF=''; [ -t 0 ] && echo; return 0; fi
  if [ "$rc" -gt 128 ]; then LINE_BUF+="$part"; return 2; fi
  if [ -n "$LINE_BUF$part" ]; then LINE="$LINE_BUF$part"; LINE_BUF=''; return 0; fi
  return 1
}

trim() { local t="${1//$'\r'/}"; t="${t#"${t%%[![:space:]]*}"}"; printf '%s' "${t%"${t##*[![:space:]]}"}"; }

# read_token <route> <rclone version>: the sign-in, by the route (relay, paste or token), into
# LOGIN_TOKEN; exit 1 (nothing changed) when there is none.
read_token() {
  local route="$1" v="$2" timeout="${CLOUD_FOLDER_LOGIN_TIMEOUT:-600}" start ms_url='' input=yes LINE='' LINE_BUF='' rc delivered=no
  local hint="rclone authorize \"onedrive\""
  say "sign-in for remote '$remote_name' (remoteType $remote_type), rclone $v."
  if [ "$route" != token ]; then
    if ! auth_start; then
      if [ "$route" = relay ]; then say "rclone authorize could not start here: $AUTH_ERROR"; return 1; fi
      say "rclone authorize could not start here ($AUTH_ERROR); paste a token instead."
      route=token
    fi
  fi
  if [ "$route" = token ]; then
    say "On a machine with a web browser, install the same rclone version ($v, https://downloads.rclone.org/$v/) and run:"
    echo
    echo "    $hint"
    echo
    say 'sign in in the browser it opens; it prints a token between "Paste the following into your remote machine --->" and "<---End paste".'
    [ -t 0 ] && printf 'cloud-folder: paste that token here and press Enter (it is not shown): '
    if [ -t 0 ]; then read -r -s LINE || LINE=''; echo; else read -r LINE || true; fi
    LINE="$(trim "$LINE")"
    parse_paste "$LINE"
    case "$PASTE_KIND" in
      token) LOGIN_TOKEN="$LINE"; return 0 ;;
      *) if [ -z "$LINE" ]; then say 'no token pasted; nothing changed'; else say 'that is not the token rclone authorize prints (one line of JSON with access_token); nothing changed. Check that both sides run the same rclone version.'; fi
         return 1 ;;
    esac
  fi

  if [ "$route" = relay ]; then
    say "sign-in URL: $AUTH_LINK"
    say "waiting up to ${timeout}s for the sign-in in the browser (the launcher relays it here)..."
  else
    ms_url="$(http_get "$AUTH_HOST" "$AUTH_PORT" "/${AUTH_LINK#http://*/}" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -n 1)"
    ms_url="${ms_url:-$AUTH_LINK}"
    say 'open this address in a web browser (on any machine) and sign in:'
    echo
    echo "    sign-in URL: $ms_url"
    echo
    say 'the browser then shows an error page for http://localhost:53682/?code=... ("cannot be reached"): that is expected.'
    say 'copy that whole address from the address bar and paste it here.'
    say "or paste the token that $hint prints on a machine with a browser (rclone $v, https://downloads.rclone.org/$v/)."
    [ -t 0 ] && printf 'cloud-folder: address or token (not shown): '
  fi

  start=$SECONDS
  while kill -0 "$AUTH_PID" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      say "no sign-in within ${timeout}s; nothing changed (CLOUD_FOLDER_LOGIN_TIMEOUT sets the wait)"
      auth_stop; return 1
    fi
    if [ "$input" = no ]; then sleep 0.2; continue; fi
    read_line_from_stdin; rc=$?
    if [ "$rc" -eq 2 ]; then continue; fi
    if [ "$rc" -eq 1 ]; then
      input=no
      if [ "$route" != relay ] && [ "$delivered" = no ]; then say 'no address or token pasted; nothing changed'; auth_stop; return 1; fi
      continue
    fi
    LINE="$(trim "$LINE")"
    [ -n "$LINE" ] || continue
    parse_paste "$LINE"
    case "$PASTE_KIND" in
      token) LOGIN_TOKEN="$LINE"; auth_stop; return 0 ;;
      code)
        if deliver_code "$PASTE_PATH"; then
          say 'address received; rclone is getting the token...'
          delivered=yes input=no
        else
          say "rclone refused that address ($AUTH_ERROR): it belongs to another sign-in, or was pasted twice. Sign in again with the sign-in URL above and paste the new address."
          if [ ! -t 0 ]; then auth_stop; return 1; fi
          printf 'cloud-folder: address or token (not shown): '
        fi ;;
      *)
        say 'that is neither the address the browser shows after the sign-in (http://localhost:53682/?code=...) nor the token rclone authorize prints; nothing changed.'
        if [ ! -t 0 ]; then auth_stop; return 1; fi
        printf 'cloud-folder: address or token (not shown): ' ;;
    esac
  done
  wait "$AUTH_PID" 2>/dev/null; rc=$?
  AUTH_PID=''
  if [ "$rc" -ne 0 ] || ! auth_token; then
    AUTH_ERROR="$(auth_error_line)"
    say "rclone authorize failed (exit $rc${AUTH_ERROR:+: $AUTH_ERROR}); nothing changed"
    auth_stop; return 1
  fi
  auth_stop
  parse_paste "$LOGIN_TOKEN"
  if [ "$PASTE_KIND" != token ]; then LOGIN_TOKEN=''; say 'rclone authorize printed something that is not a token; nothing changed'; return 1; fi
  say 'signed in in the browser; rclone has the token'
  return 0
}

do_login() {
  local v token secret='' auth lines drive_id="${CLOUD_FOLDER_DRIVE_ID:-}" ctype login_route=paste a
  for a in "$@"; do
    case "$a" in
      --relay) login_route=relay ;;
      --token) login_route=token ;;
      *) say "login: unknown argument '$a' (--relay or --token)"; return 2 ;;
    esac
  done
  local -a answers=()
  command -v rclone >/dev/null 2>&1 || { say 'rclone is not on PATH: rebuild with the Feature in mode auto or sync'; return 3; }
  prepare_state || { say "the state folder $state_dir is not writable"; return 3; }
  case "$remote_type" in
    sharepoint)
      if [ -z "$drive_id" ] && [ -z "$site_url" ]; then say 'remoteType sharepoint needs siteUrl (the option, or CLOUD_FOLDER_SITE_URL), for example https://<tenant>.sharepoint.com/sites/<site>'; return 2; fi
      ctype=url ;;
    onedrive) ctype=onedrive ;;
    *) say "remoteType '$remote_type' is not known (sharepoint or onedrive)"; return 2 ;;
  esac
  v="$(rclone version 2>/dev/null | head -n 1)"; v="${v#rclone }"

  if [ -n "${CLOUD_FOLDER_CLIENT_ID:-}" ]; then
    # Client credentials (the cluster case; unverified, see NOTES): an app registration's id, its
    # tenant, and its secret from a file the platform mounts or from the environment.
    auth=client-credentials
    if [ -z "${CLOUD_FOLDER_TENANT:-}" ]; then say 'client credentials need CLOUD_FOLDER_TENANT (the tenant id) too'; return 2; fi
    if [ -n "${CLOUD_FOLDER_CLIENT_SECRET_FILE:-}" ]; then
      [ -r "$CLOUD_FOLDER_CLIENT_SECRET_FILE" ] || { say "CLOUD_FOLDER_CLIENT_SECRET_FILE cannot be read: $CLOUD_FOLDER_CLIENT_SECRET_FILE"; return 2; }
      secret="$(< "$CLOUD_FOLDER_CLIENT_SECRET_FILE")"
    else
      secret="${CLOUD_FOLDER_CLIENT_SECRET:-}"
    fi
    unset CLOUD_FOLDER_CLIENT_SECRET
    secret="${secret//$'\r'/}"; secret="${secret%%$'\n'*}"
    [ -n "$secret" ] || { say 'client credentials need a secret: CLOUD_FOLDER_CLIENT_SECRET_FILE (a file) or CLOUD_FOLDER_CLIENT_SECRET'; return 2; }
    lines=("type = onedrive" "client_id = $CLOUD_FOLDER_CLIENT_ID" "client_secret = $secret" "tenant = $CLOUD_FOLDER_TENANT" "client_credentials = true" "drive_type = $drive_type")
  else
    auth=token
    read_token "$login_route" "$v" || return 1
    token="$LOGIN_TOKEN"; LOGIN_TOKEN=''
    secret="$token"
    lines=("type = onedrive" "token = $token" "drive_type = $drive_type")
    answers+=(config_refresh_token=false)
  fi
  [ -n "$drive_id" ] && lines+=("drive_id = $drive_id")
  section_write "${lines[@]}" || { say "could not write $conf"; return 1; }
  say "remote '$remote_name' written to $conf (mode 600, $auth)"

  if [ -z "$drive_id" ]; then
    answers+=("config_type=$ctype")
    [ "$ctype" = url ] && answers+=("config_site_url=$site_url")
    if ! drive_lookup "$secret" "${answers[@]}"; then
      say "the sign-in is kept, but the remote has no drive yet: fix the cause and run task cloud-folder:login again, or set CLOUD_FOLDER_DRIVE_ID"
      return 1
    fi
  fi
  chmod 0600 "$conf" 2>/dev/null
  secret=''; token=''
  if rcl lsjson --stat --contimeout 10s --timeout 15s --low-level-retries 1 --retries 1 "$remote" >/dev/null 2>&1; then
    say "signed in: $remote answers"
  else
    say "signed in, but $remote does not answer yet (a wrong remotePath? it must exist on the remote); task cloud-folder:status shows the error"
  fi
  start_any
  return 0
}

# ---------------------------------------------------------------- report ----
cmd="${1:-report}"
[ $# -gt 0 ] && shift
case "$cmd" in
  report)
    prepare_state verbose || true
    resolve
    [ "$MODE_USED" = sync ] && ensure_local "$REAL" >/dev/null 2>&1
    [ "$MODE_USED" = mount ] && start_mount
    assess remote
    print_report
    [ "$MODE_USED" = sync ] && start_timer
    exit 0 ;;
  status)
    json=no
    for a in "$@"; do
      case "$a" in
        --json) json=yes ;;
        *) echo "cloud-folder: status: unknown argument '$a' (only --json)" >&2; exit 2 ;;
      esac
    done
    assess remote
    if [ "$json" = yes ]; then print_json; else print_report; fi
    verdict_ok && exit 0
    exit 1 ;;
  version)
    resolve
    say "Feature $feature_version; mode option $mode_option (in use: $MODE_USED); mount point $mount_point; host mount $host_mount; state $state_dir"
    if [ "$FUSE" = yes ]; then say "FUSE: usable"; else say "FUSE: not usable ($FUSE_WHY)"; fi
    if command -v rclone >/dev/null 2>&1; then say "rclone: $(rclone version 2>/dev/null | head -n 1)${rclone_version_option:+ (option rcloneVersion $rclone_version_option)}"
    else say "rclone: not installed (mode host needs none)"; fi
    exit 0 ;;
  login) do_login "$@"; exit $? ;;
  sync) do_sync "$@"; exit $? ;;
  start) start_any; exit $? ;;
  stop) stop_any "$@"; exit $? ;;
  unmount) stop_mount "$@"; exit $? ;;
  fuse-check)
    fuse_check
    if [ "$FUSE" = yes ]; then say "FUSE usable: $FUSE_WHY"; exit 0; fi
    say "FUSE not usable: $FUSE_WHY"; exit 1 ;;
  run) run_loop; exit $? ;;
  shutdown-check)
    [ $# -le 1 ] || { echo "usage: cloud-folder-setup shutdown-check [SECONDS]" >&2; exit 2; }
    shutdown_check "${1:-}"; exit $? ;;
  link)
    [ $# -eq 2 ] || { echo "usage: cloud-folder-setup link MOUNT_POINT HOST_MOUNT" >&2; exit 2; }
    link_mount_point "$1" "$2"
    exit $? ;;
  folder)
    [ $# -eq 1 ] || { echo "usage: cloud-folder-setup folder MOUNT_POINT" >&2; exit 2; }
    make_folder "$1"
    exit $? ;;
  *)
    echo "usage: cloud-folder-setup [status [--json] | version | login [--relay | --token] | sync [--resync] [--force] | start | stop | unmount [--force] | fuse-check | shutdown-check [SECONDS] | link MOUNT_POINT HOST_MOUNT | folder MOUNT_POINT]" >&2
    exit 2 ;;
esac
