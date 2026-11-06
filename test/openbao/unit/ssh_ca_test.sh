#!/usr/bin/env bash
# Docker-free tests of the openbao Feature's SSH certificate authority: dcf-ssh-sign
# (src/openbao/dcf-ssh-sign.sh, with the real dcf-secret) and the three tasks that make the CA
# (openbao-server ssh-ca-init, ssh-ca-role and ssh-ca-import) against a stub `bao` that keeps a
# small state in a temp folder (mounts, the CA's public key, the roles as written, the KV records)
# and logs every call with its token. That the real bao answers as the stub plays, and that a
# certificate really verifies with ssh-keygen -Y verify, is the container test
# test/openbao/ssh_ca.sh (CI). Covered:
#  - dcf-ssh-sign: refused inside an agent's job (exit 3, for every subcommand, bao never called);
#    sign (the public key on stdin and in no argument, the certificate alone on stdout, the role
#    path, the principals, the key id and a ttl in seconds, the default role and --role), each exit
#    code with its one line (10 unreachable, 11 sealed, not initialised or no CA, 12 no token,
#    13 a token that may not sign and a principal outside the role, 2 for a wrong call, an unknown
#    role, a private key or an RSA key on stdin, 1 for a failure no signal explains), ca,
#    ca --fingerprint, roles (one per line, nothing else), status in every state, no fallback to a
#    file or the environment;
#  - the tasks: the guard (agent's job), what is refused before bao is asked (names, patterns,
#    durations, a mount that is the KV mount), init in client mode (the ssh mount, the CA generated
#    by the server, the role's JSON: ed25519 only, user certificates only, host certificates off, no
#    extensions, no critical options, the lifetimes, the patterns in the KV record), a second run
#    changing nothing, ALLOWED, TTL and MAX_TTL, a second role with the same defaults, the role
#    task without a CA, import (the key on stdin only, never an argument, never in a file, an
#    existing CA never replaced, a key that is not ed25519 or not a private key refused), and in
#    server mode the refusal without a terminal (nothing changed) and the Operator's policy
#    carrying the sign path while no other policy this Feature writes does.
# Part of `task lint` (`task test:openbao-unit`). Needs jq and ssh-keygen.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
sign_script="${SIGN_SCRIPT:-$root/src/openbao/dcf-ssh-sign.sh}"
server_script="${SERVER_SCRIPT:-$root/src/openbao/openbao-server.sh}"

T="$(mktemp -d /tmp/obsshca.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/feat-client" "$T/feat-server" "$T/st"
for m in client server; do
  cp "$root/src/openbao/env.sh" "$root/src/openbao/openbao-lib.sh" "$T/feat-$m/"
  printf 'MODE=%s\n' "$m" > "$T/feat-$m/options.env"
done
install -m 0755 "$sign_script" "$T/bin/dcf-ssh-sign"
install -m 0755 "$server_script" "$T/bin/openbao-server"
install -m 0755 "$root/src/openbao/dcf-secret.sh" "$T/bin/dcf-secret"
LOG="$T/calls.log"
ST="$T/st"

ssh-keygen -q -t ed25519 -N '' -C ca -f "$T/ca"
ssh-keygen -q -t ed25519 -N '' -C relay -f "$T/key"
ssh-keygen -q -t rsa -b 2048 -N '' -C rsa -f "$T/rsa"
CA_PUB="$(awk '{print $1" "$2}' "$T/ca.pub")"
printf '%s\n' "$CA_PUB" > "$T/ca.stub.pub" # what the server's config/ca returns: no comment
CA_FP="$(ssh-keygen -lf "$T/ca.pub" | awk '{print $2}')"
GUID=11111111-2222-3333-4444-555555555555

cat > "$T/bin/bao" <<'STUB'
#!/usr/bin/env bash
# Stub bao for the SSH CA: $STUB_STATE keeps mounts, ca.pub, role.<name>.json, kv.<name>, sign.*
echo "$*" >> "$STUB_LOG"
echo "$1 $2 token=${BAO_TOKEN-unset}" >> "$STUB_STATE/tokens.log"
S="$STUB_STATE"
st="$(cat "$S/state" 2>/dev/null || echo unsealed)"
case "$1 $2" in
  "status -format=json")
    case "$st" in
      uninit) echo '{"initialized": false, "sealed": true}'; exit 2 ;;
      sealed) echo '{"initialized": true, "sealed": true}'; exit 2 ;;
      down) exit 1 ;;
      *) echo '{"initialized": true, "sealed": false}'; exit 0 ;;
    esac ;;
  "token lookup") [ -n "${BAO_TOKEN:-}" ] && [ "${BAO_TOKEN}" != s.DEAD ]; exit $? ;;
  "token capabilities")
    [ -n "${BAO_TOKEN:-}" ] && [ "${BAO_TOKEN}" != s.DEAD ] || { echo "permission denied" >&2; exit 2; }
    [ "$BAO_TOKEN" = s.OPERATOR ] || { echo deny; exit 0; }
    case "$3" in */sign/*) echo update ;; */config/ca) echo read ;; */roles) echo list ;; *) echo deny ;; esac
    exit 0 ;;
  "policy write") cat > "$S/policy.$3"; exit 0 ;;
esac
# everything below is the token's to use: only the Operator's token may read or write the CA
if [ "${BAO_TOKEN:-}" = s.SCRIBE ]; then echo "Error: permission denied" >&2; exit 2; fi
case "$1" in
  read)
    case "$2" in
      -format=json)
        case "$3" in
          sys/mounts/*) m="${3#sys/mounts/}"; grep -qxF "$m" "$S/mounts" 2>/dev/null || exit 2; printf '{"data": {"type": "%s"}}\n' "$(cat "$S/mount-type.$m" 2>/dev/null || echo ssh)"; exit 0 ;;
          */roles/*) r="${3##*/}"; [ -f "$S/role.$r.json" ] || { echo "No value found at $3" >&2; exit 2; }
            printf '{"data": %s}\n' "$(cat "$S/role.$r.json")"; exit 0 ;;
        esac ;;
      -field=public_key) [ -s "$S/ca.pub" ] || { echo "No value found" >&2; exit 2; }; cat "$S/ca.pub"; echo; exit 0 ;;
    esac ;;
  secrets) [ "$2" = enable ] && { echo "${3#-path=}" >> "$S/mounts"; echo "$4" > "$S/mount-type.${3#-path=}"; exit 0; } ;;
  write)
    case "$*" in
      *"/config/ca generate_signing_key=true"*) cp "$STUB_CA_PUB" "$S/ca.pub"; exit 0 ;;
      *"/config/ca private_key=- public_key="*)
        cat > "$S/import.stdin"
        for a in "$@"; do case "$a" in public_key=*) printf '%s' "${a#public_key=}" > "$S/ca.pub" ;; esac; done
        exit 0 ;;
      *"/roles/"*" -") r="${2##*/}"; cat > "$S/role.$r.json"; exit 0 ;;
      *"-field=signed_key"*"/sign/"*)
        cat > "$S/sign.stdin"
        case "${STUB_SIGN:-ok}" in
          ok) echo "ssh-ed25519-cert-v01@openssh"".com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t stub"; exit 0 ;;
          *) echo "Error writing data: stub failure" >&2; exit 2 ;;
        esac ;;
    esac ;;
  list)
    shift; [ "${1:-}" = -format=json ] && shift
    ls "$S"/role.*.json >/dev/null 2>&1 || { echo "No value found at $1" >&2; exit 2; }
    for f in "$S"/role.*.json; do b="${f##*/role.}"; echo "${b%.json}"; done | jq -R . | jq -s .
    exit 0 ;;
  kv)
    case "$2" in
      put) printf '%s\n' "$*" > "$S/kvput.last"
        name="$(printf '%s\n' "$@" | grep '^ssh-ca/roles/')"; r="${name##*/}"
        for a in "$@"; do case "$a" in allowed=*) printf '%s' "${a#allowed=}" > "$S/kv.$r" ;; esac; done
        exit 0 ;;
      get)
        name="${!#}"; r="${name##*/}"
        [ -f "$S/kv.$r" ] || { echo "No value found" >&2; exit 2; }
        cat "$S/kv.$r"; exit 0 ;;
    esac ;;
esac
echo "stub bao: unexpected call: $*" >&2
exit 99
STUB
chmod +x "$T/bin/bao"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
lacks() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}
reset() { # a server with nothing set up
  rm -rf "${ST:?}"/*
  : > "$LOG"
  echo unsealed > "$ST/state"
}
# setup_ca: the state init leaves (the mount, the CA, the default role and a second one)
setup_ca() {
  reset
  run_srv client OPENBAO_TASK_NAME= -- ssh-ca-init >/dev/null
  run_srv client OPENBAO_TASK_NAME=register OPENBAO_TASK_ALLOWED='writer@*' OPENBAO_TASK_TTL=30d OPENBAO_TASK_MAX_TTL=90d -- ssh-ca-role >/dev/null
  : > "$LOG"
}

# runs [VAR=value ...] -- <args>: dcf-ssh-sign; INPUT is its stdin (a file); the token is BAO_TOKEN.
INPUT=""
runs() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG"
  out="$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" STUB_LOG="$LOG" STUB_STATE="$ST" STUB_CA_PUB="$T/ca.stub.pub" \
    OPENBAO_FEATURE_DIR="$T/feat-client" OPENBAO_STATE_DIR="$T/state" BAO_TOKEN=s.OPERATOR DCF_SECRET_X="from-the-environment" \
    "${envs[@]}" bash "$T/bin/dcf-ssh-sign" "$@" 2>"$T/err" < "${INPUT:-/dev/null}")"
  rc=$?
  err="$(cat "$T/err")"
  INPUT=""
}
# run_srv <client|server> [VAR=value ...] -- <openbao-server args>; stdin is INPUT (a file)
run_srv() {
  local mode="$1"
  shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG"
  out="$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" STUB_LOG="$LOG" STUB_STATE="$ST" STUB_CA_PUB="$T/ca.stub.pub" \
    OPENBAO_FEATURE_DIR="$T/feat-$mode" OPENBAO_STATE_DIR="$T/state" BAO_TOKEN=s.ROOTISH "${envs[@]}" \
    bash "$T/bin/openbao-server" "$@" 2>"$T/err" < "${INPUT:-/dev/null}")"
  rc=$?
  err="$(cat "$T/err")"
  INPUT=""
}
calls() { cat "$LOG"; }

# ------------------------------------------------------------------ dcf-ssh-sign ----
setup_ca
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id "relay-$GUID"
check "sign: exit 0" 0 "$rc"
check "sign: the certificate alone on stdout, one line" "ssh-ed25519-cert-v01@openssh"".com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t stub" "$out"
check "sign: nothing on stderr" "" "$err"
has "sign: the default role's sign path, the principals and the key id" "write -field=signed_key ssh-ca/sign/default public_key=- valid_principals=relay@$GUID key_id=relay-$GUID" "$(calls)"
lacks "sign: the public key is in no argument" "AAAAC3" "$(calls)"
check "sign: the public key went on bao's stdin" "$(cat "$T/key.pub")" "$(cat "$ST/sign.stdin")"
lacks "sign: no ttl unless asked" "ttl=" "$(calls)"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID,fed-$GUID" --key-id k --ttl 12h
has "sign: two principals, comma separated" "valid_principals=relay@$GUID,fed-$GUID" "$(calls)"
has "sign: a ttl in seconds" "ttl=43200" "$(calls)"
INPUT="$T/key.pub" runs -- sign --principals "writer@h-t" --key-id k --role register
check "sign --role register: exit 0" 0 "$rc"
has "sign --role: that role's path" "/sign/register " "$(calls)"
INPUT="$T/key.pub" runs -- sign --principals="fed-$GUID" --key-id=k --role=default --ttl=90d
has "sign: the = forms" "ttl=7776000" "$(calls)"
INPUT="$T/key.pub" runs DCF_SSH_CA_ROLE=register -- sign --principals "writer@h-t" --key-id k
check "DCF_SSH_CA_ROLE names the default role" "/sign/register " "$(grep -o '/sign/[a-z]* ' "$LOG" | head -1)"

# a principal outside the role: 13, nothing signed
INPUT="$T/key.pub" runs -- sign --principals "evil" --key-id k
check "a principal outside the role: exit 13" 13 "$rc"
check "13: nothing on stdout" "" "$out"
has "13: the line names the role and what it allows" "outside the role 'default' (it allows: relay@*,fed-*)" "$err"
check "13: bao was never asked to sign" 0 "$(grep -c 'signed_key' "$LOG")"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k --role register
check "a principal only another role allows: exit 13" 13 "$rc"
INPUT="$T/key.pub" runs -- sign --principals "writer@h-t" --key-id k
check "and the other way round (register's principal under default): exit 13" 13 "$rc"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID,evil" --key-id k
check "one good and one bad principal: exit 13, nothing signed" "13:0" "$rc:$(grep -c signed_key "$LOG")"
INPUT="$T/key.pub" runs BAO_TOKEN=s.SCRIBE -- sign --principals "relay@$GUID" --key-id k
check "a token that may not sign (an AppRole's): exit 13" 13 "$rc"
has "13: says only the Operator's policy may" "only the Operator's policy may sign" "$err"
check "13: bao was never asked to sign" 0 "$(grep -c 'signed_key' "$LOG")"
INPUT="$T/key.pub" runs BAO_TOKEN= -- sign --principals "relay@$GUID" --key-id k
check "no token: exit 12" 12 "$rc"
has "12: names the login task" "task openbao:login" "$err"
INPUT="$T/key.pub" runs BAO_TOKEN=s.DEAD -- sign --principals "relay@$GUID" --key-id k
check "an expired or revoked token: exit 12" 12 "$rc"
echo sealed > "$ST/state"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k
check "sealed: exit 11" 11 "$rc"
has "11: names the unseal task" "task openbao:unseal" "$err"
echo uninit > "$ST/state"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k
check "not initialised: exit 11" 11 "$rc"
echo down > "$ST/state"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k
check "unreachable: exit 10" 10 "$rc"
echo unsealed > "$ST/state"
rm -f "$ST/ca.pub"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k --role nope
check "an unknown role with no CA: exit 11" 11 "$rc"
has "11: names the CA task" "task openbao:ssh:ca:init" "$err"
setup_ca
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k --role nope
check "an unknown role: exit 2" 2 "$rc"
has "2: says how to list and make roles" "dcf-ssh-sign roles" "$err"
INPUT="$T/key.pub" runs STUB_SIGN=fail -- sign --principals "relay@$GUID" --key-id k
check "a failure no signal explains: exit 1" 1 "$rc"
has "1: bao's own words follow" "stub failure" "$err"
check "1: nothing on stdout" "" "$out"
INPUT="$T/key.pub" runs STUB_SIGN=fail -- sign --principals "relay@$GUID" --key-id k --ttl 9999d
check "a ttl above the role's maximum: exit 2 (worked out from the role's max_ttl)" 2 "$rc"
INPUT="$T/key" runs -- sign --principals "relay@$GUID" --key-id k
check "a private key on stdin: exit 2" 2 "$rc"
has "2: says it takes only a public key" "only a public key" "$err"
check "2: bao never called" 0 "$(wc -l < "$LOG")"
INPUT="$T/rsa.pub" runs -- sign --principals "relay@$GUID" --key-id k
check "an RSA public key: exit 2 (ed25519 only)" 2 "$rc"
check "no stdin at all (a terminal or nothing): exit 2" 2 "$( INPUT=/dev/null runs -- sign --principals "relay@$GUID" --key-id k; echo $rc)"
for bad in "relay@a b" 'a;b' '*' '-x'; do
  INPUT="$T/key.pub" runs -- sign --principals "$bad" --key-id k
  check "an unusable principal '$bad': exit 2" 2 "$rc"
done
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id 'a b'
check "an unusable key id: exit 2" 2 "$rc"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k --ttl 5x
check "a bad ttl: exit 2" 2 "$rc"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID" --key-id k --role Bad
check "a bad role name: exit 2" 2 "$rc"
INPUT="$T/key.pub" runs -- sign --key-id k
check "no principals: exit 2" 2 "$rc"
INPUT="$T/key.pub" runs -- sign --principals "relay@$GUID"
check "no key id: exit 2" 2 "$rc"
runs -- bogus
check "an unknown command: exit 2" 2 "$rc"
runs --
check "no command: exit 2" 2 "$rc"
runs DCF_SECRET_AS=x -- ca
check "DCF_SECRET_AS is refused" 2 "$rc"

# ca, fingerprint, roles, status
runs -- ca
check "ca: the public key, one line" "$CA_PUB" "$out"
check "ca: exit 0" 0 "$rc"
runs -- ca --fingerprint
check "ca --fingerprint: as ssh-keygen -lf prints it" "$(printf '%s\n' "$CA_PUB" | ssh-keygen -lf -)" "$out"
has "ca --fingerprint: SHA256" "SHA256:$(printf '%s' "$CA_FP" | sed 's/^SHA256://')" "$out"
runs -- ca --bogus
check "ca with another argument: exit 2" 2 "$rc"
runs BAO_TOKEN=s.SCRIBE -- ca
check "ca with a token that may not read it: exit 13" 13 "$rc"
runs BAO_TOKEN= -- ca
check "ca with no token: exit 12" 12 "$rc"
rm -f "$ST/ca.pub"
runs -- ca
check "ca with no CA: exit 11" 11 "$rc"
check "11: nothing on stdout" "" "$out"
setup_ca
runs -- roles
check "roles: one per line, nothing else" "default
register" "$out"
runs BAO_TOKEN=s.SCRIBE -- roles
check "roles with a token that may not list: exit 13" 13 "$rc"
runs -- status
check "status: ready" "ready:0" "$out:$rc"
runs BAO_TOKEN=s.SCRIBE -- status
check "status with an AppRole's token: denied, exit 13" "denied:13" "$out:$rc"
runs BAO_TOKEN= -- status
check "status with no token: logged-out, exit 12" "logged-out:12" "$out:$rc"
echo sealed > "$ST/state"; runs -- status
check "status sealed: exit 11" "sealed:11" "$out:$rc"
echo down > "$ST/state"; runs -- status
check "status unreachable: exit 10" "unreachable:10" "$out:$rc"
echo unsealed > "$ST/state"; rm -f "$ST/ca.pub"; runs -- status
check "status with no CA: not-initialised, exit 11" "not-initialised:11" "$out:$rc"
setup_ca

# an agent's job: refused for every subcommand, bao never called
for v in DEVHOST_JOB_CHILD CLAUDECODE MY_AGENT; do
  for c in "sign --principals relay@$GUID --key-id k" "ca" "ca --fingerprint" "roles" "status" ""; do
    # shellcheck disable=SC2086  # the words of a command
    INPUT="$T/key.pub" runs "$v=1" OPENBAO_AGENT_JOB_VARS=MY_AGENT -- $c
    check "inside an agent's job ($v): '${c:-no command}' is refused, exit 3, bao never called" "3:0" "$rc:$(wc -l < "$LOG")"
  done
done
has "the refusal names the variable and says only the Operator signs" "CLAUDECODE is set): only the Operator signs" "$(INPUT="$T/key.pub" runs CLAUDECODE=1 -- ca; echo "$err")"
check "no certificate came out of a refused sign" "" "$(INPUT="$T/key.pub" runs CLAUDECODE=1 -- sign --principals "relay@$GUID" --key-id k; echo "$out")"

# no fallback: a file in the state folder or the environment never stands in for the server
mkdir -p "$T/state"
printf 'ssh-ed25519 AAAAfile\n' > "$T/state/ca.pub"
rm -f "$ST/ca.pub"
runs DCF_SSH_CA_PUBLIC_KEY=ssh-ed25519\ AAAAenv -- ca
check "no CA in the server: exit 11, nothing from a file or the environment" "11:" "$rc:$out"
setup_ca

# ------------------------------------------------------------- the tasks: init ----
reset
run_srv client -- ssh-ca-init
check "init (client mode, a token that may): exit 0" 0 "$rc"
has "init: enabled the ssh engine at the default mount" "secrets enable -path=ssh-ca ssh" "$(calls)"
has "init: the CA is generated by the server, ed25519" "write ssh-ca/config/ca generate_signing_key=true key_type=ssh-ed25519" "$(calls)"
has "init: says the CA's fingerprint" "$CA_FP" "$err"
has "init: says to compare it out of band" "out of band" "$err"
role="$(cat "$ST/role.default.json")"
check "init: the role is a CA role" true "$(jq -r '.key_type == "ca"' <<<"$role")"
check "init: user certificates on" true "$(jq -r '.allow_user_certificates' <<<"$role")"
check "init: host certificates off" false "$(jq -r '.allow_host_certificates' <<<"$role")"
check "init: ed25519 only" '["ssh-ed25519"]' "$(jq -c '.allowed_user_key_lengths | keys' <<<"$role")"
check "init: no extensions permitted" '""' "$(jq -c '.allowed_extensions' <<<"$role")"
check "init: no critical options permitted" '""' "$(jq -c '.allowed_critical_options' <<<"$role")"
check "init: no default extensions or critical options" '{}:{}' "$(jq -c '.default_extensions' <<<"$role"):$(jq -c '.default_critical_options' <<<"$role")"
check "init: no empty principals" false "$(jq -r '.allow_empty_principals' <<<"$role")"
check "init: default_ttl 2160h (90 days)" 7776000 "$(jq -r '.ttl' <<<"$role")"
check "init: max_ttl the same unless asked" 7776000 "$(jq -r '.max_ttl' <<<"$role")"
check "init: the server's allowed_users is * (OpenBao has no wildcard matching; the patterns are in the KV record)" '*' "$(jq -r '.allowed_users' <<<"$role")"
check "init: the patterns of AOF's two principal forms in the KV record" 'relay@*,fed-*' "$(cat "$ST/kv.default")"
has "init: the record is in the KV mount, under ssh-ca/roles/" "kv put -mount=dcf ssh-ca/roles/default" "$(calls)"
has "init (client mode): prints the policy paths the server's owner adds" 'path "ssh-ca/sign/*"' "$err"
check "init (client mode): writes no policy" 0 "$(grep -c '^policy write' "$LOG")"
# idempotent
: > "$LOG"; : > "$ST/tokens.log"
run_srv client -- ssh-ca-init
check "init again: exit 0" 0 "$rc"
has "init again: reports the existing CA" "already there" "$err"
has "init again: says nothing changed" "nothing changed" "$err"
check "init again: no write, no enable, no policy" 0 "$(grep -cE '^(write|secrets enable|policy write|kv put)' "$LOG")"
# options
reset
run_srv client OPENBAO_TASK_ALLOWED='relay@*' OPENBAO_TASK_TTL=1h OPENBAO_TASK_MAX_TTL=2h OPENBAO_TASK_MOUNT=pki-ssh -- ssh-ca-init
check "init with ALLOWED, TTL, MAX_TTL and MOUNT: exit 0" 0 "$rc"
has "the mount named by MOUNT" "secrets enable -path=pki-ssh ssh" "$(calls)"
check "TTL and MAX_TTL" '3600:7200' "$(jq -r '"\(.ttl):\(.max_ttl)"' "$ST/role.default.json")"
check "ALLOWED in the record" 'relay@*' "$(cat "$ST/kv.default")"
reset
run_srv client DCF_SSH_CA_MOUNT=other DCF_SSH_CA_ROLE=relay -- ssh-ca-init
has "DCF_SSH_CA_MOUNT names the mount" "secrets enable -path=other ssh" "$(calls)"
check "DCF_SSH_CA_ROLE names the default role" true "$([ -f "$ST/role.relay.json" ] && echo true || echo false)"
reset
run_srv client OPENBAO_TASK_ALLOWED='relay@aaa,fed-bbb' -- ssh-ca-init
check "a role of exact names: the server enforces them itself (allowed_users is the list)" 'relay@aaa,fed-bbb' "$(jq -r '.allowed_users' "$ST/role.default.json")"
# a mount of another type is never taken over
reset
echo ssh-ca > "$ST/mounts"; echo kv > "$ST/mount-type.ssh-ca"
run_srv client -- ssh-ca-init
check "a mount of another type: refused, exit 1" 1 "$rc"
check "nothing written to it" 0 "$(grep -cE '^write' "$LOG")"

# refusals before bao is asked
reset
run_srv client "OPENBAO_TASK_ALLOWED=x y" -- ssh-ca-init
check "ALLOWED with a space: exit 2" 2 "$rc"
run_srv client "OPENBAO_TASK_ALLOWED=rel;ay" -- ssh-ca-init
check "ALLOWED with a ; : exit 2" 2 "$rc"
run_srv client "OPENBAO_TASK_ALLOWED=a,,b" -- ssh-ca-init
check "ALLOWED with an empty pattern: exit 2" 2 "$rc"
run_srv client OPENBAO_TASK_TTL=5x -- ssh-ca-init
check "TTL that is no duration: exit 2" 2 "$rc"
run_srv client OPENBAO_TASK_TTL=2h OPENBAO_TASK_MAX_TTL=1h -- ssh-ca-init
check "MAX_TTL below TTL: exit 2" 2 "$rc"
run_srv client OPENBAO_TASK_MOUNT=dcf -- ssh-ca-init
check "MOUNT that is the KV mount: exit 2" 2 "$rc"
run_srv client OPENBAO_TASK_MOUNT=a/b -- ssh-ca-init
check "MOUNT with a slash: exit 2" 2 "$rc"
check "none of them called bao" 0 "$(wc -l < "$LOG")"
for v in DEVHOST_JOB_CHILD CLAUDECODE MY_AGENT; do
  for c in ssh-ca-init ssh-ca-role ssh-ca-import; do
    INPUT="$T/ca" run_srv client "$v=1" OPENBAO_AGENT_JOB_VARS=MY_AGENT OPENBAO_TASK_NAME=r OPENBAO_TASK_ALLOWED=x@* -- "$c"
    check "$c inside an agent's job ($v): refused, exit 3, bao never called" "3:0" "$rc:$(wc -l < "$LOG")"
  done
done
has "the refusal is the Feature's own line" "refuses to run inside an agent's job" "$err"
echo down > "$ST/state"
run_srv client -- ssh-ca-init
check "init with the server unreachable: exit 10 (dcf-secret's)" 10 "$rc"
echo sealed > "$ST/state"
run_srv client -- ssh-ca-init
check "init with the server sealed: exit 11" 11 "$rc"
echo unsealed > "$ST/state"
run_srv client BAO_TOKEN= -- ssh-ca-init
check "init with no token: exit 12" 12 "$rc"
check "none of those wrote anything" 0 "$(grep -cE '^(write|secrets|policy|kv put)' "$LOG")"

# ------------------------------------------------------------- the tasks: role ----
reset
run_srv client OPENBAO_TASK_NAME=register OPENBAO_TASK_ALLOWED='writer@*' -- ssh-ca-role
check "role with no CA yet: exit 1" 1 "$rc"
has "role with no CA: names the init task" "task openbao:ssh:ca:init" "$err"
check "role with no CA: no role written" 0 "$(find "$ST" -name 'role.*.json' | wc -l)"
run_srv client -- ssh-ca-role
check "role with no NAME and ALLOWED: exit 2" 2 "$rc"
run_srv client OPENBAO_TASK_NAME=Bad OPENBAO_TASK_ALLOWED=x@ -- ssh-ca-role
check "role with a bad name: exit 2" 2 "$rc"
reset
run_srv client -- ssh-ca-init
run_srv client OPENBAO_TASK_NAME=register OPENBAO_TASK_ALLOWED='writer@*' OPENBAO_TASK_TTL=30d OPENBAO_TASK_MAX_TTL=90d -- ssh-ca-role
check "role register: exit 0" 0 "$rc"
rj="$ST/role.register.json"
check "role register: same refusals as the default: user certs, no host certs, ed25519 only" "true:false:[\"ssh-ed25519\"]" "$(jq -r '"\(.allow_user_certificates):\(.allow_host_certificates):\(.allowed_user_key_lengths | keys | tojson)"' "$rj")"
check "role register: no extensions, no critical options" '"":"":{}:{}' "$(jq -r '[(.allowed_extensions|tojson), (.allowed_critical_options|tojson), (.default_extensions|tojson), (.default_critical_options|tojson)] | join(":")' "$rj")"
check "role register: its patterns and lifetimes" "writer@*:2592000:7776000" "$(cat "$ST/kv.register"):$(jq -r '"\(.ttl):\(.max_ttl)"' "$ST/role.register.json")"
check "role register: the default role is untouched" 'relay@*,fed-*' "$(cat "$ST/kv.default")"
check "role register: the Operator's policy is not written in client mode" 0 "$(grep -c '^policy write' "$LOG")"
run_srv client OPENBAO_TASK_NAME=register OPENBAO_TASK_ALLOWED='writer@*' OPENBAO_TASK_TTL=30d OPENBAO_TASK_MAX_TTL=90d -- ssh-ca-role
has "role again as asked: nothing changed" "already as asked: nothing changed" "$err"
check "role again: no write" 0 "$(grep -cE '^(write|kv put)' "$LOG")"
run_srv client OPENBAO_TASK_NAME=register OPENBAO_TASK_ALLOWED='writer@*,agent@*' -- ssh-ca-role
check "role updated (another pattern and ttl): exit 0" 0 "$rc"
check "role updated: the new patterns" "writer@*,agent@*" "$(cat "$ST/kv.register")"
run_srv client OPENBAO_TASK_NAME=default OPENBAO_TASK_ALLOWED='relay@*' -- ssh-ca-role
check "the default role is a role like any: ca:role changes it" 'relay@*' "$(cat "$ST/kv.default")"

# ----------------------------------------------------------- the tasks: import ----
reset
INPUT="$T/ca" run_srv client -- ssh-ca-import
check "import (client mode): exit 0" 0 "$rc"
has "import: the key went in on bao's stdin" "write ssh-ca/config/ca private_key=- public_key=$CA_PUB" "$(calls)"
check "import: bao's stdin held the private key" "$(cat "$T/ca")" "$(cat "$ST/import.stdin")"
lacks "import: the private key is in no argument" "BEGIN OPENSSH PRIVATE KEY" "$(calls)"
lacks "import: the private key was not printed" "BEGIN OPENSSH" "$out$err"
has "import: the fingerprint is reported" "$CA_FP" "$err"
has "import: says to delete the copy" "delete your copy" "$err"
check "import: no file under the temp folder holds the key's body (but the input and bao's stdin)" 0 "$(grep -rlF "$(sed -n 4p "$T/ca")" "$T" 2>/dev/null | grep -vc -e "^$T/ca$" -e "^$ST/import.stdin$" -e '^$')"
INPUT="$T/ca" run_srv client -- ssh-ca-import
check "import when a CA is there: refused, exit 3, never replaced" 3 "$rc"
INPUT="$T/ca" run_srv client -- ssh-ca-init
check "init on an imported CA keeps it and makes the role" "0:true" "$rc:$([ -f "$ST/role.default.json" ] && echo true || echo false)"
check "init on an imported CA: no second CA generated" 0 "$(grep -c generate_signing_key "$LOG")"
reset
INPUT="$T/key.pub" run_srv client -- ssh-ca-import
check "import of a public key: exit 2" 2 "$rc"
INPUT="$T/rsa" run_srv client -- ssh-ca-import
check "import of an RSA key: exit 2 (ed25519 only)" 2 "$rc"
printf 'not a key\n' > "$T/junk"
INPUT="$T/junk" run_srv client -- ssh-ca-import
check "import of junk: exit 2" 2 "$rc"
check "none of them called bao to write" 0 "$(grep -cE '^write' "$LOG")"
cp "$T/ca" "$T/ca-pass"
ssh-keygen -q -p -P '' -N 'hunter2' -f "$T/ca-pass" >/dev/null
INPUT="$T/ca-pass" run_srv client -- ssh-ca-import
check "import of a key with a passphrase: exit 2, nothing written" "2:0" "$rc:$(grep -cE '^write' "$LOG")"

# ------------------------------------------------------------------ server mode ----
reset
run_srv server -- ssh-ca-init
check "server mode, no terminal: refused, exit 3" 3 "$rc"
has "it says it needs a terminal" "needs a terminal" "$err"
check "nothing was written (the root token is never asked for)" 0 "$(grep -cE '^(write|secrets|policy|kv put)' "$LOG")"
INPUT="$T/ca" run_srv server -- ssh-ca-import
check "server mode import, no terminal for the shares: refused, exit 3" 3 "$rc"
check "nothing written" 0 "$(grep -cE '^(write|secrets|policy|kv put)' "$LOG")"
setup_ca
run_srv server -- ssh-ca-init
check "server mode, everything already there: exit 0 with no terminal and no shares" 0 "$rc"
has "it says nothing changed" "nothing changed" "$err"

# the Operator's policy has the sign path, and no other policy of this Feature does
pol="$(bash -c ". '$root/src/openbao/openbao-lib.sh'; operator_policy dcf")"
has "the Operator's policy: sign with any role" 'path "ssh-ca/sign/*" {
  capabilities = ["update"]' "$pol"
has "the Operator's policy: the CA's public key (read)" 'path "ssh-ca/config/ca" {
  capabilities = ["read"]' "$pol"
lacks "the Operator's policy never writes the CA or a role" '"create"' "$(bash -c ". '$root/src/openbao/openbao-lib.sh'; ssh_ca_policy")"
pol2="$(bash -c ". '$root/src/openbao/openbao-lib.sh'; operator_policy dcf other-ca")"
has "the policy follows the CA's mount" 'path "other-ca/sign/*"' "$pol2"
for f in openbao-server.sh openbao-onboard.sh openbao-keyfile.sh; do
  # every policy the Feature writes for a back (a role of one secret, the backup role) names only
  # its own path: none of those lines can mention the CA
  check "$f: the AppRole and backup policies never name the SSH CA" 0 "$(grep -E 'capabilities|policy write' "$root/src/openbao/$f" | grep -c 'ssh-ca')"
done
check "only the Operator's policy takes the CA's paths (one place writes them: openbao-lib.sh)" 1 "$(grep -l 'sign/\*' "$root"/src/openbao/*.sh | wc -l)"

echo
echo "ssh_ca_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
