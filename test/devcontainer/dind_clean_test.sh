#!/usr/bin/env bash
# Docker-free tests of .devcontainer/dind-clean.sh and dind-guard.sh with `docker`
# and `df` stubbed first on PATH. Part of `task lint` (`task test:dind-clean`).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
dir="$here/../../.devcontainer"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want '$2', got '$3')"; fi; }
has() { case "$3" in *"$2"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: $1 (no '$2' in '$3')";; esac; }

mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  info) [ "${STUB_DAEMON:-up}" = up ]; exit $? ;;
  system) [ "$2" = df ] && echo "1.5GB" ;;
esac
exit 0
S
cat > "$T/bin/df" <<'S'
#!/usr/bin/env bash
printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 100 1 %s 1%% /\n' "$STUB_AVAIL_KB"
S
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" STUB_LOG="$T/log"

: > "$T/log"; out=$(bash "$dir/dind-clean.sh" 2>&1)
has "prune all" "system prune -af --volumes" "$(cat "$T/log")"
has "builder prune" "builder prune -af" "$(cat "$T/log")"
has "report line" "dind-clean: pruned" "$out"

: > "$T/log"; out=$(STUB_DAEMON=down bash "$dir/dind-clean.sh" 2>&1); rc=$?
ok "no daemon exits 0" 0 "$rc"
has "no daemon line" "no Docker daemon" "$out"
case "$(cat "$T/log")" in *prune*) fail=$((fail+1)); echo "FAIL: pruned without daemon";; *) pass=$((pass+1));; esac

out=$(STUB_AVAIL_KB=$((5*1024*1024)) bash "$dir/dind-guard.sh" 2>&1); rc=$?
ok "guard refuses" 1 "$rc"; has "guard message" "need 20 GB" "$out"
out=$(FORCE=1 STUB_AVAIL_KB=$((5*1024*1024)) bash "$dir/dind-guard.sh" 2>&1); rc=$?
ok "FORCE overrides" 0 "$rc"
out=$(STUB_AVAIL_KB=$((50*1024*1024)) bash "$dir/dind-guard.sh" 2>&1); rc=$?
ok "enough space" 0 "$rc"

echo "dind-clean tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
