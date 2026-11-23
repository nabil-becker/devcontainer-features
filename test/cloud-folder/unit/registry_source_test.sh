#!/usr/bin/env bash
# Docker-free tests of the cloud-folder Feature's registry source (src/cloud-folder/
# registry-source-cloud-folder.sh) over a faked cloud folder (a temp folder as the mount point, a
# fake cloud-folder-setup for the status): fetch copies a folder under the cloud folder (the sync
# marker left out), the version fingerprint changes with a file, a folder or a mount point that is
# not there and a status that says not set up are exit 1 with one line, the mount point from
# CLOUD_FOLDER_MOUNT_POINT and from options.env's default, .. refused, a path with a space,
# nothing written into the cloud folder, and, with dcf-registry, a cloud-folder layer resolved and
# its last good copy used when the folder goes. Part of `task lint` (`task test:cloud-folder-unit`).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

bin="$T/bin"; mkdir -p "$bin"
cp "$root/src/cloud-folder/registry-source-cloud-folder.sh" "$bin/registry-source-cloud-folder"
for f in dcf-registry registry-source-path; do cp "$root/src/component-registry/$f.sh" "$bin/$f"; done
chmod +x "$bin"/*
# A fake cloud-folder-setup: status is ok unless $T/notsetup exists.
printf '#!/bin/sh\nif [ -e "%s/notsetup" ]; then echo "cloud-folder: not usable (no-source): nothing mounted"; echo second line; exit 1; fi\necho "cloud-folder: usable (host)"\n' "$T" > "$bin/cloud-folder-setup"
chmod +x "$bin/cloud-folder-setup"
export PATH="$bin:$PATH" CLOUD_FOLDER_MOUNT_POINT="$T/cf" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
S=registry-source-cloud-folder

mkdir -p "$T/cf/registry/mine" "$T/cf/registry/with space"
printf '[skills/cf]\nbody:text = from the cloud folder\n' > "$T/cf/registry/mine/mine.layer"
echo marker > "$T/cf/registry/mine/.cloud-folder-bisync"
echo x > "$T/cf/registry/with space/a.layer"

mkdir "$T/d"; $S fetch l "$T/d" remote=registry/mine >/dev/null 2>"$T/err"; check "fetch: exit 0" 0 $?
check "fetch: the layer's file is copied" "[skills/cf]" "$(head -n 1 "$T/d/mine.layer")"
check "fetch: the sync marker is not copied" no "$([ -e "$T/d/.cloud-folder-bisync" ] && echo yes || echo no)"
rm -rf "$T/d"; mkdir "$T/d"; $S fetch l "$T/d" "remote=/registry/with space/" >/dev/null 2>&1; check "fetch: a path with a space and slashes around it" yes "$([ -f "$T/d/a.layer" ] && echo yes)"
before="$(cd "$T/cf" && find . -printf '%p %s %T@\n' | sort | cksum)"
v1="$($S version l remote=registry/mine)"; rm -rf "$T/d"; mkdir "$T/d"; $S fetch l "$T/d" remote=registry/mine >/dev/null 2>&1
check "nothing is written into the cloud folder by version or fetch" "$before" "$(cd "$T/cf" && find . -printf '%p %s %T@\n' | sort | cksum)"
contains "version: a tree fingerprint" "$v1" "tree-"
check "version: stable" "$v1" "$($S version l remote=registry/mine)"
echo changed >> "$T/cf/registry/mine/mine.layer"
check "version: a changed file changes it" yes "$([ "$($S version l remote=registry/mine)" != "$v1" ] && echo yes)"
v2="$($S version l remote=registry/mine)"; echo m2 > "$T/cf/registry/mine/.cloud-folder-bisync"
check "version: the sync marker does not change it" "$v2" "$($S version l remote=registry/mine)"

out="$($S version l remote=registry/none 2>&1)"; rc=$?
check "a folder that is not there: exit 1" 1 $rc
contains "... one line naming it" "$out" "no folder registry/none"
check "... exactly one line" 1 "$(printf '%s\n' "$out" | wc -l)"
touch "$T/notsetup"
out="$($S version l remote=registry/mine 2>&1)"; rc=$?
check "the cloud folder not set up: exit 1" 1 $rc
contains "... with the Feature's reason" "$out" "not set up: cloud-folder: not usable (no-source)"
check "... one line (the status's second line is not shown)" 1 "$(printf '%s\n' "$out" | wc -l)"
rm "$T/notsetup"
out="$(CLOUD_FOLDER_MOUNT_POINT="$T/absent" $S version l remote=registry/mine 2>&1)"; rc=$?
check "nothing at the mount point: exit 1" 1 $rc
contains "... said" "$out" "nothing at $T/absent"
mkdir -p "$T/bin2"; cp "$bin/registry-source-cloud-folder" "$T/bin2/"
out="$(PATH="$T/bin2:/usr/bin:/bin" $S version l remote=registry/mine 2>&1)"; check "without cloud-folder-setup the folder itself is read" 0 $?
export PATH="$bin:$PATH"

$S version l remote=../etc >/dev/null 2>&1; check ".. in remote: exit 2" 2 $?
$S version l >/dev/null 2>&1; check "no remote: exit 2" 2 $?
$S version l path=x >/dev/null 2>&1; check "an unknown setting: exit 2" 2 $?
$S frobnicate >/dev/null 2>&1; check "an unknown verb: exit 3" 3 $?
check "supports lists its verbs" "fetch version supports" "$($S supports | tr '\n' ' ' | sed 's/ $//')"

# With dcf-registry
C="$T/case"; mkdir -p "$C/repo/.devcontainer"; cd "$C/repo" || exit 1
export COMPONENT_REGISTRY_STATE_DIR="$C/state"
printf 'layers:\n  - id: mine\n    at: /Corp\n    sources:\n      - { kind: cloud-folder, remote: registry/mine }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "resolve with a cloud-folder layer: exit 0" 0 $?
contains "the layer's value is resolved" "$(cat "$C/state/view/meta/skills/cf/values/body" 2>/dev/null)" "from the cloud folder"
mv "$T/cf/registry/mine" "$T/cf/registry/gone"
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "the folder goes: resolve still exits 0" 0 $rc
contains "the last good copy is said" "$out" "using the last good copy"
contains "the last good copy is still resolved" "$(cat "$C/state/view/meta/skills/cf/values/body" 2>/dev/null)" "from the cloud folder"
printf 'layers:\n  - id: mine\n    at: /Corp\n    sources:\n      - { kind: cloud-folder, url: x }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a cloud-folder source with url and no remote: exit 2" 2 $rc
contains "... says remote is needed" "$out" "a cloud-folder source needs remote"
printf 'layers:\n  - id: mine\n    at: /Corp\n    sources:\n      - { kind: db, url: x }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"
contains "a db source with no driver says driver is needed" "$out" "a db source needs driver"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
