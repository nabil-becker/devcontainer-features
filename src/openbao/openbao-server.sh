#!/usr/bin/env bash
# openbao-server: what the openbao Feature's server-mode tasks run (task openbao:init, :unseal,
# :seal, :server:status, :approle:issue and :approle:revoke). It is a thin layer over the `bao`
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
#   openbao-server approle-issue          ROLE=<name> [POLICY_PATH=<mount/path>] or ALL=1 (the
#                                         OPENBAO_TASK_ROLE, OPENBAO_TASK_POLICY_PATH and
#                                         OPENBAO_TASK_ALL variables the Taskfile sets)
#   openbao-server approle-revoke         ROLE=<name> (OPENBAO_TASK_ROLE)
#
# Every command that handles a share or a token (init, unseal, seal) refuses inside an agent's job
# and, for init and unseal, without a terminal: the shares and the token must never reach a
# transcript, which the scribe reads. Exit codes: dcf-secret's numbers where they mean the same
# (10 unreachable, 11 sealed or not initialised, 12 no valid token, 14 no such role), 3 refused
# (an agent's job, no terminal, the wrong mode), 2 a wrong call, 1 a step failed.
set -u

prog=openbao-server
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
mount="${DCF_SECRET_MOUNT:-dcf}"
st_rc=0
st_json=""

say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}
usage() {
  say "usage: openbao-server init|unseal|seal|status|approle-issue|approle-revoke (the tasks of the openbao Feature run it)"
  exit 2
}

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"

mode_now="$(openbao_mode 2>/dev/null || echo client)"

# ---------------------------------------------------------------------------- refusals ----
# An agent's job: the devhost's backs run their CLI with DEVHOST_JOB_CHILD, and Claude Code sets
# CLAUDECODE on every process it starts (its tool calls, subagents and headless runs).
# OPENBAO_AGENT_JOB_VARS names more variables (space separated) for another agent CLI.
guard() { # <task> <why>
  local v
  # shellcheck disable=SC2086  # a list of names
  for v in DEVHOST_JOB_CHILD CLAUDECODE ${OPENBAO_AGENT_JOB_VARS:-}; do
    if [ -n "${!v:-}" ]; then
      die 3 "task openbao:$1 refuses to run inside an agent's job ($v is set): $2. Run it yourself in a plain terminal in the devcontainer"
    fi
  done
}
need_tty() { # <task>
  { [ -t 0 ] && [ -t 1 ]; } || die 3 "task openbao:$1 needs a terminal on stdin and stdout (it asks for secrets and prints them only to a terminal); run it in a plain terminal, not through a pipe or a script"
}
need_server_mode() { # <task>
  [ "$mode_now" = server ] || die 3 "task openbao:$1 is for server mode: this container runs no server (mode $mode_now); the server's owner does this, or set the Feature option mode to server"
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
        die 11 "the server is sealed: the Operator unseals it with task openbao:unseal"
      fi
      die 11 "the server is not initialised: the Operator initialises it with task openbao:init"
      ;;
    *) die 10 "the server at ${BAO_ADDR:-the default address (https://127.0.0.1:8200)} is unreachable: task openbao:server:status says whether it runs; the start hook is openbao-setup start" ;;
  esac
}
need_token() {
  bao token lookup >/dev/null 2>&1 || die 12 "no valid token (none, expired or revoked): log in with task openbao:login -- -method=userpass username=operator (task openbao:logout first clears a dead one)"
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
    bao operator unseal || die 1 "bao could not take that share (a wrong share? bao operator unseal -reset clears the progress, then run this again)"
  done
  wait_active || say "the server is unsealed but has not become the active node yet; give it a few seconds"
}

# ---------------------------------------------------------------------------------- init ----
operator_policy() {
  cat <<EOF
# The Operator (userpass): the secrets, the snapshot read, AppRole roles and their secret ids, the
# policies the AppRole tasks write (approle-*), and sealing. Not the rest of sys/: no
# snapshot-force, no audit, no policy except approle-*. Written by openbao:init.
path "$mount/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
path "sys/seal" {
  capabilities = ["update", "sudo"]
}
path "auth/approle/role" {
  capabilities = ["list"]
}
path "auth/approle/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/acl/approle-*" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF
}

# Everything init sets up, with the root token in BAO_TOKEN and the password in $op_pw. Each step
# is idempotent: it is skipped when it is already there.
configure_store() {
  bao read "sys/mounts/$mount" >/dev/null 2>&1 || bao secrets enable -path="$mount" -version=2 kv >/dev/null || return 1
  bao read sys/auth/userpass >/dev/null 2>&1 || bao auth enable userpass >/dev/null || return 1
  bao read sys/auth/approle >/dev/null 2>&1 || bao auth enable approle >/dev/null || return 1
  operator_policy | bao policy write operator - >/dev/null || return 1
  # The login lifetime (ruling 6): 4 hours, at most 8 with no renewal past that.
  printf '%s' "$op_pw" | bao write auth/userpass/users/operator password=- token_policies=operator token_ttl=4h token_max_ttl=8h >/dev/null || return 1
}

ask() { # <prompt> -> $REPLY, echoed input
  printf '%s ' "$1" >&2
  IFS= read -r REPLY || die 3 "no answer (the input ended)"
}
ask_secret() { # <prompt> -> $REPLY, input hidden
  printf '%s ' "$1" >&2
  IFS= read -rs REPLY || die 3 "no answer (the input ended)"
  printf '\n' >&2
}

cmd_init() {
  guard init "it prints the unseal shares and the root token once, and they must never land in a transcript"
  need_server_mode init
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
    # shellcheck disable=SC2030  # the subshell's own copy, on purpose
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
  echo "openbao: unsealed. Log in (task openbao:login -- -method=userpass username=operator) if you have no valid login." >&2
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
    echo "audit:    $dir/audit.log"
    local choice="" dest="" chosen=""
    if [ -f "$dir/backup-choice" ]; then
      choice="$(sed -n 's/^choice=//p' "$dir/backup-choice")"
      dest="$(sed -n 's/^dest=//p' "$dir/backup-choice")"
      chosen="$(sed -n 's/^date=//p' "$dir/backup-choice")"
    fi
    case "$choice" in
      path) echo "backup:   destination $dest (chosen $chosen); there is no backup task in this version yet: copy a raft snapshot (bao operator raft snapshot save) there yourself" ;;
      none) echo "backup:   WARNING no backup (chosen $chosen): a lost machine loses everything in this server" ;;
      *) echo "backup:   WARNING none chosen yet: task openbao:init asks (a lost machine loses everything in this server)" ;;
    esac
  fi
  if [ "$st_rc" -eq 0 ]; then
    if bao token lookup >/dev/null 2>&1; then
      echo "login:    valid"
    else
      echo "login:    none or expired: task openbao:login -- -method=userpass username=operator"
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
  IFS= read -r op_pw || die 2 "configure takes the Operator's password on stdin"
  [ "${#op_pw}" -ge 12 ] || die 2 "the password is shorter than 12 characters"
  server_state
  state_exit
  configure_store || die 1 "a configuration step failed (bao's message is above)"
  op_pw=""
}

# --------------------------------------------------------------------------------- approle ----
role_ok() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,63}$ ]]; }
ppath_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$ ]]; }
list_keys() { bao list "$1" 2>/dev/null | sed '1,2d'; }
role_exists() { bao read "auth/approle/role/$1" >/dev/null 2>&1; }

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
    # The role may read this one secret and nothing else (not even a listing).
    printf 'path "%s/data/%s" {\n  capabilities = ["read"]\n}\n' "${ppath%%/*}" "${ppath#*/}" | bao policy write "$policy" - >/dev/null || die 1 "could not write the policy $policy"
  elif ! role_exists "$role"; then
    die 2 "role '$role' does not exist: give POLICY_PATH=<mount/path> (the one secret it may read) the first time"
  fi
  if [ -n "$ppath" ]; then
    # Loopback only: a stolen secret id works from inside this container, and the token it gives
    # too. Short tokens (5 minutes, at most 15); secret ids that do not expire, so the backs do
    # not stop on a date nobody watches (they are reissued instead).
    bao write "auth/approle/role/$role" token_policies="$policy" token_ttl=5m token_max_ttl=15m \
      secret_id_ttl=0 secret_id_num_uses=0 secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32 >/dev/null || die 1 "could not write the role $role"
  fi
  reissue_role "$role" || exit 1
}

cmd_approle_revoke() {
  need_server_mode approle:revoke
  local role="${OPENBAO_TASK_ROLE:-}"
  [ -n "$role" ] || die 2 "name a role: ROLE=<name>"
  role_ok "$role" || die 2 "'$role' is not a role name"
  preflight
  role_exists "$role" || die 14 "no such role '$role'"
  # Deleting a role destroys the secret ids issued under it (OpenBao's role deletion flushes them).
  bao delete "auth/approle/role/$role" >/dev/null || die 1 "could not delete the role $role"
  bao policy delete "approle-$role" >/dev/null 2>&1 || true
  rm -rf "${dir:?}/approle/$role"
  echo "openbao: role $role deleted with its secret ids and its policy, and its files under $dir/approle removed; a token it already made lives at most 15 minutes (token_max_ttl)" >&2
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
  approle-issue) cmd_approle_issue ;;
  approle-revoke) cmd_approle_revoke ;;
  *) usage ;;
esac
