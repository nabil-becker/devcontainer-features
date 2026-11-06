#!/usr/bin/env bash
# openbao-server: what the openbao Feature's server-mode tasks run (task openbao:init, :unseal,
# :seal, :server:status, :password, :approle:issue and :approle:revoke). It is a thin layer over the `bao`
# CLI (NFR-13): the state of the server comes from `bao status`'s exit code and JSON, never from
# parsed English; the only text read back is the init output's "Unseal Key N:" and "Initial Root
# Token:" lines, which the CLI documents.
#
#   openbao-server init [-pgp-keys=...]   once: ask for the backup choice and the Operator's
#                                         password, initialise (3 shares, threshold 2), print the
#                                         shares to the terminal, unseal, configure, revoke root
#   openbao-server unseal                 ask for shares at bao's own prompt until it is unsealed
#   openbao-server seal                   seal the server (the Operator's token)
#   openbao-server status                 mode, state, storage, backup choice, login (both modes)
#   openbao-server password               a new password for the Operator, with a root token from
#                                         two unseal shares (no current password or login needed)
#   openbao-server approle-issue          ROLE=<name> [POLICY_PATH=<mount/path>] or ALL=1 (the
#                                         OPENBAO_TASK_ROLE, OPENBAO_TASK_POLICY_PATH and
#                                         OPENBAO_TASK_ALL variables the Taskfile sets)
#   openbao-server approle-revoke         ROLE=<name> (OPENBAO_TASK_ROLE)
#   openbao-server backup                 a raft snapshot into DEST (OPENBAO_TASK_DEST, else the
#                                         backupDest option, else the folder recorded at init) as
#                                         openbao-<machine>-<UTC time>.snap, never overwriting;
#                                         KEEP (OPENBAO_TASK_KEEP) / backupKeep prune its own files
#   openbao-server backup-role            (re)make the backup role with a root token from the shares
#   openbao-server restore                FROM=<file> (OPENBAO_TASK_FROM): install a snapshot, with
#                                         a throwaway init on an empty server or a root token from
#                                         the shares on a store in use, then unseal and reissue
#   openbao-server ssh-ca-init            the SSH certificate authority: the ssh mount (DCF_SSH_CA_MOUNT), its
#                                         CA generated inside OpenBao, the default role, the sign path in the
#                                         Operator's policy (OPENBAO_TASK_ALLOWED, _TTL, _MAX_TTL, _MOUNT);
#                                         idempotent; server mode: a root token from two shares
#   openbao-server ssh-ca-role            another signing role (OPENBAO_TASK_NAME, _ALLOWED, _TTL, _MAX_TTL)
#   openbao-server ssh-ca-import          the CA's private key from stdin instead of a generated one
#   openbao-server after-write            what a task that writes a secret ends with: the backup (when
#                                         a destination is set) or the reminder; always exit 0
#
# Every command that handles a share or a token (init, unseal, seal, restore, password, and approle-issue with
# POLICY_PATH, approle-revoke and backup-role, which make a root token from the shares for their one
# step and revoke it after) refuses inside an agent's job and, for all but seal, without a terminal: the shares and the token must never reach a
# transcript, which the scribe reads. Exit codes: dcf-secret's numbers where they mean the same
# (10 unreachable, 11 sealed or not initialised, 12 no valid token, 14 no such role), 3 refused
# (an agent's job, no terminal, the wrong mode), 2 a wrong call, 1 a step failed. backup adds 13 (the
# snapshot read is denied) and 20 (DEST missing or not writable).
set -u

prog=openbao-server
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
# shellcheck disable=SC1091  # installed by install.sh next to env.sh
. "$ob_dir/openbao-lib.sh" || { echo "$prog: $ob_dir/openbao-lib.sh is missing: rebuild the devcontainer" >&2; exit 10; }
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
mount="${DCF_SECRET_MOUNT:-dcf}"
st_rc=0
st_json=""

usage() {
  say "usage: openbao-server init|unseal|seal|status|password|approle-issue|approle-revoke|backup|backup-role|restore|ssh-ca-init|ssh-ca-role|ssh-ca-import|after-write (the tasks of the openbao Feature run it)"
  exit 2
}

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"

mode_now="$(openbao_mode 2>/dev/null || echo client)"
# unlock: keyfile (the OpenBao key file, from the workstation's launcher) or operator (typed)
unlock_now="$(openbao_unlock 2>/dev/null || echo operator)"
[ "$mode_now" = server ] || unlock_now=operator
login_hint() { # what gets the Operator a token
  if [ "$unlock_now" = keyfile ]; then
    echo "task dc:openbao:unlock on the workstation (the OpenBao key file logs you in; nothing is typed)"
  else
    echo "task openbao:login -- -method=userpass username=operator"
  fi
}
unseal_hint() {
  if [ "$unlock_now" = keyfile ]; then
    echo "the workstation's launcher unseals it with the OpenBao key file (task dc:openbao:unlock), or two custody shares at task openbao:unseal"
  else
    echo "the Operator unseals it with task openbao:unseal"
  fi
}

# ---------------------------------------------------------------------------- refusals ----
need_server_mode() { # <task>
  [ "$mode_now" = server ] || die 3 "task openbao:$1 is for server mode: this container runs no server (mode $mode_now); the server's owner does this, or set the Feature option mode to server"
}
not_keyfile() { # <task> <what instead>
  [ "$unlock_now" != keyfile ] || die 3 "task openbao:$1 is not for a server opened with the OpenBao key file (the unlock option is keyfile): $2"
}

# ----------------------------------------------------------------------- the server ----
# `bao status`: exit 0 unsealed, 2 sealed (an uninitialised server is sealed too, and its JSON says
# initialized false), anything else could not ask.
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
        die 11 "the server is sealed: $(unseal_hint)"
      fi
      die 11 "the server is not initialised: the Operator initialises it with task openbao:init"
      ;;
    *) die 10 "the server at ${BAO_ADDR:-the default address (https://127.0.0.1:8200)} is unreachable: task openbao:server:status says whether it runs; the start hook is openbao-setup start" ;;
  esac
}
need_token() {
  bao token lookup >/dev/null 2>&1 || die 12 "no valid token (none, expired or revoked): log in with $(login_hint) (task openbao:logout first clears a dead one)"
}
preflight() {
  server_state
  state_exit
  need_token
}
wait_active() { # after an unseal, a single raft node needs a moment to become the active node
  local _
  for _ in $(seq 1 40); do
    bao read -format=json sys/leader 2>/dev/null | grep -Eq '"is_self"[[:space:]]*:[[:space:]]*true' && return 0
    sleep 0.5
  done
  return 1
}

# Ask for shares at bao's own prompt (input hidden, a terminal required) until the server is
# unsealed; `bao operator unseal` prints the progress each time.
unseal_loop() {
  local n=0
  while :; do
    server_state
    [ "$st_rc" -eq 0 ] && break
    [ "$st_rc" -eq 2 ] || state_exit
    n=$((n + 1))
    [ "$n" -le 6 ] || die 1 "still sealed after $((n - 1)) shares: check the shares and start again (bao operator unseal -reset clears the progress)"
    paste_off
    echo "openbao: share $n: one of the three unseal shares task openbao:init printed (a long base64 string; NOT your Operator password), typed at bao's hidden prompt:" >&2
    bao operator unseal || die 1 "bao could not take that as an unseal share: a password typed instead of a share, or a mistyped share? A share is the base64 string openbao:init printed, not the Operator password. bao operator unseal -reset clears the progress, then run this again"
  done
  wait_active || say "the server is unsealed but has not become the active node yet; give it a few seconds"
}

# ---------------------------------------------------------------------------------- init ----
# Everything init sets up, with the root token in BAO_TOKEN and the password in $op_pw. Each step
# is idempotent: it is skipped when it is already there.
configure_store() {
  bao read "sys/mounts/$mount" >/dev/null 2>&1 || bao secrets enable -path="$mount" -version=2 kv >/dev/null || return 1
  if [ "$unlock_now" != keyfile ]; then
    bao read sys/auth/userpass >/dev/null 2>&1 || bao auth enable userpass >/dev/null || return 1
  fi
  bao read sys/auth/approle >/dev/null 2>&1 || bao auth enable approle >/dev/null || return 1
  operator_policy "$mount" | bao policy write operator - >/dev/null || return 1
  if [ "$unlock_now" != keyfile ]; then
    # The login lifetime (ruling 6): 4 hours, at most 8 with no renewal past that.
    printf '%s' "$op_pw" | bao write auth/userpass/users/operator password=- token_policies=operator token_ttl=4h token_max_ttl=8h >/dev/null || return 1
  fi
  # The backup role (read on the snapshot path only, loopback only): what a scheduled backup logs in
  # with, since the Operator's token ends after at most 8 hours.
  ensure_backup_role || return 1
  reissue_role backup || return 1
}

cmd_init() {
  guard init "it prints the unseal shares and the root token once, and they must never land in a transcript"
  need_server_mode init
  not_keyfile init "task dc:openbao:keyfile:create on the workstation initialises it (five shares: three custody shares printed there once, two in the OpenBao key file; no password)"
  need_tty init
  local a
  for a in "$@"; do
    case "$a" in
      -pgp-keys=* | -pgp-keys | -root-token-pgp-key=* | -root-token-pgp-key) ;;
      *) die 2 "openbao:init takes only -pgp-keys (encrypts the shares to your keys; you decrypt them yourself before the unseal step); the share count and threshold are fixed at 3 and 2" ;;
    esac
  done
  server_state
  case "$st_rc" in
    0) die 3 "the server is already initialised and unsealed: nothing to initialise" ;;
    2) is_initialised && die 3 "the server is already initialised: unseal it with task openbao:unseal (a second init would need an empty store)" ;;
    *) state_exit ;;
  esac

  echo "openbao: initialising the server at ${BAO_ADDR:-the default address}. Three unseal shares are made (any two open the server)." >&2
  echo "openbao: a machine loss loses what is in this server's volume (a bounded-loss exception to ADR 0045): a backup destination limits that." >&2

  # The backup choice is asked for and never defaulted.
  local choice_kind="" choice_dest="" tries=0
  while [ -z "$choice_kind" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die 3 "no backup choice made: nothing was changed"
    ask "Backup destination: a folder path (the cloud folder, a USB disk), or type: no backup"
    case "$REPLY" in
      "") echo "openbao: the choice is explicit: a folder path, or the words: no backup" >&2 ;;
      [Nn]o\ [Bb]ackup) choice_kind=none ;;
      /*)
        if [ -d "$REPLY" ] && [ -w "$REPLY" ]; then
          choice_kind=path
          choice_dest="$REPLY"
        else
          echo "openbao: '$REPLY' is not a writable folder; pick another, or type: no backup" >&2
        fi
        ;;
      *) echo "openbao: '$REPLY' is not an absolute folder path; pick one, or type: no backup" >&2 ;;
    esac
  done

  tries=0
  local pw1="" pw2=""
  op_pw=""
  while [ -z "$op_pw" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die 3 "no password chosen: nothing was changed"
    ask_secret "Choose the Operator's password (at least 12 characters; you log in with it each sitting):"
    pw1="$REPLY"
    ask_secret "Again:"
    pw2="$REPLY"
    if [ "${#pw1}" -lt 12 ]; then
      echo "openbao: too short (12 characters at least)" >&2
    elif [ "$pw1" != "$pw2" ]; then
      echo "openbao: the two did not match" >&2
    else
      op_pw="$pw1"
    fi
  done

  local out root shares
  out="$(bao operator init -key-shares=3 -key-threshold=2 "$@" 2>&1)" || {
    printf '%s\n' "$out" | sed 's/^/openbao-server: /' >&2
    die 1 "bao operator init failed"
  }
  root="$(sed -n 's/^Initial Root Token: //p' <<<"$out")"
  shares="$(grep -E '^Unseal Key [0-9]+: ' <<<"$out")"
  [ -n "$root" ] && [ -n "$shares" ] || die 1 "bao operator init answered, but its output had no shares or root token; the server may be initialised without them: stop it, delete $dir/raft and start again"

  cat <<EOF

THE UNSEAL SHARES. Shown once, here only. Any two open the server; losing two of the three loses
every secret in it. Keep one in your password manager, one on paper offline, and one with a second
trusted person or on a hardware key. Never in git, in the container, or where backups go.

$shares

EOF
  ask "Press Enter once all three are stored (you then enter two of them to prove it):"
  # (the typed answer is ignored)
  unseal_loop

  local rc=0
  (
    # shellcheck disable=SC2030  # in this subshell only
    export BAO_TOKEN="$root"
    configure_store
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    BAO_TOKEN="$root" bao token revoke -self >/dev/null 2>&1
    root=""
    op_pw=""
    die 1 "a configuration step failed (bao's message is above) and the root token is revoked. The store holds nothing yet, so to start over: stop the server, delete $dir/raft, run openbao-setup start and task openbao:init again (new shares)"
  fi

  umask 077
  {
    echo "choice=$choice_kind"
    [ "$choice_kind" = path ] && echo "dest=$choice_dest"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dir/backup-choice"
  BAO_TOKEN="$root" bao token revoke -self >/dev/null 2>&1 || say "the root token could not be revoked: revoke it by hand (bao token revoke -self)"
  root=""
  op_pw=""

  echo "openbao: initialised, unsealed and configured: the dcf KV mount, userpass (user operator, login 4 hours, at most 8), approle, the Operator's policy, the audit log." >&2
  if [ "$choice_kind" = none ]; then
    echo "openbao: backup choice recorded: NO BACKUP. A lost machine loses everything in this server; task openbao:server:status keeps saying so." >&2
  else
    echo "openbao: backup destination recorded: $choice_dest" >&2
  fi
  echo "openbao: the root token is revoked. Log in: task openbao:login -- -method=userpass username=operator" >&2
}

# -------------------------------------------------------------------------------- unseal ----
cmd_unseal() {
  guard unseal "it asks for the unseal shares, which must never land in a transcript"
  need_server_mode unseal
  need_tty unseal
  server_state
  case "$st_rc" in
    0)
      echo "openbao: the server is already unsealed" >&2
      exit 0
      ;;
    2) is_initialised || die 11 "the server is not initialised: the Operator initialises it with task openbao:init" ;;
    *) state_exit ;;
  esac
  unseal_loop
  echo "openbao: unsealed. Log in ($(login_hint)) if you have no valid login." >&2
}

# ---------------------------------------------------------------------------------- seal ----
cmd_seal() {
  guard seal "it uses the Operator's token and stops every Feature that reads a secret"
  need_server_mode seal
  server_state
  if [ "$st_rc" -eq 2 ]; then
    echo "openbao: the server is already sealed" >&2
    exit 0
  fi
  state_exit
  need_token
  bao operator seal || die 1 "bao could not seal the server (the token's policy needs update and sudo on sys/seal, which the Operator's policy has)"
  echo "openbao: sealed. The Operator unseals it with task openbao:unseal." >&2
}

# --------------------------------------------------------------------------------- status ----
cmd_status() {
  local state
  echo "mode:     $mode_now"
  echo "address:  ${BAO_ADDR:-the default (https://127.0.0.1:8200)}"
  server_state
  case "$st_rc" in
    0) state=unsealed ;;
    2) if is_initialised; then state=sealed; else state="not initialised"; fi ;;
    *) state=unreachable ;;
  esac
  echo "server:   $state"
  if [ "$mode_now" = server ]; then
    local pid
    pid="$(cat "$dir/server.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = bao ]; then
      echo "process:  bao server, pid $pid, log $dir/server.log"
    else
      echo "process:  not running: openbao-setup start (task openbao:setup) starts it"
    fi
    echo "storage:  raft, $dir/raft (tier 4: the volume)"
    if [ "$unlock_now" = keyfile ]; then
      echo "unlock:   keyfile (the OpenBao key file on the workstation unseals and logs in at every task dc:*; three custody shares are the spare)"
      local rp=""
      rp="$(cat "$dir/renewer.pid" 2>/dev/null || true)"
      if [[ "$rp" =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$rp/cmdline" 2>/dev/null | grep -q 'openbao-keyfile renew'; then
        echo "renewer:  running, pid $rp (renews the Operator's periodic token; log $dir/renewer.log)"
      else
        echo "renewer:  not running (it starts with the next unlock: task dc:openbao:unlock on the workstation)"
      fi
    else
      echo "unlock:   operator (two typed unseal shares after every start, a password per sitting)"
    fi
    echo "audit:    $dir/audit.log"
    local choice="" dest="" chosen=""
    if [ -f "$dir/backup-choice" ]; then
      choice="$(sed -n 's/^choice=//p' "$dir/backup-choice")"
      dest="$(sed -n 's/^dest=//p' "$dir/backup-choice")"
      chosen="$(sed -n 's/^date=//p' "$dir/backup-choice")"
    fi
    backup_status_lines "$choice" "$dest" "$chosen"
  fi
  if [ "$st_rc" -eq 0 ]; then
    if bao token lookup >/dev/null 2>&1; then
      echo "login:    valid"
    else
      echo "login:    none or expired: $(login_hint)"
    fi
  fi
  case "$state" in
    unsealed) exit 0 ;;
    unreachable) exit 10 ;;
    *) exit 11 ;;
  esac
}

# ------------------------------------------------------------------------------- configure ----
# What init sets up (the mounts, the Operator's policy and login), for a token that already exists:
# openbao-onboard claim runs it with the claim token and the receiver's password on stdin, after the
# sender's users are deleted. Not a task: the Operator never runs it by hand.
cmd_configure() {
  guard configure "it takes the Operator's new password and a root token"
  need_server_mode configure
  # shellcheck disable=SC2031  # init's subshell sets its own BAO_TOKEN; here it is the caller's
  [ -n "${BAO_TOKEN:-}" ] || die 2 "configure takes the token in BAO_TOKEN and the Operator's password on stdin"
  if [ "$unlock_now" = keyfile ]; then
    op_pw="" # no password: the OpenBao key file's rotate makes the Operator's login
  else
    IFS= read -r op_pw || die 2 "configure takes the Operator's password on stdin"
    [ "${#op_pw}" -ge 12 ] || die 2 "the password is shorter than 12 characters"
  fi
  server_state
  state_exit
  configure_store || die 1 "a configuration step failed (bao's message is above)"
  op_pw=""
}

# --------------------------------------------------------------------------------- password ----
# A new password for the Operator, for one who forgot it: no current password and no login are
# needed, the unseal shares are the authority (as for a role). The password is asked first, twice,
# then the shares make a root token that writes it (on bao's stdin, never an argument) and is revoked.
set_operator_password() { # the password is in $op_pw; runs with the root token
  bao read sys/auth/userpass >/dev/null 2>&1 || { say "the userpass login is not enabled in this store (an onboarding claim not done yet? task openbao:onboard:claim); nothing was changed"; return 1; }
  bao read auth/userpass/users/operator >/dev/null 2>&1 || { say "there is no user 'operator' in this store (an onboarding claim not done yet? task openbao:onboard:claim); nothing was changed"; return 1; }
  printf '%s' "$op_pw" | bao write auth/userpass/users/operator/password password=- >/dev/null || { say "bao did not take the new password; the old one still holds"; return 1; }
}

cmd_password() {
  need_server_mode password
  not_keyfile password "it has no password; the Operator logs in with the OpenBao key file (task dc:openbao:unlock on the workstation). To go back to a password, set unlock to operator, then task openbao:password"
  guard password "it asks for a new password and a root token made from the unseal shares, which must never land in a transcript"
  need_tty password
  server_state
  state_exit
  local tries=0 pw1="" pw2=""
  op_pw=""
  while [ -z "$op_pw" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die 3 "no password chosen: nothing was changed"
    ask_secret "Choose the Operator's new password (at least 12 characters; you log in with it each sitting):"
    pw1="$REPLY"
    ask_secret "Again:"
    pw2="$REPLY"
    if [ "${#pw1}" -lt 12 ]; then
      echo "openbao: too short (12 characters at least)" >&2
    elif [ "$pw1" != "$pw2" ]; then
      echo "openbao: the two did not match" >&2
    else
      op_pw="$pw1"
    fi
  done
  pw1="" pw2="" REPLY=""
  local rc=0
  as_root password "changing the Operator's password" set_operator_password || rc=$?
  op_pw=""
  [ "$rc" -eq 0 ] || die 1 "the Operator's password was not changed (the messages above say why); the root token is revoked"
  echo "openbao: the Operator's password is changed. Tokens the Operator already holds stay valid until they expire (at most 8 hours). Log in with the new one: task openbao:login -- -method=userpass username=operator" >&2
}

# --------------------------------------------------------------------------------- approle ----
# A root token from the unseal shares, for one step, with no login needed. The loopback listener
# of the config openbao-setup start writes has OpenBao's unauthenticated root-token endpoints on
# (sys/generate-root/*, disable_unauthed_generate_root_endpoints = false); bao's CLI cannot use
# them (since OpenBao 2.6.0 `bao operator generate-root` calls only the authenticated
# sys/generate-root-token), so they are called with curl. The attempt is started there and the
# server hands back its one-time password, kept in a variable; the Operator types the shares at a
# hidden prompt, each sent on curl's stdin with the attempt's nonce (so a share never feeds an
# attempt someone else started); the encoded token is decoded here with the one-time password (an
# XOR: bao's own -decode asks the authenticated status first, which needs a login); the step runs
# with the token (BAO_TOKEN in a subshell, nowhere else); and the token is revoked straight after,
# also on failure or an interrupt (an attempt this task started and abandoned is cancelled). No
# share, one-time password or token is printed, logged, put in a file or passed as an argument.
# A listener with the endpoints off (a config of the repo's own, without the marker line) answers
# 405: the task then uses the CLI's authenticated flow, which needs the Operator's login (the
# policy's two generate-root-token paths) and passes the one-time password as an argument (useless
# without the encoded token, which goes over stdin).
root_otp="" root_tok="" root_started=0 root_done=0 root_via=""
root_replaced=0 # set by a restore: the store the token was made in is replaced, so a failed revoke is expected
gr_call() { # <method> <attempt|update>: the body on stdin; prints the response, then the HTTP code on a last line of its own
  local -a ca=()
  [ -z "${BAO_CACERT:-}" ] || ca=(--cacert "$BAO_CACERT")
  local url="${BAO_ADDR:-http://127.0.0.1:8200}/v1/sys/generate-root/$2"
  curl -sS --noproxy '*' --max-time 30 "${ca[@]}" -X "$1" -H 'X-Vault-Request: true' --data-binary @- -w '\n%{http_code}' "$url" 2>/dev/null # dcf-curl: allow a request to the local server, not a download: no retry (a share is sent once)
}
json_str() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -n 1; } # <key> <json>
json_err() { sed -n 's/.*"errors"[[:space:]]*:[[:space:]]*\["\([^"]*\)".*/\1/p' <<<"$1" | head -n 1; }
root_cleanup() {
  if [ -n "$root_tok" ] && [ "$root_replaced" -eq 1 ]; then
    # try, silently: when the snapshot went in, the token is gone with the store it was made in
    BAO_TOKEN="$root_tok" bao token revoke -self >/dev/null 2>&1 || true
    root_tok=""
  fi
  if [ -n "$root_tok" ]; then
    BAO_TOKEN="$root_tok" bao token revoke -self >/dev/null 2>&1 || echo "$prog: THE ROOT TOKEN COULD NOT BE REVOKED: revoke it now (bao token revoke -self with it), or seal the server" >&2
    root_tok=""
  fi
  if [ "$root_started" -eq 1 ] && [ "$root_done" -eq 0 ]; then
    if [ "$root_via" = legacy ]; then
      gr_call DELETE attempt </dev/null >/dev/null || true
    else
      bao operator generate-root -cancel >/dev/null 2>&1 || true
    fi
  fi
  root_started=0
  root_otp=""
}
as_root() { # <task> <what it is for> <command> [args]: the command runs with a root token
  local task="$1" what="$2" out code req n=0 enc nonce share rc=0
  shift 2
  guard "$task" "it needs a root token made from the unseal shares, which must never land in a transcript"
  need_tty "$task"
  trap 'root_cleanup' EXIT
  trap 'root_cleanup; exit 130' INT TERM HUP
  out="$(printf '{}' | gr_call PUT attempt)"
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  case "$code" in
    200) root_via=legacy root_started=1 ;;
    405) root_via=cli ;;
    400)
      case "$(json_err "$out")" in
        *"in progress"*) say "a root token generation is already in progress: one started in another terminal, or by a task that was killed. It is not taken over; cancel it with an HTTP DELETE to ${BAO_ADDR:-http://127.0.0.1:8200}/v1/sys/generate-root/attempt (no token needed)" ;;
        *) say "the server refused to start a root token generation: $(json_err "$out")" ;;
      esac
      die 3 "nothing was changed"
      ;;
    *) die 1 "could not start a root token generation at ${BAO_ADDR:-http://127.0.0.1:8200} (HTTP ${code:-none}${out:+: $(json_err "$out")}); nothing was changed" ;;
  esac
  if [ "$root_via" = legacy ]; then
    root_otp="$(json_str otp "$out")"
    nonce="$(json_str nonce "$out")"
    [ -n "$root_otp" ] && [ -n "$nonce" ] || die 1 "the server started a root token generation but sent back no one-time password or nonce; the attempt is cancelled"
  else
    # The listener has the unauthenticated endpoints off: the CLI's authenticated flow, with the login.
    bao token lookup >/dev/null 2>&1 || die 12 "this server's listener has the unauthenticated root-token endpoints off (no disable_unauthed_generate_root_endpoints = false in its config: a config of your own, without the marker line), so a root token needs the Operator's login: log in (task openbao:login -- -method=userpass username=operator) and run this again, or add that line to the listener block and restart the server"
    root_otp="$(bao operator generate-root -generate-otp)" && [ -n "$root_otp" ] || die 1 "bao could not make a one-time password for the root token (does the Operator's login still hold? task openbao:login)"
    out="$(bao operator generate-root -init -otp="$root_otp" -format=json 2>&1)" || {
      echo "$prog: bao could not start a root token generation. One may already be in progress (bao operator generate-root -status; -cancel ends it)." >&2
      die 3 "nothing was changed"
    }
    root_started=1
  fi
  req="$(sed -n 's/.*"required"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$out" | head -n 1)"
  [ -n "$req" ] || req=2
  echo "openbao: $what needs a root token, made from $req unseal shares typed at the prompt (hidden); it is used for this step only and revoked straight after." >&2
  while :; do
    n=$((n + 1))
    [ "$n" -le $((req + 2)) ] || die 1 "the root token generation did not complete after $((n - 1)) shares: check the shares and run the task again (the attempt is cancelled)"
    if [ "$root_via" = legacy ]; then
      ask_secret "Unseal share $n of $req (one of the three shares task openbao:init printed; not your password) (hidden):"
      share="${REPLY#"${REPLY%%[![:space:]]*}"}" # a paste's surrounding blanks off; one inside is no share
      share="${share%"${share##*[![:space:]]}"}"
      REPLY=""
      if [[ ! "$share" =~ ^[A-Za-z0-9+/=]+$ ]]; then
        share=""
        die 1 "that is not an unseal share: a password typed instead of a share, or a mistyped share? A share is the base64 string openbao:init printed, not the Operator password; the attempt is cancelled: run the task again"
      fi
      out="$(printf '{"key":"%s","nonce":"%s"}' "$share" "$nonce" | gr_call PUT update)"
      share=""
      code="${out##*$'\n'}"
      out="${out%$'\n'*}"
      [ "$code" = 200 ] || die 1 "the server did not take that share (${code:-no answer}${out:+: $(json_err "$out")}): a password typed instead of a share, or a share of another store? A share is the base64 string openbao:init printed, not the Operator password; the attempt is cancelled: run the task again"
    else
      # bao's own prompt goes to its stdout, which is captured here (the JSON is read back): so say it
      paste_off
      printf 'Unseal share %s of %s (one of the three shares task openbao:init printed; not your password) (hidden): ' "$n" "$req" >&2
      out="$(bao operator generate-root -otp="$root_otp" -format=json)" || { printf '\n' >&2; die 1 "bao could not take that as an unseal share: a password typed instead of a share, or a mistyped share? A share is the base64 string openbao:init printed, not the Operator password; the attempt is cancelled: run the task again"; }
      printf '\n' >&2
    fi
    grep -Eq '"complete"[[:space:]]*:[[:space:]]*true' <<<"$out" && break
  done
  root_done=1
  enc="$(json_str encoded_token "$out")"
  out=""
  if [ "$root_via" = legacy ]; then
    root_tok="$(otp_decode "$enc" "$root_otp")" || root_tok=""
    [ -n "$root_tok" ] || die 1 "the server made the root token but its answer could not be decoded (an OpenBao change?); a root token now exists that nobody holds (useless without the one-time password, which is gone); report this"
  else
    root_tok="$(printf '%s' "$enc" | bao operator generate-root -decode=- -otp="$root_otp")" || root_tok=""
    [ -n "$root_tok" ] || die 1 "the root token could not be decoded: the shares were probably wrong; run the task again"
  fi
  enc=""
  root_otp=""
  (
    # shellcheck disable=SC2030,SC2031  # the token is meant to live in this subshell only
    export BAO_TOKEN="$root_tok"
    "$@"
  ) || rc=$?
  root_cleanup
  trap - EXIT INT TERM HUP
  return "$rc"
}

# What the root token is used for.
create_role() { # <role> <policy> <ppath>
  # The role may read this one secret and nothing else (not even a listing).
  printf 'path "%s/data/%s" {\n  capabilities = ["read"]\n}\n' "${3%%/*}" "${3#*/}" | bao policy write "$2" - >/dev/null || { say "could not write the policy $2"; return 1; }
  # Loopback only, short tokens, secret ids that do not expire (openbao-lib.sh: one definition)
  role_write "$1" "$2" || { say "could not write the role $1"; return 1; }
}
delete_role() { # <role>
  # Deleting a role destroys the secret ids issued under it (OpenBao's role deletion flushes them).
  bao delete "auth/approle/role/$1" >/dev/null || { say "could not delete the role $1"; return 1; }
  bao policy delete "approle-$1" >/dev/null 2>&1 || true
}

role_ok() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,63}$ ]]; }
ppath_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$ ]]; }
list_keys() { bao list "$1" 2>/dev/null | sed '1,2d'; }
role_exists() { bao read "auth/approle/role/$1/role-id" >/dev/null 2>&1; }

# One valid secret id per role: the old ones are destroyed (issuing a new one does not end the
# others of the role, so their accessors are destroyed first), then one is made and written, with
# the role id (not secret), under the state dir. Nothing is printed of either.
reissue_role() { # <role>
  local role="$1" acc sid rid
  while IFS= read -r acc; do
    [ -n "$acc" ] || continue
    bao write "auth/approle/role/$role/secret-id-accessor/destroy" secret_id_accessor="$acc" >/dev/null || { say "could not destroy a secret id of role $role"; return 1; }
  done < <(list_keys "auth/approle/role/$role/secret-id")
  sid="$(bao write -f -field=secret_id "auth/approle/role/$role/secret-id")" && [ -n "$sid" ] || { say "could not make a secret id for role $role"; return 1; }
  rid="$(bao read -field=role_id "auth/approle/role/$role/role-id")" && [ -n "$rid" ] || { say "could not read the role id of role $role"; return 1; }
  (
    umask 077
    mkdir -p "$dir/approle/$role" || exit 1
    printf '%s' "$sid" > "$dir/approle/$role/secret_id.tmp.$$" && mv -f "$dir/approle/$role/secret_id.tmp.$$" "$dir/approle/$role/secret_id" || exit 1
    printf '%s' "$rid" > "$dir/approle/$role/role_id.tmp.$$" && mv -f "$dir/approle/$role/role_id.tmp.$$" "$dir/approle/$role/role_id" || exit 1
  ) || { say "could not write the secret id of role $role under $dir/approle"; return 1; }
  echo "openbao: role $role: a new secret id (and the role id) written under $dir/approle/$role, mode 600; every earlier secret id of the role is destroyed" >&2
}

cmd_approle_issue() {
  need_server_mode approle:issue
  local role="${OPENBAO_TASK_ROLE:-}" ppath="${OPENBAO_TASK_POLICY_PATH:-}" all="${OPENBAO_TASK_ALL:-}"
  if [ -n "$all" ]; then
    [ -z "$role" ] && [ -z "$ppath" ] || die 2 "ALL=1 reissues every role in the store: do not combine it with ROLE or POLICY_PATH"
  else
    [ -n "$role" ] || die 2 "name a role (ROLE=<name>, lower case, with POLICY_PATH=<mount/path> the first time) or ALL=1"
  fi
  [ -z "$ppath" ] || {
    ppath_ok "$ppath" || die 2 "'$ppath' is not <mount>/<path> (letters, digits, . _ - and / between parts)"
    role_ok "$role" || die 2 "'$role' is not a role name (lower case letters, digits, - and _, starting with a letter)"
    guard approle:issue "making a role needs a root token made from the unseal shares, which must never land in a transcript"
    need_tty approle:issue
  }
  preflight
  if [ -n "$all" ]; then
    local r n=0 failed=0
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      n=$((n + 1))
      reissue_role "$r" || failed=1
    done < <(list_keys auth/approle/role)
    [ "$n" -gt 0 ] || echo "openbao: no AppRole roles in the store, nothing to reissue" >&2
    exit "$failed"
  fi
  role_ok "$role" || die 2 "'$role' is not a role name (lower case letters, digits, - and _, starting with a letter)"
  local policy="approle-$role"
  if [ -n "$ppath" ]; then
    ppath_ok "$ppath" || die 2 "'$ppath' is not <mount>/<path> (letters, digits, . _ - and / between parts)"
    # Making a role writes a policy: that is the shares' step (a token that could write any policy
    # could give a role snapshot-force). Refused inside an agent's job and without a terminal.
    as_root approle:issue "making the role $role (it writes a policy)" create_role "$role" "$policy" "$ppath" || die 1 "the role $role was not made (the messages above say why); the root token is revoked"
  elif ! role_exists "$role"; then
    die 2 "role '$role' does not exist: give POLICY_PATH=<mount/path> (the one secret it may read) the first time; making a role asks for the unseal shares"
  fi
  reissue_role "$role" || exit 1
}

cmd_approle_revoke() {
  need_server_mode approle:revoke
  local role="${OPENBAO_TASK_ROLE:-}"
  [ -n "$role" ] || die 2 "name a role: ROLE=<name>"
  role_ok "$role" || die 2 "'$role' is not a role name"
  guard approle:revoke "deleting a role needs a root token made from the unseal shares, which must never land in a transcript"
  need_tty approle:revoke
  preflight
  role_exists "$role" || die 14 "no such role '$role'"
  # Deleting a role, and its policy, is the shares' step (see approle:issue).
  as_root approle:revoke "deleting the role $role" delete_role "$role" || die 1 "the role $role was not deleted (the messages above say why); the root token is revoked"
  rm -rf "${dir:?}/approle/$role"
  echo "openbao: role $role deleted with its secret ids and its policy, and its files under $dir/approle removed; a token it already made lives at most 15 minutes (token_max_ttl)" >&2
}

# ------------------------------------------------------------------------------- backup ----
# A backup is `bao operator raft snapshot save` copied to a folder the consumer names, as
# openbao-<machine>-<UTC time>.snap, never over a file that exists. The snapshot is ciphertext (the
# barrier key is protected by the unseal shares) and the shares never go with it.
# Settings: the Feature options baked into options.env (BACKUPDEST, BACKUPKEEP, BACKUPINTERVAL,
# BACKUPWARNAFTER) and their run-time twins OPENBAO_SETUP_BACKUP_* in the environment.
opt() { # <options.env name> <twin variable> -> the value (the twin wins, even when empty)
  local twin="$2" v
  if [ -n "${!twin+set}" ]; then
    printf '%s' "${!twin}"
    return 0
  fi
  v="$(
    # shellcheck disable=SC1091  # written by install.sh
    [ -f "$ob_dir/options.env" ] && . "$ob_dir/options.env"
    printf '%s' "${!1:-}"
  )"
  printf '%s' "$v"
}
machine_name() {
  local m="${OPENBAO_MACHINE:-}"
  [ -n "$m" ] || m="$(hostname 2>/dev/null || true)"
  m="${m//[^A-Za-z0-9._-]/-}"
  printf '%s' "${m:-machine}"
}
default_dest() { # the destination used when none is named: the option, else the one recorded at init
  local d
  d="$(opt BACKUPDEST OPENBAO_SETUP_BACKUP_DEST)"
  [ -n "$d" ] || d="$(sed -n 's/^dest=//p' "$dir/backup-choice" 2>/dev/null | head -n 1)"
  printf '%s' "$d"
}
interval_secs() { # <5m|6h|1d> -> seconds, or fails
  local v="$1"
  [[ "$v" =~ ^([0-9]+)([mhd])$ ]] || return 1
  local n="${BASH_REMATCH[1]}"
  [ "$n" -gt 0 ] || return 1
  case "${BASH_REMATCH[2]}" in
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
  esac
}
age_text() { # <seconds>
  local s="$1"
  if [ "$s" -lt 120 ]; then echo "${s}s"
  elif [ "$s" -lt 7200 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}
last_field() { sed -n "s/^$1=//p" "$dir/last-backup" 2>/dev/null | head -n 1; }
backup_meaning() { # <exit code> -> the line for it
  case "$1" in
    10) echo "the server is unreachable: task openbao:server:status says whether it runs" ;;
    11) echo "the server is sealed or not initialised: the Operator runs task openbao:unseal" ;;
    12) echo "cannot log in: task openbao:approle:issue ROLE=backup reissues the backup role's secret id (or log in: task openbao:login)" ;;
    13) echo "the token may not read the snapshot (sys/storage/raft/snapshot): the policy decides; in client mode the server's owner" ;;
    20) echo "the destination is missing or not writable: check the folder (is the drive or cloud folder mounted?)" ;;
    *) echo "see the lines above" ;;
  esac
}

tmp_dir=""
cleanup() {
  [ -z "$tmp_dir" ] || rm -rf "${tmp_dir:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

bk_part=""
cmd_backup() {
  # (also run in a subshell, where the script's traps are not inherited)
  trap 'rm -f "$bk_part"; cleanup' EXIT
  trap 'exit 130' INT TERM HUP
  local dest="${OPENBAO_TASK_DEST:-}" keep="${OPENBAO_TASK_KEEP:-}"
  [ -n "$dest" ] || dest="$(default_dest)"
  [ -n "$dest" ] || die 2 "no destination: give DEST=<folder>, or set the backupDest option (OPENBAO_SETUP_BACKUP_DEST), or record one with task openbao:init"
  [ -n "$keep" ] || keep="$(opt BACKUPKEEP OPENBAO_SETUP_BACKUP_KEEP)"
  keep="${keep:-30}"
  [[ "$keep" =~ ^[0-9]+$ ]] || die 2 "KEEP/backupKeep is '$keep': a whole number (0 keeps every backup)"
  server_state
  state_exit
  [ -d "$dest" ] && [ -w "$dest" ] || die 20 "$(backup_meaning 20) ('$dest')"

  # who logs in: the backup role in server mode (its secret id is in the volume), else the token
  # of the sitting (client mode: the role or token the server's owner provides)
  local tok=""
  if [ "$mode_now" = server ] && [ -s "$dir/approle/backup/secret_id" ] && [ -s "$dir/approle/backup/role_id" ]; then
    tok="$(env -u BAO_TOKEN bao write -field=token auth/approle/login role_id="@$dir/approle/backup/role_id" secret_id="@$dir/approle/backup/secret_id" 2>/dev/null)" && [ -n "$tok" ] ||
      die 12 "the backup role cannot log in: $(backup_meaning 12)"
  else
    need_token
    [ "$mode_now" != server ] || say "no backup role in this volume (a server made before openbao 1.3.0): using your login; task openbao:backup:role makes the role"
    # shellcheck disable=SC2031  # init's subshell sets its own root token; this is the sitting's
    tok="${BAO_TOKEN:-}"
  fi
  as_tok() { if [ -n "$tok" ]; then BAO_TOKEN="$tok" "$@"; else "$@"; fi; }
  as_tok bao token capabilities sys/storage/raft/snapshot 2>/dev/null | grep -Eqw 'read|root|sudo' || die 13 "$(backup_meaning 13)"

  # the snapshot goes to a private folder on tmpfs, and nowhere else until the copy; it is removed
  # on every way out (the EXIT trap)
  local base="${OPENBAO_BACKUP_TMP:-/dev/shm}"
  [ -d "$base" ] && [ -w "$base" ] || die 1 "no tmpfs folder at $base for the temporary snapshot (the store would otherwise touch the disk): set OPENBAO_BACKUP_TMP"
  tmp_dir="$(umask 077 && mktemp -d "$base/openbao-backup.XXXXXX")" || die 1 "could not make a private temporary folder in $base"
  export BAO_CLIENT_TIMEOUT="${BAO_CLIENT_TIMEOUT:-300}"
  as_tok bao operator raft snapshot save "$tmp_dir/snap" 2>"$tmp_dir/err" || { sed 's/^/openbao-server: bao: /' "$tmp_dir/err" >&2; die 1 "bao could not take the snapshot"; }
  [ -s "$tmp_dir/snap" ] || die 1 "bao answered but the snapshot is empty"
  local sum
  sum="$(sha256sum "$tmp_dir/snap" | cut -d' ' -f1)"

  # copied whole under a name outside the pattern, checked, then moved into place without
  # overwriting; a name that exists (two backups in one second) waits for the next second
  local machine stamp final tries=0
  machine="$(machine_name)"
  bk_part="$dest/.openbao-backup-$$.part"
  local part="$bk_part"
  cp "$tmp_dir/snap" "$part" 2>"$tmp_dir/err" || { sed 's/^/openbao-server: cp: /' "$tmp_dir/err" >&2; die 20 "could not copy the snapshot into '$dest': $(backup_meaning 20)"; }
  chmod 600 "$part" 2>/dev/null || true
  [ "$(sha256sum "$part" | cut -d' ' -f1)" = "$sum" ] || die 20 "the copy in '$dest' differs from the snapshot (a full disk or a sync folder?): nothing was kept"
  while :; do
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    final="$dest/openbao-$machine-$stamp.snap"
    if [ ! -e "$final" ]; then
      mv -n "$part" "$final" 2>/dev/null
      if [ ! -e "$part" ]; then break; fi
    fi
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die 1 "could not find a free name in '$dest' (openbao-$machine-<time>.snap exists): nothing was overwritten"
    sleep 1
  done

  (
    umask 077
    {
      echo "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "epoch=$(date -u +%s)"
      echo "file=$final"
      echo "sha256=$sum"
    } > "$dir/last-backup.tmp.$$" && mv -f "$dir/last-backup.tmp.$$" "$dir/last-backup"
  ) 2>/dev/null || say "the time of this backup could not be recorded in $dir/last-backup (server:status will not show it)"

  # the retention: this machine's own files in this folder, beyond the newest KEEP; nothing else
  local f tail n=0 removed=0
  local -a mine=()
  if [ "$keep" -gt 0 ]; then
    while IFS= read -r f; do
      tail="${f##*/}"
      tail="${tail#"openbao-$machine-"}"
      [[ "$tail" =~ ^[0-9]{8}T[0-9]{6}Z\.snap$ ]] && mine+=("$f")
    done < <(LC_ALL=C find "$dest" -maxdepth 1 -type f -name "openbao-$machine-*.snap" 2>/dev/null | LC_ALL=C sort)
    n="${#mine[@]}"
    if [ "$n" -gt "$keep" ]; then
      for f in "${mine[@]:0:$((n - keep))}"; do
        [ "$f" != "$final" ] && rm -f -- "$f" && removed=$((removed + 1))
      done
    fi
  fi
  echo "openbao: backup written: $final"
  echo "openbao: sha256: $sum"
  [ "$removed" -eq 0 ] || echo "openbao: removed $removed older backup(s) of this machine beyond the newest $keep (only openbao-$machine-<time>.snap files)"
  return 0
}

# What a task that writes a secret ends with. It never fails: the write stands whatever the backup
# does (the folder missing, the server sealed), and the backup's own line and meaning are printed.
cmd_after_write() {
  local d rc=0 t
  # A client has no store of its own to back up (a central server's owner does that)
  [ "$mode_now" = server ] || exit 0
  d="$(default_dest)"
  t="$(last_field time)"
  if [ -z "$d" ]; then
    say "not backed up since ${t:-ever}; task openbao:backup DEST=<folder> takes a backup (the destination can be recorded with the backupDest option)"
    exit 0
  fi
  (cmd_backup) || rc=$?
  [ "$rc" -eq 0 ] || say "the write stands, but its backup to '$d' failed with exit $rc: $(backup_meaning "$rc"). Not backed up since ${t:-ever}."
  exit 0
}

# The Feature's own timer (OpenBao has no scheduled snapshots; see the NOTES): one background loop
# per container, started by the start hook, running the backup into the default destination every
# backupInterval. A sealed server is skipped with a line in backup.log until the next tick.
timer_alive() {
  local pid
  pid="$(cat "$dir/backup-timer.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'backup-timer-run'
}
cmd_backup_timer_start() { # never fails the start hook that calls it
  [ "$mode_now" = server ] || exit 0
  local iv secs d
  iv="$(opt BACKUPINTERVAL OPENBAO_SETUP_BACKUP_INTERVAL)"
  [ -n "$iv" ] || exit 0
  secs="$(interval_secs "$iv")" || { say "backupInterval '$iv' is not 5m, 6h, 1d (a number and m, h or d): no timer"; exit 0; }
  [ "$secs" -ge 300 ] || { say "backupInterval '$iv' is under 5 minutes: no timer"; exit 0; }
  d="$(default_dest)"
  [ -n "$d" ] || { say "backupInterval is set but there is no destination (the backupDest option, or the one recorded at init): no timer"; exit 0; }
  if timer_alive; then
    echo "openbao: backup timer already running (every $iv into $d)"
    exit 0
  fi
  if command -v setsid >/dev/null 2>&1; then
    (umask 077; setsid "$0" backup-timer-run </dev/null >>"$dir/backup.log" 2>&1 &)
  else
    (umask 077; nohup "$0" backup-timer-run </dev/null >>"$dir/backup.log" 2>&1 &)
  fi
  echo "openbao: backup timer started (every $iv into $d; backup.log in the volume says what each run did)"
  exit 0
}
cmd_backup_timer_run() {
  local iv secs ticks=0 rc
  iv="$(opt BACKUPINTERVAL OPENBAO_SETUP_BACKUP_INTERVAL)"
  secs="$(interval_secs "$iv")" || die 2 "backupInterval '$iv' is not a number and m, h or d"
  echo "$$" > "$dir/backup-timer.pid"
  while :; do
    sleep "${OPENBAO_TIMER_SLEEP:-$secs}"
    rc=0
    (cmd_backup) >> "$dir/backup.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) openbao: scheduled backup done" >> "$dir/backup.log"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) openbao: scheduled backup skipped or failed, exit $rc: $(backup_meaning "$rc")" >> "$dir/backup.log"
    fi
    if [ "$(wc -l < "$dir/backup.log" 2>/dev/null || echo 0)" -gt 400 ]; then
      tail -n 200 "$dir/backup.log" > "$dir/backup.log.tmp" && cat "$dir/backup.log.tmp" > "$dir/backup.log"
      rm -f "$dir/backup.log.tmp"
    fi
    ticks=$((ticks + 1))
    [ -z "${OPENBAO_TIMER_TICKS:-}" ] || [ "$ticks" -lt "$OPENBAO_TIMER_TICKS" ] || break
  done
}

backup_status_lines() { # in server mode, after the destination/choice lines of status
  local choice="$1" dest="$2" chosen="$3" t e f s now warn wsecs age
  t="$(last_field time)"
  e="$(last_field epoch)"
  f="$(last_field file)"
  s="$(last_field sha256)"
  warn="$(opt BACKUPWARNAFTER OPENBAO_SETUP_BACKUP_WARN_AFTER)"
  warn="${warn:-7d}"
  wsecs="$(interval_secs "$warn")" || wsecs=604800
  if [ -n "$e" ] && [[ "$e" =~ ^[0-9]+$ ]]; then
    now="$(date -u +%s)"
    age=$((now - e))
    [ "$age" -ge 0 ] || age=0
    if [ "$age" -gt "$wsecs" ]; then
      echo "backup:   WARNING last backup $(age_text "$age") ago (more than backupWarnAfter $warn), $t, $f"
    else
      echo "backup:   last backup $(age_text "$age") ago, $t, $f (sha256 ${s:0:12}...)"
    fi
    [ "$choice" != path ] || echo "          destination $dest (chosen $chosen)"
    return 0
  fi
  case "$choice" in
    path) echo "backup:   WARNING no backup taken yet (destination $dest, chosen $chosen): task openbao:backup" ;;
    none) echo "backup:   WARNING no backup (chosen $chosen): a lost machine loses everything in this server; task openbao:backup DEST=<folder> takes one" ;;
    *) echo "backup:   WARNING none chosen yet: task openbao:init asks, or the backupDest option names one (a lost machine loses everything in this server); task openbao:backup DEST=<folder> takes one" ;;
  esac
}

# The backup role: read on the snapshot path and nothing else, loopback only, short tokens, a
# secret id that does not expire (reissued, like every role's). Needs a token that may write roles:
# init's root token, or one made from the shares.
ensure_backup_role() {
  printf 'path "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n' | bao policy write approle-backup - >/dev/null || return 1
  bao write auth/approle/role/backup token_policies=approle-backup token_ttl=5m token_max_ttl=15m \
    secret_id_ttl=0 secret_id_num_uses=0 secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32 >/dev/null || return 1
}

backup_role_step() { ensure_backup_role && reissue_role backup; }

cmd_backup_role() {
  guard backup:role "it makes a root token from the unseal shares, which must never land in a transcript"
  need_server_mode backup:role
  need_tty backup:role
  server_state
  state_exit
  as_root backup:role "making the backup role (it writes a policy and a role)" backup_role_step || die 1 "could not make the backup role (bao's message is above); the root token is revoked"
  echo "openbao: the backup role is in place; task openbao:backup uses it from now on, and the timer (backupInterval) can log in" >&2
}

# ------------------------------------------------------------------------------- restore ----
stop_server() {
  local pid _
  pid="$(cat "$dir/server.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = bao ] || return 0
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    [ -d "/proc/$pid" ] || return 0
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
  [ ! -d "/proc/$pid" ]
}
start_server_again() {
  command -v openbao-setup >/dev/null 2>&1 || die 1 "openbao-setup is not on PATH: start the server by hand (task openbao:setup) and run this task again"
  openbao-setup start >&2 || true
  local _
  for _ in $(seq 1 40); do
    server_state
    [ "$st_rc" -eq 1 ] || return 0
    sleep 0.5
  done
  die 10 "the server did not come back after its storage was cleared: $dir/server.log says why"
}
wait_sealed() { # after a restore the node reloads and seals itself
  local _
  for _ in $(seq 1 60); do
    server_state
    [ "$st_rc" -eq 2 ] && return 0
    sleep 0.5
  done
  return 1
}

cmd_restore() {
  guard restore "it takes the unseal shares, which must never land in a transcript"
  need_server_mode restore
  need_tty restore
  local from="${OPENBAO_TASK_FROM:-}" marker="$dir/restore.pending" machine other onboarding base tkey troot json fresh=0
  [ -n "$from" ] || die 2 "name the snapshot: FROM=<file> (a file written by task openbao:backup)"
  [ -f "$from" ] && [ -r "$from" ] || die 2 "FROM '$from' is not a readable file"
  [ -s "$from" ] || die 2 "FROM '$from' is empty"
  machine="$(machine_name)"
  base="${from##*/}"
  other=""
  onboarding=""
  # An onboarding snapshot (task openbao:onboard:export) is named onboarding-<machine>-<time>.snap:
  # the file name is what a restore can read before it has a token. It is a starter store to claim,
  # not another machine's backup; the claim token is what lets openbao:onboard:claim take it over.
  if [[ "$base" =~ ^onboarding-(.+)-[0-9]{8}T[0-9]{6}Z\.snap$ ]]; then
    onboarding="${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^openbao-(.+)-[0-9]{8}T[0-9]{6}Z\.snap$ ]] && [ "${BASH_REMATCH[1]}" != "$machine" ]; then
    other="${BASH_REMATCH[1]}"
  fi
  if [ -n "$onboarding" ]; then
    echo "openbao: this is an onboarding snapshot, made on '$onboarding' by task openbao:onboard:export: a starter store with the keys that machine chose to hand over. It is unsealed with the shares that machine gave you and finished by task openbao:onboard:claim, which rotates them and revokes everything it held." >&2
  fi
  if [ -n "$other" ]; then
    echo "openbao: WARNING this snapshot was written on '$other', not on this machine ('$machine'). Restoring your own backup restores your own access; someone else's backup is not an onboarding hand-over (that is a file named onboarding-<machine>-<time>.snap, made by task openbao:onboard:export, finished by task openbao:onboard:claim)." >&2
    ask "Type: restore  to go on, anything else stops:"
    [ "$REPLY" = restore ] || die 3 "stopped; nothing was changed"
  fi

  server_state
  [ "$st_rc" -eq 2 ] || [ "$st_rc" -eq 0 ] || state_exit
  if [ "$st_rc" -eq 2 ] && ! is_initialised; then
    fresh=1
  elif [ -e "$marker" ]; then
    # an earlier restore stopped between the throwaway init and the end of the restore: the store
    # holds nothing, and its throwaway shares were never kept, so it starts again from empty
    echo "openbao: an earlier restore did not finish (restore.pending): clearing the empty store and starting again" >&2
    stop_server || die 1 "could not stop the server: stop it (pid in $dir/server.pid), delete $dir/raft and run this task again"
    rm -rf "${dir:?}/raft"
    rm -f "$marker"
    start_server_again
    server_state
    { [ "$st_rc" -eq 2 ] && ! is_initialised; } || die 1 "the store is still not empty after it was cleared: delete $dir/raft by hand and run this task again"
    fresh=1
  fi

  if [ "$fresh" -eq 1 ]; then
    echo "openbao: this server is not initialised: it is initialised with one throwaway share, the snapshot is installed over it, and the throwaway share and token are discarded" >&2
    (umask 077; { echo "from=$from"; echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$marker")
    json="$(bao operator init -key-shares=1 -key-threshold=1 -format=json 2>/dev/null | tr -d '\n')" || true
    tkey="$(sed -n 's/.*"unseal_keys_b64"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json")"
    troot="$(sed -n 's/.*"root_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$json")"
    json=""
    [ -n "$tkey" ] && [ -n "$troot" ] || die 1 "bao could not initialise the empty server for the restore; run this task again (it starts from empty)"
    bao operator unseal "$tkey" >/dev/null || die 1 "bao could not unseal the empty server; run this task again (it starts from empty)"
    tkey=""
    wait_active || die 1 "the empty server did not become the active node; run this task again"
    trap 'root_cleanup' EXIT
    trap 'root_cleanup; exit 130' INT TERM HUP
    root_tok="$troot"
    troot=""
    BAO_TOKEN="$root_tok" bao operator raft snapshot restore -force "$from" || die 1 "bao could not install the snapshot (its message is above); run this task again (it starts from empty)"
    root_cleanup
    trap - EXIT INT TERM HUP
    rm -f "$marker"
  else
    echo "openbao: this server already holds a store: the snapshot REPLACES every secret in it (and every login and role). Keep a backup of the current store first if you may need it." >&2
    ask "Type: restore  to go on, anything else stops:"
    [ "$REPLY" = restore ] || die 3 "stopped; nothing was changed"
    if [ "$st_rc" -eq 2 ]; then
      echo "openbao: the server is sealed: enter shares of the current store to unseal it first" >&2
      bao operator unseal -reset >/dev/null 2>&1 || true
      unseal_loop
    fi
    root_replaced=1 # the snapshot replaces the store the root token lives in: nothing is left to revoke
    as_root restore "installing the snapshot" bao operator raft snapshot restore -force "$from" || die 1 "bao could not install the snapshot (its message is above); the current store is unchanged"
  fi

  # the restored store is sealed under the snapshot's own shares
  if ! wait_sealed; then
    # A snapshot of a store with the same shares (a restore of your own backup onto the store it came
    # from) leaves the node unsealed: it still has to finish loading the restored mounts and users
    # before a login can work, so give it a moment instead of sealing it (no token to do that with).
    echo "openbao: the server stayed unsealed (the snapshot holds the same unseal key); letting it finish loading the restored store" >&2
    wait_active || true
    sleep 5
  fi
  {
    umask 077
    { echo "from=$from"; echo "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$dir/last-restore"
  } 2>/dev/null || true
  echo "openbao: the snapshot is installed. The store is sealed under the shares of the store it came from: enter two of them (not the throwaway one)." >&2
  bao operator unseal -reset >/dev/null 2>&1 || true
  unseal_loop

  if [ -n "$onboarding" ]; then
    # The server stays up and unsealed under the sender's shares. No login, no reissue: nothing of
    # the sender's is trusted yet, and the claim does it all (it takes the claim token).
    echo "openbao: restored from $from; the server is unsealed under the sender's shares and nothing of the sender's has been trusted or reissued. Next: task openbao:onboard:claim (it asks for the claim token, your own Operator password and two of the sender's shares)." >&2
    exit 0
  fi

  if [ "$unlock_now" = keyfile ]; then
    # No password here and no key file in the container: the workstation makes the new key file, which
    # also reissues every AppRole's secret id and logs the Operator in.
    openbao-setup unlock --status >/dev/null 2>&1 || true # remembers the restored store's cluster id
    echo "openbao: restored from $from; the server is unsealed. This server is opened with the OpenBao key file: run task dc:openbao:keyfile:rotate on the workstation (two shares of the restored store) to make its new key file; it also reissues every AppRole's secret id and logs you in." >&2
    exit 0
  fi
  # The backs and the backup role must work again: the secret ids' files in the volume are not in
  # the snapshot and the ids in the store are the old ones, so every role is reissued. That needs
  # only the Operator's login of the restored store (it may reissue the secret ids of existing
  # roles), which also leaves the Operator logged in.
  echo "openbao: log in as the Operator of the restored store (its password, at the hidden prompt) to reissue the roles' secret ids:" >&2
  if ! bao login -no-print -method=userpass username=operator; then
    say "the restore is done and the store is unsealed, but the login failed (the password of the store this snapshot came from?): log in (task openbao:login -- -method=userpass username=operator), then run task openbao:approle:issue ALL=1"
    exit 1
  fi
  local r rc=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    reissue_role "$r" || rc=1
  done < <(list_keys auth/approle/role)
  if [ "$rc" -ne 0 ]; then
    say "the restore is done and the store is unsealed, but reissuing the roles failed: task openbao:approle:issue ALL=1 (logged in) finishes it"
    exit 1
  fi
  role_exists backup || echo "openbao: the restored store has no backup role (it was made before openbao 1.3.0): task openbao:backup:role makes it, which scheduled backups need" >&2
  echo "openbao: restored from $from; the server is unsealed, you are logged in as the Operator and every AppRole has a new secret id." >&2
  [ -f "$dir/backup-choice" ] || echo "openbao: this volume has no backup choice yet: task openbao:backup DEST=<folder> takes a backup, and the backupDest option names a default" >&2
}

# ------------------------------------------------------------------ SSH certificate authority ----
# task openbao:ssh:ca:init, :ca:role and :ca:import. The CA is an SSH secrets engine mount
# (DCF_SSH_CA_MOUNT, default ssh-ca) whose signing key is generated inside OpenBao, or imported once
# from stdin, and never leaves it (the engine returns only the public key). A signing role is a
# named set of principal patterns: ed25519 subject keys only, user certificates only, no
# extensions and no critical options, a default lifetime and a maximum one. The default role
# (DCF_SSH_CA_ROLE, default "default", patterns relay@<guid>,fed-<guid>) is made by init and is a role like
# any other (:ca:role changes it or adds more). OpenBao matches a role's allowed_users exactly,
# with no wildcard, so a role whose patterns have a * or a <guid> is stored with allowed_users "*" and its
# patterns are kept in the KV store as ssh-ca/roles/<role> (field allowed); dcf-ssh-sign checks
# them before it signs, and the verifier's cert-authority line is the boundary that counts (the
# NOTES say so). A role of exact names is enforced by the server itself.
# Making the mount, the CA or a role writes things the Operator's token may not (and the
# Operator's policy gets the sign path here), so in server mode it is the shares' step, like
# making an AppRole role (as_root: a plain terminal, refused inside an agent's job, two unseal
# shares, a root token used for this step only). Against a server elsewhere (client mode) the step
# runs with the token you hold, which the server's owner must have given the rights.
camount="${DCF_SSH_CA_MOUNT:-ssh-ca}"
dcf_secret_bin="${DCF_SECRET_BIN:-dcf-secret}"
ca_default_role="${DCF_SSH_CA_ROLE:-default}"
ca_default_allowed='relay@<guid>,fed-<guid>'
ca_key_id_format='{{role_name}}-{{public_key_hash}}' # no name of a token or a person in a key id
ca_default_ttl=2160h # 90 days

ca_mount_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] && [ "$1" != "$mount" ] && [ "$1" != sys ] && [ "$1" != auth ]; }
ca_allowed_ok() { # a comma separated list of principals or patterns (pattern_ok in openbao-lib.sh)
  local p
  local -a ps
  [ -n "$1" ] || return 1
  IFS=, read -ra ps <<<"$1"
  for p in "${ps[@]}"; do pattern_ok "$p" || return 1; done
}
ca_server_allowed() { # what the server's allowed_users holds for these patterns
  case "$1" in *'*'* | *'<guid>'*) echo '*' ;; *) echo "$1" ;; esac
}
ca_fp() { printf '%s\n' "$1" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}'; }
ca_pub_now() { bao read -field=public_key "$camount/config/ca" 2>/dev/null | head -n 1; }

# The role as asked, with the token in use: everything there already, so there is nothing to do.
ca_role_current() { # <role> <patterns> <ttl secs> <max secs>
  local json
  json="$(bao read -format=json "$camount/roles/$1" 2>/dev/null)" || return 1
  jq -e --arg au "$(ca_server_allowed "$2")" --arg kf "$ca_key_id_format" --argjson t "$3" --argjson m "$4" '.data |
    .key_type == "ca" and .allow_user_certificates == true and .allow_host_certificates == false and
    .allow_user_key_ids == true and .allow_empty_principals == false and .allowed_users == $au and
    .key_id_format == $kf and
    .ttl == $t and .max_ttl == $m and (.allowed_extensions // "") == "" and
    (.allowed_critical_options // "") == "" and ((.allowed_user_key_lengths // {}) | keys) == ["ssh-ed25519"]' >/dev/null <<<"$json" || return 1
  [ "$(bao kv get -mount="$mount" -field=allowed "ssh-ca/roles/$1" 2>/dev/null)" = "$2" ]
}

ca_report() { # <public key> <what>
  say "SSH CA at $camount: $(ca_fp "$1") ($2). Compare this fingerprint with the other side's out of band (dcf-ssh-sign ca --fingerprint), never from a shared folder or a message that anyone else could have changed"
}

# What runs with the token for this step (the root token in server mode, the caller's own in client
# mode). KEY and KEY_PUB hold an imported key; nothing else secret is in reach.
ssh_ca_apply() { # <init|role|import> <role> <patterns> <ttl secs> <max secs>
  local what="$1" role="$2" patterns="$3" ttl="$4" max="$5" type pub err
  type="$(bao read -format=json "sys/mounts/$camount" 2>/dev/null | jq -r '.data.type // empty' 2>/dev/null)"
  if [ -z "$type" ]; then
    err="$(bao secrets enable -path="$camount" ssh 2>&1 >/dev/null)" || { say "could not enable the ssh secrets engine at $camount: $err"; return 1; }
    say "enabled the ssh secrets engine at $camount"
  elif [ "$type" != ssh ]; then
    say "$camount is a $type mount, not an ssh one: DCF_SSH_CA_MOUNT (or MOUNT=) names another"
    return 1
  fi
  pub="$(ca_pub_now)"
  case "$what" in
    import)
      [ -z "$pub" ] || { say "$camount already has a CA ($(ca_fp "$pub")): it is never replaced here"; return 1; }
      err="$(printf '%s' "$KEY" | bao write "$camount/config/ca" private_key=- public_key="$KEY_PUB" 2>&1 >/dev/null)" || { say "OpenBao did not take the key as the CA: $err"; return 1; }
      pub="$(ca_pub_now)"
      [ -n "$pub" ] && [ "$(ca_fp "$pub")" = "$(ca_fp "$KEY_PUB")" ] || { say "the CA was written, but what OpenBao returns does not match the key that was read: look at $camount/config/ca before using it"; return 1; }
      ca_report "$pub" "imported; the private key is only in OpenBao now, delete your copy"
      return 0
      ;;
    init)
      if [ -z "$pub" ]; then
        err="$(bao write "$camount/config/ca" generate_signing_key=true key_type=ssh-ed25519 2>&1 >/dev/null)" || { say "OpenBao could not generate the CA: $err"; return 1; }
        pub="$(ca_pub_now)"
        [ -n "$pub" ] || { say "the CA was generated but its public key cannot be read back"; return 1; }
        ca_report "$pub" "generated in OpenBao, ed25519; its private key never leaves it"
      else
        ca_report "$pub" "already there, left as it is"
      fi
      ;;
    role)
      [ -n "$pub" ] || { say "there is no CA at $camount yet: task openbao:ssh:ca:init makes it (and the default role)"; return 1; }
      ;;
  esac
  # The role: only what is asked and nothing wider.
  jq -n --arg au "$(ca_server_allowed "$patterns")" --arg kf "$ca_key_id_format" --argjson t "$ttl" --argjson m "$max" '{
    key_type: "ca", allow_user_certificates: true, allow_host_certificates: false, allow_user_key_ids: true,
    allow_empty_principals: false, allowed_users: $au, key_id_format: $kf, allowed_extensions: "", allowed_critical_options: "",
    default_extensions: {}, default_critical_options: {}, allowed_user_key_lengths: {"ssh-ed25519": 0},
    ttl: $t, max_ttl: $m}' | bao write "$camount/roles/$role" - >/dev/null || { say "could not write the role $role at $camount"; return 1; }
  # The patterns, where dcf-ssh-sign reads them (see above).
  bao kv put -mount="$mount" "ssh-ca/roles/$role" allowed="$patterns" ttl="$ttl" max_ttl="$max" >/dev/null || { say "could not write the role's patterns to $mount/ssh-ca/roles/$role (is the $mount KV mount there?)"; return 1; }
  say "role $role at $camount: ed25519 keys only, user certificates only, no extensions, no critical options, a key id of the role name and the key's hash; principals $patterns; lifetime $ttl s by default, $max s at most"
  if [ "$mode_now" = server ]; then
    # The Operator may sign with every role of the mount from now on (an existing store keeps its
    # policy until this runs).
    operator_policy "$mount" "$camount" | bao policy write operator - >/dev/null || { say "could not write the Operator's policy"; return 1; }
  fi
}

cmd_ssh_ca() { # <init|role|import>
  local what="$1" role patterns ttl max ttl_s max_s rc=0 pub
  guard "ssh:ca:$what" "it changes the certificate authority and, in server mode, uses a root token made from the unseal shares, which must never land in a transcript"
  [ -z "${OPENBAO_TASK_MOUNT:-}" ] || camount="$OPENBAO_TASK_MOUNT"
  ca_mount_ok "$camount" || die 2 "'$camount' is not a mount name for the CA (letters, digits, - and _; not the $mount KV mount, sys or auth)"
  command -v jq >/dev/null 2>&1 || die 1 "jq is not installed: rebuild the devcontainer (the openbao Feature installs it)"
  command -v ssh-keygen >/dev/null 2>&1 || die 1 "ssh-keygen is not installed (openssh-client)"
  case "$what" in
    init)
      role="$ca_default_role"
      patterns="${OPENBAO_TASK_ALLOWED:-$ca_default_allowed}"
      ;;
    role)
      role="${OPENBAO_TASK_NAME:-}"
      patterns="${OPENBAO_TASK_ALLOWED:-}"
      [ -n "$role" ] && [ -n "$patterns" ] || die 2 "NAME=<role> ALLOWED=<principals or patterns, comma separated> are required (TTL=<dur> and MAX_TTL=<dur> optional)"
      ;;
    import) role="" patterns="" ;;
  esac
  if [ "$what" != import ]; then
    role_ok "$role" || die 2 "'$role' is not a role name (lower case letters, digits, - and _, starting with a letter)"
    ca_allowed_ok "$patterns" || die 2 "ALLOWED='$patterns' is not a comma separated list of principals or patterns (letters, digits, . _ @ -, * for any run of them, <guid> for a lowercase 8-4-4-4-12 GUID)"
    ! admits_operator "$patterns" || die 2 "ALLOWED='$patterns' would admit the principal operator: no certificate names it, under any role (a narrower pattern, e.g. writer@*)"
    ttl="${OPENBAO_TASK_TTL:-$ca_default_ttl}"
    ttl_s="$(dur_secs "$ttl")" || die 2 "TTL='$ttl' is not a duration (a number and s, m, h or d: 90d, 2160h)"
    max="${OPENBAO_TASK_MAX_TTL:-}"
    if [ -n "$max" ]; then max_s="$(dur_secs "$max")" || die 2 "MAX_TTL='$max' is not a duration (a number and s, m, h or d)"; else max_s="$ttl_s"; fi
    [ "$max_s" -ge "$ttl_s" ] || die 2 "MAX_TTL ($max) is shorter than TTL ($ttl): the default lifetime cannot exceed the maximum"
  fi
  if [ "$what" = import ]; then
    [ ! -t 0 ] || die 2 "the CA's private key is read from stdin: pipe it in (never as an argument)"
    KEY="$(tr -d '\r'; printf x)"
    KEY="${KEY%x}"
    [ -z "$KEY" ] || [ "${KEY: -1}" = $'\n' ] || KEY="$KEY"$'\n'
    head -n 1 <<<"$KEY" | grep -q -- '^-----BEGIN .*PRIVATE KEY-----' || { KEY=""; die 2 "stdin is not a private key (no -----BEGIN ... PRIVATE KEY----- line)"; }
    KEY_PUB="$(printf '%s' "$KEY" | ssh-keygen -y -P '' -f /dev/stdin 2>/dev/null | awk '{print $1" "$2}')"
    [ -n "$KEY_PUB" ] && [ "$KEY_PUB" != " " ] || { KEY=""; die 2 "ssh-keygen cannot read that key (a passphrase on it? remove it from a copy first: ssh-keygen -p -N '' -f <copy>)"; }
    [[ "$KEY_PUB" == ssh-ed25519\ * ]] || { KEY=""; die 2 "the CA key must be an ed25519 key (ssh-keygen -t ed25519), the role signs ed25519 keys only"; }
  fi

  # The server and the token first (dcf-secret status: its line and its exit code), then whether
  # there is anything to do: with the CA and the role as asked there, nothing is asked of anyone.
  "$dcf_secret_bin" status >/dev/null || exit $?
  pub="$(ca_pub_now)"
  case "$what" in
    import)
      [ -z "$pub" ] || { KEY=""; die 3 "$camount already has a CA ($(ca_fp "$pub")): it is never replaced here"; }
      ;;
    init | role)
      if [ -n "$pub" ] && ca_role_current "$role" "$patterns" "$ttl_s" "$max_s"; then
        [ "$what" = role ] || ca_report "$pub" "already there, left as it is"
        say "role $role at $camount is already as asked: nothing changed"
        return 0
      fi
      ;;
  esac

  if [ "$mode_now" = server ]; then
    if [ "$what" = import ]; then
      # The key came on stdin; the shares are typed at the terminal.
      (exec </dev/tty) 2>/dev/null || { KEY=""; die 3 "task openbao:ssh:ca:import needs a terminal for the unseal shares (the key is piped in, the shares are typed): run it in a plain terminal in the devcontainer"; }
      exec </dev/tty
    fi
    as_root "ssh:ca:$what" "the SSH certificate authority at $camount (the mount, the CA, a role and the Operator's policy)" ssh_ca_apply "$what" "$role" "$patterns" "${ttl_s:-0}" "${max_s:-0}" || rc=$?
    KEY=""
    [ "$rc" -eq 0 ] || die 1 "the SSH CA step failed (the messages above say why); the root token is revoked"
  else
    ssh_ca_apply "$what" "$role" "$patterns" "${ttl_s:-0}" "${max_s:-0}" || { KEY=""; die 1 "the SSH CA step failed (the messages above say why); the token you hold needs the rights to enable a mount, write its CA and roles and write to $mount/ssh-ca (the server's owner gives them)"; }
    KEY=""
    say "against a server of yours elsewhere, its Operator's policy needs these paths for dcf-ssh-sign (its owner adds them; this Feature cannot):"
    ssh_ca_policy "$camount" >&2
  fi
  [ "$what" = import ] && say "next: task openbao:ssh:ca:init makes the default role and gives the Operator's policy the sign path"
  return 0
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  init) cmd_init "$@" ;;
  unseal) cmd_unseal ;;
  seal) cmd_seal ;;
  status) cmd_status ;;
  configure) cmd_configure ;;
  password) cmd_password ;;
  approle-issue) cmd_approle_issue ;;
  approle-revoke) cmd_approle_revoke ;;
  backup) cmd_backup ;;
  backup-role) cmd_backup_role ;;
  restore) cmd_restore ;;
  ssh-ca-init) cmd_ssh_ca init ;;
  ssh-ca-role) cmd_ssh_ca role ;;
  ssh-ca-import) cmd_ssh_ca import ;;
  after-write) cmd_after_write ;;
  backup-timer-start) cmd_backup_timer_start ;;
  backup-timer-run) cmd_backup_timer_run ;;
  *) usage ;;
esac
