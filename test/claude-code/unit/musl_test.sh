#!/usr/bin/env bash
# Docker-free test of the musl detection in the claude-code installer (src/claude-code/install.sh):
# under `set -euo pipefail`, `ldd /bin/ls | grep -q musl` can read as "not musl" on a musl system
# (grep -q exits at the first match, ldd gets SIGPIPE, the pipeline is 141). A fake ldd prints
# "musl" first and then 100000 lines; the if block is cut out of the installer and run in a strict
# shell. Part of `task lint` (`task test:claude-unit`). INSTALL_SH points the test at another copy
# of the installer (the mutation check).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
install_sh="${INSTALL_SH:-$here/../../../src/claude-code/install.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

mkdir -p "$T/musl" "$T/glibc"
cat > "$T/musl/ldd" <<'F'
#!/usr/bin/env bash
echo "musl libc (x86_64)"
for i in $(seq 1 100000); do echo "Version 1.2.5 line $i of a long report"; done
F
cat > "$T/glibc/ldd" <<'F'
#!/usr/bin/env bash
echo "ldd (GNU libc) 2.36"
for i in $(seq 1 1000); do echo "line $i"; done
F
chmod +x "$T/musl/ldd" "$T/glibc/ldd"

sed -n '/^  if ldd \/bin\/ls/,/^  fi/p' "$install_sh" > "$T/block.sh"
check 'the installer has the ldd check' yes "$([ -s "$T/block.sh" ] && echo yes || echo no)"

platform() { # <dir with the fake ldd>
  PATH="$1:$PATH" bash -c 'set -euo pipefail; platform=linux-x64; . "$1"; echo "$platform"' _ "$T/block.sh" 2>&1
}

# 20 runs: SIGPIPE is a race, a single run can pass by luck.
bad=0
for _ in $(seq 1 20); do
  [ "$(platform "$T/musl")" = linux-x64-musl ] || bad=$((bad + 1))
done
check 'a musl system is detected as musl, every run' 0 "$bad"
check 'a glibc system is not' linux-x64 "$(platform "$T/glibc")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
