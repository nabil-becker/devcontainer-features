#!/usr/bin/env bash
# dcf-secret: the one way a Feature or a script of this collection asks OpenBao for a secret.
#
#   dcf-secret get <name> [--field <field>]     the value on stdout, nothing else
#   dcf-secret put <name> --field <field> [--replace]
#                                               the value on stdin (never an argument); keeps the
#                                               secret's other fields, --replace drops them
#   dcf-secret status [<name>]                  one word: ready | sealed | unreachable |
#                                               logged-out | denied | not-initialised
#   dcf-secret ttl                              the seconds the token has left (0: it does not
#                                               expire), so a caller can live no longer than it
#
# A name is logical (ssh/<key>, register/<principal>, token/<name>) and lives at
# <DCF_SECRET_MOUNT>/<name> (mount default: dcf, a KV v2 mount). A thin wrapper over the `bao`
# CLI (NFR-13): the exit code is worked out from bao's own signals (the exit code of `bao status`,
# the capabilities `bao token capabilities` reports), never from the words of an error message.
# Nothing is read from a file, a volume or the environment instead of the server: no fallback.
#
# Exit codes, the same for every caller, each with one plain line on stderr naming the fix:
#   0  done        10 the server is unreachable    11 the server is sealed (or not initialised)
#   12 no token, or it expired    13 the token may not use this name    14 no such secret
#   1  bao failed for a reason none of the signals explain (a put; bao's own message follows)
#   2  a wrong call (usage)
set -u

prog=dcf-secret
caps=""
mount="${DCF_SECRET_MOUNT:-dcf}"

say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}
usage() {
  cat >&2 <<'EOF'
usage: dcf-secret get <name> [--field <field>]    print the value (field default: value)
       dcf-secret put <name> --field <field> [--replace]
                                                  read the value from stdin; the secret's other
                                                  fields are kept unless --replace
       dcf-secret status [<name>]                 print ready, sealed, unreachable, logged-out,
                                                  denied or not-initialised
       dcf-secret ttl                             print the seconds the token has left (0: none)
EOF
  exit 2
}

# What to do about each failure, one line each. They name this Feature's tasks, which work in both
# modes: in server mode the Operator runs them; in client mode the server is somebody else's and
# the same tasks say so. env.sh (shared with the tasks) gives the BAO_ADDR default of server mode.
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
fix_unreachable() { say "the server at ${BAO_ADDR:-the default address (https://127.0.0.1:8200)} is unreachable: task openbao:server:status says whether it runs and how to start it (against a server elsewhere, check BAO_ADDR)"; }
fix_sealed() { say "the server is sealed: the Operator unseals it with task openbao:unseal (against a server elsewhere, its owner does, with bao operator unseal)"; }
fix_uninitialised() { say "the server is not initialised: the Operator initialises it with task openbao:init (against a server elsewhere, its owner does, with bao operator init)"; }
fix_login() { say "no valid token (none, expired or revoked): log in with task openbao:login (task openbao:logout first clears a dead one)"; }
fix_denied() { say "the token may not $1 '$2' at $mount: its policy has to allow it (ask the server's owner)"; }

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"

[ -z "${DCF_SECRET_AS:-}" ] || die 2 "DCF_SECRET_AS (logging in as an AppRole) is not supported in this version of the openbao Feature"

name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; }
field_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; }

# Where in the server the name lives (KV v2 keeps the data under <mount>/data/).
api_path() { echo "$mount/data/$1"; }

# `bao status` is the server's own answer: exit 0 unsealed, 2 sealed (an uninitialised server is
# sealed too, and its JSON says initialized false), anything else could not ask. Sets st_rc/st_json.
server_state() {
  st_json="$(bao status -format=json 2>/dev/null)"
  st_rc=$?
}
state_exit() { # exit with the line for a server that is not ready; no-op when it is
  # $1 = word: also print the status word on stdout (dcf-secret status)
  case "$st_rc" in
    0) return 0 ;;
    2)
      if grep -Eq '"initialized"[[:space:]]*:[[:space:]]*false' <<<"$st_json"; then
        [ "${1:-}" = word ] && echo not-initialised
        fix_uninitialised
      else
        [ "${1:-}" = word ] && echo sealed
        fix_sealed
      fi
      exit 11
      ;;
    *)
      [ "${1:-}" = word ] && echo unreachable
      fix_unreachable
      exit 10
      ;;
  esac
}

# Capabilities of the current token on a path (`bao token capabilities`): a failure means the call
# was refused, so there is no usable token (the default policy lets every valid token ask).
caps_of() { # <path> -> sets caps, returns bao's exit code
  caps="$(bao token capabilities "$1" 2>/dev/null)"
}
can() { # <read|write|patch|create> : does $caps allow it (write: create or update)
  local words
  case "$1" in
    read) words='read' ;;
    patch) words='patch' ;;
    create) words='create' ;;
    *) words='create|update' ;;
  esac
  grep -Eq "(^|[^a-z])($words|root)([^a-z]|\$)" <<<"$caps"
}

# After a failed call: the server's state, then the token, then what the token may do.
# $1 read|write, $2 name, $3 bao's own stderr. Always exits.
diagnose() {
  server_state
  state_exit
  caps_of "$(api_path "$2")" || { fix_login; exit 12; }
  can "$1" || { fix_denied "$1" "$2"; exit 13; }
  if [ "$1" = read ]; then
    die 14 "no such secret (or field) '$2' at $mount: write it with dcf-secret put"
  fi
  say "bao could not write '$2' at $mount for a reason its signals do not explain:"
  printf '%s\n' "$3" >&2
  exit 1
}

cmd_get() {
  local name="" field=value
  while [ $# -gt 0 ]; do
    case "$1" in
      --field) [ $# -ge 2 ] || usage; field="$2"; shift 2 ;;
      --field=*) field="${1#--field=}"; shift ;;
      -*) usage ;;
      *) [ -z "$name" ] || usage; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || usage
  name_ok "$name" || die 2 "'$name' is not a secret name (letters, digits, . _ - and / between parts)"
  field_ok "$field" || die 2 "'$field' is not a field name"

  # The value goes straight to our stdout (fd 3 is the original one); only bao's stderr is kept.
  local err rc
  { err="$(bao kv get -mount="$mount" -field="$field" "$name" 2>&1 1>&3 3>&-)"; rc=$?; } 3>&1
  [ "$rc" -eq 0 ] && exit 0
  diagnose read "$name" "$err"
}

cmd_put() {
  local name="" field="" replace=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --field) [ $# -ge 2 ] || usage; field="$2"; shift 2 ;;
      --field=*) field="${1#--field=}"; shift ;;
      --replace) replace=1; shift ;;
      -*) usage ;;
      *) [ -z "$name" ] || usage; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] && [ -n "$field" ] || usage
  name_ok "$name" || die 2 "'$name' is not a secret name (letters, digits, . _ - and / between parts)"
  field_ok "$field" || die 2 "'$field' is not a field name"
  [ ! -t 0 ] || die 2 "the value is read from stdin: pipe it in (never as an argument)"

  # The value is held in memory only (never a file, never an argument) because a merge may need
  # to offer it to bao twice. `x` keeps trailing newlines through the command substitution.
  local value err rc
  value="$(cat; printf x)"
  value="${value%x}"
  # shellcheck disable=SC2069  # stderr is wanted, bao's stdout (a table of metadata) is not
  send() { printf '%s' "$value" | bao kv "$@" 2>&1 >/dev/null; }

  if [ "$replace" -eq 1 ]; then
    # --replace: the secret becomes this one field (bao kv put).
    err="$(send put -mount="$mount" "$name" "$field=-")"
    rc=$?
    [ "$rc" -eq 0 ] && exit 0
    diagnose write "$name" "$err"
  fi

  # The default merges: patch writes this field and keeps the others. A patch fails on a secret
  # that does not exist yet, and on a token without the patch capability: the capabilities say
  # which, never the words of the error.
  err="$(send patch -mount="$mount" "$name" "$field=-")"
  rc=$?
  [ "$rc" -eq 0 ] && exit 0
  server_state
  state_exit
  caps_of "$(api_path "$name")" || { fix_login; exit 12; }
  if ! can patch; then
    say "the token may not patch '$name' at $mount, so a field cannot be merged: its policy needs the patch capability, or write the whole secret with --replace"
    exit 13
  fi
  if ! can create; then
    say "the token may not create '$name' at $mount (it does not exist yet, so there is nothing to patch): its policy has to allow it (ask the server's owner)"
    exit 13
  fi
  # Create it, only if it is still absent (-cas=0): a secret that appeared since the patch makes
  # this fail, and then one more patch merges into it.
  err="$(send put -cas=0 -mount="$mount" "$name" "$field=-")"
  rc=$?
  [ "$rc" -eq 0 ] && exit 0
  err="$(send patch -mount="$mount" "$name" "$field=-")"
  rc=$?
  [ "$rc" -eq 0 ] && exit 0
  say "bao could not write '$name' at $mount for a reason its signals do not explain:"
  printf '%s\n' "$err" >&2
  exit 1
}

cmd_status() {
  local name="${1:-}"
  [ $# -le 1 ] || usage
  [ -z "$name" ] || name_ok "$name" || die 2 "'$name' is not a secret name"
  server_state
  state_exit word
  if ! bao token lookup >/dev/null 2>&1; then
    echo logged-out
    fix_login
    exit 12
  fi
  if [ -n "$name" ]; then
    caps_of "$(api_path "$name")" || true
    if ! can read; then
      echo denied
      fix_denied read "$name"
      exit 13
    fi
  fi
  echo ready
  exit 0
}

# The token's remaining lifetime, from `bao token lookup`'s JSON (the "ttl" field, in seconds;
# 0 for a token that does not expire, such as a root token). ssh-agent's key:load lives no longer.
cmd_ttl() {
  local json ttl
  [ $# -eq 0 ] || usage
  server_state
  state_exit
  json="$(bao token lookup -format=json 2>/dev/null)" || { fix_login; exit 12; }
  ttl="$(sed -n 's/.*"ttl"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$json" | head -n 1)"
  [ -n "$ttl" ] || die 1 "bao token lookup gave no ttl for this token"
  echo "$ttl"
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  get) cmd_get "$@" ;;
  put) cmd_put "$@" ;;
  status) cmd_status "$@" ;;
  ttl) cmd_ttl "$@" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
