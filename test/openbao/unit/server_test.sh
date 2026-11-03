#!/usr/bin/env bash
# Docker-free tests of openbao-server (src/openbao/openbao-server.sh), what the server-mode tasks
# run, against a stub `bao` that keeps a small state (not initialised, sealed, unsealed, down) and
# logs every call with the token it was given. That the real bao behaves as the stub plays is the
# container test test/openbao/server_mode.sh (CI), and was run against a real bao 2.7.2 server while
# this was written. Covered:
#  - the refusal inside an agent's job for EVERY task that handles a share or a token (init,
#    unseal, seal): each of DEVHOST_JOB_CHILD, CLAUDECODE and a variable named in
#    OPENBAO_AGENT_JOB_VARS, with and without a terminal, directly and through the Taskfile, and
#    never a call to bao, never a prompt; and the refusal without a terminal and in client mode;
#  - init under a pseudo-terminal (script(1)): the backup choice asked for and recorded (a path, or
#    the explicit words; an empty or invalid answer asked again), the Operator's password (twice,
#    12 characters at least, on bao's stdin and never in an argument), 3 shares threshold 2, the
#    shares printed to the terminal only (in no file, no log, no argument), the unseal, the
#    configuration in order, the root token used only for it and then revoked, and a failed step
#    revoking it too; only -pgp-keys accepted;
#  - unseal and seal; status in every state with the backup warning; the AppRole tasks (a role's
#    policy, loopback binding, one valid secret id written 0600 and never printed, ALL=1, revoke).
# Part of `task lint` (`task test:openbao-unit`). SCRIPT points the test at another copy of the
# script (used to show a test fails when the code it covers is broken). Needs task, and script(1)
# for the terminal tests (skipped without it).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
script="${SCRIPT:-$root/src/openbao/openbao-server.sh}"

T="$(mktemp -d /tmp/obsrv.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/feat-server" "$T/feat-client" "$T/state" "$T/backups"
cp "$root/src/openbao/env.sh" "$T/feat-server/env.sh"
cp "$root/src/openbao/env.sh" "$T/feat-client/env.sh"
printf 'MODE=server\n' > "$T/feat-server/options.env"
printf 'MODE=client\n' > "$T/feat-client/options.env"
install -m 0755 "$script" "$T/bin/openbao-server"
install -m 0755 "$root/src/openbao/openbao-run.sh" "$T/bin/openbao-run"
LOG="$T/calls.log"

cat > "$T/bin/bao" <<'STUB'
#!/bin/bash
# Stub bao. $STUB_DIR/stubstate is uninit, sealed, unsealed or down; $STUB_DIR/have lists what exists.
echo "$*" >> "$STUB_LOG"
echo "$1 $2 token=${BAO_TOKEN-unset}" >> "$STUB_DIR/tokens.log"
st="$(cat "$STUB_DIR/stubstate" 2>/dev/null || echo unsealed)"
have() { grep -qxF "$1" "$STUB_DIR/have" 2>/dev/null; }
add() { echo "$1" >> "$STUB_DIR/have"; }
drop() { grep -vxF "$1" "$STUB_DIR/have" > "$STUB_DIR/have.new" 2>/dev/null; mv "$STUB_DIR/have.new" "$STUB_DIR/have"; }
case "$1 $2" in
  "status -format=json")
    case "$st" in
      uninit) echo '{"initialized": false, "sealed": true}'; exit 2 ;;
      sealed) echo '{"initialized": true, "sealed": true}'; exit 2 ;;
      down) exit 1 ;;
      *) echo '{"initialized": true, "sealed": false}'; exit 0 ;;
    esac ;;
  "operator init")
    [ "$st" = uninit ] || exit 2
    [ -z "${STUB_INIT_FAIL:-}" ] || { echo "Error initializing: stub" >&2; exit 2; }
    echo sealed > "$STUB_DIR/stubstate"
    printf 'Unseal Key 1: SHARE-ONE-aaaa\nUnseal Key 2: SHARE-TWO-bbbb\nUnseal Key 3: SHARE-THREE-cccc\n\nInitial Root Token: s.ROOT-TOKEN\n\nVault initialized.\n'
    exit 0 ;;
  "operator unseal")
    [ -z "${STUB_UNSEAL_FAIL:-}" ] || { echo "Error unsealing: stub" >&2; exit 2; }
    n=$(( $(cat "$STUB_DIR/unseal.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/unseal.n"
    if [ "$n" -ge 2 ]; then echo unsealed > "$STUB_DIR/stubstate"; echo "Sealed false"; else echo "Unseal Progress 1/2"; fi
    exit 0 ;;
  "operator seal") [ "${STUB_SEAL_RC:-0}" -eq 0 ] && echo sealed > "$STUB_DIR/stubstate"; exit "${STUB_SEAL_RC:-0}" ;;
  "token lookup") exit "${STUB_LOOKUP_RC:-0}" ;;
  "token revoke") exit 0 ;;
  "read -format=json") echo '{"data": {"is_self": true}}' | sed 's/"is_self": true/"is_self": true/'; exit 0 ;;
  "secrets enable") [ -z "${STUB_STEP_FAIL:-}" ] || exit 2; add "sys/mounts/dcf"; exit 0 ;;
  "auth enable") add "sys/auth/$3"; exit 0 ;;
  "policy write") cat > "$STUB_DIR/policy.$3"; exit 0 ;;
  "policy delete") rm -f "$STUB_DIR/policy.$3"; exit 0 ;;
  "list auth/approle/role")
    roles="$(sed -n 's#^auth/approle/role/##p' "$STUB_DIR/have" 2>/dev/null)"
    [ -n "$roles" ] || { echo "No value found" >&2; exit 2; }
    printf 'Keys\n----\n%s\n' "$roles"; exit 0 ;;
  "delete auth/approle/role/"*) drop "$2"; rm -f "$STUB_DIR/acc.${2##*/}"; exit 0 ;;
esac
case "$1" in
  read)
    case "$2" in
      -field=role_id) echo "ROLEID-${3#auth/approle/role/}" | sed 's#/role-id##'; exit 0 ;;
      *) have "$2" && exit 0; exit 2 ;;
    esac ;;
  list)
    r="${2#auth/approle/role/}"; r="${r%/secret-id}"
    [ -s "$STUB_DIR/acc.$r" ] || { echo "No value found" >&2; exit 2; }
    printf 'Keys\n----\n'; cat "$STUB_DIR/acc.$r"; exit 0 ;;
  write)
    case "${*:2}" in
      *"secret-id-accessor/destroy"*)
        r="$2"; r="${r#auth/approle/role/}"; r="${r%%/*}"
        a="${!#}"; a="${a#secret_id_accessor=}"
        grep -vxF "$a" "$STUB_DIR/acc.$r" > "$STUB_DIR/acc.new" 2>/dev/null; mv "$STUB_DIR/acc.new" "$STUB_DIR/acc.$r"; exit 0 ;;
      "-f -field=secret_id auth/approle/role/"*)
        r="${4#auth/approle/role/}"; r="${r%/secret-id}"
        n=$(( $(cat "$STUB_DIR/sid.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/sid.n"
        echo "ACC-$n" >> "$STUB_DIR/acc.$r"
        printf 'SECRETID-%s' "$n"; exit 0 ;;
      "auth/userpass/users/operator "*) cat > "$STUB_DIR/userpass.stdin"; exit 0 ;;
      "auth/approle/role/"*) add "$2"; exit 0 ;;
    esac ;;
  delete) exit 0 ;;
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

reset() { # <state>: a fresh stub state and state dir
  rm -rf "${T:?}/state" "${T:?}"/acc.* "${T:?}"/sid.n "${T:?}"/unseal.n "${T:?}"/policy.* "${T:?}"/userpass.stdin "${T:?}"/have "${T:?}"/tokens.log
  mkdir -p "$T/state" "$T/backups"
  echo "${1:-unsealed}" > "$T/stubstate"
  : > "$LOG"
}
envs() { # the environment every run gets, the mode first
  echo "PATH=$T/bin:/usr/local/bin:/usr/bin:/bin" "HOME=$T/home" "STUB_LOG=$LOG" "STUB_DIR=$T" "OPENBAO_STATE_DIR=$T/state" "OPENBAO_FEATURE_DIR=$T/feat-${MODE_FEAT:-server}"
}
MODE_FEAT=server
# run [VAR=value ...] -- <args>: stdout+stderr in $out, exit status in $rc, no terminal
run() {
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  # shellcheck disable=SC2046  # envs prints words
  out="$(env -i $(envs) "${e[@]}" bash "$T/bin/openbao-server" "$@" 2>&1)"
  rc=$?
}
have_script=0
command -v script >/dev/null 2>&1 && have_script=1
# script -e returns the child's exit status, but through a pipeline only the last command's status
# is seen: keep it in a file
term() { # <input: answers separated by ';', an empty one is Enter> [VAR=value ...] -- <args>
  local input="$1"
  shift
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  # shellcheck disable=SC2046  # envs prints words
  local cmd
  cmd="env -i $(envs | tr '\n' ' ') ${e[*]:-} bash $T/bin/openbao-server $*"
  rm -f "$T/term.rc"
  out="$({
    sleep 0.7
    while IFS= read -r -d ';' part; do printf '%s\n' "$part"; sleep 0.4; done <<<"$input;"
    sleep 1.5
  } | { script -qefc "$cmd; echo \$? > $T/term.rc" /dev/null 2>&1 || true; } | tr -d '\r')"
  rc="$(cat "$T/term.rc" 2>/dev/null || echo "?")"
}
calls() { cat "$LOG"; }

# ------------------------------------------------------------------------------ refusals ----
# Inside an agent's job: every task that handles a share or a token. No call to bao, whatever else.
for t in init unseal seal; do
  for v in DEVHOST_JOB_CHILD CLAUDECODE; do
    reset sealed
    run "$v=1" -- "$t"
    check "$t refuses inside an agent's job ($v): exit 3" 3 "$rc"
    has "$t ($v): the line names the variable and the reason" "refuses to run inside an agent's job ($v is set)" "$out"
    check "$t ($v): bao is never called" "" "$(calls)"
  done
  reset sealed
  run OPENBAO_AGENT_JOB_VARS="OTHERCLI MYCLI" MYCLI=1 -- "$t"
  check "$t refuses for a variable named in OPENBAO_AGENT_JOB_VARS: exit 3" 3 "$rc"
  has "$t (OPENBAO_AGENT_JOB_VARS): names MYCLI" "(MYCLI is set)" "$out"
  reset sealed
  run DEVHOST_JOB_CHILD= -- "$t" </dev/null
  lacks "$t: an empty DEVHOST_JOB_CHILD is no agent's job" "agent's job" "$out"
done
# through the Taskfile: the tasks are wired to the refusal (task runs openbao-server from PATH)
if command -v task >/dev/null 2>&1; then
  for t in init unseal seal; do
    reset sealed
    # shellcheck disable=SC2046  # envs prints words
    out="$(cd "$T" && env -i $(envs) DEVHOST_JOB_CHILD=1 task -t "$root/src/openbao/taskfile.yml" "$t" 2>&1)"
    rc=$?
    check "task openbao:$t refuses inside an agent's job: not exit 0" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
    has "task openbao:$t: the refusal is the one shown" "refuses to run inside an agent's job (DEVHOST_JOB_CHILD is set)" "$out"
    check "task openbao:$t: bao is never called" "" "$(calls)"
  done
else
  echo "skip - the Taskfile refusals (no task on PATH)"
fi
# with a terminal the refusal still comes first: no prompt, no call
if [ "$have_script" -eq 1 ]; then
  for t in init unseal seal; do
    reset sealed
    term "no backup" DEVHOST_JOB_CHILD=1 -- "$t"
    has "$t under a terminal in an agent's job is still refused" "refuses to run inside an agent's job" "$out"
    lacks "$t under a terminal in an agent's job asks nothing" "Backup destination" "$out"
    check "$t under a terminal in an agent's job: bao is never called" "" "$(calls)"
  done
fi
# no terminal
for t in init unseal; do
  reset sealed
  run -- "$t"
  check "$t without a terminal: exit 3" 3 "$rc"
  has "$t without a terminal: says so" "needs a terminal" "$out"
  check "$t without a terminal: bao is never called" "" "$(calls)"
done
# client mode: this container runs no server
MODE_FEAT=client
for t in init unseal seal approle-issue approle-revoke; do
  reset sealed
  run OPENBAO_TASK_ROLE=x -- "$t"
  check "$t in client mode: exit 3" 3 "$rc"
  has "$t in client mode: says why" "this container runs no server (mode client)" "$out"
  check "$t in client mode: bao is never called" "" "$(calls)"
done
MODE_FEAT=server

# ------------------------------------------------------------------------------------ init ----
if [ "$have_script" -eq 1 ]; then
  reset uninit
  term "no backup;correct horse battery;correct horse battery;;" -- init
  check "init: exit 0" 0 "$rc"
  has "init: the shares are printed to the terminal" "Unseal Key 1: SHARE-ONE-aaaa" "$out"
  has "init: all three" "Unseal Key 3: SHARE-THREE-cccc" "$out"
  has "init: says to store them" "Keep one in your password manager" "$out"
  check "init: the backup choice file says none, with a date" "choice=none" "$(sed -n 1p "$T/state/backup-choice")"
  check "init: the choice has a date" 1 "$(grep -c '^date=20' "$T/state/backup-choice")"
  check "init: the choice file is mode 600" 600 "$(stat -c %a "$T/state/backup-choice")"
  check "init: 3 shares and threshold 2" "operator init -key-shares=3 -key-threshold=2" "$(grep '^operator init' "$LOG")"
  check "init: unsealed with two shares (two unseal calls, no share as an argument)" "operator unseal|operator unseal" "$(grep '^operator unseal' "$LOG" | paste -sd'|')"
  order="$(grep -nE '^(operator init|operator unseal|secrets enable|auth enable|policy write|write auth/userpass|token revoke)' "$LOG" | sed 's/^[0-9]*://' | awk '{print $1" "$2}' | paste -sd'|')"
  check "init: the steps in order, root revoked last" "operator init|operator unseal|operator unseal|secrets enable|auth enable|auth enable|policy write|write auth/userpass/users/operator|token revoke" "$order"
  has "init: the dcf KV v2 mount" "secrets enable -path=dcf -version=2 kv" "$(calls)"
  has "init: userpass and approle enabled" "auth enable userpass" "$(calls)"
  has "init: approle" "auth enable approle" "$(calls)"
  has "init: the login lifetime of ruling 6 (4 hours, at most 8)" "token_ttl=4h token_max_ttl=8h" "$(calls)"
  has "init: the Operator's policy" "token_policies=operator" "$(calls)"
  check "init: the password reached bao on stdin" "correct horse battery" "$(cat "$T/userpass.stdin")"
  lacks "init: the password is in no argument" "correct horse" "$(calls)"
  lacks "init: no share is in any argument" "SHARE-" "$(calls)"
  check "init: the root token was used for the configuration only" "yes" "$(grep -q 'secrets enable token=s.ROOT-TOKEN' "$T/tokens.log" && ! grep -q 'status -format=json token=s.ROOT' "$T/tokens.log" && echo yes)"
  check "init: and revoked with itself" "yes" "$(grep -q 'token revoke token=s.ROOT-TOKEN' "$T/tokens.log" && echo yes)"
  check "init: no share or token is written anywhere in the state dir" "" "$(grep -rl 'SHARE-\|ROOT-TOKEN' "$T/state" 2>/dev/null)"
  has "init: the Operator's policy allows sealing and the snapshot read, not snapshot-force" "sys/seal" "$(cat "$T/policy.operator")"
  has "init: the policy has the snapshot read" "sys/storage/raft/snapshot" "$(cat "$T/policy.operator")"
  lacks "init: the policy has no path for snapshot-force" 'snapshot-force"' "$(cat "$T/policy.operator")"
  has "init: the policy has the dcf secrets" 'path "dcf/*"' "$(cat "$T/policy.operator")"
  has "init: says the backup is none and will keep saying it" "NO BACKUP" "$out"

  # a backup destination: an empty answer, a relative one and a missing folder are asked again
  reset uninit
  term ";backups;/nonexistent/dir;$T/backups;a password that is long;a password that is long;;" -- init
  check "a path choice: exit 0" 0 "$rc"
  check "the choice is the path" "choice=path" "$(sed -n 1p "$T/state/backup-choice")"
  check "with the destination" "dest=$T/backups" "$(sed -n 2p "$T/state/backup-choice")"
  has "an empty answer is asked again" "the choice is explicit" "$out"
  has "a relative path is refused" "'backups' is not an absolute folder path" "$out"
  has "a missing folder is refused" "'/nonexistent/dir' is not a writable folder" "$out"
  has "the destination is said" "backup destination recorded: $T/backups" "$out"

  # the password: too short, then mismatched, then accepted
  reset uninit
  term "no backup;short;short;twelve chars ok;different one here;correct horse battery;correct horse battery;;" -- init
  check "the password is asked again until it is good: exit 0" 0 "$rc"
  has "a short password is refused" "too short" "$out"
  has "a mismatch is refused" "did not match" "$out"
  check "the accepted password is the last pair" "correct horse battery" "$(cat "$T/userpass.stdin")"

  # only -pgp-keys is accepted
  reset uninit
  term "no backup;correct horse battery;correct horse battery;;" -- init -pgp-keys=a.asc,b.asc,c.asc
  check "init -pgp-keys is passed to bao" "operator init -key-shares=3 -key-threshold=2 -pgp-keys=a.asc,b.asc,c.asc" "$(grep '^operator init' "$LOG")"
  reset uninit
  term "no backup" -- init -key-shares=1
  check "init refuses any other flag (the share count is fixed): exit 2" 2 "$rc"
  check "init with another flag: bao is never called" "" "$(calls)"

  # not twice
  reset sealed
  term "no backup" -- init
  check "init on an initialised, sealed server is refused" 3 "$rc"
  has "init: says to unseal" "task openbao:unseal" "$out"
  lacks "init: asks nothing then" "Backup destination" "$out"
  reset unsealed
  term "no backup" -- init
  check "init on an unsealed server is refused" 3 "$rc"
  reset down
  term "no backup" -- init
  check "init with the server unreachable: exit 10" 10 "$rc"

  # a failing step revokes the root token and says how to start over; a failing init prints nothing
  reset uninit
  term "no backup;correct horse battery;correct horse battery;;" STUB_STEP_FAIL=1 -- init
  check "a configuration step that fails: exit 1" 1 "$rc"
  check "the root token is revoked after a failed step" "yes" "$(grep -q 'token revoke token=s.ROOT-TOKEN' "$T/tokens.log" && echo yes)"
  has "and the way to start over is named" "delete $T/state/raft" "$out"
  check "no backup choice is recorded for a failed init" "no" "$([ -e "$T/state/backup-choice" ] && echo yes || echo no)"
  reset uninit
  term "no backup;correct horse battery;correct horse battery;;" STUB_INIT_FAIL=1 -- init
  check "bao operator init failing: exit 1" 1 "$rc"
  lacks "and no share is shown" "Unseal Key" "$out"

  # unseal
  reset sealed
  term "" -- unseal
  check "unseal: exit 0" 0 "$rc"
  check "unseal: two prompts' worth of bao operator unseal" 2 "$(grep -c '^operator unseal' "$LOG")"
  check "unseal: no share is an argument" "operator unseal|operator unseal" "$(grep '^operator unseal' "$LOG" | paste -sd'|')"
  reset unsealed
  term "" -- unseal
  check "unseal on an unsealed server: exit 0, nothing asked" "0 0" "$rc $(grep -c '^operator unseal' "$LOG")"
  reset uninit
  term "" -- unseal
  check "unseal on a server that is not initialised: exit 11" 11 "$rc"
  has "unseal: names the init task" "task openbao:init" "$out"
  reset down
  term "" -- unseal
  check "unseal on an unreachable server: exit 10" 10 "$rc"
  reset sealed
  term "" STUB_UNSEAL_FAIL=1 -- unseal
  check "unseal with a share bao refuses: exit 1" 1 "$rc"
  has "unseal: says how to reset" "-reset" "$out"
else
  echo "skip - init and unseal under a terminal (no script(1))"
fi

# ------------------------------------------------------------------------------------- seal ----
reset unsealed
run -- seal
check "seal: exit 0" 0 "$rc"
check "seal calls bao operator seal" 1 "$(grep -c '^operator seal' "$LOG")"
has "seal: names the unseal task" "task openbao:unseal" "$out"
reset sealed
run -- seal
check "seal on a sealed server: exit 0" 0 "$rc"
check "seal on a sealed server: no second seal" 0 "$(grep -c '^operator seal' "$LOG")"
reset unsealed
run STUB_LOOKUP_RC=2 -- seal
check "seal without a valid login: exit 12" 12 "$rc"
check "seal without a login: nothing sealed" 0 "$(grep -c '^operator seal' "$LOG")"
reset down
run -- seal
check "seal with the server unreachable: exit 10" 10 "$rc"
reset unsealed
run STUB_SEAL_RC=2 -- seal
check "seal refused by the policy: exit 1" 1 "$rc"

# ---------------------------------------------------------------------------------- status ----
reset unsealed
run -- status
check "status unsealed: exit 0" 0 "$rc"
has "status: the mode" "mode:     server" "$out"
has "status: the address defaults to the local server" "address:  http://127.0.0.1:8200" "$out"
has "status: unsealed" "server:   unsealed" "$out"
has "status: the storage" "storage:  raft, $T/state/raft" "$out"
has "status: the audit log" "audit:    $T/state/audit.log" "$out"
has "status: no backup chosen yet is a warning" "WARNING none chosen yet" "$out"
has "status: a valid login" "login:    valid" "$out"
printf 'choice=none\ndate=2026-11-03T10:00:00Z\n' > "$T/state/backup-choice"
run -- status
has "status: a recorded no backup is a standing warning with its date" "WARNING no backup (chosen 2026-11-03T10:00:00Z)" "$out"
printf 'choice=path\ndest=/mnt/somewhere\ndate=2026-11-03T10:00:00Z\n' > "$T/state/backup-choice"
run -- status
has "status: a destination is shown" "destination /mnt/somewhere" "$out"
lacks "status: a destination is no warning" "WARNING" "$out"
run STUB_LOOKUP_RC=2 -- status
has "status: no login says how" "-method=userpass username=operator" "$out"
check "status: still exit 0" 0 "$rc"
reset sealed
run -- status
check "status sealed: exit 11" 11 "$rc"
has "status sealed" "server:   sealed" "$out"
lacks "status sealed asks no login" "login:" "$out"
reset uninit
run -- status
check "status not initialised: exit 11" 11 "$rc"
has "status not initialised" "server:   not initialised" "$out"
reset down
run -- status
check "status unreachable: exit 10" 10 "$rc"
has "status unreachable" "server:   unreachable" "$out"
has "status: a server that is not running says how to start it" "openbao-setup start" "$out"
MODE_FEAT=client
reset unsealed
run BAO_ADDR=https://bao.example.test -- status
check "status in client mode: exit 0" 0 "$rc"
has "status in client mode: the mode" "mode:     client" "$out"
has "status in client mode: the address as set" "address:  https://bao.example.test" "$out"
lacks "status in client mode: no process or storage lines" "storage:" "$out"
lacks "status in client mode: no backup warning" "backup:" "$out"
MODE_FEAT=server

# ---------------------------------------------------------------------------------- approle ----
reset unsealed
run OPENBAO_TASK_ROLE=scribe OPENBAO_TASK_POLICY_PATH=dcf/register/scribe -- approle-issue
check "approle:issue a new role: exit 0" 0 "$rc"
check "the policy is named after the role and reads that one secret" 'path "dcf/data/register/scribe" {' "$(sed -n 1p "$T/policy.approle-scribe")"
check "and only reads" '  capabilities = ["read"]' "$(sed -n 2p "$T/policy.approle-scribe")"
rolecall="$(grep '^write auth/approle/role/scribe token_policies' "$LOG")"
has "the role is bound to loopback for the secret id" "secret_id_bound_cidrs=127.0.0.1/32" "$rolecall"
has "and for the token" "token_bound_cidrs=127.0.0.1/32" "$rolecall"
has "the token lives 5 minutes, at most 15" "token_ttl=5m token_max_ttl=15m" "$rolecall"
has "secret ids do not expire" "secret_id_ttl=0 secret_id_num_uses=0" "$rolecall"
has "the role carries its policy" "token_policies=approle-scribe" "$rolecall"
check "the secret id is written" "SECRETID-1" "$(cat "$T/state/approle/scribe/secret_id")"
check "with the role id" "ROLEID-scribe" "$(cat "$T/state/approle/scribe/role_id")"
check "the secret id file is mode 600" 600 "$(stat -c %a "$T/state/approle/scribe/secret_id")"
check "the folder is private" 700 "$(stat -c %a "$T/state/approle/scribe")"
lacks "the secret id is never printed" "SECRETID" "$out"
lacks "nor the role id" "ROLEID" "$out"
lacks "nor put in an argument" "SECRETID" "$(calls)"
# reissue: exactly one valid secret id afterwards
: > "$LOG"
run OPENBAO_TASK_ROLE=scribe -- approle-issue
check "reissuing an existing role: exit 0" 0 "$rc"
check "the old secret id's accessor is destroyed" 1 "$(grep -c 'secret-id-accessor/destroy secret_id_accessor=ACC-1' "$LOG")"
check "a new secret id replaces it" "SECRETID-2" "$(cat "$T/state/approle/scribe/secret_id")"
check "one valid secret id is left" "ACC-2" "$(cat "$T/acc.scribe")"
check "an existing role's settings are not rewritten without POLICY_PATH" 0 "$(grep -c '^write auth/approle/role/scribe token_policies' "$LOG")"
# ALL=1
run OPENBAO_TASK_ROLE=librarian OPENBAO_TASK_POLICY_PATH=dcf/register/librarian -- approle-issue
: > "$LOG"
run OPENBAO_TASK_ALL=1 -- approle-issue
check "ALL=1: exit 0" 0 "$rc"
check "ALL=1 reissues every role (in the order the server lists them)" "SECRETID-5 SECRETID-4" "$(printf '%s %s' "$(cat "$T/state/approle/librarian/secret_id")" "$(cat "$T/state/approle/scribe/secret_id")")"
check "ALL=1: the old ids are destroyed" 2 "$(grep -c 'secret-id-accessor/destroy' "$LOG")"
check "ALL=1 rewrites no role" 0 "$(grep -c '^write auth/approle/role/[a-z]* token_policies' "$LOG")"
reset unsealed
run OPENBAO_TASK_ALL=1 -- approle-issue
check "ALL=1 with no roles: exit 0" 0 "$rc"
has "ALL=1 with no roles says so" "no AppRole roles" "$out"
# refusals and preflight
run OPENBAO_TASK_ROLE=newrole -- approle-issue
check "a new role without POLICY_PATH: exit 2" 2 "$rc"
has "says to give POLICY_PATH" "POLICY_PATH" "$out"
run OPENBAO_TASK_ROLE='Bad Role' OPENBAO_TASK_POLICY_PATH=dcf/x -- approle-issue
check "a bad role name: exit 2" 2 "$rc"
run OPENBAO_TASK_ROLE=ok OPENBAO_TASK_POLICY_PATH='dcf' -- approle-issue
check "a policy path with no secret in it: exit 2" 2 "$rc"
run OPENBAO_TASK_ROLE=ok OPENBAO_TASK_POLICY_PATH='dcf/a"b' -- approle-issue
check "a policy path with a quote: exit 2" 2 "$rc"
run OPENBAO_TASK_ALL=1 OPENBAO_TASK_ROLE=x -- approle-issue
check "ALL=1 with a role: exit 2" 2 "$rc"
run -- approle-issue
check "no role and no ALL: exit 2" 2 "$rc"
reset sealed
run OPENBAO_TASK_ROLE=x OPENBAO_TASK_POLICY_PATH=dcf/x -- approle-issue
check "approle:issue on a sealed server: exit 11" 11 "$rc"
reset unsealed
run OPENBAO_TASK_ROLE=x OPENBAO_TASK_POLICY_PATH=dcf/x STUB_LOOKUP_RC=2 -- approle-issue
check "approle:issue without a login: exit 12" 12 "$rc"
check "approle:issue without a login writes nothing" 0 "$(grep -c '^write\|^policy' "$LOG")"
reset down
run OPENBAO_TASK_ROLE=x OPENBAO_TASK_POLICY_PATH=dcf/x -- approle-issue
check "approle:issue with the server unreachable: exit 10" 10 "$rc"
# revoke
reset unsealed
run OPENBAO_TASK_ROLE=scribe OPENBAO_TASK_POLICY_PATH=dcf/register/scribe -- approle-issue
run OPENBAO_TASK_ROLE=scribe -- approle-revoke
check "approle:revoke: exit 0" 0 "$rc"
check "approle:revoke deletes the role (OpenBao ends its secret ids with it)" 1 "$(grep -c '^delete auth/approle/role/scribe' "$LOG")"
check "approle:revoke deletes the role's policy" 1 "$(grep -c '^policy delete approle-scribe' "$LOG")"
check "approle:revoke removes the files" "no" "$([ -e "$T/state/approle/scribe" ] && echo yes || echo no)"
run OPENBAO_TASK_ROLE=scribe -- approle-revoke
check "approle:revoke of an unknown role: exit 14" 14 "$rc"
run -- approle-revoke
check "approle:revoke without a role: exit 2" 2 "$rc"

echo
echo "server_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
