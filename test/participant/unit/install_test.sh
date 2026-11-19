#!/usr/bin/env bash
# Docker-free tests of the participant component's installer (components/participant/
# install-participant.sh), every path moved into a temp folder with the DCF_PARTICIPANT_*
# variables: a first install (the files, the agents symlink, the state folders and their modes,
# the Taskfile include, installed-by); a second Feature with the same version installs nothing
# (one copy, installed-by unchanged); an older copy never replaces a newer one; a newer copy
# replaces an older one; --taskfile false leaves the include out and a later caller that wants it
# adds it without copying the component again; an unknown argument and a missing --by are
# refused. Also that each Feature's vendored copy (src/<id>/participant) installs the same
# files. Part of `task lint` (`task test:participant-unit`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
comp="$root/components/participant"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# A fake go-task registry refresh, first on PATH: records each call instead of writing the real one.
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho refreshed >> "%s/registry-calls"\n' "$T" > "$T/fakebin/task-features-registry"
chmod +x "$T/fakebin/task-features-registry"
export PATH="$T/fakebin:$PATH"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

# A fresh target tree per case; a copy of the component whose version can be set.
setup() {
  rm -rf "$T/root" "$T/src-a" "$T/src-b" "$T/registry-calls"
  export DCF_PARTICIPANT_LIB="$T/root/lib/dcf-participant" DCF_PARTICIPANT_BIN="$T/root/bin" \
    DCF_PARTICIPANT_INCLUDES="$T/root/includes.d" DCF_PARTICIPANT_STATE="$T/root/state/agents"
  cp -r "$comp" "$T/src-a"
  cp -r "$comp" "$T/src-b"
}
version_of() { printf '%s\n' "$2" > "$T/$1/COMPONENT_VERSION"; }
inst() { local d="$1"; shift; bash "$T/$d/install-participant.sh" "$@" 2>&1; }

ver="$(head -n 1 "$comp/COMPONENT_VERSION")"

# ------------------------------------------------------------- first install ----
setup
out="$(inst src-a --by claude-code)"; rc=$?
check 'first install: exit 0' 0 "$rc"
contains 'first install: says what it installed' "$out" "installed component $ver (by claude-code)"
check 'first install: agents.sh in the lib folder, executable' yes "$([ -x "$DCF_PARTICIPANT_LIB/agents.sh" ] && echo yes || echo no)"
check 'first install: agents on PATH is a symlink into the lib folder' "$DCF_PARTICIPANT_LIB/agents.sh" "$(readlink "$DCF_PARTICIPANT_BIN/agents")"
check 'first install: the same agents.sh as the component' yes "$(cmp -s "$comp/agents.sh" "$DCF_PARTICIPANT_LIB/agents.sh" && echo yes || echo no)"
check 'first install: COMPONENT_VERSION' "$ver" "$(cat "$DCF_PARTICIPANT_LIB/COMPONENT_VERSION")"
check 'first install: installed-by' claude-code "$(cat "$DCF_PARTICIPANT_LIB/installed-by")"
check 'first install: the Taskfile include' yes "$(cmp -s "$comp/taskfile.yml" "$DCF_PARTICIPANT_INCLUDES/agents.yml" && echo yes || echo no)"
check 'first install: state folder sticky and open' 1777 "$(stat -c %a "$DCF_PARTICIPANT_STATE")"
check 'first install: leases open, not sticky' 777 "$(stat -c %a "$DCF_PARTICIPANT_STATE/leases")"
check 'first install: the go-task registry refreshed once' 1 "$(wc -l < "$T/registry-calls" | tr -d ' ')"
check 'first install: no leftover build folder' no "$([ -e "$DCF_PARTICIPANT_LIB.new" ] && echo yes || echo no)"

# ------------------------------------------------- second Feature, same version ----
: > "$DCF_PARTICIPANT_STATE/leases/marker"
out="$(inst src-b --by agents)"; rc=$?
check 'same version: exit 0' 0 "$rc"
contains 'same version: says it is already there' "$out" "component $ver already installed (by claude-code); agents's copy ($ver) not installed"
check 'same version: installed-by unchanged (nothing copied)' claude-code "$(cat "$DCF_PARTICIPANT_LIB/installed-by")"
check 'same version: one lib folder' 1 "$(find "$T/root/lib" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
check 'same version: the state is kept' yes "$([ -e "$DCF_PARTICIPANT_STATE/leases/marker" ] && echo yes || echo no)"

# ------------------------------------------------------ an older copy never wins ----
setup
version_of src-a 1.2.0; version_of src-b 1.1.9
inst src-a --by claude-code >/dev/null
out="$(inst src-b --by agents)"
contains 'older copy: not installed' "$out" "component 1.2.0 already installed"
check 'older copy: the newer stays' 1.2.0 "$(cat "$DCF_PARTICIPANT_LIB/COMPONENT_VERSION")"
setup
version_of src-a 1.10.0; version_of src-b 1.9.0
inst src-a --by claude-code >/dev/null
inst src-b --by agents >/dev/null
check 'older copy: 1.10.0 beats 1.9.0 (numeric, not text)' 1.10.0 "$(cat "$DCF_PARTICIPANT_LIB/COMPONENT_VERSION")"

# ------------------------------------------------------ a newer copy replaces ----
setup
version_of src-a 1.0.0; version_of src-b 1.1.0
inst src-a --by agents >/dev/null
out="$(inst src-b --by claude-code)"
contains 'newer copy: replaces and says so' "$out" "replaced component 1.0.0 with 1.1.0 (by claude-code)"
check 'newer copy: the version' 1.1.0 "$(cat "$DCF_PARTICIPANT_LIB/COMPONENT_VERSION")"
check 'newer copy: installed-by' claude-code "$(cat "$DCF_PARTICIPANT_LIB/installed-by")"
check 'newer copy: the symlink still resolves' yes "$([ -x "$DCF_PARTICIPANT_BIN/agents" ] && echo yes || echo no)"

# ------------------------------------------------------------- the Taskfile ----
setup
inst src-a --by claude-code --taskfile false >/dev/null
check 'taskfile false: no include' no "$([ -e "$DCF_PARTICIPANT_INCLUDES/agents.yml" ] && echo yes || echo no)"
out="$(inst src-b --by agents --taskfile true)"
contains 'taskfile: a later caller that wants it installs nothing else' "$out" "already installed"
check 'taskfile: a later caller that wants it adds the include' yes "$([ -f "$DCF_PARTICIPANT_INCLUDES/agents.yml" ] && echo yes || echo no)"

# ------------------------------------------------------------- refused usage ----
setup
out="$(inst src-a)"; rc=$?
check 'no --by: exit 2' 2 "$rc"
contains 'no --by: says so' "$out" "--by <feature id> is required"
out="$(inst src-a --by x --bogus)"; rc=$?
check 'unknown argument: exit 2' 2 "$rc"

# ----------------------------------------------------- the vendored copies ----
for copy in "$root"/src/*/participant; do
  [ -d "$copy" ] || continue
  id="$(basename "$(dirname "$copy")")"
  check "src/$id/participant is the component (task components:sync)" "" "$(diff -rq "$comp" "$copy" 2>&1)"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
