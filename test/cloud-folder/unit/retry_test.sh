#!/usr/bin/env bash
# Docker-free test of the download retry flags of the cloud-folder installer (curl_retry_flags in
# src/cloud-folder/install.sh): every rclone download retries every error (a TLS reset, "curl: (35)
# unexpected eof", is not retried by plain --retry) when curl is 7.71+, and an older curl keeps
# plain --retry. Support is read from `curl --help all`, which must be read to the end (a
# `| grep -q` under pipefail answers "unsupported" when curl gets SIGPIPE). Fake curls stand in for
# both. Part of `task lint` (`task test:cloud-folder-unit`). INSTALL_SH points the test at another
# copy of the installer (the mutation check).
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

mkdir -p "$T/new" "$T/old"
# A new curl: the flag is on the first line of a very long help text.
cat > "$T/new/curl" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo "     --retry-all-errors  Retry all errors"
  for i in $(seq 1 100000); do echo "     --option-$i  filler"; done
fi
F
# An old curl: a long help text without the flag.
cat > "$T/old/curl" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  for i in $(seq 1 1000); do echo "     --option-$i  filler"; done
fi
F
chmod +x "$T/new/curl" "$T/old/curl"

sed -n '/^curl_retry_flags()/,/^}/p' "$install_sh" > "$T/fn.sh"
check 'the installer defines curl_retry_flags' yes "$([ -s "$T/fn.sh" ] && echo yes || echo no)"

flags() { # <dir with the fake curl>
  PATH="$1:$PATH" bash -c 'set -euo pipefail; . "$1"; curl_retry_flags; echo "${CURL_RETRY[*]}"' _ "$T/fn.sh" 2>&1
}

# 20 runs: SIGPIPE is a race, a single run can pass by luck.
bad=0
for _ in $(seq 1 20); do
  [ "$(flags "$T/new")" = '--retry 3 --retry-delay 2 --retry-all-errors' ] || bad=$((bad + 1))
done
check 'a curl with --retry-all-errors gets it, every run (no SIGPIPE false negative)' 0 "$bad"
check 'an older curl keeps plain --retry' '--retry 3 --retry-delay 2' "$(flags "$T/old")"

# All three downloads use the flags: no curl call of the rclone install without them.
calls="$(grep -c 'curl -fsSL' "$install_sh")"
used="$(grep 'curl -fsSL' "$install_sh" | grep -cF 'CURL_RETRY')"
check 'every download (version file, SHA256SUMS, zip) uses CURL_RETRY' "3 3" "$calls $used"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
