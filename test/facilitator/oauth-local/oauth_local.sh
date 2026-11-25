#!/usr/bin/env bash
# `task facilitator:oauth-local`: N5b on one machine, with no public https address. Keycloak (the login server, in the internal
# Docker) and a facilitator node (http.url http://localhost:8765, http.insecure) with Keycloak as its one issuer, so Claude Code
# (the OAuth client, which registers itself at Keycloak) can log in and talk to a test agent. For a local machine only: plain
# http, a throwaway password, a throwaway realm.
#
#   oauth_local.sh up         start Keycloak and the node, wait until both answer, print what to run (the default)
#   oauth_local.sh down       stop the node and the test agent, remove the Keycloak container and the state folder
#   oauth_local.sh status     what runs
#   oauth_local.sh fx ARGS..  the node's own `facilitator` command (http list, http approve <handle>, verify --conv <id>)
#   oauth_local.sh info       print the instructions again
#
# The node runs from a built bundle (FACILITATOR_BUNDLE: a folder holding bin/facilitator or a facilitator-<version>-linux-<arch>.tar.gz,
# else dist/ of this checkout; `task bundle:build` makes one). The Docker is the default context, never `--context host`.
# State (the node's home, keys in files, the logs, the throwaway password) is one folder, mode 700: FACILITATOR_OAUTH_LOCAL_DIR,
# default ${TMPDIR:-/tmp}/facilitator-oauth-local. It makes no network and no volume: one container, with its port on 127.0.0.1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
here="$root/test/facilitator/oauth-local"
tests="$root/test/facilitator"
state="${FACILITATOR_OAUTH_LOCAL_DIR:-${TMPDIR:-/tmp}/facilitator-oauth-local}"
image="quay.io/keycloak/keycloak:26.8.2@sha256:7e66a96e4739239070aeaf72e4c5decf0f7f682cfc725b9f7ea2b336eaba38b3"
cname="facilitator-oauth-local-keycloak"
realm="facilitator-test"
kc_port=8080
node_port=8765
issuer="http://localhost:$kc_port/realms/$realm"
base="http://localhost:$node_port"
user="tester"

die() { echo "oauth-local: $*" >&2; exit 1; }
dock() { docker --context default "$@"; }

resolve_tree() {
  local version arch src
  version="$(bash "$root/bundles/facilitator/install.sh" --version)"
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  src="${FACILITATOR_BUNDLE:-}"
  [ -n "$src" ] || { [ -f "$root/dist/facilitator-$version-linux-$arch.tar.gz" ] && src="$root/dist/facilitator-$version-linux-$arch.tar.gz"; }
  [ -n "$src" ] || die "no bundle: set FACILITATOR_BUNDLE (a folder or a .tar.gz) or run: task bundle:build"
  if [ -d "$src" ]; then tree="$src"; else mkdir -p "$state/tree" && tar -xzf "$src" -C "$state/tree" && tree="$state/tree/facilitator"; fi
  py="$tree/python/bin/python3"
  [ -x "$py" ] || die "no python in the bundle $tree"
  "$py" -I -c "import mcp, uvicorn, jwt, cryptography" || die "the bundle lacks mcp, jwt or cryptography"
}

node_env() {
  export FACILITATOR_HOME="$state/home" FACILITATOR_KEYS=file FACILITATOR_TRANSPORT=poll FACILITATOR_DIRCTL=/nonexistent FACILITATOR_SLIMCTL=/nonexistent
  unset CLAUDECODE DEVHOST_JOB_CHILD FACILITATOR_HANDLE FACILITATOR_TOKEN
}

# bg PIDFILE LOGFILE CMD...: CMD in its own session, so it outlives this script; its own pid (setsid may fork) goes in PIDFILE
bg() {
  local pidfile="$1" log="$2"; shift 2
  # shellcheck disable=SC2016  # the single quotes are meant: the inner bash expands $$ and $0
  setsid bash -c 'echo $$ >"$0"; exec "$@"' "$pidfile" "$@" >"$log" 2>&1 </dev/null &
}
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
stop_pid() {
  if pid_alive "$1"; then
    local p; p="$(cat "$1")"; kill "$p" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$p" 2>/dev/null || true
  fi
  rm -f "$1"
}

print_info() {
  local pw; pw="$(cat "$state/password" 2>/dev/null || echo '(not started)')"
  cat <<INFO

The node and Keycloak run. Sign-in server: $issuer   node: $base/mcp
Test user (throwaway, this run only): $user  password: $pw

1. Where the browser and Claude Code run decides what must be reachable.
   Claude Code opens a browser for the login. That browser must reach localhost:$kc_port (Keycloak) and the port Claude Code
   listens on for the redirect; Claude Code must reach localhost:$node_port (the node).
   * Easiest: run Claude Code on the workstation (Windows) and publish the devhost's ports to it. This devhost forwards no
     ports on its own (its devcontainer.json has no forwardPorts or appPort, and the launcher publishes none). Add
         "appPort": [$kc_port, $node_port, 8976]
     to .devcontainer/devcontainer.json (host side, in your own checkout, not committed) and rebuild with \`task devcontainer:up\`,
     then restart this task. In VS Code, forward the same ports from its Ports panel instead.
   * Or run Claude Code inside the devhost and give it the redirect port above: --callback-port 8976 (below); the Windows
     browser then needs localhost:$kc_port and localhost:8976 forwarded, as above.
   Check from Windows: open http://localhost:$kc_port/realms/$realm/.well-known/openid-configuration (JSON) and
   http://localhost:$node_port/.well-known/oauth-protected-resource/mcp (JSON).

2. Add the node to Claude Code (Claude Code 2.1.x; --callback-port pins the redirect port, only needed when Claude Code is in the devhost):
       claude mcp add --transport http --callback-port 8976 facilitator $base/mcp

3. Log in: start \`claude\`, type  /mcp , choose  facilitator , then  Authenticate. The browser opens Keycloak: sign in as
   $user with the password above. Claude Code registers itself at Keycloak (dynamic client registration) on its own.
   Back in Claude Code the facilitator's tools are there. Ask it to use the facilitator: say who is there, then send "hello" to
   jester (the only agent the node shows).

4. On the node, in the devhost (the first message is held until you approve the client):
       task facilitator:oauth-local -- fx http list                  # the client, named by Keycloak and the subject, waiting
       task facilitator:oauth-local -- fx http approve <handle>      # the handle from the list, e.g. kc-<subject>
       task facilitator:oauth-local -- fx verify --conv <id>         # the conversation id is in Claude Code's reply; shows: via http (oauth, ...)
   The test agent (jester) answers every message with a joke. Logs: $state/node.log, docker logs $cname

5. Stop and clean up:  task facilitator:oauth-local -- down
INFO
}

cmd="${1:-up}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
fx)
  [ -d "$state/repo" ] || die "not running: task facilitator:oauth-local"
  resolve_tree; node_env
  (cd "$state/repo" && exec "$py" -I "$tree/bin/facilitator" "$@")
  ;;
info) print_info ;;
status)
  dock ps --filter "name=^$cname\$" --format 'keycloak: {{.Names}} {{.Status}}' | grep . || echo "keycloak: not running"
  pid_alive "$state/node.pid" && echo "node: running (pid $(cat "$state/node.pid"))" || echo "node: not running"
  pid_alive "$state/agent.pid" && echo "test agent: running" || echo "test agent: not running"
  ;;
down)
  stop_pid "$state/agent.pid"; stop_pid "$state/node.pid"
  dock rm -f "$cname" >/dev/null 2>&1 || true
  rm -rf "$state"
  echo "oauth-local: stopped; the container and the state folder $state are gone (the Keycloak image stays: docker rmi $image)"
  ;;
up)
  command -v docker >/dev/null || die "docker is needed (the internal Docker, the default context)"
  dock info >/dev/null 2>&1 || die "the internal Docker does not answer (docker info)"
  if (exec 3<>"/dev/tcp/127.0.0.1/$kc_port") 2>/dev/null && ! dock ps -q --filter "name=^$cname\$" | grep -q .; then die "port $kc_port is in use by something else"; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$node_port") 2>/dev/null && ! pid_alive "$state/node.pid"; then die "port $node_port is in use by something else"; fi
  mkdir -p "$state"; chmod 700 "$state"
  resolve_tree

  # ---- Keycloak: dev mode, the realm imported from a file in this repo, a throwaway admin and user password
  if ! dock ps -q --filter "name=^$cname\$" | grep -q .; then
    dock rm -f "$cname" >/dev/null 2>&1 || true
    admin_pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    user_pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    umask 077; printf '%s\n' "$user_pw" >"$state/password"; printf '%s\n' "$admin_pw" >"$state/admin-password"; umask 022
    # create, copy the realm in, start: no bind mount, so it works whichever daemon the context names
    dock create --name "$cname" -p "127.0.0.1:$kc_port:8080" \
      -e "KC_BOOTSTRAP_ADMIN_USERNAME=admin" -e "KC_BOOTSTRAP_ADMIN_PASSWORD=$admin_pw" \
      -e "KC_HOSTNAME=http://localhost:$kc_port" -e KC_HTTP_ENABLED=true \
      "$image" start-dev --import-realm >/dev/null
    mkdir -p "$state/import" && cp "$here/realm.json" "$state/import/realm.json"
    dock cp "$state/import" "$cname:/opt/keycloak/data/import"
    dock start "$cname" >/dev/null
  fi
  echo "oauth-local: waiting for Keycloak (the first start takes up to a minute)"
  ready=""
  for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null "$issuer/.well-known/openid-configuration" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  [ -n "$ready" ] || { dock logs --tail 30 "$cname" >&2 || true; die "Keycloak did not answer at $issuer"; }
  if [ ! -f "$state/password-set" ]; then
    admin_pw="$(cat "$state/admin-password")"; user_pw="$(cat "$state/password")"
    dock exec "$cname" /opt/keycloak/bin/kcadm.sh config credentials --server "http://localhost:8080" --realm master --user admin --password "$admin_pw" >/dev/null
    dock exec "$cname" /opt/keycloak/bin/kcadm.sh set-password -r "$realm" --username "$user" --new-password "$user_pw" >/dev/null
    : >"$state/password-set"
  fi

  # ---- the node
  node_env
  repo="$state/repo"; mkdir -p "$repo/.devcontainer"
  cat >"$repo/.devcontainer/participants.yml" <<'YML'
participants:
  - name: jester
    cli: openai-compatible
    kind: resident
    description: tells jokes (the test agent of oauth-local)
  - name: domain-expert-one
    cli: claude
    kind: resident
YML
  cat >"$repo/.devcontainer/facilitator.yml" <<YML
facilitator:
  humans: [you]
  http:
    listen: 127.0.0.1:$node_port
    url: $base
    insecure: true
    issuers:
      - name: kc
        issuer: $issuer
YML
  cat >"$repo/.devcontainer/mesh.yml" <<'YML'
preset: team
expose:
  jester: public
  "*": local
limits:
  public:
    http_receive_wait: 25s
YML
  fx() { (cd "$repo" && "$py" -I "$tree/bin/facilitator" "$@"); }
  fx register --all --no-directory >/dev/null
  if ! pid_alive "$state/node.pid"; then
    (cd "$repo" && bg "$state/node.pid" "$state/node.log" "$py" -I "$tree/bin/facilitator" http serve)
  fi
  if ! pid_alive "$state/agent.pid"; then
    (cd "$repo" && bg "$state/agent.pid" "$state/agent.log" "$py" -I "$tests/integration/http_agent.py" jester 86400 "Why did the packet cross the network? To get to the other site." "$tree/lib")
  fi
  ready=""
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -d '{}' 2>/dev/null || true)"
    [ "$code" = 401 ] && { ready=1; break; }
    sleep 1
  done
  [ -n "$ready" ] || { tail -10 "$state/node.log" >&2 || true; die "the node did not answer at $base/mcp (expected 401)"; }
  fx http issuers | sed 's/^/oauth-local: node: /'
  print_info
  ;;
*) die "unknown command '$cmd' (up, down, status, fx, info)" ;;
esac
