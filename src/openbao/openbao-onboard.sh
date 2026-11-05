#!/usr/bin/env bash
# openbao-onboard: what the openbao Feature's onboarding tasks run (task openbao:onboard:export,
# :onboard:claim, openbao:wrap and :unwrap). A thin layer over the `bao` CLI (NFR-13): the state of
# a server comes from `bao status`'s exit code and JSON, every other answer from bao's JSON output
# (read with jq), never from parsed English.
#
#   openbao-onboard export    NAMES=<name>,... DEST=<folder>: a short-lived second server in this
#                             container, the named secrets copied into it, the onboarding marker,
#                             a raft snapshot in DEST (never overwritten), then the instance is
#                             stopped and its folder deleted; the fresh unseal shares and the
#                             claim token are printed once, to the terminal
#   openbao-onboard claim     after openbao:restore of such a snapshot: rotate-keys (new unseal
#                             shares), the revocation of everything the sender held, the reissue
#                             of the AppRole secret ids, a rotated data key, the sender's marker
#                             replaced by the receiver's
#   openbao-onboard wrap      NAMES=<name>,... [TTL=15m]: one one-use wrapping token per secret,
#                             against a central server this client reaches
#   openbao-onboard unwrap    FROM=<file> [ISSUER_ADDR=]: look each token up, refuse unless its
#                             creation path is the expected secret's, then unwrap once and put
#
# The OPENBAO_TASK_* variables the Taskfile sets carry the arguments (NAMES, DEST, TTL, OUT, SHOW,
# FROM, ISSUER_ADDR, ROTATE). Every command here handles a share or a token, so every one refuses
# inside an agent's job (the rule of section 3 of the proposal); export, claim and a prompted
# unwrap need a terminal, because they ask for secrets and print them only to it. Exit codes:
# dcf-secret's numbers where they mean the same (10 unreachable, 11 sealed or not initialised,
# 12 no valid token, 13 denied, 14 no such secret), 3 refused (an agent's job, no terminal, the
# wrong mode, nothing to claim, a token that must not be unwrapped), 2 a wrong call, 1 a step failed.
set -u

prog=openbao-onboard
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
# shellcheck disable=SC1091  # installed by install.sh next to env.sh
. "$ob_dir/openbao-lib.sh" || { echo "$prog: $ob_dir/openbao-lib.sh is missing: rebuild the devcontainer" >&2; exit 10; }
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
mount="${DCF_SECRET_MOUNT:-dcf}"
st_rc=0
st_json=""
own_addr="${BAO_ADDR:-}"

usage() {
  say "usage: openbao-onboard export|claim|wrap|unwrap (the tasks of the openbao Feature run it)"
  exit 2
}

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"

mode_now="$(openbao_mode 2>/dev/null || echo client)"
unlock_now="$(openbao_unlock 2>/dev/null || echo operator)"

# ---------------------------------------------------------------------------- refusals ----
need_server_mode() { # <task>
  [ "$mode_now" = server ] || die 3 "task openbao:$1 is for server mode: this container runs no server (mode $mode_now)"
}
need_jq() { command -v jq >/dev/null 2>&1 || die 1 "jq is not installed: rebuild the devcontainer (the openbao Feature installs it)"; }

name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; }
field_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }

# `bao status`: exit 0 unsealed, 2 sealed (an uninitialised server is sealed too), else could not ask.
server_state() {
  st_json="$(bao status -format=json 2>/dev/null)"
  st_rc=$?
}
is_initialised() { ! grep -Eq '"initialized"[[:space:]]*:[[:space:]]*false' <<<"$st_json"; }
state_exit() { # exit with the line for a server that is not ready; no-op when it is
  case "$st_rc" in
    0) return 0 ;;
    2)
      if is_initialised; then
        die 11 "the server is sealed: the Operator unseals it with task openbao:unseal (against a server elsewhere, its owner does)"
      fi
      die 11 "the server is not initialised: the Operator initialises it with task openbao:init"
      ;;
    *) die 10 "the server at ${BAO_ADDR:-the default address (https://127.0.0.1:8200)} is unreachable: task openbao:server:status says whether it runs (against a server elsewhere, check BAO_ADDR)" ;;
  esac
}
need_token() {
  bao token lookup >/dev/null 2>&1 || die 12 "no valid token (none, expired or revoked): log in with task openbao:login (task openbao:logout first clears a dead one)"
}
machine_name() {
  local m="${OPENBAO_MACHINE:-$(hostname 2>/dev/null || echo unknown)}"
  m="${m//[^A-Za-z0-9._-]/-}"
  printf '%s' "${m:-unknown}"
}
split_names() { # <comma list> -> names[] (checked, no duplicates)
  names=()
  local n x dup
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    name_ok "$n" || die 2 "'$n' is not a secret name (letters, digits, . _ - and / between parts)"
    case "$n" in onboarding | onboarding/*) die 2 "'$n': the names under onboarding/ are the onboarding marker's" ;; esac
    dup=0
    for x in "${names[@]:-}"; do [ "$x" = "$n" ] && dup=1; done
    [ "$dup" -eq 1 ] || names+=("$n")
  done < <(tr ',' '\n' <<<"$1")
  [ "${#names[@]}" -gt 0 ] || die 2 "name the secrets: NAMES=<name>,<name>"
}
cannot_read() { # <name>: exit with dcf-secret's code unless the current login can read the secret
  # (a read of the whole secret, whatever its fields, its value going nowhere; then the status says
  # whether the policy allows the path: allowed and failing is 14, no such secret)
  local rc=0
  bao kv get -mount="$mount" "$1" >/dev/null 2>&1 </dev/null && return 0
  dcf-secret status "$1" >/dev/null 2>&1 </dev/null || rc=$?
  [ "$rc" -ne 0 ] || rc=14
  die "$rc" "cannot read '$1' with the current login (dcf-secret exit $rc; run: dcf-secret status $1, or write the secret first)"
}
alive() { # <pid file> : is it a running bao
  local pid
  pid="$(cat "$1" 2>/dev/null)" || return 1
  [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = bao ]
}

# ---------------------------------------------------------------------------------- export ----
ob_port="${OPENBAO_ONBOARD_PORT:-8210}"
ob_inst="$dir/onboarding"
inst_addr="http://127.0.0.1:$ob_port"
inst_token=""

stop_instance() {
  local pid i
  if alive "$ob_inst/server.pid"; then
    pid="$(cat "$ob_inst/server.pid")"
    kill "$pid" 2>/dev/null
    for i in $(seq 1 40); do
      [ -d "/proc/$pid" ] || break
      sleep 0.25
    done
    [ ! -d "/proc/$pid" ] || kill -9 "$pid" 2>/dev/null
  fi
  rm -rf "${ob_inst:?}"
}

# bao against the onboarding instance, with its root token in the environment of that one call
inst_bao() { BAO_ADDR="$inst_addr" BAO_TOKEN="$inst_token" bao "$@"; }

cmd_export() {
  guard onboard:export "it makes fresh unseal shares and a claim token and prints them once, and they must never land in a transcript"
  [ $# -eq 0 ] || die 2 "openbao:onboard:export takes no extra arguments (the fresh shares are not PGP-encrypted in this version: the instance has to be unsealed to be filled)"
  need_tty onboard:export
  need_jq
  local dest="${OPENBAO_TASK_DEST:-}" n
  split_names "${OPENBAO_TASK_NAMES:-}"
  [ -n "$dest" ] || die 2 "name the folder the snapshot goes to: DEST=<folder> (an absolute path)"
  case "$dest" in /*) ;; *) die 2 "DEST must be an absolute folder path" ;; esac
  [ -d "$dest" ] && [ -w "$dest" ] || die 2 "DEST '$dest' is not a writable folder"

  # The sender's own store: the names are read from it with the sender's login.
  server_state
  state_exit
  need_token
  for n in "${names[@]}"; do
    cannot_read "$n"
  done

  alive "$ob_inst/server.pid" && die 3 "an onboarding instance is still running (pid $(cat "$ob_inst/server.pid")); stop it before a new export"
  rm -rf "${ob_inst:?}"
  trap stop_instance EXIT
  (umask 077; mkdir -p "$ob_inst/raft" "$ob_inst/tmp") || die 1 "could not make $ob_inst"
  (
    umask 077
    cat > "$ob_inst/server.hcl" <<HCL
# Written by openbao:onboard:export: a short-lived second server, only for the shared keys. Raft
# storage in its own folder, a loopback listener on its own port, no audit device. Deleted with
# the folder when the export ends.
ui = false
api_addr = "$inst_addr"
cluster_addr = "http://127.0.0.1:$((ob_port + 1))"

storage "raft" {
  path    = "$ob_inst/raft"
  node_id = "onboarding"
}

listener "tcp" {
  address         = "127.0.0.1:$ob_port"
  cluster_address = "127.0.0.1:$((ob_port + 1))"
  tls_disable     = true
}
HCL
  ) || die 1 "could not write the onboarding instance's config"
  if command -v setsid >/dev/null 2>&1; then
    (umask 077; setsid bao server -config="$ob_inst/server.hcl" </dev/null >>"$ob_inst/server.log" 2>&1 & echo "$!" > "$ob_inst/server.pid")
  else
    (umask 077; nohup bao server -config="$ob_inst/server.hcl" </dev/null >>"$ob_inst/server.log" 2>&1 & echo "$!" > "$ob_inst/server.pid")
  fi
  local i rc=1
  for i in $(seq 1 "${OPENBAO_START_TRIES:-40}"); do
    BAO_ADDR="$inst_addr" bao status -format=json >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 1 ] && break
    sleep 0.5
  done
  [ "$rc" -ne 1 ] || die 1 "the onboarding instance does not answer at $inst_addr (two servers in one container may not fit here: run the export in a second devcontainer in server mode; the end of $ob_inst/server.log follows)$(tail -n 5 "$ob_inst/server.log" 2>/dev/null | sed 's/^/\n  /')"

  local init shares=() s
  init="$(BAO_ADDR="$inst_addr" bao operator init -key-shares=3 -key-threshold=2 -format=json 2>/dev/null)" || die 1 "bao operator init failed on the onboarding instance"
  inst_token="$(jq -r '.root_token // empty' <<<"$init")"
  while IFS= read -r s; do shares+=("$s"); done < <(jq -r '.unseal_keys_b64[]?' <<<"$init")
  init=""
  [ -n "$inst_token" ] && [ "${#shares[@]}" -eq 3 ] || die 1 "the onboarding instance's init answered without 3 shares and a root token"
  for s in "${shares[0]}" "${shares[1]}"; do
    printf '%s' "$s" | BAO_ADDR="$inst_addr" bao write sys/unseal key=- >/dev/null || die 1 "the onboarding instance would not take a share"
  done
  for i in $(seq 1 40); do
    BAO_ADDR="$inst_addr" bao read -format=json sys/leader 2>/dev/null | grep -Eq '"is_self"[[:space:]]*:[[:space:]]*true' && break
    sleep 0.5
  done

  inst_bao secrets enable -path="$mount" -version=2 kv >/dev/null || die 1 "could not enable the $mount mount in the onboarding instance"
  # The values go through a pipe, never an argument and never a file. A secret keeps all its fields.
  for n in "${names[@]}"; do
    (
      set -o pipefail
      bao kv get -mount="$mount" -format=json "$n" | jq -c '.data.data' | inst_bao kv put -mount="$mount" "$n" - >/dev/null
    ) || die 1 "could not copy '$n' into the onboarding instance"
  done
  local machine now
  machine="$(machine_name)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  inst_bao kv put -mount="$mount" onboarding/marker machine="$machine" at="$now" >/dev/null || die 1 "could not write the onboarding marker"

  local stamp final
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  final="$dest/onboarding-$machine-$stamp.snap"
  [ ! -e "$final" ] || die 1 "$final exists: an export never overwrites (wait a second and run it again)"
  inst_bao operator raft snapshot save "$ob_inst/tmp/snap" >/dev/null || die 1 "could not take the snapshot of the onboarding instance"
  (umask 077; set -o noclobber; cat "$ob_inst/tmp/snap" > "$final") || { rm -f "$final"; die 1 "could not write $final"; }
  rm -f "$ob_inst/tmp/snap"

  cat <<EOF

THE FRESH UNSEAL SHARES AND THE CLAIM TOKEN of the onboarding snapshot. Shown once, here only.
Any two shares open the restored server. They are not your own store's shares. Hand over the
shares and the claim token to the receiver, one by one and not with the snapshot file (a
password manager's share, a call). Never in git or where the snapshot goes.

$(for i in 0 1 2; do printf 'Unseal Key %s: %s\n' "$((i + 1))" "${shares[$i]}"; done)

Claim token: $inst_token

EOF
  ask "Press Enter once you have passed them on:"
  shares=()
  inst_token=""
  say "the snapshot is $final (mode 600): $(printf '%s names' "${#names[@]}") copied, the marker '$machine' $now."
  say "the receiver runs: task openbao:restore FROM=<the file> (needs the shares), then task openbao:onboard:claim (needs the claim token and the shares)."
  say "what the receiver holds afterwards is what you put in: you still know every value that was in it, for good."
}

# ----------------------------------------------------------------------------------- claim ----
claim_state="$dir/onboarding-claim-state"

# `bao` with the claim token, for the calls of the revocation
cl() { BAO_TOKEN="$claim_tok" bao "$@"; }
cl_list() { cl list -format=json "$1" 2>/dev/null | jq -r '.[]?' 2>/dev/null; } # a missing list is empty

# Every secret name under the mount, but the marker's own, one per line.
walk_names() { # <prefix, with the trailing slash or empty>
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      */) [ "$1$k" = onboarding/ ] || walk_names "$1$k" ;;
      *) echo "$1$k" ;;
    esac
  done < <(cl kv list -mount="$mount" -format=json "${1:-/}" 2>/dev/null | jq -r '.[]?' 2>/dev/null)
}

cmd_claim() {
  guard onboard:claim "it asks for the sender's unseal shares and the claim token, prints the new shares once and handles a root token"
  need_server_mode onboard:claim
  [ $# -eq 0 ] || die 2 "openbao:onboard:claim takes no extra arguments (ROTATE=0 skips the data key rotation)"
  need_tty onboard:claim
  need_jq
  server_state
  state_exit

  ask_secret "The claim token (printed by openbao:onboard:export on the sender's side):"
  claim_tok="$REPLY"
  [ -n "$claim_tok" ] || die 3 "no claim token given"
  local pol
  pol="$(cl token lookup -format=json 2>/dev/null | jq -r '(.data.policies // []) | join(",")')" || pol=""
  [ -n "$pol" ] || die 12 "that token is not valid on this server: restore the sender's snapshot first (task openbao:restore), and check the token is the claim token of that export"
  [ "$pol" = root ] || die 3 "that token is not a root token (its policies: $pol): the claim token of an export is one"

  local marker_machine="" marker_at="" resume=0
  if [ -f "$claim_state" ]; then resume=1; fi
  if cl kv get -mount="$mount" -format=json onboarding/marker >/dev/null 2>&1; then
    marker_machine="$(cl kv get -mount="$mount" -field=machine onboarding/marker 2>/dev/null)"
    marker_at="$(cl kv get -mount="$mount" -field=at onboarding/marker 2>/dev/null)"
  else
    die 3 "this store has no onboarding marker: it was not made by task openbao:onboard:export, or it was already claimed. A store restored from a backup of your own needs no claim"
  fi

  local newpw="" pw2="" tries=0
  # A server opened with the OpenBao key file has no password: the workstation's keyfile:rotate
  # makes the Operator's login at the end.
  [ "$unlock_now" != keyfile ] || newpw=keyfile
  while [ -z "$newpw" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die 3 "no password chosen: nothing was changed"
    ask_secret "Choose YOUR OWN Operator password (at least 12 characters; you log in with it each sitting):"
    newpw="$REPLY"
    ask_secret "Again:"
    pw2="$REPLY"
    if [ "${#newpw}" -lt 12 ]; then
      echo "openbao: too short (12 characters at least)" >&2
      newpw=""
    elif [ "$newpw" != "$pw2" ]; then
      echo "openbao: the two did not match" >&2
      newpw=""
    fi
  done
  pw2=""

  echo "openbao: claiming the store that machine '$marker_machine' made at $marker_at. Its sender knows every value in it for good (section 15 of the proposal)." >&2

  # ---- 1. rotate-keys: new unseal shares, the sender's old ones stop opening later backups -------
  if [ "$resume" -eq 1 ]; then
    echo "openbao: an earlier claim already rotated the unseal shares (the new ones are in force); continuing with the revocations." >&2
  else
    local old=() s i
    for i in 1 2; do
      ask_secret "Unseal share $i of 2 (one the sender handed over; a long base64 string, not a password):"
      old+=("$REPLY")
    done
    local init nonce out vnonce keys=()
    init="$(cl operator rotate-keys -init -key-shares=3 -key-threshold=2 -verify -format=json 2>/dev/null)" || die 1 "bao operator rotate-keys could not start (the claim token needs the root policy; the server must be unsealed)"
    nonce="$(jq -r '.nonce // empty' <<<"$init")"
    [ -n "$nonce" ] || die 1 "bao operator rotate-keys started but gave no nonce"
    out=""
    for s in "${old[@]}"; do
      out="$(printf '%s' "$s" | cl operator rotate-keys -nonce="$nonce" -format=json - 2>/dev/null)" || {
        cl operator rotate-keys -cancel >/dev/null 2>&1
        die 1 "bao would not take a share (a wrong share?): the rotation is cancelled, nothing changed; run the task again"
      }
    done
    old=()
    [ "$(jq -r '.complete // false' <<<"$out")" = true ] || { cl operator rotate-keys -cancel >/dev/null 2>&1; die 1 "the rotation did not complete with two shares: cancelled, nothing changed"; }
    vnonce="$(jq -r '.verification_nonce // empty' <<<"$out")"
    while IFS= read -r s; do keys+=("$s"); done < <(jq -r '.keys_base64[]?' <<<"$out")
    out=""
    [ -n "$vnonce" ] && [ "${#keys[@]}" -eq 3 ] || { cl operator rotate-keys -cancel >/dev/null 2>&1; die 1 "bao answered without 3 new shares and a verification nonce: cancelled, nothing changed"; }
    cat <<EOF

YOUR NEW UNSEAL SHARES. Shown once, here only. Any two open the server; losing two of the three
loses every secret in it. Keep one in your password manager, one on paper offline, and one with a
second trusted person or on a hardware key. Never in git, in the container, or where backups go.
The sender's shares stop opening this server's later backups once you confirm them below.

$(for i in 0 1 2; do printf 'Unseal Key %s: %s\n' "$((i + 1))" "${keys[$i]}"; done)

EOF
    keys=()
    # The verification: bao commits the new shares only once two of them have been typed back.
    local ok=0 tries2=0
    while [ "$ok" -eq 0 ]; do
      tries2=$((tries2 + 1))
      [ "$tries2" -le 3 ] || { cl operator rotate-keys -cancel >/dev/null 2>&1; die 1 "the new shares were not confirmed: the rotation is cancelled and the sender's shares are still the ones in force. Run the task again (new shares)"; }
      ok=1
      for i in 1 2; do
        ask_secret "Type new unseal share $i of 2 to prove you stored them:"
        if ! printf '%s' "$REPLY" | cl operator rotate-keys -verify -nonce="$vnonce" -format=json - >/dev/null 2>&1; then
          echo "openbao: bao did not take that share; start over with the first of two" >&2
          cl operator rotate-keys -verify -cancel >/dev/null 2>&1
          ok=0
          break
        fi
      done
    done
    (umask 077; echo rotated > "$claim_state")
    echo "openbao: the new unseal shares are in force." >&2
  fi

  # ---- 2. everything the sender held -------------------------------------------------------------
  local own acc n_tok=0 failed=0
  own="$(cl token lookup -format=json | jq -r '.data.accessor')"
  while IFS= read -r acc; do
    [ -n "$acc" ] && [ "$acc" != "$own" ] || continue
    if cl token revoke -accessor "$acc" >/dev/null 2>&1; then n_tok=$((n_tok + 1)); else say "could not revoke token accessor $acc"; failed=1; fi
  done < <(cl_list auth/token/accessors)
  # and by prefix, for the tokens an auth method's login made (the claim token stays: a check)
  local p
  for p in auth/approle/login auth/userpass/login auth/token/create; do
    cl lease revoke -prefix "$p" >/dev/null 2>&1 || true
    cl token lookup >/dev/null 2>&1 || die 1 "revoking the prefix $p ended the claim token too: the sender's access may still stand; read the message above and ask for help"
  done
  echo "openbao: $n_tok token(s) the sender's store held were revoked (and every token the login paths made)." >&2

  # users: every userpass user goes; the receiver's own is made by configure below
  local u n_usr=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if cl delete "auth/userpass/users/$u" >/dev/null 2>&1; then n_usr=$((n_usr + 1)); else say "could not delete the user $u"; failed=1; fi
  done < <(cl_list auth/userpass/users)
  # other auth methods than token, userpass and approle: a login the sender configured
  local am
  while IFS= read -r am; do
    case "$am" in token/ | userpass/ | approle/ | "") ;; *)
      if cl auth disable "${am%/}" >/dev/null 2>&1; then say "auth method '$am' disabled (it was the sender's)"; else say "could not disable the auth method $am"; failed=1; fi
      ;;
    esac
  done < <(cl read -format=json sys/auth 2>/dev/null | jq -r '(.data // .) | keys[]' 2>/dev/null | grep '/$')

  # roles: read the policies, delete the role (that destroys its secret ids), write it again as
  # the Feature writes it (role_write, the one definition in openbao-lib.sh)
  local r pols n_role=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [[ "$r" =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || { say "role '$r' has a name this Feature does not make; it is deleted and not rebuilt"; cl delete "auth/approle/role/$r" >/dev/null 2>&1; continue; }
    pols="$(cl read -format=json "auth/approle/role/$r" 2>/dev/null | jq -r '(.data.token_policies // []) | join(",")')"
    cl delete "auth/approle/role/$r" >/dev/null 2>&1 || { say "could not delete the role $r"; failed=1; continue; }
    if [ -n "$pols" ]; then
      BAO_TOKEN="$claim_tok" role_write "$r" "$pols" || { say "could not write the role $r again"; failed=1; continue; }
      n_role=$((n_role + 1))
    fi
  done < <(cl_list auth/approle/role)
  echo "openbao: $n_usr user(s) deleted, $n_role AppRole role(s) deleted and written again (every earlier secret id is gone)." >&2

  # audit devices: any that is not the file device of this server's own config is the sender's
  local ad
  while IFS= read -r ad; do
    case "$ad" in file/ | "") ;; *)
      if cl audit disable "${ad%/}" >/dev/null 2>&1; then say "audit device '$ad' disabled (it was the sender's)"; else say "could not disable the audit device $ad"; failed=1; fi
      ;;
    esac
  done < <(cl read -format=json sys/audit 2>/dev/null | jq -r '(.data // .) | keys[]' 2>/dev/null | grep '/$')

  # the receiver's own: the mounts and the Operator (a configure of openbao-server, as init does)
  [ "$unlock_now" != keyfile ] || newpw=""
  printf '%s\n' "$newpw" | BAO_TOKEN="$claim_tok" openbao-server configure || { newpw=""; die 1 "could not set up the Operator (the message above): the claim token is still valid, run the task again"; }
  newpw=""

  # policies that are neither the Feature's own nor a role's: the receiver reads them
  local pl
  while IFS= read -r pl; do
    case "$pl" in root | default | operator | approle-*) ;; *) echo "openbao: policy '$pl' came with the snapshot: read it (bao policy read $pl), none was deleted" >&2 ;; esac
  done < <(cl_list sys/policies/acl)

  # ---- 3. the reissue (the generic task; the roles and policies came back in the snapshot) -------
  OPENBAO_TASK_ALL=1 BAO_TOKEN="$claim_tok" openbao-server approle-issue || { say "the reissue of the secret ids failed (the message above): run task openbao:approle:issue ALL=1 after logging in"; failed=1; }

  # ---- 4. the data key -------------------------------------------------------------------------------
  if [ "${OPENBAO_TASK_ROTATE:-1}" != 0 ]; then
    if cl operator rotate >/dev/null 2>&1; then
      echo "openbao: the data key is rotated (new writes use a new key; what was written before stays under the key the sender knew)." >&2
    else
      say "bao operator rotate failed"
      failed=1
    fi
  else
    echo "openbao: ROTATE=0: the data key was not rotated." >&2
  fi

  # ---- 5. the marker, the names, the end ----------------------------------------------------------
  local names_out
  names_out="$(walk_names "")"
  cl kv metadata delete -mount="$mount" onboarding/marker >/dev/null 2>&1 || { say "could not remove the onboarding marker"; failed=1; }
  cl kv put -mount="$mount" onboarding/claimed from="$marker_machine" made_at="$marker_at" claimed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || { say "could not write the claim record"; failed=1; }

  if [ "$failed" -ne 0 ]; then
    claim_tok=""
    die 1 "the claim did not finish: the claim token is NOT revoked (it is the only way in), the new unseal shares are in force, and what failed is named above. Run task openbao:onboard:claim again (it resumes after the rotation)"
  fi
  cl token revoke -self >/dev/null 2>&1 || say "the claim token could not be revoked: bao token revoke -self with it, by hand"
  claim_tok=""
  rm -f "$claim_state"
  openbao-token-helper erase 2>/dev/null || true
  if [ "$unlock_now" = keyfile ]; then
    cat >&2 <<EOF
openbao: claimed. The claim token is revoked and your new unseal shares are the only ones. This
server is opened with the OpenBao key file: run task dc:openbao:keyfile:rotate on the workstation
with two of the new shares; it makes the key file (five shares: three custody, two in the file)
and logs you in.
The sender (machine '$marker_machine') knows these values for good; put new values for the ones
you want to be yours alone (dcf-secret put <name> --field <field>):
  ${names_out//$'\n'/$'\n'  }
EOF
    return 0
  fi
  cat >&2 <<EOF
openbao: claimed. The claim token is revoked and the new unseal shares are the only ones. Log in:
  task openbao:login -- -method=userpass username=operator
The sender (machine '$marker_machine') knows these values for good; put new values for the ones
you want to be yours alone (dcf-secret put <name> --field <field>):
  ${names_out//$'\n'/$'\n'  }
openbao: this store has no backup yet: task openbao:server:status shows the backup choice.
EOF
}

# ------------------------------------------------------------------------------------ wrap ----
# 15 minutes by default, 1 hour at most (the server's owner may also enforce it by policy).
ttl_seconds() { # <value> -> seconds on stdout, or return 1
  local v="$1" n unit
  [[ "$v" =~ ^([0-9]+)([smh]?)$ ]] || return 1
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in
    m) n=$((n * 60)) ;;
    h) n=$((n * 3600)) ;;
  esac
  printf '%s' "$n"
}

cmd_wrap() {
  guard wrap "it makes tokens that open secrets and handles the server's token"
  need_jq
  [ $# -eq 0 ] || die 2 "openbao:wrap takes its arguments as variables (NAMES, TTL, OUT, SHOW)"
  split_names "${OPENBAO_TASK_NAMES:-}"
  local ttl_in="${OPENBAO_TASK_TTL:-15m}" ttl
  ttl="$(ttl_seconds "$ttl_in")" || die 2 "TTL '$ttl_in' is not a duration (seconds, or a number with s, m or h: 15m, 1h)"
  [ "$ttl" -ge 1 ] || die 2 "TTL must be at least a second"
  [ "$ttl" -le 3600 ] || die 2 "TTL '$ttl_in' is longer than the cap of 1 hour: a wrapping token that lives longer is a secret that waits longer to be read by someone else"
  local show="${OPENBAO_TASK_SHOW:-}"
  [ -z "$show" ] || need_tty wrap
  server_state
  state_exit
  need_token
  local n out="${OPENBAO_TASK_OUT:-}" stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -z "$out" ]; then
    # tmpfs: the file never reaches the volume or a disk
    [ -d /dev/shm ] && [ -w /dev/shm ] || die 2 "no tmpfs to write the tokens to (/dev/shm): give OUT=<file>"
    out="/dev/shm/openbao-wrap-$stamp.txt"
  fi
  [ ! -e "$out" ] || die 2 "$out exists: a wrapping run never overwrites (OUT=<another file>)"
  for n in "${names[@]}"; do
    cannot_read "$n"
  done
  local tokens=() tok expiry
  for n in "${names[@]}"; do
    tok="$(bao kv get -mount="$mount" -wrap-ttl="${ttl}s" -format=json "$n" 2>/dev/null | jq -r '.wrap_info.token // empty')" || tok=""
    [ -n "$tok" ] || die 1 "bao made no wrapping token for '$n' (wrapping must not be forbidden by the server's policy; the TTL may be outside the server's limits)"
    tokens+=("$n $tok")
  done
  (umask 077; set -o noclobber; printf '%s\n' "${tokens[@]}" > "$out") || { rm -f "$out"; die 1 "could not write $out"; }
  expiry="$(date -u -d "+${ttl} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "in ${ttl}s")"
  say "${#names[@]} one-use wrapping token(s) in $out (mode 600): each opens once, and expires $expiry; the receiver runs task openbao:unwrap FROM=<that file> (ISSUER_ADDR=$own_addr if their address for this server differs)."
  say "the channel matters: a token that anyone else reads first is spent, and the receiver learns it only when their unwrap is refused. A token that fails as used or expired is an event to investigate. Delete the file when it is passed on."
  if [ -n "$show" ]; then
    printf '%s\n' "${tokens[@]}"
  fi
  tokens=()
}

# ---------------------------------------------------------------------------------- unwrap ----
cmd_unwrap() {
  guard unwrap "it takes a one-use token and puts the value it opens into the store"
  need_jq
  [ $# -eq 0 ] || die 2 "openbao:unwrap takes its arguments as variables (FROM, ISSUER_ADDR)"
  local from="${OPENBAO_TASK_FROM:-}" issuer="${OPENBAO_TASK_ISSUER_ADDR:-$own_addr}"
  [ -n "$issuer" ] || die 2 "ISSUER_ADDR=<address of the server that made the tokens> (BAO_ADDR is not set)"
  local -a pairs=()
  local line n t
  if [ -n "$from" ]; then
    [ -f "$from" ] && [ -r "$from" ] || die 2 "FROM '$from' is not a readable file"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      n="${line%% *}"
      t="${line#* }"
      [ -n "$n" ] && [ -n "$t" ] && [ "$n" != "$line" ] || die 2 "a line of $from is not '<name> <token>'"
      pairs+=("$n $t")
    done < "$from"
  else
    need_tty unwrap
    ask "The name of the secret the token opens (as the sender named it):"
    n="$REPLY"
    ask_secret "The wrapping token (hidden):"
    pairs+=("$n $REPLY")
    REPLY=""
  fi
  [ "${#pairs[@]}" -gt 0 ] || die 2 "no tokens in $from"

  # Our own store first: a token is spent by its first use, so a value that has nowhere to go must
  # be found out before any token is touched.
  server_state
  state_exit
  need_token
  local p
  for p in "${pairs[@]}"; do
    n="${p%% *}"
    name_ok "$n" || die 2 "'$n' is not a secret name"
    case "$n" in onboarding | onboarding/*) die 2 "'$n': the names under onboarding/ are the onboarding marker's" ;; esac
  done
  dcf-secret status >/dev/null 2>&1 || die 12 "the store here is not ready (task openbao:server:status, dcf-secret status)"

  # The lookup of every token, against the issuer, before any unwrap. The wrapping token is also the
  # token of the call, so no other token of ours (a saved login) is sent to the issuer. Nothing is
  # unwrapped unless every token passes.
  local lj cpath ctime cttl now_s ends_s
  for p in "${pairs[@]}"; do
    n="${p%% *}"
    t="${p#* }"
    lj="$(printf '%s' "$t" | BAO_ADDR="$issuer" BAO_TOKEN="$t" bao write -format=json sys/wrapping/lookup token=- 2>/dev/null)" || die 3 "do not unwrap; ask the sender: the token for '$n' is not valid at $issuer (already used, expired, or from another server). A token that was used or expired is an event to investigate"
    cpath="$(jq -r '.data.creation_path // empty' <<<"$lj")"
    ctime="$(jq -r '.data.creation_time // empty' <<<"$lj")"
    cttl="$(jq -r '.data.creation_ttl // 0' <<<"$lj")"
    [ "$cpath" = "$mount/data/$n" ] || die 3 "do not unwrap; ask the sender: the token for '$n' was made by a read of '${cpath:-an unknown path}', not of $mount/data/$n (a different secret, or data a stranger put there)"
    now_s="$(date -u +%s)"
    ends_s="$(date -u -d "$ctime" +%s 2>/dev/null || echo 0)"
    ends_s=$((ends_s + cttl))
    [ "$ends_s" -gt "$now_s" ] || die 3 "do not unwrap; ask the sender: the token for '$n' has run out"
  done

  local f v rc
  for p in "${pairs[@]}"; do
    n="${p%% *}"
    t="${p#* }"
    lj="$(BAO_ADDR="$issuer" BAO_TOKEN="$t" bao unwrap -format=json 2>/dev/null)" || die 1 "the unwrap of '$n' failed after the lookup passed (the token is spent if the server answered): ask the sender for a new one"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      field_ok "$f" || { say "a field of '$n' is named '$f', which dcf-secret cannot store: skipped"; continue; }
      rc=0
      jq -j --arg f "$f" '.data.data[$f] | if type == "string" then . else tojson end' <<<"$lj" | dcf-secret put "$n" --field "$f" || rc=$?
      [ "$rc" -eq 0 ] || die "$rc" "dcf-secret could not put the field '$f' of '$n' (exit $rc): the token is spent; ask the sender for a new one"
    done < <(jq -r '.data.data | keys[]?' <<<"$lj")
    lj=""
    say "'$n' unwrapped and put."
  done
  say "done: ${#pairs[@]} secret(s). Delete ${from:-the file}, if there was one. The sender knows these values: put new ones if they must be yours alone."
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  export) cmd_export "$@" ;;
  claim) cmd_claim "$@" ;;
  wrap) cmd_wrap "$@" ;;
  unwrap) cmd_unwrap "$@" ;;
  *) usage ;;
esac
