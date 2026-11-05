#!/usr/bin/env bash
# openbao-setup: the openbao Feature's postCreateCommand (no argument) and postStartCommand
# (`openbao-setup start`), run as the remote user from the workspace folder; also behind
# `task openbao:setup`. Idempotent, never fatal: a problem is reported, not allowed to abort the
# rest of post-create or post-start.
#
# 1. dcf-persist makes OPENBAO_STATE_DIR (the Feature's named volume, or a bind mount a repo put on
#    the same target) exist and belong to the remote user.
# 2. bao keeps its token there through the token helper the Feature configures (BAO_CONFIG_PATH in
#    containerEnv, set for every process): the login survives a rebuild. A token already in
#    ~/.vault-token (a login from before this Feature, or from a process without the variable) is
#    moved into the state dir once, when the state dir has none and the helper is in effect.
# 3. Says which mode it runs in and what is known without asking the server: the address, whether
#    the token helper is in effect, whether a login is saved. It never contacts the server (an
#    unreachable one must not hold post-create).
# 4. `start`, server mode only (and, with the backupInterval option, the backup timer, below): write the server's config into the state dir (raft storage on the
#    Feature's volume, one loopback listener, the file audit device), start `bao server` in the
#    background and say whether it is not initialised, sealed or unsealed. It never waits for an
#    unseal and never prompts: a start hook that waits holds every Feature's start. The server
#    stays sealed until the Operator runs task openbao:unseal (or, with the unlock option set to
#    keyfile, until the workstation's launcher sends the OpenBao key file).
# 5. `unlock`, `keyfile` and `renew`: the OpenBao key file's container side, which the workstation's
#    launcher runs at this absolute path; handed over to openbao-keyfile (see there).
set -u

case "${1:-}" in
  unlock | keyfile | renew) exec "$(dirname "$(readlink -f "$0")")/openbao-keyfile" "$@" ;;
esac

# Defaults baked by install.sh from the Feature options. OPENBAO_SETUP_* in the environment
# (containerEnv) override them without a rebuild.
feature_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f "$feature_dir/options.env" ] && source "$feature_dir/options.env"
mode="${OPENBAO_SETUP_MODE-${MODE:-client}}"
unlock="${OPENBAO_SETUP_UNLOCK:-${UNLOCK:-operator}}"
[ "$unlock" = keyfile ] || unlock=operator
# env.sh gives server mode its BAO_ADDR default (the local listener), as it does for dcf-secret
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$feature_dir/env.sh" ] && source "$feature_dir/env.sh"
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
old="$HOME/.vault-token"
target="$dir/token"
feature_config=/usr/local/share/openbao-feature/bao-config.hcl

# ----------------------------------------------------------------- server mode: the start ----
conf="$dir/server.hcl"
marker='# Written by the openbao Feature (openbao-setup start); remove this line to keep your own edits.'
listen=127.0.0.1:8200

write_config() {
  # Rewritten on every start while it still carries the marker line (so a Feature upgrade reaches
  # it); a config whose marker was removed is the repo's own and is left alone.
  if [ -f "$conf" ] && [ "$(head -n 1 "$conf")" != "$marker" ]; then return 0; fi
  (
    umask 077
    {
      echo "$marker"
      cat <<HCL
# One node, raft storage on the Feature's volume (tier 4; losing the machine loses it unless a
# backup exists, see the NOTES). The listener is loopback only and has no TLS: it never leaves
# the container. OpenBao has used no mlock since 2.0.0, so no disable_mlock is needed.
ui = false
api_addr = "http://$listen"
cluster_addr = "http://127.0.0.1:8201"

storage "raft" {
  path    = "$dir/raft"
  node_id = "devhost"
}

# The legacy unauthenticated root-token endpoints (sys/generate-root/*) are on for this listener,
# so two unseal shares alone make a root token when nobody is logged in (a forgotten password).
# Without a token a caller can only start, read or cancel an attempt; completing one takes the
# shares. Rekey stays off (the default).
listener "tcp" {
  address     = "$listen"
  tls_disable = true
  disable_unauthed_generate_root_endpoints = false
}

# The file audit device, declared here rather than enabled through the API (which a server
# refuses unless unsafe_allow_api_audit_creation is set): it names every identity that reads a key.
audit "file" "file" {
  description = "Every request, in the state volume"
  options {
    file_path = "$dir/audit.log"
  }
}
HCL
    } > "$conf.tmp.$$" && mv -f "$conf.tmp.$$" "$conf"
  )
}

server_alive() {
  local pid
  pid="$(cat "$dir/server.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = bao ]
}

start_server() {
  [ "$mode" = server ] || return 0
  if ! command -v bao >/dev/null 2>&1; then
    echo "openbao: bao not found on PATH, the server is not started; rebuild the container" >&2
    return 0
  fi
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  if [ ! -w "$dir" ]; then
    echo "openbao: $dir is not writable, the server is not started (its storage lives there)" >&2
    return 0
  fi
  if ! write_config; then
    echo "openbao: could not write $conf, the server is not started" >&2
    return 0
  fi
  (umask 077; mkdir -p "$dir/raft")
  if server_alive; then
    echo "openbao: server already running (pid $(cat "$dir/server.pid"))"
  else
    # a rekey waiting for the OpenBao key file's confirmation lives in the server's memory: a new
    # server process has none, so the record says it was dropped (keyfile status then answers so)
    if [ -f "$dir/keyfile-pending" ] && grep -qx 'state=pending' "$dir/keyfile-pending" && grep -qx 'kind=rekey' "$dir/keyfile-pending"; then
      sed -i 's/^state=pending$/state=dropped/' "$dir/keyfile-pending" 2>/dev/null || true
    fi
    if command -v setsid >/dev/null 2>&1; then
      (umask 077; setsid bao server -config="$conf" </dev/null >>"$dir/server.log" 2>&1 & echo "$!" > "$dir/server.pid")
    else
      (umask 077; nohup bao server -config="$conf" </dev/null >>"$dir/server.log" 2>&1 & echo "$!" > "$dir/server.pid")
    fi
  fi
  # Wait only for the listener to answer (any answer: sealed counts), never for an unseal.
  local st_rc st_json
  for _ in $(seq 1 "${OPENBAO_START_TRIES:-40}"); do
    st_json="$(BAO_ADDR="http://$listen" bao status -format=json 2>/dev/null)"
    st_rc=$?
    [ "$st_rc" -ne 1 ] && break
    sleep 0.5
  done
  case "$st_rc" in
    0) echo "openbao: server running and unsealed at http://$listen" ;;
    2)
      if grep -Eq '"initialized"[[:space:]]*:[[:space:]]*false' <<<"$st_json"; then
        if [ "$unlock" = keyfile ]; then
          echo "openbao: server started at http://$listen, not initialised; the Operator runs task dc:openbao:keyfile:create on the workstation (the OpenBao key file)"
        else
          echo "openbao: server started at http://$listen, not initialised; the Operator runs task openbao:init"
        fi
      elif [ "$unlock" = keyfile ]; then
        echo "openbao: server started at http://$listen, sealed; the workstation's launcher unseals it with the OpenBao key file at its next task dc:* (or task dc:openbao:unlock; two custody shares at task openbao:unseal also do)"
      else
        echo "openbao: server started at http://$listen, sealed; the Operator runs task openbao:unseal"
      fi
      ;;
    *)
      echo "openbao: the server was started but does not answer at http://$listen; the end of $dir/server.log:" >&2
      tail -n 8 "$dir/server.log" 2>/dev/null | sed 's/^/openbao:   /' >&2
      ;;
  esac
  return 0
}

# The optional backup timer (the backupInterval option): openbao-server decides whether there is one
# to start and says so; it never fails the start.
start_backup_timer() {
  [ "$mode" = server ] || return 0
  command -v openbao-server >/dev/null 2>&1 || return 0
  [ -n "$(opt_backup_interval)" ] || return 0
  openbao-server backup-timer-start || true
}
opt_backup_interval() {
  if [ -n "${OPENBAO_SETUP_BACKUP_INTERVAL+set}" ]; then printf '%s' "$OPENBAO_SETUP_BACKUP_INTERVAL"; else printf '%s' "${BACKUPINTERVAL:-}"; fi
}

if [ "${1:-}" = start ]; then
  start_server
  start_backup_timer
  exit 0
fi

dcf-persist --label openbao "$dir"

case "$mode" in
  client) echo "openbao: mode client (the bao CLI and dcf-secret; BAO_ADDR names the server)" ;;
  server)
    if [ "$unlock" = keyfile ]; then
      echo "openbao: mode server, unlock keyfile (a server with raft storage in $dir/raft, started by the post-start hook; the workstation's launcher unseals it and logs the Operator in with the OpenBao key file)"
    else
      echo "openbao: mode server (a server with raft storage in $dir/raft, started by the post-start hook; sealed until the Operator runs task openbao:unseal)"
    fi
    ;;
  *)
    echo "openbao: mode '$mode' is not known (client or server); running as client" >&2
    mode=client
    ;;
esac

# Only with the token helper in effect is a token moved: otherwise bao still reads ~/.vault-token.
helper=0
[ "${BAO_CONFIG_PATH:-}" = "$feature_config" ] && helper=1

if [ ! -w "$dir" ]; then
  echo "openbao: $dir is not writable, so the login cannot be kept in it and will not survive a rebuild" >&2
elif [ "$helper" -eq 1 ] && [ -f "$old" ] && [ ! -L "$old" ]; then
  if [ -e "$target" ]; then
    echo "openbao: $old is left where it is: the state dir already has a login, and bao uses that one"
  elif (umask 077; mv "$old" "$target") 2>/dev/null; then
    chmod 0600 "$target" 2>/dev/null || true
    echo "openbao: login token moved from $old into the state dir (once)"
  else
    echo "openbao: could not move $old into $dir; that login will not survive a rebuild" >&2
  fi
fi

if [ "$helper" -eq 1 ]; then
  echo "openbao: token helper in effect (BAO_CONFIG_PATH), the login is kept in $dir"
elif [ -z "${BAO_CONFIG_PATH:-}" ]; then
  echo "openbao: BAO_CONFIG_PATH is not set, so bao keeps its token in ~/.vault-token and a rebuild logs you out; this Feature sets it in containerEnv (a repo's own containerEnv may have removed it)" >&2
else
  echo "openbao: BAO_CONFIG_PATH is $BAO_CONFIG_PATH, not this Feature's $feature_config; put token_helper = \"/usr/local/bin/openbao-token-helper\" in that file to keep the login in $dir" >&2
fi

if ! command -v bao >/dev/null 2>&1; then
  echo "openbao: bao not found on PATH; rebuild the container and check the build log for this Feature" >&2
  exit 0
fi
echo "openbao: $(bao version 2>/dev/null | head -n 1) at $(command -v bao)"
if [ -n "${OPENBAO_ADDR_DEFAULTED:-}" ]; then
  echo "openbao: BAO_ADDR is not set; server mode uses its default $BAO_ADDR for dcf-secret and the tasks (a bare bao needs BAO_ADDR set)"
else
  echo "openbao: BAO_ADDR ${BAO_ADDR:-is not set (bao falls back to https://127.0.0.1:8200); put it in containerEnv}"
fi
if [ -n "${BAO_TOKEN:-}" ]; then
  echo "openbao: BAO_TOKEN is set in the environment and takes precedence over the saved login"
elif [ -s "$target" ]; then
  echo "openbao: a login is saved in $dir (it may have expired; dcf-secret status checks it)"
elif [ "$mode" = server ] && [ "$unlock" = keyfile ]; then
  echo "openbao: no login yet; the workstation's launcher logs the Operator in with the OpenBao key file (task dc:openbao:unlock)"
elif [ "$mode" = server ]; then
  echo "openbao: no login yet; once the server is unsealed, run task openbao:login -- -method=userpass username=operator (it persists in $dir)"
else
  echo "openbao: no login yet; run 'bao login' (or task openbao:login) once, it persists in $dir"
fi
exit 0
