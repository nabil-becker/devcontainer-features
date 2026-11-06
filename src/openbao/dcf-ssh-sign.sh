#!/usr/bin/env bash
# dcf-ssh-sign: the one way a Feature or a script of this collection asks the SSH certificate
# authority in OpenBao to sign a user certificate (the authority is made by task
# openbao:ssh:ca:init, more roles by task openbao:ssh:ca:role).
#
#   dcf-ssh-sign sign --principals <p1,p2,...> --key-id <id> [--ttl <dur>] [--role <name>]
#                                   the public key (one ssh-ed25519 line) on stdin, the certificate
#                                   on stdout (one line, an ssh-ed25519-cert-v01 certificate)
#   dcf-ssh-sign ca                 the CA's public key, one line (ssh-ed25519 AAAA...)
#   dcf-ssh-sign ca --fingerprint   its SHA256 fingerprint as ssh-keygen -lf prints it, for the
#                                   Operator to compare out of band with the other side's
#   dcf-ssh-sign roles              the signing roles' names, one per line
#   dcf-ssh-sign status             one word: ready | sealed | unreachable | logged-out | denied |
#                                   not-initialised (no CA yet)
#
# A role is a named set of principal patterns (the default role, DCF_SSH_CA_ROLE, is just the one
# --role leaves out). The CA lives at the mount DCF_SSH_CA_MOUNT (default ssh-ca). The private key
# of the CA never leaves OpenBao: nothing here takes or prints one, and the public key on stdin
# must not be one. A thin wrapper over the `bao` CLI (NFR-13): the exit code is worked out from
# bao's own signals (dcf-secret status, the capabilities `bao token capabilities` reports, whether
# the CA and the role can be read), never from the words of an error message. Nothing is read from
# a file, a volume or the environment instead of the server: no fallback.
#
# Only the Operator's policy may sign (see ssh_ca_policy in openbao-lib.sh): a token of an AppRole
# (the backs) or of an agent is refused with 13. The command also refuses to run inside an agent's
# job (exit 3, like the Feature's other Operator commands).
#
# Exit codes, the same as dcf-secret's, each with one plain line on stderr naming the fix:
#   0  done        10 the server is unreachable    11 the server is sealed, or not initialised, or
#                                                  has no CA
#   12 no token, or it expired    13 the token may not sign, or a principal is outside the role
#   2  a wrong call (usage, an unknown role)       3 refused (inside an agent's job)
#   1  bao failed for a reason none of the signals explain (bao's own message follows)
set -u

prog=dcf-ssh-sign
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
# shellcheck disable=SC1091  # installed by install.sh next to env.sh
. "$ob_dir/openbao-lib.sh" 2>/dev/null || { echo "$prog: $ob_dir/openbao-lib.sh is missing: rebuild the devcontainer" >&2; exit 1; }

camount="${DCF_SSH_CA_MOUNT:-ssh-ca}"
default_role="${DCF_SSH_CA_ROLE:-default}"
dcf_secret="${DCF_SECRET_BIN:-dcf-secret}"
caps=""

usage() {
  cat >&2 <<'EOF'
usage: dcf-ssh-sign sign --principals <p1,p2,...> --key-id <id> [--ttl <dur>] [--role <name>]
                                                   the public key on stdin, the certificate on stdout
       dcf-ssh-sign ca [--fingerprint]             the CA's public key (or its SHA256 fingerprint)
       dcf-ssh-sign roles                          the signing roles, one per line
       dcf-ssh-sign status                         print ready, sealed, unreachable, logged-out,
                                                   denied or not-initialised
EOF
  exit 2
}

# An agent's job is refused before anything else, also a call with no or a wrong argument.
if v="$(agent_job)"; then
  die 3 "dcf-ssh-sign refuses to run inside an agent's job ($v is set): only the Operator signs certificates. Run it yourself in a plain terminal in the devcontainer"
fi

fix_denied() { say "the token may not $1: only the Operator's policy may sign (log in as the Operator with task openbao:login; an agent's or an AppRole's token is refused on purpose, and a server made before openbao 1.6.0 gets the policy from task openbao:ssh:ca:init)"; }
fix_no_ca() { say "the SSH CA is not set up at $camount in this server: the Operator makes it with task openbao:ssh:ca:init (against a server elsewhere, its owner does)"; }

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"
command -v jq >/dev/null 2>&1 || die 1 "jq is not installed: rebuild the devcontainer (the openbao Feature installs it)"
command -v ssh-keygen >/dev/null 2>&1 || die 1 "ssh-keygen is not installed (openssh-client)"
[ -z "${DCF_SECRET_AS:-}" ] || die 2 "DCF_SECRET_AS (logging in as an AppRole) is not supported in this version of the openbao Feature"

role_ok() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,63}$ ]]; }
principal_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$ ]]; }
key_id_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@:/+=-]{0,127}$ ]]; }

# dcf-secret status is the server's and the token's state: its exit code (10, 11, 12) and its one
# plain line on stderr are ours.
need_ready() {
  local rc=0
  "$dcf_secret" status >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
}

caps_of() { caps="$(bao token capabilities "$1" 2>/dev/null)"; }
can() { grep -Eq "(^|[^a-z])($1|root)([^a-z]|\$)" <<<"$caps"; } # <update|read|list>

# The CA's public key line, or nothing.
ca_pub() { bao read -field=public_key "$camount/config/ca" 2>/dev/null | head -n 1; }

# After the CA's public key could not be read: the server's state, the token, what the token may
# do, and then there is no CA. Always exits.
ca_missing() { # <what the call needed, for the denial line>
  need_ready
  caps_of "$camount/config/ca" || { say "no valid token (none, expired or revoked): log in with task openbao:login"; exit 12; }
  can read || { fix_denied "read the CA at $camount"; exit 13; }
  fix_no_ca
  exit 11
}

# The principal patterns of a role: the record task openbao:ssh:ca:role keeps (a comma separated
# list, in the KV store as ssh-ca/roles/<role>), else the role's own allowed_users. OpenBao
# matches allowed_users exactly (no wildcards), so a role with patterns has allowed_users "*" there
# and the patterns are checked here and by the verifier's cert-authority line.
role_patterns() { # <role> -> the list on stdout; fails when the role cannot be read
  local p json
  if p="$("$dcf_secret" get "ssh-ca/roles/$1" --field allowed 2>/dev/null)" && [ -n "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  json="$(bao read -format=json "$camount/roles/$1" 2>/dev/null)" || return 1
  jq -r '.data.allowed_users // ""' <<<"$json"
}

matches_any() { # <principal> <comma separated patterns>
  local p="$1" pat
  local -a pats
  IFS=, read -ra pats <<<"$2"
  for pat in "${pats[@]}"; do
    [[ "$pat" =~ ^[A-Za-z0-9._@*-]+$ ]] || continue # never a glob metacharacter of the shell
    # shellcheck disable=SC2254  # the pattern is meant to be one
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

cmd_sign() {
  local principals="" kid="" ttl="" role="$default_role" secs="" pub p rc out
  while [ $# -gt 0 ]; do
    case "$1" in
      --principals) [ $# -ge 2 ] || usage; principals="$2"; shift 2 ;;
      --principals=*) principals="${1#--principals=}"; shift ;;
      --key-id) [ $# -ge 2 ] || usage; kid="$2"; shift 2 ;;
      --key-id=*) kid="${1#--key-id=}"; shift ;;
      --ttl) [ $# -ge 2 ] || usage; ttl="$2"; shift 2 ;;
      --ttl=*) ttl="${1#--ttl=}"; shift ;;
      --role) [ $# -ge 2 ] || usage; role="$2"; shift 2 ;;
      --role=*) role="${1#--role=}"; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$principals" ] && [ -n "$kid" ] || usage
  role_ok "$role" || die 2 "'$role' is not a role name (lower case letters, digits, - and _, starting with a letter)"
  key_id_ok "$kid" || die 2 "'$kid' is not a usable key id (letters, digits and . _ @ : / + = -, at most 128)"
  local -a plist
  IFS=, read -ra plist <<<"$principals"
  [ "${#plist[@]}" -gt 0 ] || usage
  for p in "${plist[@]}"; do
    principal_ok "$p" || die 2 "'$p' is not a usable principal (letters, digits and . _ @ -, comma between principals)"
  done
  if [ -n "$ttl" ]; then
    secs="$(dur_secs "$ttl")" || die 2 "'$ttl' is not a duration (a number and s, m, h or d: 90d, 12h, 3600)"
  fi
  [ ! -t 0 ] || die 2 "the public key is read from stdin: pipe it in (never as an argument)"
  # The one thing taken from stdin: a public key. A private key is refused and never echoed.
  pub="$(cat)"
  if grep -q -- 'PRIVATE KEY' <<<"$pub"; then
    die 2 "what came on stdin is a private key: dcf-ssh-sign takes only a public key (ssh-ed25519 AAAA...) and never a private one"
  fi
  if [ "$(grep -c . <<<"$pub")" -ne 1 ] || [[ "$pub" != ssh-ed25519\ * ]] || ! printf '%s\n' "$pub" | ssh-keygen -l -f - >/dev/null 2>&1; then
    die 2 "stdin is not one ssh-ed25519 public key line (the role signs ed25519 keys only)"
  fi

  need_ready
  caps_of "$camount/sign/$role" || { say "no valid token (none, expired or revoked): log in with task openbao:login"; exit 12; }
  can update || { fix_denied "sign with role '$role' at $camount"; exit 13; }
  local pats
  if ! pats="$(role_patterns "$role")"; then
    [ -n "$(ca_pub)" ] || ca_missing
    die 2 "no signing role '$role' at $camount: dcf-ssh-sign roles lists them, task openbao:ssh:ca:role makes one"
  fi
  for p in "${plist[@]}"; do
    matches_any "$p" "$pats" || { say "the principal '$p' is outside the role '$role' (it allows: $pats): ask for a principal of that form, or sign with another role (dcf-ssh-sign roles), or have the Operator change the role with task openbao:ssh:ca:role"; exit 13; }
  done

  rc=0
  out="$(printf '%s\n' "$pub" | bao write -field=signed_key "$camount/sign/$role" public_key=- valid_principals="$principals" key_id="$kid" ${secs:+ttl="$secs"} 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    need_ready
    [ -n "$(ca_pub)" ] || ca_missing
    if [ -n "$secs" ]; then
      local maxs
      maxs="$(bao read -format=json "$camount/roles/$role" 2>/dev/null | jq -r '.data.max_ttl // empty' 2>/dev/null)"
      [[ "$maxs" =~ ^[0-9]+$ ]] && [ "$secs" -gt "$maxs" ] && die 2 "--ttl $ttl is longer than the role '$role' allows ($maxs seconds): ask for less, or have the Operator raise it with task openbao:ssh:ca:role MAX_TTL=<dur>"
    fi
    say "bao could not sign with role '$role' for a reason its signals do not explain:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  [[ "$out" == "ssh-ed25519-cert-v01@openssh"".com "* ]] || die 1 "bao answered, but not with an ssh-ed25519 certificate: nothing printed"
  printf '%s\n' "$out"
}

cmd_ca() {
  local fp=0 pub
  case "${1:-}" in
    '') ;;
    --fingerprint) fp=1; shift ;;
    *) usage ;;
  esac
  [ $# -le 1 ] || usage
  need_ready
  pub="$(ca_pub)"
  [ -n "$pub" ] || ca_missing
  if [ "$fp" -eq 1 ]; then
    printf '%s\n' "$pub" | ssh-keygen -l -f - || die 1 "ssh-keygen could not read the CA's public key"
  else
    printf '%s\n' "$pub"
  fi
}

cmd_roles() {
  local json
  [ $# -eq 0 ] || usage
  need_ready
  if json="$(bao list -format=json "$camount/roles" 2>/dev/null)"; then
    jq -r '.[]' <<<"$json"
    return 0
  fi
  caps_of "$camount/roles" || { say "no valid token (none, expired or revoked): log in with task openbao:login"; exit 12; }
  can list || { fix_denied "list the roles at $camount"; exit 13; }
  # An empty list is a failed call to bao: with the CA there, no role is made yet.
  [ -n "$(ca_pub)" ] || ca_missing
  return 0
}

cmd_status() {
  local word rc=0
  [ $# -eq 0 ] || usage
  # dcf-secret's word and its one line on stderr are the server's and the token's state.
  word="$("$dcf_secret" status)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$word"
    exit "$rc"
  fi
  if [ -z "$(ca_pub)" ]; then
    caps_of "$camount/config/ca" || true
    if can read; then
      echo not-initialised
      fix_no_ca
      exit 11
    fi
    echo denied
    fix_denied "read the CA at $camount"
    exit 13
  fi
  caps_of "$camount/sign/$default_role" || true
  if ! can update; then
    echo denied
    fix_denied "sign with role '$default_role' at $camount"
    exit 13
  fi
  echo ready
  exit 0
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  sign) cmd_sign "$@" ;;
  ca) cmd_ca "$@" ;;
  roles) cmd_roles "$@" ;;
  status) cmd_status "$@" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
