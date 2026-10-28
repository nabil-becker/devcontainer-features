#!/usr/bin/env bash
# Docker-free test of add_safe_directory in src/git/git-setup.sh: under `set -euo pipefail`,
# `git config --get-all safe.directory | grep -qxF <dir>` can miss a directory that is listed
# (grep -q exits at the first match, git gets SIGPIPE, the pipeline is 141) and then adds a
# duplicate entry. A fake git lists the directory first and then 100000 more lines, and records
# every --add; the function is cut out of git-setup.sh and run in a strict shell. Part of
# `task lint` (`task test:git-unit`). SETUP_SH points the test at another copy of git-setup.sh
# (the mutation check).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/git/git-setup.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/git" <<'F'
#!/usr/bin/env bash
case "$*" in
  *--get-all*)
    echo /workspaces/listed
    for i in $(seq 1 100000); do echo "/other/dir/$i"; done ;;
  *--add*) echo "$*" >> "$ADDS" ;;
esac
F
chmod +x "$T/bin/git"

sed -n '/^add_safe_directory()/,/^}/p' "$setup_sh" > "$T/fn.sh"
check 'git-setup defines add_safe_directory' yes "$([ -s "$T/fn.sh" ] && echo yes || echo no)"

run() { # <dir>
  PATH="$T/bin:$PATH" ADDS="$T/adds" bash -c 'set -euo pipefail; . "$1"; add_safe_directory "$2"' _ "$T/fn.sh" "$1" 2>&1
}

# 20 runs: SIGPIPE is a race, a single run can pass by luck.
: > "$T/adds"
bad=0
for _ in $(seq 1 20); do
  [ "$(run /workspaces/listed)" = 'safe.directory: /workspaces/listed (kept)' ] || bad=$((bad + 1))
done
check 'a listed directory is kept, every run' 0 "$bad"
check 'and nothing is added twice' 0 "$(wc -l < "$T/adds" | tr -d ' ')"
check 'an unlisted directory is added' 'safe.directory: /workspaces/new (added)' "$(run /workspaces/new)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
