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
#   openbao-server backup                 a raft snapshot into DEST (OPENBAO_TASK_DEST, else the
#                                         backupDest option, else the folder recorded at init) as
#                                         openbao-<machine>-<UTC time>.snap, never overwriting;
#                                         KEEP (OPENBAO_TASK_KEEP) / backupKeep prune its own files
#   openbao-server backup-role            (re)make the backup role with a root token from the shares
#   openbao-server restore                FROM=<file> (OPENBAO_TASK_FROM): install a snapshot, with
#                                         a throwaway init on an empty server or a root token from
#                                         the shares on a store in use, then unseal and reissue
#   openbao-server after-write            what a task that writes a secret ends with: the backup (when
#                                         a destination is set) or the reminder; always exit 0
#
# Every command that handles a share or a token (init, unseal, seal, restore, backup-role) refuses inside an agent's job
# and, for init and unseal, without a terminal: the shares and the token must never reach a
# transcript, which the scribe reads. Exit codes: dcf-secret's numbers where they mean the same
# (10 unreachable, 11 sealed or not initialised, 12 no valid token, 14 no such role), 3 refused
# (an agent's job, no terminal, the wrong mode), 2 a wrong call, 1 a step failed. backup adds 13 (the
# snapshot read is denied) and 20 (DEST missing or not writable).
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
  say "usage: openbao-server init|unseal|seal|status|approle-issue|approle-revoke|backup|backup-role|restore|after-write (the tasks of the openbao Feature run it)"
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
  # rootgen lets the Operator's login start a root token generation (the shares complete it)
  rootgen_policy | bao policy write rootgen - >/dev/null || return 1
  printf '%s' "$op_pw" | bao write auth/userpass/users/operator password=- token_policies=operator,rootgen token_ttl=4h token_max_ttl=8h >/dev/null || return 1
  # The backup role (read on the snapshot path only, loopback only): what a scheduled backup logs in
  # with, since the Operator's token ends after at most 8 hours.
  ensure_backup_role || return 1
  reissue_role backup || return 1
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
    # shellcheck disable=SC2030  # only the configuration subshell holds the root token
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
    backup_status_lines "$choice" "$dest" "$chosen"
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
root_tok=""
cleanup() {
  [ -z "$tmp_dir" ] || rm -rf "${tmp_dir:?}"
  if [ -n "$root_tok" ]; then
    BAO_TOKEN="$root_tok" bao token revoke -self >/dev/null 2>&1 || say "a root token could not be revoked: revoke it by hand (bao token revoke -self with that token) or seal the server"
    root_tok=""
  fi
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
    *) echo "backup:   WARNING none chosen yet: task openbao:init asks (a lost machine loses everything in this server); task openbao:backup DEST=<folder> takes one" ;;
  esac
}

# ---------------------------------------------------------------- root token from shares ----
# The Operator's policy holds no snapshot-force and cannot make or delete roles (a 4-hour token
# must not be able to replace the store or mint an identity), so these tasks take a root token made
# from the unseal shares, use it once and revoke it. OpenBao 2.6.0 and later make that call
# authenticated (sys/generate-root-token; the unauthenticated sys/generate-root is deprecated and
# off by default), so it needs a token that may call it: the Operator's login, through the policy
# rootgen that init writes (starting an attempt is not the authority, the shares are). The shares are
# typed at bao's own hidden prompt, never held here; the token lives in $root_tok and is revoked by
# the EXIT trap at the latest.
rootgen_policy() {
  cat <<EOF
# Lets the Operator's login start a root token generation. The shares complete it; without two of
# them the call makes nothing. Written by openbao:init.
path "sys/generate-root-token/attempt" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/generate-root-token/update" {
  capabilities = ["update"]
}
EOF
}
make_root() { # the sitting's login starts it, the shares complete it; sets $root_tok
  local otp out enc n=0 nf
  server_state
  [ "$st_rc" -eq 0 ] || state_exit
  need_token
  bao token capabilities sys/generate-root-token/update 2>/dev/null | grep -Eqw 'update|root|sudo' ||
    die 12 "your login may not make a root token (policy rootgen: a store initialised before openbao 1.3.0 lacks it, and a root token cannot be made without a login that has it); see the NOTES, section Backup and restore"
  bao operator generate-root -cancel >/dev/null 2>&1 || true
  otp="$(bao operator generate-root -generate-otp 2>/dev/null)" && [ -n "$otp" ] || die 1 "bao could not make a one-time pad for a root token"
  bao operator generate-root -init -otp="$otp" >/dev/null 2>&1 || die 1 "bao could not start a root token generation"
  echo "openbao: a root token is made from the unseal shares (used once, then revoked); enter two of the three, one at each hidden prompt" >&2
  nf="$(umask 077 && mktemp "${TMPDIR:-/tmp}/openbao-root.XXXXXX")" || die 1 "could not make a temporary file"
  while :; do
    n=$((n + 1))
    if [ "$n" -gt 4 ]; then
      rm -f "$nf"
      bao operator generate-root -cancel >/dev/null 2>&1 || true
      die 1 "no root token after $((n - 1)) shares: check the shares and start again"
    fi
    echo "openbao: unseal share (hidden):" >&2
    # bao writes its own prompt into the output file with the JSON (it prints it to stdout), the
    # prompt's text is not needed; the typed share is read from the terminal and goes nowhere else
    if ! bao operator generate-root -otp="$otp" -format=json > "$nf"; then
      rm -f "$nf"
      bao operator generate-root -cancel >/dev/null 2>&1 || true
      die 1 "bao could not take that share (a wrong share?): the root token generation is cancelled; run the task again"
    fi
    if tr -d '\n' < "$nf" | grep -Eq '"complete"[[:space:]]*:[[:space:]]*true'; then
      enc="$(tr -d '\n' < "$nf" | sed -n 's/.*"encoded_\(root_\)\{0,1\}token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p')"
      rm -f "$nf"
      break
    fi
  done
  [ -n "$enc" ] || die 1 "bao finished the root token generation but returned no token"
  root_tok="$(printf '%s' "$enc" | bao operator generate-root -decode=- -otp="$otp" 2>/dev/null)" && [ -n "$root_tok" ] || { root_tok=""; die 1 "bao could not decode the root token"; }
}
drop_root() {
  [ -z "$root_tok" ] && return 0
  BAO_TOKEN="$root_tok" bao token revoke -self >/dev/null 2>&1 || say "the root token could not be revoked: seal the server (task openbao:seal) and unseal it again, which ends it"
  root_tok=""
}

# The backup role: read on the snapshot path and nothing else, loopback only, short tokens, a
# secret id that does not expire (reissued, like every role's). Needs a token that may write roles:
# init's root token, or one made from the shares.
ensure_backup_role() {
  printf 'path "sys/storage/raft/snapshot" {\n  capabilities = ["read"]\n}\n' | bao policy write approle-backup - >/dev/null || return 1
  bao write auth/approle/role/backup token_policies=approle-backup token_ttl=5m token_max_ttl=15m \
    secret_id_ttl=0 secret_id_num_uses=0 secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32 >/dev/null || return 1
}

cmd_backup_role() {
  guard backup:role "it makes a root token from the unseal shares, which must never land in a transcript"
  need_server_mode backup:role
  need_tty backup:role
  server_state
  state_exit
  make_root
  local rc=0
  (
    # shellcheck disable=SC2030,SC2031  # the root token is only for this subshell
    export BAO_TOKEN="$root_tok"
    ensure_backup_role && reissue_role backup
  ) || rc=$?
  drop_root
  [ "$rc" -eq 0 ] || die 1 "could not make the backup role (bao's message is above); the root token is revoked"
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
  local from="${OPENBAO_TASK_FROM:-}" marker="$dir/restore.pending" machine other base tkey troot json fresh=0
  [ -n "$from" ] || die 2 "name the snapshot: FROM=<file> (a file written by task openbao:backup)"
  [ -f "$from" ] && [ -r "$from" ] || die 2 "FROM '$from' is not a readable file"
  [ -s "$from" ] || die 2 "FROM '$from' is empty"
  machine="$(machine_name)"
  base="${from##*/}"
  other=""
  if [[ "$base" =~ ^openbao-(.+)-[0-9]{8}T[0-9]{6}Z\.snap$ ]] && [ "${BASH_REMATCH[1]}" != "$machine" ]; then
    other="${BASH_REMATCH[1]}"
  fi
  if [ -n "$other" ]; then
    echo "openbao: WARNING this snapshot was written on '$other', not on this machine ('$machine'). Restoring your own backup restores your own access; restoring someone else's snapshot is onboarding, and the next task is task openbao:onboard:claim." >&2
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
    root_tok="$troot"
    troot=""
    BAO_TOKEN="$root_tok" bao operator raft snapshot restore -force "$from" || die 1 "bao could not install the snapshot (its message is above); run this task again (it starts from empty)"
    drop_root
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
    make_root
    BAO_TOKEN="$root_tok" bao operator raft snapshot restore -force "$from" || die 1 "bao could not install the snapshot (its message is above); the current store is unchanged"
    drop_root
  fi

  # the restored store is sealed under the snapshot's own shares
  wait_sealed || say "the server did not seal itself after the restore; sealing it"
  if [ "$st_rc" -eq 0 ]; then bao operator seal >/dev/null 2>&1 || true; fi
  {
    umask 077
    { echo "from=$from"; echo "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$dir/last-restore"
  } 2>/dev/null || true
  echo "openbao: the snapshot is installed. The store is sealed under the shares of the store it came from: enter two of them (not the throwaway one)." >&2
  bao operator unseal -reset >/dev/null 2>&1 || true
  unseal_loop

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

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  init) cmd_init "$@" ;;
  unseal) cmd_unseal ;;
  seal) cmd_seal ;;
  status) cmd_status ;;
  approle-issue) cmd_approle_issue ;;
  approle-revoke) cmd_approle_revoke ;;
  backup) cmd_backup ;;
  backup-role) cmd_backup_role ;;
  restore) cmd_restore ;;
  after-write) cmd_after_write ;;
  backup-timer-start) cmd_backup_timer_start ;;
  backup-timer-run) cmd_backup_timer_run ;;
  *) usage ;;
esac
