# shellcheck shell=bash
# openbao-feature/openbao-lib.sh: sourced (never run) by openbao-server and openbao-onboard, so the
# two share one definition of what must not drift apart: the refusal inside an agent's job and
# without a terminal, the prompts, the AppRole role settings, the Operator's policy and the decoding
# of a root token made from the shares. openbao-keyfile sources it too. The caller sets `prog` first.

# shellcheck disable=SC2154  # prog is the caller's
say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}

# An agent's job: the devhost's backs run their CLI with DEVHOST_JOB_CHILD, and Claude Code sets
# CLAUDECODE on every process it starts (its tool calls, subagents and headless runs).
# OPENBAO_AGENT_JOB_VARS names more variables (space separated) for another agent CLI.
agent_job() { # the name of the variable that says this is an agent's job, or fail
  local v
  # shellcheck disable=SC2086  # a list of names
  for v in DEVHOST_JOB_CHILD CLAUDECODE ${OPENBAO_AGENT_JOB_VARS:-}; do
    if [ -n "${!v:-}" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}
guard() { # <task> <why>
  local v
  if v="$(agent_job)"; then
    die 3 "task openbao:$1 refuses to run inside an agent's job ($v is set): $2. Run it yourself in a plain terminal in the devcontainer"
  fi
}
dur_secs() { # <5m|6h|90d|3600> -> seconds, or fail (a number and s, m, h or d; bare is seconds)
  [[ "$1" =~ ^([1-9][0-9]*)([smhd]?)$ ]] || return 1
  local n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    '' | s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
  esac
}

# Principal patterns of an SSH CA role (task openbao:ssh:ca:role, dcf-ssh-sign): the characters of a
# principal (letters, digits . _ @ -), a * for any run of them and <guid> for exactly a lowercase
# 8-4-4-4-12 GUID. A pattern is matched whole, never as a part. One definition for the task (what a
# role may admit) and the command (what it signs).
pattern_ok() { # <pattern>
  local rest="${1//<guid>/}" first='^[A-Za-z0-9*<]' chars='^[A-Za-z0-9._@*-]*$'
  [ -n "$1" ] && [[ "$rest" =~ $chars ]] && [[ "$1" =~ $first ]] && [ "${#1}" -le 160 ]
}
pattern_regex() { # <pattern> -> an anchored extended regex on stdout
  local re="$1"
  re="${re//./\\.}"
  re="${re//\*/.*}"
  local guid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  re="${re//<guid>/$guid}"
  printf '^%s$' "$re"
}
principal_matches() { # <principal> <comma separated patterns>: 0 when any pattern covers it
  local p="$1" pat re
  local -a pats
  IFS=, read -ra pats <<<"$2"
  for pat in "${pats[@]}"; do
    pattern_ok "$pat" || continue
    re="$(pattern_regex "$pat")"
    [[ "$p" =~ $re ]] && return 0
  done
  return 1
}
# No certificate ever names the principal operator (the Operator's own login is not a user to log in
# as): a role may not admit it and no role signs it, in any capitalisation.
admits_operator() { # <comma separated patterns>
  principal_matches operator "${1,,}"
}
is_operator_principal() { [ "${1,,}" = operator ]; }

# Bracketed paste off (ESC [ ? 2004 l). A shell such as pwsh (PSReadLine) leaves it on while a child
# runs, so a pasted share arrives as ESC[200~<share>ESC[201~ and bao's hidden prompt, which reads
# raw bytes, sends the markers with the key ("'key' must be a valid hex or base64 string"). Only
# to a terminal; the shell sets it again at its next prompt.
paste_off() {
  if [ -t 1 ]; then printf '\033[?2004l'; elif [ -t 2 ]; then printf '\033[?2004l' >&2; fi
  return 0
}
need_tty() { # <task>
  { [ -t 0 ] && [ -t 1 ]; } || die 3 "task openbao:$1 needs a terminal on stdin and stdout (it asks for secrets and prints them only to a terminal); run it in a plain terminal, not through a pipe or a script"
  paste_off # every prompt that follows takes a paste as typed
}
ask() { # <prompt> -> $REPLY, echoed input
  printf '%s ' "$1" >&2
  IFS= read -r REPLY || die 3 "no answer (the input ended)"
}
ask_secret() { # <prompt> -> $REPLY, input hidden
  paste_off
  printf '%s ' "$1" >&2
  IFS= read -rs REPLY || die 3 "no answer (the input ended)"
  printf '\n' >&2
}

# The one definition of an AppRole role of this Feature, with the token of the environment: only
# from inside this container (loopback-bound secret ids and tokens), 5 minute tokens (at most 15),
# secret ids that do not expire, so the backs do not stop on a date nobody watches (they are
# reissued instead).
role_write() { # <role> <comma separated policies>
  bao write "auth/approle/role/$1" token_policies="$2" token_ttl=5m token_max_ttl=15m \
    secret_id_ttl=0 secret_id_num_uses=0 secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32 >/dev/null
}

# The Operator's policy, one definition for init, configure (an onboarding claim) and the OpenBao
# key file's create and rotate.
operator_policy() { # <kv mount> [<SSH CA mount>, default DCF_SSH_CA_MOUNT or ssh-ca]
  cat <<EOF
# The Operator (userpass, or the operator AppRole of the OpenBao key file): the secrets, the snapshot read, sealing, reissuing the secret ids of
# AppRole roles that already exist, and starting or cancelling a root-token generation (which only
# the unseal shares can complete). NOT any policy (sys/policies/acl/*), not the making, changing or
# deleting of a role, not snapshot-force, not audit: a token that could write a policy could give a
# role snapshot-force. Creating and deleting roles use a root token made from the shares for that
# step only. Its own AppRole (the OpenBao key file's login) is denied outright: a token that could
# mint an operator secret id would outlive every rotation. It may read whether a rekey waits for its
# verification (the OpenBao key file's keyfile status). Written by openbao:init and by the key
# file's create and rotate.
path "$1/*" {
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
path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}
path "auth/approle/role/+/secret-id" {
  capabilities = ["create", "update", "list"]
}
path "auth/approle/role/+/secret-id-accessor/destroy" {
  capabilities = ["update"]
}
path "sys/generate-root-token/attempt" {
  capabilities = ["read", "update", "delete"]
}
path "sys/generate-root-token/update" {
  capabilities = ["update"]
}
path "auth/approle/role/operator" {
  capabilities = ["deny"]
}
path "auth/approle/role/operator/*" {
  capabilities = ["deny"]
}
path "auth/userpass/users" {
  capabilities = ["list"]
}
path "sys/rotate/root/verify" {
  capabilities = ["read"]
}
$(ssh_ca_policy "${2:-}")
EOF
}

# The part of the Operator's policy for the SSH certificate authority (task openbao:ssh:ca:init):
# one definition, also printed for the owner of a server this Feature only has a client for. The
# Operator may sign a user certificate with any role of the mount, read the CA's public key and
# the roles (to list them and to check a principal against a role's patterns). NOT the mount, the
# CA key (config/ca is read-only: OpenBao never returns the private key) and not a role: making
# one is the root-token step of openbao:ssh:ca:init and :ca:role. The backs' AppRoles and an
# agent's token have no path here, so they are refused.
ssh_ca_policy() { # [<SSH CA mount>]
  local m="${1:-${DCF_SSH_CA_MOUNT:-ssh-ca}}"
  cat <<EOF
path "$m/sign/*" {
  capabilities = ["update"]
}
path "$m/config/ca" {
  capabilities = ["read"]
}
path "$m/roles" {
  capabilities = ["list"]
}
path "$m/roles/*" {
  capabilities = ["read"]
}
EOF
}

# The token from sys/generate-root/update's encoded_token, decoded with the attempt's one-time
# password, in memory.
otp_decode() { # <encoded token> <one-time password>: the token on stdout (base64 without padding, XORed with the OTP)
  local e="$1" o="$2" c k i=0 out=""
  while [ $((${#e} % 4)) -ne 0 ]; do e+="="; done
  for c in $(printf '%s' "$e" | base64 -d 2>/dev/null | od -An -v -tu1); do
    [ "$i" -lt "${#o}" ] || return 1
    printf -v k '%d' "'${o:i:1}"
    printf -v c '%03o' $((c ^ k))
    printf -v c '%b' "\\0$c"
    out+="$c"
    i=$((i + 1))
  done
  [ "$i" -gt 0 ] && [ "$i" -eq "${#o}" ] || return 1
  printf '%s' "$out"
}
