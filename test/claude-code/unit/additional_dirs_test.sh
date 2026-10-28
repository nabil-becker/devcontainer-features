#!/usr/bin/env bash
# Docker-free tests of the claude-code Feature's additionalDirectories option: the managed-
# settings drop-in claude-additional-dirs.sh writes (empty writes nothing and removes an old
# drop-in; one folder; several; a space in a path; ~ and ~/x expanded to the remote user's
# home; spaces around commas, a trailing / and duplicates dropped; a quote escaped; a relative
# path or ~user refused with nothing written; a re-run gives the same bytes; a folder taken out
# is gone after the next run). Part of `task lint` (`task test:claude-unit`). DIRS_SH points
# the test at another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
dirs_sh="${DIRS_SH:-$root/src/claude-code/claude-additional-dirs.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

out="$T/etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json"
run() { bash "$dirs_sh" "$1" /home/vscode "$out" 2>&1; }
file() { if [ -e "$out" ]; then cat "$out"; else echo '(none)'; fi; }

o="$(run '')"; rc=$?
check 'empty: exit 0' 0 "$rc"
check 'empty: nothing written' '(none)' "$(file)"
o="$(run ' , ,')"
check 'only commas and spaces: nothing written' '(none)' "$(file)"

o="$(run '/workspaces/shared')"; rc=$?
check 'one folder: exit 0' 0 "$rc"
check 'one folder: the drop-in' '{"permissions":{"additionalDirectories":["/workspaces/shared"]}}' "$(file)"
contains 'one folder: says so' "$o" '1 additional working directory'
check 'one folder: readable by every user (0644)' 644 "$(stat -c %a "$out")"

o="$(run '/a, /b/ ,/a,~/notes,~')"
check 'several: in order, spaces around commas, a trailing / and duplicates dropped, ~ expanded' \
  '{"permissions":{"additionalDirectories":["/a","/b","/home/vscode/notes","/home/vscode"]}}' "$(file)"

o="$(run '/mnt/c/Users/me/One Drive/Client "X"')"
check 'a space in a path is kept, a quote escaped' '{"permissions":{"additionalDirectories":["/mnt/c/Users/me/One Drive/Client \"X\""]}}' "$(file)"

run '/a,/b' >/dev/null; first="$(file)"
run '/a,/b' >/dev/null
check 're-run: the same bytes' "$first" "$(file)"
run '/a' >/dev/null
check 'a folder taken out of the option is gone after the next run' '{"permissions":{"additionalDirectories":["/a"]}}' "$(file)"

o="$(run 'relative/path')"; rc=$?
check 'a relative path: refused (exit 2)' 2 "$rc"
contains 'a relative path: says why' "$o" "'relative/path' is not an absolute path"
check 'a relative path: the earlier drop-in is left as it was' '{"permissions":{"additionalDirectories":["/a"]}}' "$(file)"
o="$(run '/ok,~root/x')"; rc=$?
check '~user: refused (exit 2)' 2 "$rc"
# shellcheck disable=SC2088  # a literal ~ is what the script gets
o="$(bash "$dirs_sh" '~/x' '' "$out" 2>&1)"; rc=$?
check '~ without a known home: refused (exit 2)' 2 "$rc"

o="$(run '')"
check 'empty after a non-empty build: the old drop-in removed' '(none)' "$(file)"
contains 'empty after a non-empty build: says so' "$o" 'removed'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
