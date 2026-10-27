#!/usr/bin/env bash
# cloud-folder-setup: the cloud-folder Feature's postStartCommand (a host folder is mounted, or
# not, per start; the sync timer is started per start), also behind every `task cloud-folder:*`.
#
#   cloud-folder-setup                 post-start: make the state volume usable, report on the
#                                      folder, start the sync timer in sync mode (never fatal)
#   cloud-folder-setup status [--json] the report; exit 0 when the folder is usable, 1 when not
#                                      (host: missing, not mounted, not writable; sync: no
#                                      remote, never synced, last sync failed, not writable; or
#                                      a mode this version does not know). --json: one object.
#   cloud-folder-setup version         the Feature version, the mode, the mount point, rclone
#   cloud-folder-setup login           sign in (interactive: a token pasted from `rclone
#                                      authorize "onedrive"`; or client credentials from
#                                      CLOUD_FOLDER_CLIENT_* without a prompt) and write the
#                                      remote into the Feature's rclone.conf; then start the timer
#   cloud-folder-setup sync [--resync] [--force]
#                                      one `rclone bisync` between the remote and the folder
#                                      (the first run of a folder is a --resync on its own)
#   cloud-folder-setup start | stop    the sync timer (one supervised loop, PID file in the
#                                      volume; start is idempotent, stop waits for a running sync)
#   cloud-folder-setup run             the timer loop itself (start runs it detached)
#   cloud-folder-setup shutdown-check [SECONDS]
#                                      for a repository's shutdown:check: exit 1 while a sync
#                                      runs (after waiting up to SECONDS, default 60) or while
#                                      local files changed since the last successful sync
#   cloud-folder-setup link MOUNT_POINT HOST_MOUNT
#                                      install.sh, as root: make MOUNT_POINT a symbolic link to
#                                      HOST_MOUNT (nothing when they are the same path)
#   cloud-folder-setup folder MOUNT_POINT
#                                      install.sh, as root, mode sync: make MOUNT_POINT a folder
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
# Nothing is written into the folder by a status: writability is the access check (test -w).
# The sync writes one hidden marker there (.cloud-folder-bisync, excluded from the sync) that
# tells a folder already synced from a new one (after a rebuild), which gets a --resync.
# Test hooks (not options): DCF_CLOUD_FOLDER_MOUNTINFO names the mount table to read (default
# /proc/self/mountinfo); DCF_CLOUD_FOLDER_HOST_MOUNT replaces the fixed host mount path;
# DCF_CLOUD_FOLDER_STATE_DIR replaces the state volume's path; DCF_CLOUD_FOLDER_GRACE the
# seconds a sync gets to stop gracefully (default 100).
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
  say "mountPoint $mp is a folder, filled by the sync (it is handed to the remote user at start)"
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

# ---------------------------------------------------------------- assess ----
# resolve: sets the host facts (REAL, LINKED, PRESENT, MOUNTED, IS_DIR, EMPTY, WRITABLE) and the
# mode: MODE_USED (host | sync | none) and WHY, or VERDICT=unknown-mode.
resolve() {
  PRESENT=no; MOUNTED=no; IS_DIR=no; EMPTY=unknown; WRITABLE=no; HINT=''; LINKED=no; VERDICT=''
  REAL="$(real_path "$mount_point")"
  [ -L "$mount_point" ] && LINKED=yes
  [ -e "$mount_point" ] && PRESENT=yes
  [ -d "$mount_point" ] && IS_DIR=yes
  is_mounted "$REAL" && MOUNTED=yes
  if [ "$IS_DIR" = yes ] && [ -r "$mount_point" ] && [ -x "$mount_point" ]; then
    if [ -n "$(find -H "$mount_point" -mindepth 1 -maxdepth 1 ! -name "$marker_name" -print -quit 2>/dev/null)" ]; then EMPTY=no; else EMPTY=yes; fi
  fi
  [ "$IS_DIR" = yes ] && [ -w "$mount_point" ] && [ -x "$mount_point" ] && WRITABLE=yes
  conf_state

  case "$mode_option" in
    host)
      MODE_USED=host; WHY='set by the option or CLOUD_FOLDER_MODE' ;;
    sync)
      MODE_USED=sync; WHY='set by the option or CLOUD_FOLDER_MODE' ;;
    auto)
      if [ "$MOUNTED" = yes ]; then MODE_USED=host; WHY="auto: something is mounted at $mount_point"
      elif [ "$CONF" = ok ]; then MODE_USED=sync; WHY="auto: nothing is mounted at $mount_point, and a remote is configured"
      else MODE_USED=none; WHY="auto: nothing is mounted at $mount_point, and no remote is configured"; fi ;;
    mount)
      MODE_USED=none; WHY="mode mount is not in this version of the Feature ($feature_version), which knows auto, host and sync; it comes later"
      VERDICT=unknown-mode ;;
    *)
      MODE_USED=none; WHY="mode '$mode_option' is unknown (auto, host or sync)"
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

assess_sync() {
  local check_remote="${1:-}" p err
  read_record
  SYNC_PID=''; LOOP_PID=''; REACHABLE=unknown; REACH_ERR=''
  p="$(pid_of "$run_dir/sync.pid")"; ours "$p" && SYNC_PID="$p"
  p="$(pid_of "$run_dir/loop.pid")"; ours "$p" && LOOP_PID="$p"
  RCLONE_OK=no; command -v rclone >/dev/null 2>&1 && RCLONE_OK=yes
  MARKER=no; [ -f "$REAL/$marker_name" ] && MARKER=yes
  PENDING="$(pending_count "$REAL")"
  NEEDS_RESYNC=no
  [ -n "$(find "$state_dir/bisync" -maxdepth 1 -name '*.lst-err' -print -quit 2>/dev/null)" ] && NEEDS_RESYNC=yes
  if [ "$check_remote" = remote ] && [ "$CONF" = ok ] && [ "$RCLONE_OK" = yes ]; then
    if err="$(timeout 30 env RCLONE_CONFIG="$conf" RCLONE_CACHE_DIR="$state_dir/cache" rclone lsjson --stat --contimeout 10s --timeout 15s --low-level-retries 1 --retries 1 "$remote" 2>&1 >/dev/null)"; then
      REACHABLE=yes
    else
      REACHABLE=no; REACH_ERR="$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-300)"
    fi
  fi

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
  printf '"verdict":%s,"ok":%s,"hint":%s}\n' \
    "$(json_str "$VERDICT")" "$(if verdict_ok; then printf true; else printf false; fi)" "$(json_str "$HINT")"
}

print_report() {
  local state
  say "mode $MODE_USED ($WHY)"
  if [ "$MODE_USED" = sync ]; then print_sync_report; return; fi
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

print_verdict() {
  case "$VERDICT" in
    ok) if [ "$MODE_USED" = sync ]; then say "ok: the folder is synced and writable"; else say "ok: the folder is mounted and writable"; fi ;;
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

# shutdown_check [SECONDS]: exit 1 while a sync runs (after waiting) or local changes wait.
shutdown_check() {
  local max="${1:-${CLOUD_FOLDER_SHUTDOWN_WAIT:-60}}" waited=0 p rc=0
  case "$max" in '' | *[!0-9]*) echo "cloud-folder: shutdown-check: SECONDS must be a number" >&2; return 2 ;; esac
  resolve
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

do_login() {
  local v token secret='' auth lines drive_id="${CLOUD_FOLDER_DRIVE_ID:-}" ctype
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
    say "sign-in for remote '$remote_name' (remoteType $remote_type), rclone $v."
    say "On a machine with a web browser, install the same rclone version ($v, https://downloads.rclone.org/$v/) and run:"
    echo
    echo '    rclone authorize "onedrive"'
    echo
    say 'sign in in the browser it opens; it prints a token between "Paste the following into your remote machine --->" and "<---End paste".'
    [ -t 0 ] && printf 'cloud-folder: paste that token here and press Enter (it is not shown): '
    if [ -t 0 ]; then read -r -s token || token=''; echo; else read -r token || true; fi
    token="${token//$'\r'/}"
    token="${token#"${token%%[![:space:]]*}"}"; token="${token%"${token##*[![:space:]]}"}"
    case "$token" in
      '{'*'"access_token"'*'}') ;;
      '') say 'no token pasted; nothing changed'; return 1 ;;
      *) say 'that is not the token rclone authorize prints (one line of JSON with access_token); nothing changed. Check that both sides run the same rclone version.'; return 1 ;;
    esac
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
  start_timer
  return 0
}

# ---------------------------------------------------------------- report ----
cmd="${1:-report}"
[ $# -gt 0 ] && shift
case "$cmd" in
  report)
    prepare_state verbose || true
    resolve
    [ "$MODE_USED" = sync ] && [ "$CONF" = ok ] && ensure_local "$REAL" >/dev/null 2>&1
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
    if command -v rclone >/dev/null 2>&1; then say "rclone: $(rclone version 2>/dev/null | head -n 1)${rclone_version_option:+ (option rcloneVersion $rclone_version_option)}"
    else say "rclone: not installed (mode host needs none)"; fi
    exit 0 ;;
  login) do_login; exit $? ;;
  sync) do_sync "$@"; exit $? ;;
  start) start_timer; exit $? ;;
  stop) stop_timer; exit $? ;;
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
    echo "usage: cloud-folder-setup [status [--json] | version | login | sync [--resync] [--force] | start | stop | shutdown-check [SECONDS] | link MOUNT_POINT HOST_MOUNT | folder MOUNT_POINT]" >&2
    exit 2 ;;
esac
