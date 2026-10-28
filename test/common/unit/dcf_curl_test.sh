#!/usr/bin/env bash
# Docker-free test of the collection's download helper (src/common/dcf-curl.sh): dcf_curl adds
# --retry 3 --retry-delay 2 --retry-connrefused, and --retry-all-errors when curl has it (read from
# `curl --help all` to the end: a `| grep -q` under pipefail answers "unsupported" when curl gets
# SIGPIPE); an older curl keeps plain --retry; the caller's arguments pass through unchanged.
# Fake curls stand in for both. Then the real curl against a local server that cuts the first
# connection: mid-transfer (curl exit 56) and mid-TLS-handshake (curl exit 35, needs openssl);
# plain `curl --retry 3` gives up, dcf_curl gets the file. Part of `task lint`
# (`task test:common-unit`). DCF_CURL_SH points the test at another copy (the mutation check).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
helper="${DCF_CURL_SH:-$here/../../../src/common/dcf-curl.sh}"

T="$(mktemp -d)"
server_pid=
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

pass=0 fail=0 skip=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

mkdir -p "$T/new" "$T/old" "$T/srv"
# A new curl: the flag is on the first line of a very long help text; any other call records
# its arguments and counts the --help calls.
cat > "$T/new/curl" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo help >> "$CALLS.help"
  echo "     --retry-all-errors  Retry all errors"
  for i in $(seq 1 100000); do echo "     --option-$i  filler"; done
  exit 0
fi
echo "$*" >> "$CALLS"
F
# An old curl: a long help text without the flag.
cat > "$T/old/curl" <<'F'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  for i in $(seq 1 1000); do echo "     --option-$i  filler"; done
  exit 0
fi
echo "$*" >> "$CALLS"
F
chmod +x "$T/new/curl" "$T/old/curl"

run() { # <dir with the fake curl> <curl arguments>: what the fake curl got
  local dir="$1"; shift
  rm -f "$T/calls" "$T/calls.help"
  CALLS="$T/calls" PATH="$dir:$PATH" bash -c 'set -euo pipefail; . "$1"; shift; dcf_curl "$@"' _ "$helper" "$@" 2>&1
  cat "$T/calls" 2>/dev/null
}

# 20 runs: SIGPIPE is a race, a single run can pass by luck.
bad=0
for _ in $(seq 1 20); do
  [ "$(run "$T/new" -fsSL https://example.invalid/a)" = '--retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors -fsSL https://example.invalid/a' ] || bad=$((bad + 1))
done
check 'a curl with --retry-all-errors gets it, every run (no SIGPIPE false negative)' 0 "$bad"
check 'an older curl keeps plain --retry, the flag dropped' \
  '--retry 3 --retry-delay 2 --retry-connrefused -fsSL https://example.invalid/a' "$(run "$T/old" -fsSL https://example.invalid/a)"
check 'the caller'"'"'s arguments pass through unchanged (-I, -o, -w, a space)' \
  "--retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors -fsSIL -o /dev/null -w %{url_effective} https://example.invalid/a b" \
  "$(run "$T/new" -fsSIL -o /dev/null -w '%{url_effective}' 'https://example.invalid/a b')"
rm -f "$T/calls" "$T/calls.help"
CALLS="$T/calls" PATH="$T/new:$PATH" bash -c 'set -euo pipefail; . "$1"; dcf_curl -o a x; dcf_curl -o b y' _ "$helper" >/dev/null 2>&1
check 'curl --help is read once per shell, not per download' '1 2' "$(wc -l < "$T/calls.help" | tr -d ' ') $(wc -l < "$T/calls" | tr -d ' ')"
check 'sourcing it runs nothing (no curl call before the first download)' '' \
  "$(rm -f "$T/calls" "$T/calls.help"; CALLS="$T/calls" PATH="$T/new:$PATH" bash -c 'set -euo pipefail; . "$1"' _ "$helper" 2>&1; cat "$T/calls" "$T/calls.help" 2>/dev/null)"

# --- the real curl against a server that cuts the first connection.
if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  skip=$((skip + 2)); echo "skip - the real-curl checks need curl and python3"
else
  printf 'the whole file\n%.0s' $(seq 1 200) > "$T/srv/body"
  cat > "$T/srv/server.py" <<'PY'
# Serves <body> on 127.0.0.1; the first <cuts> connections are reset (RST): in "mid" mode after
# the headers and part of the body (curl exit 56), in "tls" mode before the TLS handshake
# (curl exit 35). Writes the port to <port file>, then each connection to <log>.
import os, socket, ssl, struct, sys
mode, body_path, port_file, log, cuts = sys.argv[1:6]
cert = sys.argv[6:8]
body = open(body_path, 'rb').read()
cuts = int(cuts)
ctx = None
if mode == 'tls':
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(*cert)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0)); s.listen(8)
open(port_file + '.tmp', 'w').write(str(s.getsockname()[1]))
os.rename(port_file + '.tmp', port_file)
n = 0
def reset(c):
    c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0)); c.close()
while True:
    c, _ = s.accept(); n += 1
    with open(log, 'a') as f: f.write('cut\n' if n <= cuts else 'served\n')
    try:
        if n <= cuts and mode == 'tls':
            reset(c); continue
        if ctx: c = ctx.wrap_socket(c, server_side=True)
        req = b''
        while b'\r\n\r\n' not in req:
            chunk = c.recv(4096)
            if not chunk: break
            req += chunk
        head = b'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(body)
        if n <= cuts:
            c.sendall(head + body[:100]); reset(c); continue
        c.sendall(head + body); c.close()
    except (OSError, ssl.SSLError):
        c.close()
PY
  serve() { # <mode> <cuts> [cert key]: starts the server, sets url_port; 1 when it never starts
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null && wait "$server_pid" 2>/dev/null
    rm -f "$T/port" "$T/log"
    python3 -I "$T/srv/server.py" "$1" "$T/srv/body" "$T/port" "$T/log" "$2" "${@:3}" 2>"$T/server.err" &
    server_pid=$!
    # Up to 30 s: under load (lint running beside it) python's start can take seconds.
    for _ in $(seq 1 300); do [ -s "$T/port" ] && break; sleep 0.1; done
    url_port="$(cat "$T/port" 2>/dev/null)"
    if [ -z "$url_port" ]; then
      fail=$((fail + 1))
      echo "FAIL - the $1 test server did not start within 30 s (stderr: $(tr '\n' ' ' < "$T/server.err"))"
      return 1
    fi
  }
  fetch() { # <how: plain|dcf> <url> [curl args]: "<exit code> <whole|partial> <bytes received>"
    local how="$1" url="$2" rc; shift 2
    rm -f "$T/got"
    if [ "$how" = plain ]; then
      curl -fsS --retry 3 --retry-delay 1 "$@" -o "$T/got" "$url" 2>"$T/curl.err"; rc=$?
    else
      bash -c 'set -euo pipefail; . "$1"; shift; dcf_curl "$@"' _ "$helper" -fsS "$@" -o "$T/got" "$url" 2>"$T/curl.err"; rc=$?
    fi
    echo "$rc $(cmp -s "$T/got" "$T/srv/body" && echo whole || echo partial) $(if [ -f "$T/got" ]; then wc -c < "$T/got" | tr -d ' '; else echo 0; fi)"
  }
  check_fetch() { # <name> <mode> <want: whole|fails> <fetch result>
    local rc got bytes ok=no
    read -r rc got bytes <<< "$4"
    case "$3" in
      whole) [ "$rc" = 0 ] && [ "$got" = whole ] && ok=yes ;;
      fails) [ "$rc" != 0 ] && [ "$got" = partial ] && ok=yes ;;
    esac
    if [ "$ok" = yes ]; then pass=$((pass + 1)); echo "ok   - $1 (exit $rc, $bytes of $(wc -c < "$T/srv/body" | tr -d ' ') bytes)"
    else
      fail=$((fail + 1))
      echo "FAIL - $1 (mode $2, wanted $3; curl exit $rc, $got file, $bytes of $(wc -c < "$T/srv/body" | tr -d ' ') bytes;" \
        "server connections: $(tr '\n' ' ' < "$T/log" 2>/dev/null); curl said: $(tr '\n' ' ' < "$T/curl.err" 2>/dev/null))"
    fi
  }

  # The baseline asserts "fails, file not whole": the exact code (56 or 35 here) can shift with
  # timing under load (18 when the cut lands as a clean close), so it is reported, not compared.
  if serve mid 1; then
    check_fetch 'mid-transfer cut: plain curl --retry gives up (56 expected)' mid fails "$(fetch plain "http://127.0.0.1:$url_port/f")"
  fi
  if serve mid 1; then
    check_fetch 'mid-transfer cut: dcf_curl retries and gets the whole file' mid whole "$(fetch dcf "http://127.0.0.1:$url_port/f")"
    check 'mid-transfer cut: dcf_curl made a second connection' 'cut served' "$(tr '\n' ' ' < "$T/log" | sed 's/ $//')"
  fi

  if command -v openssl >/dev/null 2>&1 &&
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
      -keyout "$T/srv/key.pem" -out "$T/srv/cert.pem" >/dev/null 2>&1; then
    if serve tls 1 "$T/srv/cert.pem" "$T/srv/key.pem"; then
      check_fetch 'TLS reset: plain curl --retry gives up (35 expected)' tls fails "$(fetch plain "https://127.0.0.1:$url_port/f" --cacert "$T/srv/cert.pem")"
    fi
    if serve tls 1 "$T/srv/cert.pem" "$T/srv/key.pem"; then
      check_fetch 'TLS reset: dcf_curl retries and gets the whole file' tls whole "$(fetch dcf "https://127.0.0.1:$url_port/f" --cacert "$T/srv/cert.pem")"
    fi
  else
    skip=$((skip + 2)); echo "skip - the TLS-reset checks need openssl"
  fi
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
