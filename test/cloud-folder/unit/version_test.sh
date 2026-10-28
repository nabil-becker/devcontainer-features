#!/usr/bin/env bash
# Docker-free test of the version line the cloud-folder installer prints (rclone_version_line in
# src/cloud-folder/install.sh): under `set -euo pipefail` it must not die of SIGPIPE (exit 141)
# when rclone writes far more than the one line that is kept. A fake rclone prints 100000 lines
# for `version`; the function is cut out of the installer and run in a strict shell. Part of
# `task lint` (`task test:cloud-folder-unit`). INSTALL_SH points the test at another copy of the
# installer (the mutation check: a copy that still says `| head -n 1` fails).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
install_sh="${INSTALL_SH:-$here/../../../src/cloud-folder/install.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

cat > "$T/rclone" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  echo "rclone v1.99.0"
  for i in $(seq 1 100000); do echo "- os/version: line $i of a long report"; done
fi
F
chmod +x "$T/rclone"

# The function, cut out of the installer between its name and its closing brace.
sed -n '/^rclone_version_line()/,/^}/p' "$install_sh" > "$T/fn.sh"
check 'the installer defines rclone_version_line' yes "$([ -s "$T/fn.sh" ] && echo yes || echo no)"

# 20 runs: SIGPIPE is a race, a single run can pass by luck.
bad=0 first=
for _ in $(seq 1 20); do
  out="$(bash -c 'set -euo pipefail; . "$1"; v="$(rclone_version_line "$2")"; echo "$v"; echo reached-after' _ "$T/fn.sh" "$T/rclone" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || bad=$((bad + 1))
  first="$out"
done
check 'under set -euo pipefail, every run exits 0 (no 141)' 0 "$bad"
check 'the first line is printed, and the shell carried on' "$(printf 'rclone v1.99.0\nreached-after')" "$first"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
