#!/usr/bin/env bash
# openbao-keyfile: the container side of the OpenBao key file (the unlock option set to keyfile).
# The workstation's launcher runs it as /usr/local/bin/openbao-setup <subcommand>, which hands over
# to this script; nothing else is meant to call it.
#
#   unlock --status          the state, as one JSON line; no secret in or out, never refused
#   unlock --stdin           the OpenBao key file's JSON on stdin: unseal (sys/unseal, twice) if
#                            sealed, log in as the operator AppRole, revoke the previous token with
#                            itself, keep the new one where bao's token helper keeps it, start the
#                            renewer
#   keyfile create --stdin   two custody shares (or init:true on an empty server): rotate-keys to 5
#                            shares, threshold 2, with a root token from the shares (no login); the
#                            operator AppRole (1 hour periodic token, loopback only), every older
#                            operator secret id destroyed, the userpass user operator deleted, every
#                            other role's secret id reissued, the Operator logged in, a backup; the
#                            new key file and the three custody shares on stdout
#   keyfile rotate --stdin   the same from any two of the five shares
#   keyfile status           shares, threshold, whether the operator AppRole and userpass user exist
#   renew                    the renewer (started by unlock, create and rotate; detached)
#
# The contract with the launcher (docs/proposals/openbao-key-file.md, design B with its architecture
# review): secrets are read only from stdin; stdout carries one JSON object on one line, human lines
# go to stderr; no share, secret id or token is put in an argument, the environment, a file other
# than the token helper's, or a log. So every request is made with curl (the token in a curl config
# read from a pipe, the body on curl's stdin), never with the bao CLI, which takes a token only from
# the environment, a flag or its helper. Only the loopback listener the start hook wrote is spoken
# to: BAO_ADDR, VAULT_ADDR and BAO_TOKEN from the environment are ignored (finding 3).
#
# Exit codes: 0 ok, 1 failed (the JSON says why), 3 refused inside an agent's job (DEVHOST_JOB_CHILD,
# CLAUDECODE, a name in OPENBAO_AGENT_JOB_VARS), 4 not applicable (no server mode, or unlock is not
# keyfile for the commands that need it), 2 a wrong call.
set -u
umask 077
# `printf <body> | call ...` must set $http and $body in this shell: the last part of a pipeline
# runs here, not in a subshell (no job control in a script)
shopt -s lastpipe

# shellcheck disable=SC2034  # read by say() in openbao-lib.sh
prog=openbao-keyfile
self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
mount="${DCF_SECRET_MOUNT:-dcf}"
# Whatever the environment names is never used (finding 3); env.sh is not sourced for that reason.
unset BAO_ADDR VAULT_ADDR BAO_TOKEN VAULT_TOKEN BAO_NAMESPACE VAULT_NAMESPACE
# shellcheck disable=SC1091  # installed by install.sh
. "$ob_dir/openbao-lib.sh" 2>/dev/null || {
  printf '{"v":1,"ok":false,"error":"%s/openbao-lib.sh is missing: rebuild the devcontainer","code":"broken"}\n' "$ob_dir"
  exit 1
}

# ------------------------------------------------------------------------------ options ----
optval() { # <options.env name> <override variable> <default>
  local v="${!2:-}"
  if [ -z "$v" ]; then
    v="$(
      # shellcheck disable=SC1091  # written by install.sh
      [ -f "$ob_dir/options.env" ] && . "$ob_dir/options.env"
      printf '%s' "${!1:-}"
    )"
  fi
  printf '%s' "${v:-$3}"
}
server_mode=0
[ "$(optval MODE OPENBAO_SETUP_MODE client)" = server ] && server_mode=1
unlock_opt="$(optval UNLOCK OPENBAO_SETUP_UNLOCK operator)"
case "$unlock_opt" in
  operator | keyfile) ;;
  *)
    say "unlock '$unlock_opt' is not known (operator or keyfile): read as operator"
    unlock_opt=operator
    ;;
esac
mode=off
[ "$server_mode" -eq 1 ] && mode="$unlock_opt"

# The period of the Operator's token (1 hour; renewed every third of it). OPENBAO_KEYFILE_TOKEN_PERIOD
# is for the tests, which need a short one; it is read at create and rotate only.
period="${OPENBAO_KEYFILE_TOKEN_PERIOD:-1h}"
[[ "$period" =~ ^[1-9][0-9]*[smh]$ ]] || period=1h

# The address: the loopback listener in the config the start hook wrote, never another one.
addr="$(sed -n 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/server.hcl" 2>/dev/null | head -n 1)"
[[ "$addr" =~ ^127\.0\.0\.1:[0-9]{1,5}$ ]] || addr=127.0.0.1:8200
addr="http://$addr"

# ------------------------------------------------------------------------------- output ----
jstr() { printf '%s' "$1" | jq -Rs .; }
emit() { printf '%s\n' "$1"; }
fail() { # <exit code> <code word> <reason>: the line to stderr; the JSON to stdout, the plain
  # reason in "error" (what the launcher shows) and a short word in "code" (what a script tests)
  say "$3"
  emit "{\"v\":1,\"ok\":false,\"error\":$(jstr "$3"),\"code\":\"$2\"}"
  exit "$1"
}

refuse_agent() { # <what>
  local v
  # shellcheck disable=SC2086  # a list of names
  for v in DEVHOST_JOB_CHILD CLAUDECODE ${OPENBAO_AGENT_JOB_VARS:-}; do
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ -n "${!v:-}" ]; then
      fail 3 refused "openbao-setup $1 refuses to run inside an agent's job ($v is set): it handles unseal shares and the Operator's login, which must never reach a transcript. The workstation's launcher runs it (task dc:openbao:unlock, task dc:openbao:keyfile:create or :rotate)"
    fi
  done
}
need_server() { [ "$server_mode" -eq 1 ] || fail 4 "not-applicable" "this container runs no OpenBao server (the openbao Feature's mode is not server): nothing to unlock"; }
need_keyfile() {
  need_server
  [ "$mode" = keyfile ] || fail 4 "not-applicable" "this server is not opened with the OpenBao key file (the unlock option is $unlock_opt, not keyfile): set unlock to keyfile (or OPENBAO_SETUP_UNLOCK=keyfile in containerEnv) to use it"
}

# ------------------------------------------------------------------------- the HTTP API ----
# call <method> <path> [token]: the request body on stdin (nothing for GET and LIST); sets $http (the
# status, 000 when nothing answered) and $body. The token goes in a curl config read from a pipe, so
# it is in no argument and no environment; -q keeps a ~/.curlrc out.
http="" body=""
call() {
  local m="$1" p="$2" t="${3:-}" out
  local -a data=(--data-binary @-)
  case "$m" in GET | LIST) data=() ;; esac
  out="$(curl -q -sS --noproxy '*' --proto =http --max-time 30 -X "$m" -H 'X-Vault-Request: true' -K <(if [ -n "$t" ]; then printf 'header = "X-Vault-Token: %s"\n' "$t"; fi) "${data[@]}" -w '\n%{http_code}' "$addr/v1/$p" 2>/dev/null)" # dcf-curl: allow a request to the local server, not a download: no retry (a share is sent once)
  http="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [[ "$http" =~ ^[0-9]{3}$ ]] || http=000
  [ "$http" != 000 ] || body=""
}
jget() { printf '%s' "$body" | jq -r "$1 // empty" 2>/dev/null; } # <filter> on the last answer
jerr() { printf '%s' "$body" | jq -r '(.errors // []) | join("; ")' 2>/dev/null; }

# The server's state from sys/seal-status (unauthenticated): $reach (1 answered), $inited, $sealed,
# $cluster, $t_now, $n_now.
reach=0 inited="" sealed="" cluster="" t_now="" n_now=""
state() {
  call GET sys/seal-status </dev/null
  reach=0 inited="" sealed="" cluster="" t_now="" n_now=""
  [ "$http" = 200 ] || return 0
  reach=1
  inited="$(jget '.initialized | tostring')"
  sealed="$(jget '.sealed | tostring')"
  cluster="$(jget .cluster_id)"
  t_now="$(jget '.t | tostring')"
  n_now="$(jget '.n | tostring')"
}
wait_active() { # after an unseal, a single raft node needs a moment to become the active node
  local _
  for _ in $(seq 1 60); do
    call GET sys/health </dev/null
    [ "$http" = 200 ] && return 0
    sleep 0.5
  done
  return 1
}
# The cluster id is read from the store, so a sealed server does not say it: the last one seen is
# kept (not secret) so that a sealed server can still be matched with its key file.
remember_cluster() { [ -z "$cluster" ] || (printf '%s\n' "$cluster" > "$dir/cluster-id.tmp.$$" && mv -f "$dir/cluster-id.tmp.$$" "$dir/cluster-id") 2>/dev/null || true; }
known_cluster() { cat "$dir/cluster-id" 2>/dev/null | head -n 1; }

share_ok() { [[ "$1" =~ ^[A-Za-z0-9+/]+=*$ ]]; }
id_ok() { [[ "$1" =~ ^[A-Za-z0-9-]{1,128}$ ]]; }

# unseal_with <share> <share>: from any progress, sealed -> unsealed, or fails
unseal_with() {
  printf '{"reset":true}' | call PUT sys/unseal
  local s
  for s in "$@"; do
    printf '{"key":"%s"}' "$s" | call PUT sys/unseal
    s=""
    [ "$http" = 200 ] || return 1
    [ "$(jget '.sealed | tostring')" = false ] && break
  done
  [ "$(jget '.sealed | tostring')" = false ] || return 1
  wait_active || return 2
  state
  return 0
}

# ------------------------------------------------------------------------ the token ----
saved_token() { cat "$dir/token" 2>/dev/null; }
token_state() { # live, missing or dead (a saved token the server does not take now: expired,
  # revoked, or a sealed or unreachable server)
  local t
  t="$(saved_token)"
  [ -n "$t" ] || { echo missing; return; }
  call GET auth/token/lookup-self "$t" </dev/null
  t=""
  if [ "$http" = 200 ]; then echo live; else echo dead; fi
}
store_token() { # the token on stdin, through bao's own token helper (one definition of the file)
  if command -v openbao-token-helper >/dev/null 2>&1; then
    OPENBAO_STATE_DIR="$dir" openbao-token-helper store
  else
    local tmp="$dir/token.tmp.$$"
    cat > "$tmp" && mv -f "$tmp" "$dir/token"
  fi
}
# login <role id> <secret id>: the AppRole login; the previous token revoked with itself (finding 6:
# revoke-self is in the default policy, revoke-accessor is not in the Operator's); the new one
# saved; the renewer (re)started. Returns 1 when the login is refused.
login() {
  local old tok
  printf '{"role_id":"%s","secret_id":"%s"}' "$1" "$2" | call POST auth/approle/login
  [ "$http" = 200 ] || return 1
  tok="$(jget .auth.client_token)"
  body=""
  [ -n "$tok" ] || return 1
  old="$(saved_token)"
  printf '%s' "$tok" | store_token || { tok=""; return 3; }
  if [ -n "$old" ] && [ "$old" != "$tok" ]; then
    call POST auth/token/revoke-self "$old" </dev/null
  fi
  old="" tok=""
  start_renewer
  return 0
}

# ------------------------------------------------------------------------ the renewer ----
# Decided against bao agent (review finding 7; see the NOTES): its AppRole auto-auth needs the secret
# id in a file it then keeps in memory for good and re-logs in with, so a permanent Operator credential
# would live in a process of the container; this renews the one token and stops.
renewer_pid() {
  local p
  p="$(cat "$dir/renewer.pid" 2>/dev/null)" || return 1
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'openbao-keyfile renew' || return 1
  echo "$p"
}
stop_renewer() {
  local p
  p="$(renewer_pid)" || return 0
  # its own process group when setsid started it (so its sleep goes too), else the process
  kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  rm -f "$dir/renewer.pid"
}
start_renewer() {
  stop_renewer
  # detached, stdio closed: the launcher's exec returns at once (finding 7)
  if command -v setsid >/dev/null 2>&1; then
    setsid "$self" renew </dev/null >>"$dir/renewer.log" 2>&1 &
  else
    nohup "$self" renew </dev/null >>"$dir/renewer.log" 2>&1 &
  fi
  echo "$!" > "$dir/renewer.pid"
}
rlog() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) openbao-keyfile renew: $*"; }
cmd_renew() {
  echo "$$" > "$dir/renewer.pid"
  trap '[ "$(cat "$dir/renewer.pid" 2>/dev/null)" != "$$" ] || rm -f "$dir/renewer.pid"' EXIT
  trap 'exit 0' TERM INT HUP
  local tok per every last now
  tok="$(saved_token)"
  [ -n "$tok" ] || { rlog "no saved token: nothing to renew"; exit 0; }
  call GET auth/token/lookup-self "$tok" </dev/null
  case "$http" in
    400 | 401 | 403)
      rlog "the saved token is not valid (HTTP $http: expired or revoked): nothing to renew. task dc:openbao:unlock on the workstation logs in again"
      exit 1
      ;;
  esac
  per="$(jget '.data.period | tostring')"
  [[ "$per" =~ ^[0-9]+$ ]] && [ "$per" -gt 0 ] || per=3600
  every=$((per / 3))
  [ "$every" -ge 1 ] || every=1
  rlog "renewing the Operator's token every ${every}s (period ${per}s)"
  last="$(date +%s)"
  while :; do
    # short sleeps against the wall clock: after a suspend the renewal is due at once
    sleep "$((every < 30 ? every : 30))"
    now="$(date +%s)"
    [ $((now - last)) -ge "$every" ] || continue
    tok="$(saved_token)"
    [ -n "$tok" ] || { rlog "the saved token is gone (logged out): the renewer stops"; exit 0; }
    printf '{}' | call POST auth/token/renew-self "$tok"
    tok=""
    case "$http" in
      200) last="$now" ;;
      400 | 401 | 403)
        rlog "the server refused the renewal (HTTP $http: the token expired or was revoked): the renewer stops. task dc:openbao:unlock on the workstation logs in again"
        exit 1
        ;;
      *) rlog "the renewal could not be made (HTTP $http: sealed or unreachable); trying again" ;;
    esac
  done
}

# ------------------------------------------------------------------------- the input ----
input=""
read_input() {
  input="$(head -c 65537)"
  [ "${#input}" -le 65536 ] || fail 1 input "the input is larger than 64 KiB: not a key file"
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || fail 1 input "the input on stdin is not one JSON object"
  [ "$(printf '%s' "$input" | jq -r '.v // empty | tostring')" = 1 ] || fail 1 input "the input's version (v) is not 1"
}
ifield() { printf '%s' "$input" | jq -r "$1 // empty | tostring" 2>/dev/null; }
in_shares=()
read_shares() { # the two shares of the input, checked, into in_shares
  local s
  in_shares=()
  while IFS= read -r s; do in_shares+=("$s"); done < <(printf '%s' "$input" | jq -r '(.shares // [])[] | strings' 2>/dev/null)
  [ "${#in_shares[@]}" -eq 2 ] || { in_shares=(); fail 1 input "the input needs exactly two unseal shares (shares: [two strings])"; }
  for s in "${in_shares[@]}"; do share_ok "$s" || { in_shares=(); fail 1 input "a share in the input is not base64: not an unseal share"; }; done
  [ "${in_shares[0]}" != "${in_shares[1]}" ] || { in_shares=(); fail 1 input "the two shares are the same share: two different ones are needed"; }
}

# ------------------------------------------------------------------------- unlock ----
cmd_unlock_status() {
  local inited_b=false sealed_b=true tok=missing ren=false ready=false srv=""
  if [ "$server_mode" -eq 1 ]; then
    state
    if [ "$reach" -eq 1 ]; then
      [ "$inited" = true ] && inited_b=true
      [ "$sealed" = false ] && sealed_b=false
      if [ "$sealed_b" = false ]; then remember_cluster; fi
    fi
    srv="${cluster:-$(known_cluster)}"
    if [ "$reach" -eq 1 ] && [ "$sealed_b" = false ]; then
      tok="$(token_state)"
    elif [ -n "$(saved_token)" ]; then
      tok=dead
    fi
    renewer_pid >/dev/null && ren=true
    [ "$mode" = keyfile ] && [ "$sealed_b" = false ] && [ "$tok" = live ] && ready=true
    [ "$reach" -eq 1 ] || say "the server at $addr does not answer (task openbao:server:status says whether it runs)"
  fi
  emit "{\"v\":1,\"mode\":\"$mode\",\"initialized\":$inited_b,\"sealed\":$sealed_b,\"token\":\"$tok\",\"renewer\":$ren,\"ready\":$ready,\"server\":$(jstr "$srv")}"
}

cmd_unlock_stdin() {
  refuse_agent "unlock --stdin"
  need_keyfile
  read_input
  local fsrv rid sid known
  fsrv="$(ifield .server)"
  rid="$(ifield .role_id)"
  sid="$(ifield .secret_id)"
  id_ok "$fsrv" || fail 1 input "the key file names no server (server: the cluster id)"
  { id_ok "$rid" && id_ok "$sid"; } || { sid=""; fail 1 input "the key file has no role_id and secret_id of the operator AppRole"; }
  read_shares
  input=""
  state
  [ "$reach" -eq 1 ] || fail 1 unreachable "the server at $addr does not answer: the start hook (openbao-setup start) starts it; task openbao:server:status says why not"
  [ "$inited" = true ] || fail 1 "not-initialised" "the server is not initialised: task dc:openbao:keyfile:create on the workstation initialises it with the OpenBao key file"
  if [ "$sealed" = true ]; then
    known="$(known_cluster)"
    if [ -n "$known" ] && [ "$known" != "$fsrv" ]; then
      in_shares=() sid=""
      fail 1 "other-server" "this OpenBao key file is for server $fsrv, but this volume's server is $known: nothing was sent. task dc:openbao:keyfile:create makes one for this server"
    fi
    local urc=0
    unseal_with "${in_shares[@]}" || urc=$?
    in_shares=()
    case "$urc" in
      0) say "unsealed with the OpenBao key file's two shares" ;;
      2) fail 1 "not-active" "the server is unsealed but did not become the active node; run task dc:openbao:unlock again in a moment" ;;
      *)
        printf '{"reset":true}' | call PUT sys/unseal
        fail 1 "shares-refused" "the server did not take the OpenBao key file's shares (a key file of an earlier rotation, or of another store?): it is still sealed. Two custody shares open it (task openbao:unseal), then task dc:openbao:keyfile:rotate makes a new key file"
        ;;
    esac
  fi
  in_shares=()
  [ -n "$cluster" ] || state
  if [ "$cluster" != "$fsrv" ]; then
    sid=""
    fail 1 "other-server" "this OpenBao key file is for server $fsrv, but the running server is ${cluster:-unknown}: the login was not sent. task dc:openbao:keyfile:rotate (two shares of this server) makes one for it"
  fi
  remember_cluster
  local lrc=0
  login "$rid" "$sid" || lrc=$?
  sid=""
  case "$lrc" in
    0) ;;
    3) fail 1 "token-not-saved" "logged in, but the token could not be saved in $dir: is the state folder writable?" ;;
    *) fail 1 "login-refused" "the server is unsealed, but it refused the OpenBao key file's login (HTTP $http${body:+: $(jerr)}): its secret id was destroyed by a later rotation, or the store was restored. task dc:openbao:keyfile:rotate makes a new key file" ;;
  esac
  say "unsealed, logged in as the Operator (the operator AppRole); the renewer keeps the token alive while the container runs"
  emit '{"v":1,"ok":true,"done":"unsealed, logged in"}'
}

# ------------------------------------------------------------------------ the keyfile ----
# The root token from the shares through the loopback listener's unauthenticated root-token
# endpoints (ADR 0055): no login is needed, so a lost key file and a dead token are recoverable from
# two custody shares (review finding 1).
root_tok="" root_started=0 root_done=0 rot_started=0 new_acc=""
cleanup() {
  if [ "$rot_started" -eq 1 ] && [ -n "$root_tok" ]; then
    call DELETE sys/rotate/root/init "$root_tok" </dev/null
  fi
  if [ -n "$new_acc" ] && [ -n "$root_tok" ]; then
    printf '{"secret_id_accessor":"%s"}' "$new_acc" | call POST auth/approle/role/operator/secret-id-accessor/destroy "$root_tok"
  fi
  if [ -n "$root_tok" ]; then
    call POST auth/token/revoke-self "$root_tok" </dev/null
    [ "$http" = 204 ] || [ "$http" = 200 ] || say "THE ROOT TOKEN COULD NOT BE REVOKED (HTTP $http): seal the server (task openbao:seal) or restart it"
    root_tok=""
  fi
  if [ "$root_started" -eq 1 ] && [ "$root_done" -eq 0 ]; then
    call DELETE sys/generate-root/attempt </dev/null
  fi
  root_started=0
}
root_from_shares() { # the two shares in in_shares -> $root_tok, or fails
  local otp nonce enc s
  printf '{}' | call PUT sys/generate-root/attempt
  case "$http" in
    200) root_started=1 ;;
    405) fail 1 "no-unauthed-root" "this server's listener has the unauthenticated root-token endpoints off (a config of your own, without the marker line): add disable_unauthed_generate_root_endpoints = false to its listener block and restart the server" ;;
    400) fail 1 "root-in-progress" "a root token generation is already in progress ($(jerr)); it is not taken over. Cancel it with an HTTP DELETE to $addr/v1/sys/generate-root/attempt (no token needed) and run this again" ;;
    *) fail 1 "root-failed" "could not start a root token generation (HTTP $http${body:+: $(jerr)})" ;;
  esac
  otp="$(jget .otp)"
  nonce="$(jget .nonce)"
  body=""
  [ -n "$otp" ] && [ -n "$nonce" ] || fail 1 "root-failed" "the server started a root token generation without a one-time password or nonce"
  for s in "${in_shares[@]}"; do
    printf '{"key":"%s","nonce":"%s"}' "$s" "$nonce" | call PUT sys/generate-root/update
    s=""
    [ "$http" = 200 ] || fail 1 "shares-refused" "the server did not take a share for the root token (HTTP $http${body:+: $(jerr)}): not two shares of this store? Nothing was changed"
    [ "$(jget '.complete | tostring')" = true ] && break
  done
  [ "$(jget '.complete | tostring')" = true ] || fail 1 "shares-refused" "the root token generation did not complete with two shares; nothing was changed"
  root_done=1
  enc="$(jget .encoded_token)"
  body=""
  root_tok="$(otp_decode "$enc" "$otp")" || root_tok=""
  enc="" otp=""
  [ -n "$root_tok" ] || fail 1 "root-failed" "the root token could not be decoded; nothing was changed"
}
rcall() { call "$1" "$2" "$root_tok"; } # <method> <path>, the body on stdin, with the root token
ok_http() { case "$http" in 200 | 204) return 0 ;; *) return 1 ;; esac; }
step_hint="nothing irreversible was done: the shares and the OpenBao key file in force still hold"
step() { # <what>: fail unless the last call succeeded
  ok_http || fail 1 "step-failed" "$1 failed (HTTP $http${body:+: $(jerr)}); $step_hint"
}
list_keys() { # <path>, with the root token: the keys, one per line (none when the list is empty)
  rcall LIST "$1" </dev/null
  [ "$http" = 200 ] && jget '.data.keys[]?'
}
# Everything the operator AppRole needs, idempotent; with the root token.
configure_keyfile() {
  rcall GET "sys/mounts/$mount" </dev/null
  if [ "$http" != 200 ]; then
    printf '{"type":"kv","options":{"version":"2"}}' | rcall POST "sys/mounts/$mount"
    step "enabling the $mount KV mount"
  fi
  rcall GET sys/auth </dev/null
  if [ "$(jget '(.data // .) | has("approle/") | tostring')" != true ]; then
    printf '{"type":"approle"}' | rcall POST sys/auth/approle
    step "enabling the approle login"
  fi
  operator_policy "$mount" | jq -Rs '{policy: .}' | rcall PUT sys/policies/acl/operator
  step "writing the Operator's policy"
  # the Operator's role: a periodic token (renewed in the container, no maximum), from inside the
  # container only, a secret id that does not expire (it is kept only in the OpenBao key file)
  printf '{"token_policies":"operator","token_period":"%s","token_ttl":0,"token_max_ttl":0,"token_explicit_max_ttl":0,"secret_id_ttl":0,"secret_id_num_uses":0,"secret_id_bound_cidrs":"127.0.0.1/32","token_bound_cidrs":"127.0.0.1/32"}' "$period" |
    rcall POST auth/approle/role/operator
  step "writing the operator AppRole"
  # the backup role (as openbao-server's ensure_backup_role): what the backup at the end logs in with
  printf 'path "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n' | jq -Rs '{policy: .}' | rcall PUT sys/policies/acl/approle-backup
  step "writing the backup role's policy"
  printf '{"token_policies":"approle-backup","token_ttl":"5m","token_max_ttl":"15m","secret_id_ttl":0,"secret_id_num_uses":0,"secret_id_bound_cidrs":"127.0.0.1/32","token_bound_cidrs":"127.0.0.1/32"}' |
    rcall POST auth/approle/role/backup
  step "writing the backup role"
}
# Every secret id of a role destroyed by accessor (issuing one does not end the others).
destroy_secret_ids() { # <role>
  local acc
  while IFS= read -r acc; do
    [ -n "$acc" ] || continue
    printf '{"secret_id_accessor":"%s"}' "$acc" | rcall POST "auth/approle/role/$1/secret-id-accessor/destroy"
    ok_http || return 1
  done < <(list_keys "auth/approle/role/$1/secret-id")
}
# A role of the backs gets one new secret id, written with its role id under the state folder (as
# openbao-server's reissue_role does); never printed.
reissue_files() { # <role>
  local r="$1" sid rid
  destroy_secret_ids "$r" || return 1
  printf '{}' | rcall POST "auth/approle/role/$r/secret-id"
  sid="$(jget .data.secret_id)"
  [ -n "$sid" ] || return 1
  rcall GET "auth/approle/role/$r/role-id" </dev/null
  rid="$(jget .data.role_id)"
  body=""
  [ -n "$rid" ] || return 1
  (
    mkdir -p "$dir/approle/$r" || exit 1
    printf '%s' "$sid" > "$dir/approle/$r/secret_id.tmp.$$" && mv -f "$dir/approle/$r/secret_id.tmp.$$" "$dir/approle/$r/secret_id" || exit 1
    printf '%s' "$rid" > "$dir/approle/$r/role_id.tmp.$$" && mv -f "$dir/approle/$r/role_id.tmp.$$" "$dir/approle/$r/role_id" || exit 1
  ) || return 1
  sid=""
}

cmd_keyfile_make() { # <create|rotate>
  local kind="$1" repo init=0 keys=() k
  refuse_agent "keyfile $kind"
  need_keyfile
  read_input
  repo="$(ifield .repo)"
  [[ "$repo" =~ ^[A-Za-z0-9._\ -]{1,128}$ ]] || fail 1 input "the input names no repo (repo: the workspace folder name)"
  [ "$(ifield .init)" = true ] && init=1
  [ "$kind" = create ] || [ "$init" -eq 0 ] || fail 1 input "init is for keyfile create on an empty server; keyfile rotate takes two shares"
  [ "$init" -eq 1 ] || read_shares
  input=""
  trap 'cleanup' EXIT
  trap 'cleanup; exit 130' INT TERM HUP
  state
  [ "$reach" -eq 1 ] || fail 1 unreachable "the server at $addr does not answer: the start hook (openbao-setup start) starts it"

  if [ "$init" -eq 1 ]; then
    [ "$inited" = false ] || fail 1 "already-initialised" "the server is already initialised: keyfile create takes two of its unseal shares (the custody shares) instead of init"
    printf '{"secret_shares":5,"secret_threshold":2}' | call PUT sys/init
    [ "$http" = 200 ] || fail 1 "init-failed" "the server could not be initialised (HTTP $http${body:+: $(jerr)})"
    while IFS= read -r k; do keys+=("$k"); done < <(jget '.keys_base64[]?')
    root_tok="$(jget .root_token)"
    body=""
    step_hint="the store is new and holds nothing: stop the server, delete $dir/raft, start it (task openbao:setup) and run this again"
    [ "${#keys[@]}" -eq 5 ] && [ -n "$root_tok" ] || fail 1 "init-failed" "the server was initialised but did not answer with five shares and a root token; $step_hint"
    unseal_with "${keys[0]}" "${keys[1]}" || fail 1 "init-failed" "the new shares did not unseal the new server; $step_hint"
  else
    [ "$inited" = true ] || fail 1 "not-initialised" "the server is not initialised: send init (keyfile create with init:true) instead of shares"
    if [ "$sealed" = true ]; then
      unseal_with "${in_shares[@]}" || fail 1 "shares-refused" "the two shares did not unseal the server: not two shares of this store? It is still sealed; nothing was changed"
      say "unsealed with the two shares"
    fi
    root_from_shares
  fi

  configure_keyfile
  # every earlier secret id of the operator role goes (review finding 5), then the one of the key file
  destroy_secret_ids operator || fail 1 "step-failed" "destroying the earlier secret ids of the operator AppRole failed (HTTP $http)"
  local sid rid
  printf '{}' | rcall POST auth/approle/role/operator/secret-id
  step "making the operator AppRole's secret id"
  sid="$(jget .data.secret_id)"
  new_acc="$(jget .data.secret_id_accessor)"
  rcall GET auth/approle/role/operator/role-id </dev/null
  step "reading the operator AppRole's role id"
  rid="$(jget .data.role_id)"
  body=""
  [ -n "$sid" ] && [ -n "$rid" ] || fail 1 "step-failed" "the operator AppRole answered without a secret id or role id"

  if [ "$init" -eq 0 ]; then
    # rotate-keys to five shares, threshold two: the last step that can fail without loss
    rcall DELETE sys/rotate/root/init </dev/null
    printf '{"secret_shares":5,"secret_threshold":2}' | rcall PUT sys/rotate/root/init
    step "starting rotate-keys"
    rot_started=1
    local nonce
    nonce="$(jget .data.nonce)"
    for k in "${in_shares[@]}"; do
      printf '{"key":"%s","nonce":"%s"}' "$k" "$nonce" | rcall PUT sys/rotate/root/update
      k=""
      step "rotate-keys (a share)"
      [ "$(jget '.data.complete | tostring')" = true ] && break
    done
    while IFS= read -r k; do keys+=("$k"); done < <(jget '.data.keys_base64[]?')
    body=""
    [ "${#keys[@]}" -eq 5 ] || { keys=(); fail 1 "rotate-failed" "rotate-keys did not complete with five new shares; the shares in force still hold"; }
    rot_started=0
  fi
  in_shares=()
  # ---- from here the new shares are in force: they are always printed ----
  new_acc=""
  state
  remember_cluster
  local warn=()
  # The userpass user operator goes: a key-file server has no password.
  rcall GET sys/auth </dev/null
  if [ "$(jget '(.data // .) | has("userpass/") | tostring')" = true ]; then
    rcall DELETE auth/userpass/users/operator </dev/null
    ok_http || warn+=("the userpass user operator could not be deleted (HTTP $http)")
  fi
  # Every token an earlier login made (the Operator's password or key file logins, the backs' short
  # ones, which log in again at their next run): a rotation after a theft must end them.
  for k in auth/userpass/login auth/approle/login; do
    rcall PUT "sys/leases/revoke-prefix/$k" </dev/null
    ok_http || warn+=("the tokens made by $k could not be revoked (HTTP $http)")
  done
  # The backs' roles get new secret ids (after a restore their files are stale; after a theft, theirs too).
  local r
  while IFS= read -r r; do
    [ -n "$r" ] && [ "$r" != operator ] || continue
    reissue_files "$r" || warn+=("the role $r could not be reissued: task openbao:approle:issue ALL=1")
  done < <(list_keys auth/approle/role)
  # The root token is revoked, then the Operator logs in with the new key file.
  cleanup
  trap - EXIT INT TERM HUP
  local lrc=0
  login "$rid" "$sid" || lrc=$?
  [ "$lrc" -eq 0 ] || warn+=("the login with the new key file failed (HTTP $http): task dc:openbao:unlock tries again")
  # A backup under the new shares before reporting (review finding 4).
  local bk="none" dest
  dest="$(optval BACKUPDEST OPENBAO_SETUP_BACKUP_DEST "")"
  [ -n "$dest" ] || dest="$(sed -n 's/^dest=//p' "$dir/backup-choice" 2>/dev/null | head -n 1)"
  if [ -n "$dest" ] && command -v openbao-server >/dev/null 2>&1; then
    if BAO_ADDR="$addr" openbao-server backup >&2; then
      bk="$(sed -n 's/^file=//p' "$dir/last-backup" 2>/dev/null | head -n 1)"
      bk="${bk:-done}"
    else
      bk=failed
      warn+=("the backup under the new shares failed: run task openbao:backup now, before the previous custody shares are put away")
    fi
  else
    warn+=("no backup destination is recorded (the backupDest option, or task openbao:backup DEST=<folder>): take a backup now, since backups made before this rotation open only with the previous shares")
  fi
  for k in "${warn[@]}"; do say "$k"; done
  say "the store has 5 unseal shares, any 2 open it: 1 to 3 are the custody shares (keep them, and keep the previous ones until the backups made under them are pruned), 4 and 5 are the OpenBao key file's"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"v":1,"ok":true,"server":"%s","custody":["%s","%s","%s"],"keyfile":{"v":1,"server":"%s","repo":%s,"created":"%s","shares":["%s","%s"],"role_id":"%s","secret_id":"%s"},"backup":%s,"warnings":%s}\n' \
    "$cluster" "${keys[0]}" "${keys[1]}" "${keys[2]}" "$cluster" "$(jstr "$repo")" "$now" "${keys[3]}" "${keys[4]}" "$rid" "$sid" "$(jstr "$bk")" \
    "$(if [ "${#warn[@]}" -gt 0 ]; then printf '%s\n' "${warn[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'; else echo '[]'; fi)"
  keys=() sid=""
}

cmd_keyfile_status() {
  need_server
  state
  [ "$reach" -eq 1 ] || fail 1 unreachable "the server at $addr does not answer"
  [ "$sealed" = false ] && remember_cluster
  local ar=null up=null t
  t="$(saved_token)"
  if [ -n "$t" ] && [ "$sealed" = false ]; then
    call LIST auth/approle/role "$t" </dev/null
    case "$http" in
      200) ar="$(jget '(.data.keys // []) | index("operator") != null | tostring')" ;;
      404) ar=false ;;
    esac
    call LIST auth/userpass/users "$t" </dev/null
    case "$http" in
      200) up="$(jget '(.data.keys // []) | index("operator") != null | tostring')" ;;
      404) up=false ;;
    esac
  fi
  t=""
  emit "{\"v\":1,\"ok\":true,\"server\":$(jstr "${cluster:-$(known_cluster)}"),\"shares\":${n_now:-0},\"threshold\":${t_now:-0},\"approle\":${ar:-null},\"userpass\":${up:-null}}"
}

command -v jq >/dev/null 2>&1 || { echo '{"v":1,"ok":false,"error":"jq is not installed: rebuild the devcontainer","code":"broken"}'; exit 1; }
command -v curl >/dev/null 2>&1 || fail 1 broken "curl is not installed: rebuild the devcontainer"

case "${1:-} ${2:-}" in
  "unlock --status") cmd_unlock_status ;;
  "unlock --stdin") cmd_unlock_stdin ;;
  "keyfile create" | "keyfile rotate")
    [ "${3:-}" = --stdin ] || fail 2 usage "usage: openbao-setup keyfile $2 --stdin (the input on stdin)"
    cmd_keyfile_make "$2"
    ;;
  "keyfile status") cmd_keyfile_status ;;
  "renew ") cmd_renew ;;
  *) fail 2 usage "usage: openbao-setup unlock --status|--stdin, keyfile create|rotate --stdin, keyfile status (the workstation's launcher runs these)" ;;
esac
