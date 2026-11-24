#!/usr/bin/env bash
# Docker-free tests of the component-registry `http` source (src/component-registry/
# registry-source-http.sh) against a tiny local python3 server: an open endpoint, each auth type
# (bearer, header, basic) with a stub dcf-secret, the refusal to send a secret over plain http://
# without allow-insecure, ETag, Last-Modified and body-hash versions, a 404 and a timeout, an
# archive refused, redirects (followed without a secret, not with one), the secret never in the
# source's output, its process arguments or any process list, and through dcf-registry resolve:
# a 404 falling back to the last good copy. Part of `task lint` (`task test:component-registry-unit`).
# Needs python3 and curl; skipped (exit 0) without them.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then echo "skip - python3 and curl are needed"; exit 0; fi

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
srv_pid=''
trap '[ -z "$srv_pid" ] || kill "$srv_pid" 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin" "$T/share"
for f in dcf-registry registry-source-http registry-source-path registry-source-git; do cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"; done
cp "$src/dcf-curl.sh" "$T/share/dcf-curl.sh"
# A stub dcf-secret: registry/ok is the secret, anything else is not found.
SECRET='tok-s3cret-VALUE-42'
# shellcheck disable=SC2016  # the stub expands them when it runs
printf '#!/bin/sh\n[ "$1" = get ] && [ "$2" = registry/ok ] && { printf "%%s\\n" "%s"; exit 0; }\necho "not found" >&2; exit 1\n' "$SECRET" > "$bin/dcf-secret"
chmod +x "$bin/dcf-secret"
export PATH="$bin:$PATH" COMPONENT_REGISTRY_SHARE_DIR="$T/share" REGISTRY_SOURCE_HTTP_MAX_TIME=5

cat > "$T/server.py" <<'PY'
import base64, http.server, os, sys, time
SECRET = os.environ['TEST_SECRET']
REG = b"[skills/web]\nbody:text = from http\n"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, extra=(), body=REG):
        self.send_response(code)
        for k, v in extra: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        p, h = self.path.split('?')[0], self.headers
        if p == "/legacy.reg": return self.send(200)
        if p == "/open.layer": return self.send(200)
        if p == "/bearer.layer": return self.send(200 if h.get("Authorization") == "Bearer " + SECRET else 401)
        if p == "/header.layer": return self.send(200 if h.get("X-Api-Key") == SECRET else 401)
        if p == "/basic.layer":
            want = "Basic " + base64.b64encode(("bot:" + SECRET).encode()).decode()
            return self.send(200 if h.get("Authorization") == want else 401)
        if p == "/etag.layer": return self.send(200, [("ETag", '"v7"')])
        if p == "/lm.layer": return self.send(200, [("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")])
        if p == "/plain.layer": return self.send(200)
        if p == "/body2.layer": return self.send(200, body=b"[skills/web]\nbody:text = other\n")
        if p == "/slow.layer": time.sleep(3); return self.send(200 if h.get("Authorization") == "Bearer " + SECRET else 401)
        if p == "/hang.layer": time.sleep(10); return self.send(200)
        if p == "/redir.layer": return self.send(302, [("Location", "/open.layer")], b"")
        if p == "/toggle.layer": return self.send(200 if open(sys.argv[1]).read().strip() == "up" else 404)
        if p == "/archive.tar.gz": return self.send(200, body=b"x")
        return self.send(404, body=b"no")
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
echo up > "$T/toggle"
TEST_SECRET="$SECRET" python3 -I "$T/server.py" "$T/toggle" > "$T/port" 2>/dev/null &
srv_pid=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(cat "$T/port")"

S=registry-source-http
fetch_to() { rm -rf "$T/d"; mkdir "$T/d"; $S fetch h "$T/d" "$@" 2>"$T/err" >"$T/out"; }

fetch_to "url=$base/open.layer"; check "open endpoint: fetched" 0 $?
check "open endpoint: file named after the URL" "[skills/web]" "$(head -n 1 "$T/d/open.layer" 2>/dev/null)"
fetch_to "url=$base/plain.layer?x=1"; check "a query string is not part of the file name" yes "$([ -f "$T/d/plain.layer" ] && echo yes)"
fetch_to "url=$base/legacy.reg"; check "a .reg URL is saved as <layer>.layer (2.0.0)" "h.layer" "$(ls "$T/d")"
fetch_to "url=$base/open.layer" auth.type=none; check "auth none: fetched" 0 $?

fetch_to "url=$base/bearer.layer" auth.secret=registry/ok allow-insecure=true; check "bearer (the default type with a secret): fetched" 0 $?
fetch_to "url=$base/bearer.layer" auth.type=bearer allow-insecure=true; check "bearer without a secret setting: exit 2" 2 $?
fetch_to "url=$base/header.layer" auth.type=header auth.header=X-Api-Key auth.secret=registry/ok allow-insecure=true; check "header: fetched" 0 $?
fetch_to "url=$base/header.layer" auth.type=header auth.secret=registry/ok allow-insecure=true; check "header without a name: exit 2" 2 $?
fetch_to "url=$base/basic.layer" auth.type=basic auth.user=bot auth.secret=registry/ok allow-insecure=true; check "basic: fetched" 0 $?
fetch_to "url=$base/basic.layer" auth.type=basic auth.secret=registry/ok allow-insecure=true; check "basic without a user: exit 2" 2 $?
fetch_to "url=$base/bearer.layer"; check "a protected endpoint without a log-in: exit 1" 1 $?
contains "a 401 is said" "$(cat "$T/err")" "401"
fetch_to "url=$base/bearer.layer" auth.secret=registry/nope allow-insecure=true; check "a secret dcf-secret cannot read: exit 1" 1 $?
fetch_to "url=$base/open.layer" auth.type=wrong; check "an unknown auth.type: exit 2" 2 $?
fetch_to "url=$base/open.layer" auth.type=none auth.secret=registry/ok; check "none with a secret: exit 2" 2 $?

# The insecure refusal
fetch_to "url=$base/bearer.layer" auth.secret=registry/ok; rc=$?
check "a secret over plain http:// is refused: exit 2" 2 $rc
contains "the refusal says why and how" "$(cat "$T/err")" "allow-insecure: true"
check "the refusal fetched nothing" 0 "$(find "$T/d" -type f | wc -l)"
fetch_to "url=$base/open.layer" allow-insecure=maybe; check "allow-insecure must be true or false: exit 2" 2 $?

# Secrets are never shown
fetch_to "url=$base/bearer.layer" auth.secret=registry/ok allow-insecure=true
lacks "the secret is not in the output" "$(cat "$T/out" "$T/err")" "$SECRET"
fetch_to "url=$base/bearer.layer" auth.secret=registry/ok allow-insecure=true auth.type=basic auth.user=nobody
lacks "the secret is not in the error output of a rejected log-in" "$(cat "$T/err")" "$SECRET"
# ... nor in any process's arguments while a slow request is in flight
rm -rf "$T/d"; mkdir "$T/d"
$S fetch h "$T/d" "url=$base/slow.layer" auth.secret=registry/ok allow-insecure=true >/dev/null 2>&1 &
bg=$!; seen=no; saw_curl=no
for _ in $(seq 25); do
  for c in /proc/[0-9]*/cmdline; do
    [ -r "$c" ] || continue
    args="$(tr '\0' ' ' < "$c" 2>/dev/null)"
    case "$args" in *"$SECRET"*) seen=yes ;; esac
    case "$args" in curl\ *) saw_curl=yes ;; esac
  done
  sleep 0.1
done
check "the secret is in no process's arguments" no "$seen"
check "(a curl was in flight when the process list was read)" yes "$saw_curl"
wait "$bg"; check "the slow log-in request still succeeded" 0 $?

# Versions
check "version: the ETag" 'etag:"v7"' "$($S version h "url=$base/etag.layer")"
check "version: the Last-Modified" "modified:Wed, 01 Jan 2025 00:00:00 GMT" "$($S version h "url=$base/lm.layer")"
v1="$($S version h "url=$base/plain.layer")"; v2="$($S version h "url=$base/body2.layer")"
contains "version: a body hash without a validator" "$v1" "sha256:"
check "version: another body is another hash" yes "$([ "$v1" != "$v2" ] && echo yes)"
check "version: the same body is the same hash" "$v1" "$($S version h "url=$base/plain.layer")"
$S version h "url=$base/missing.layer" >/dev/null 2>&1; check "version: a 404 is exit 1" 1 $?
$S version h >/dev/null 2>&1; check "no url: exit 2" 2 $?
$S version h "url=ftp://x/y.layer" >/dev/null 2>&1; check "a non-http url: exit 2" 2 $?
$S version h "url=$base/open.layer" frob=1 >/dev/null 2>&1; check "an unknown setting: exit 2" 2 $?
$S frobnicate >/dev/null 2>&1; check "an unknown verb: exit 3" 3 $?
check "supports lists its verbs" "fetch version supports" "$($S supports | tr '\n' ' ' | sed 's/ $//')"

# Archives, 404, timeout, redirects
fetch_to "url=$base/archive.tar.gz"; check "an archive is refused: exit 1" 1 $?
contains "an archive: said" "$(cat "$T/err")" "archive"
fetch_to "url=$base/missing.layer"; check "a 404: exit 1" 1 $?
start=$SECONDS; fetch_to "url=$base/hang.layer"; rc=$?; took=$((SECONDS - start))
check "a timeout: exit 1" 1 $rc
check "a timeout ends within the limit (5 s, one retry)" yes "$([ "$took" -lt 16 ] && echo yes)"
fetch_to "url=http://127.0.0.1:1/x.layer"; check "nothing listening: exit 1" 1 $?
fetch_to "url=$base/redir.layer"; check "a redirect is followed without a secret" 0 $?
fetch_to "url=$base/redir.layer" auth.secret=registry/ok allow-insecure=true; check "a redirect is not followed with a secret" 1 $?

# Through dcf-registry resolve: the last good copy when the endpoint goes away
C="$T/case"; mkdir -p "$C/repo/.devcontainer"; cd "$C/repo" || exit 1
export COMPONENT_REGISTRY_STATE_DIR="$C/state"
printf 'layers:\n  - id: web\n    at: /Corp\n    sources:\n      - { kind: http, url: "%s/toggle.layer", auth: { type: none } }\n' "$base" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "resolve with an http layer: exit 0" 0 $?
contains "the http layer's value is resolved" "$(cat "$C/state/view/meta/skills/web/values/body" 2>/dev/null)" "from http"
echo down > "$T/toggle"
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "the endpoint 404s: resolve still exits 0" 0 "$rc"
contains "the last good copy is still resolved" "$(cat "$C/state/view/meta/skills/web/values/body" 2>/dev/null)" "from http"
contains "the last good copy is said" "$out" "using the last good copy"
printf 'layers:\n  - id: web\n    at: /Corp\n    sources:\n      - { kind: http, url: "%s/open.layer", auth: { secret: x }, allow-insecure: true }\n' "$base" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; check "the parser accepts allow-insecure and auth" 0 $?
printf 'layers:\n  - id: web\n    at: /Corp\n    sources:\n      - { kind: http, path: x }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "an http source without url is refused: exit 2" 2 "$rc"
contains "... naming the need" "$out" "an http source needs url"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
