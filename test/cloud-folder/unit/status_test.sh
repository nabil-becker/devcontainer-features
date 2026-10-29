#!/usr/bin/env bash
# Docker-free tests of cloud-folder-setup (src/cloud-folder/cloud-folder-setup.sh) over a faked
# mount point: the mount table is a file (DCF_CLOUD_FOLDER_MOUNTINFO) that lists, or does not
# list, a temp folder as a mount target, and DCF_CLOUD_FOLDER_HOST_MOUNT moves the fixed host
# mount into the temp folder, so no mount and no privilege is needed. Covered: the build-time
# link from mountPoint to the host mount (`link`) and status through it; no
# source (auto, nothing mounted), mounted and not empty, mounted and empty, mounted and not
# writable (skipped as root, which may write anywhere), a bare folder that exists but is not
# mounted, mode host with nothing mounted (and the DCF_HOST_CLOUD_FOLDER hint), the mode this
# version does not know, mode mount with no remote, a path with a space and a trailing slash, a mounted file, --json, the
# post-start report never failing, nothing written into the folder, and the Feature Taskfile
# handing CLOUD_FOLDER_* and CLI_ARGS to the script. Part of `task lint`
# (`task test:cloud-folder-unit`). SETUP_SH points the tests at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/cloud-folder/cloud-folder-setup.sh}"
taskfile="$here/../../../src/cloud-folder/taskfile.yml"

T="$(mktemp -d)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}

# mount_table <path...>: a mount table listing each path as a mount target, escaped as the
# kernel escapes it.
mount_table() {
  local p e
  : > "$T/mountinfo"
  echo '22 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw' >> "$T/mountinfo"
  for p in "$@"; do
    e="${p//\\/\\134}"; e="${e// /\\040}"
    printf '30 22 0:50 /shared %s rw,relatime - fakefs host rw\n' "$e" >> "$T/mountinfo"
  done
}

# run [VAR=value ...] -- <script args>: out = stdout+stderr, rc = exit status. Clean environment.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out="$(env -i PATH="$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$T/state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" DCF_CLOUD_FOLDER_HOST_MOUNT="$T/cloud folder" DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" "${envs[@]}" bash "$setup_sh" "$@" 2>&1)"
  rc=$?
}
field() { python3 -c 'import json, sys; v = json.loads(sys.stdin.read())[sys.argv[1]]; print(json.dumps(v) if not isinstance(v, str) else v)' "$1" <<<"$out"; }

# Until the link section, the mount point is the host mount itself (mountPoint = the fixed path).
mp="$T/cloud folder"

# --- nothing mounted, no folder
mount_table
run CLOUD_FOLDER_MOUNT_POINT="$mp" -- status
check 'no source: status exits 1' 1 "$rc"
has 'no source: says auto found nothing' 'mode none (auto: nothing is mounted' "$out"
has 'no source: says the mount point is missing' 'mount point '"$mp"': missing' "$out"
has 'no source: names the verdict' 'not usable (no-source)' "$out"
has 'no source: says how to give a host folder' 'set DCF_HOST_CLOUD_FOLDER=<host path>' "$out"
run CLOUD_FOLDER_MOUNT_POINT="$mp" --
check 'the post-start report never fails' 0 "$rc"
has 'the post-start report says the same' 'not usable (no-source)' "$out"
run CLOUD_FOLDER_MOUNT_POINT="$mp" DCF_HOST_CLOUD_FOLDER='C:\Users\someone\Shared folder' -- status
check 'a host source the launcher did not mount: exit 1' 1 "$rc"
has 'and the report names it and the likely causes' 'the launcher was given DCF_HOST_CLOUD_FOLDER=C:\Users\someone\Shared folder, but nothing is mounted here' "$out"

# --- a bare folder that is not mounted
mkdir -p "$mp"
run CLOUD_FOLDER_MOUNT_POINT="$mp" -- status
check 'bare folder: exit 1' 1 "$rc"
has 'bare folder: present, not mounted' 'present, not mounted' "$out"
has 'bare folder: says not to write there' 'is a bare folder of the container: do not write there' "$out"

# --- mounted, empty
mount_table "$mp"
run CLOUD_FOLDER_MOUNT_POINT="$mp" -- status
check 'mounted and empty: exit 0' 0 "$rc"
has 'mounted and empty: auto chose host' 'mode host (auto: something is mounted at '"$mp"')' "$out"
has 'mounted and empty: reports empty and writable' 'contents: empty; writable: yes' "$out"
has 'mounted and empty: an ok with a warning' 'ok, but empty:' "$out"
check 'status wrote nothing into the folder' '' "$(ls -A "$mp")"

# --- mounted, not empty, through the default auto and a trailing slash
echo note > "$mp/minutes.txt"
run CLOUD_FOLDER_MOUNT_POINT="$mp/" -- status
check 'mounted and not empty: exit 0' 0 "$rc"
has 'mounted and not empty: ok' 'ok: the folder is mounted and writable' "$out"
has 'a trailing slash on the mount point is ignored' "mount point $mp: mounted" "$out"
run CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_MODE=host -- status
check 'mode host, mounted: exit 0' 0 "$rc"
has 'mode host says where it came from' 'mode host (set by the option or CLOUD_FOLDER_MODE)' "$out"

# --- another folder mounted, not ours
mount_table "$T/elsewhere"
run CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_MODE=host -- status
check 'mode host, only another path mounted: exit 1' 1 "$rc"
has 'mode host, nothing mounted here: not-mounted' 'not usable (not-mounted)' "$out"

# --- mounted, not writable
mount_table "$mp"
chmod 0555 "$mp"
if [ "$(id -u)" -eq 0 ]; then
  echo "skip - unwritable: running as root, which may write anywhere"
else
  run CLOUD_FOLDER_MOUNT_POINT="$mp" -- status
  check 'mounted, not writable: exit 1' 1 "$rc"
  has 'mounted, not writable: says so' 'not usable (unwritable)' "$out"
  has 'mounted, not writable: contents still listed' 'contents: not empty; writable: no' "$out"
  run CLOUD_FOLDER_MOUNT_POINT="$mp" --
  check 'mounted, not writable: the post-start report still exits 0' 0 "$rc"
fi
chmod 0755 "$mp"

# --- a mounted file
touch "$T/file"
mount_table "$T/file"
run CLOUD_FOLDER_MOUNT_POINT="$T/file" -- status
check 'a mounted file: exit 1' 1 "$rc"
has 'a mounted file: not a folder' 'not usable (not-a-folder)' "$out"

# --- mode mount with no remote (mount is tested in mount_test.sh, sync in sync_test.sh)
mount_table "$mp"
run CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_MODE=mount -- status
check "mode mount, no remote: exit 1" 1 "$rc"
has "mode mount, no remote: says to sign in" "not usable (not-configured)" "$out"
run CLOUD_FOLDER_MOUNT_POINT="$mp" CLOUD_FOLDER_MODE=bogus -- status
check 'an unknown mode: exit 1' 1 "$rc"
has 'an unknown mode: says so' "mode 'bogus' is unknown" "$out"
run -- status --yaml
check 'an unknown status argument: exit 2' 2 "$rc"

# --- --json
run CLOUD_FOLDER_MOUNT_POINT="$mp" DCF_HOST_CLOUD_FOLDER='C:\Users\someone\a "quoted" folder' -- status --json
check '--json: exit 0 when ok' 0 "$rc"
check '--json: one line' 1 "$(wc -l <<<"$out" | tr -d ' ')"
check '--json: verdict' ok "$(field verdict)"
check '--json: mode' host "$(field mode)"
check '--json: mounted' true "$(field mounted)"
check '--json: empty' false "$(field empty)"
check '--json: writable' true "$(field writable)"
check '--json: ok' true "$(field ok)"
check '--json: the host source survives backslashes and quotes' 'C:\Users\someone\a "quoted" folder' "$(field host_source)"
mount_table
run CLOUD_FOLDER_MOUNT_POINT="$T/none" -- status --json
check '--json: exit 1 when missing' 1 "$rc"
check '--json: verdict no-source' no-source "$(field verdict)"
check '--json: empty unknown is null' null "$(field empty)"
check '--json: ok false' false "$(field ok)"

# --- the link: mountPoint another path than the host mount (what install.sh makes as root)
hm="$T/host mount"
lp="$T/mnt/shared"
mount_table
run -- link "$lp" "$hm"
check 'link: exit 0' 0 "$rc"
check 'link: mountPoint is a link to the host mount' "$hm" "$(readlink "$lp")"
check 'link: the host mount is not created' no "$([ -e "$hm" ] && echo yes || echo no)"
run -- link "$lp/" "$hm"
check 'link: again (idempotent, a trailing slash ignored)' 0 "$rc"
check 'link: still the link' "$hm" "$(readlink "$lp")"
run -- link "$hm" "$hm"
check 'link: mountPoint equal to the host mount: exit 0' 0 "$rc"
has 'link: and no link' 'no link' "$out"
check 'link: nothing made at the host mount' no "$([ -e "$hm" ] || [ -L "$hm" ] && echo yes || echo no)"
mkdir -p "$T/empty-dir"
run -- link "$T/empty-dir" "$hm"
check 'link: an empty folder gives way to the link' "$hm" "$(readlink "$T/empty-dir")"
mkdir -p "$T/full-dir"; echo x > "$T/full-dir/keep"
run -- link "$T/full-dir" "$hm"
check 'link: a folder with content is refused' 1 "$rc"
has 'link: and says why' 'is a folder with content in the image' "$out"
check 'link: its content is kept' x "$(cat "$T/full-dir/keep")"
echo x > "$T/a-file"
run -- link "$T/a-file" "$hm"
check 'link: a file is refused' 1 "$rc"
has 'link: and says why' 'is not a folder or a link' "$out"
run -- link relative "$hm"
check 'link: a relative mountPoint is refused' 1 "$rc"
run -- link "$lp"
check 'link: wrong argument count: exit 2' 2 "$rc"

# status through the link: the mount is checked at the host mount, the folder through the link
run CLOUD_FOLDER_MOUNT_POINT="$lp" DCF_CLOUD_FOLDER_HOST_MOUNT="$hm" -- status
check 'through the link, nothing mounted: exit 1' 1 "$rc"
has 'through the link: shows where it leads' "mount point $lp -> $hm: missing" "$out"
mkdir -p "$hm"
mount_table "$hm"
run CLOUD_FOLDER_MOUNT_POINT="$lp" DCF_CLOUD_FOLDER_HOST_MOUNT="$hm" -- status
check 'through the link, host mount mounted and empty: exit 0' 0 "$rc"
has 'through the link: empty' 'contents: empty' "$out"
has 'through the link: mounted' "mount point $lp -> $hm: mounted" "$out"
echo note > "$lp/minutes.txt"
check 'a file written through the link lands in the host mount' note "$(cat "$hm/minutes.txt")"
run CLOUD_FOLDER_MOUNT_POINT="$lp" DCF_CLOUD_FOLDER_HOST_MOUNT="$hm" -- status --json
check 'through the link, --json: ok' ok "$(field verdict)"
check 'through the link, --json: linked' true "$(field linked)"
check 'through the link, --json: real_path' "$hm" "$(field real_path)"
check 'through the link, --json: not empty (the listing follows the link)' false "$(field empty)"
mount_table "$lp"
run CLOUD_FOLDER_MOUNT_POINT="$lp" DCF_CLOUD_FOLDER_HOST_MOUNT="$hm" -- status
check 'a mount table naming the link itself, not the host mount: exit 1' 1 "$rc"
mkdir -p "$T/plain"
mount_table "$hm"
run CLOUD_FOLDER_MOUNT_POINT="$T/plain" DCF_CLOUD_FOLDER_HOST_MOUNT="$hm" -- status
check 'a mount point that does not lead to the mounted host mount: exit 1' 1 "$rc"
has 'and the report names the host mount' "The host mount $hm is mounted, but $T/plain does not lead to it" "$out"

# --- version
run CLOUD_FOLDER_MOUNT_POINT="$mp" -- version
check 'version: exit 0' 0 "$rc"
has 'version: names the mount point' "mount point $mp" "$out"

# --- the Feature Taskfile hands CLOUD_FOLDER_* and CLI_ARGS to the script
if command -v task >/dev/null 2>&1; then
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nexec bash %q "$@"\n' "$setup_sh" > "$T/bin/cloud-folder-setup"
  chmod +x "$T/bin/cloud-folder-setup"
  mount_table "$mp"
  out="$(cd "$T" && env -i PATH="$T/bin:$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$T/state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" task -s -t "$taskfile" status CLOUD_FOLDER_MOUNT_POINT="$mp" -- --json 2>&1)"
  rc=$?
  check 'task status: a command-line CLOUD_FOLDER_MOUNT_POINT and -- --json reach the script' 'ok' "$(field verdict 2>/dev/null)"
  out="$(cd "$T" && env -i PATH="$T/bin:$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$T/state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" CLOUD_FOLDER_MOUNT_POINT="$T/none" task -s -t "$taskfile" status 2>&1)"
  rc=$?
  check 'task status: the environment is read too, and a failure fails the task' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  has 'task status: the environment value is used' "mount point $T/none: missing" "$out"
  out="$(cd "$T" && env -i PATH="$T/bin:$PATH" HOME="$T" DCF_CLOUD_FOLDER_STATE_DIR="$T/state" DCF_CLOUD_FOLDER_MOUNTINFO="$T/mountinfo" task -s -t "$taskfile" setup CLOUD_FOLDER_MOUNT_POINT="$T/none" 2>&1)"
  check 'task setup: never fails' 0 "$?"
else
  echo "skip - the Taskfile checks: task is not on PATH"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
