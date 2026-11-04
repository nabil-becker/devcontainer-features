#!/bin/bash
# Scenario 'server_mode' (see scenarios.json): the server this Feature runs (mode=server, OpenBao
# 2.7.1), remoteUser=vscode, with the real bao: what the Docker-free tests (test/openbao/unit) can
# only stub. A terminal is played with script(1), whose output file is the Operator's screen.
#   - the start hook: raft storage on the volume, sealed and not initialised, the process the
#     remote user's, started without any mlock capability or disable_mlock;
#   - task openbao:init: the shares printed only to the terminal and in no file; the backup choice
#     recorded; the login lifetime of 4 hours and at most 8 (a renewal is capped); the root token gone;
#   - a restart comes back sealed and keeps what was written; task openbao:unseal and :seal;
#   - dcf-secret's lines for each state; the audit device;
#   - the AppRole tasks: the Operator's token cannot write a policy or make or delete a role;
#     making and deleting a role go through a root token made from two shares (typed at a
#     terminal, never echoed, revoked after); loopback binding honoured (secret id and token), one
#     valid secret id after a reissue (the Operator's token only);
#   - the refusals inside an agent's job and without a terminal, for init, unseal and seal.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:8200
unset BAO_TOKEN
state="$OPENBAO_STATE_DIR"
tf="${OPENBAO_TEST_TASKFILE:-/usr/local/share/go-task/includes.d/openbao.yml}"
t() { task -t "$tf" "$@"; }
work="$(mktemp -d)"
pw='correct horse battery staple'

# term <answers file> <command>: run the command under a pseudo-terminal, typing the lines of the
# answers (the word ENTER is an empty line) one by one; the screen is $work/screen, the exit code
# $work/rc. The shares are read off the screen when it says to press Enter, and typed back.
term() { # <command> <answer>...
  local cmd="$1" a s1 s2
  shift
  rm -f "$work/fifo" "$work/screen" "$work/rc"
  mkfifo "$work/fifo"
  script -qefc "$cmd; echo \$? > $work/rc" "$work/screen" < "$work/fifo" > /dev/null 2>&1 &
  local spid=$!
  exec 3> "$work/fifo"
  sleep 1
  # the first prompt must be up before anything is typed (a tty echoes what arrives before a hidden
  # read turns the echo off, and a loaded machine is slow to get there): wait until the screen is quiet
  local sz0=-1 sz1=0 _w
  for _w in $(seq 1 30); do
    sz1="$(stat -c %s "$work/screen" 2>/dev/null || echo 0)"
    [ "$sz1" = "$sz0" ] && [ "$sz1" -gt 0 ] && break
    sz0="$sz1"
    sleep 1
  done
  for a in "$@"; do
    case "$a" in
      SHARES)
        for _ in $(seq 1 60); do grep -aq 'Press Enter' "$work/screen" && break; sleep 0.5; done
        s1="$(grep -a -m1 '^Unseal Key 1: ' "$work/screen" | sed 's/^Unseal Key 1: //' | tr -d '\r')"
        s2="$(grep -a -m1 '^Unseal Key 2: ' "$work/screen" | sed 's/^Unseal Key 2: //' | tr -d '\r')"
        printf '%s\n' "$s1" "$s2" > "$work/shares"
        printf '\n' >&3
        sleep 1
        printf '%s\n' "$s1" >&3
        sleep 1
        printf '%s\n' "$s2" >&3
        ;;
      ENTER) printf '\n' >&3 ;;
      *) printf '%s\n' "$a" >&3 ;;
    esac
    sleep 0.7
  done
  sleep 1
  exec 3>&-
  wait "$spid" || true
  tr -d '\r' < "$work/screen" > "$work/screen.txt" || true
  term_rc="$(cat "$work/rc" 2>/dev/null || echo '?')"
}
not() { ! "$@"; }
contains() { grep -qF -- "$2" <<<"$1"; } # <text> <needle>
excludes() { ! grep -qF -- "$2" <<<"$1"; }
in_files() { grep -rlaF -- "$1" "$2" > /dev/null 2>&1; } # <needle> <folder>: found in any file
unsealed() { [ "$(openbao-run bao status -format=json | grep -c '"sealed": false')" = 1 ]; }
ttl() { bao token lookup -format=json | sed -n 's/.*"ttl": *\([0-9]*\).*/\1/p' | head -n 1; }
ttl_between() { local t; t="$(ttl)"; [ "$t" -le "$1" ] && [ "$t" -gt "$2" ]; } # <max> <min>
login_scribe() { bao write -field=token auth/approle/login role_id="$(cat "$state/approle/scribe/role_id")" secret_id="$(cat "$state/approle/scribe/secret_id")"; }
unseal_again() { # type the two saved shares at task openbao:unseal's prompts
  local s1 s2
  s1="$(sed -n 1p "$work/shares")"
  s2="$(sed -n 2p "$work/shares")"
  term "task -t $tf unseal" "$s1" "$s2"
}

# A root token made from the saved shares by hand (the test's own use, to inspect and tamper with
# a role, which the Operator's token may not): $rootok, to be dropped with drop_root.
make_root() {
  local otp out enc nonce
  otp="$(bao operator generate-root -generate-otp)"
  # A share read from stdin (-) needs the attempt's nonce; only bao's own prompt looks it up.
  out="$(bao operator generate-root -init -otp="$otp" -format=json)" || return 1
  nonce="$(sed -n 's/.*"nonce": *"\([^"]*\)".*/\1/p' <<<"$out" | head -n 1)"
  out="$(sed -n 1p "$work/shares" | bao operator generate-root -nonce="$nonce" -format=json -)" || return 1
  out="$(sed -n 2p "$work/shares" | bao operator generate-root -nonce="$nonce" -format=json -)" || return 1
  enc="$(sed -n 's/.*"encoded_token": *"\([^"]*\)".*/\1/p' <<<"$out" | head -n 1)"
  rootok="$(printf '%s' "$enc" | bao operator generate-root -decode=- -otp="$otp")" && [ -n "$rootok" ]
}
drop_root() { BAO_TOKEN="$rootok" bao token revoke -self > /dev/null 2>&1; rootok=""; }

# --- the start hook ------------------------------------------------------------------------
# post-create (hands the volume to the remote user) and post-start, as the lifecycle runs them
openbao-setup > /dev/null
openbao-setup start
rc=0; out="$(dcf-secret status 2>/dev/null)" || rc=$?
check "after the start hook the server is not initialised (exit 11)" [ "$rc:$out" = 11:not-initialised ]
check "the config is in the volume, with raft storage there" grep -q "path    = \"$state/raft\"" "$state/server.hcl"
check "the config sets no disable_mlock (OpenBao uses no mlock since 2.0.0)" not grep -q "^disable_mlock" "$state/server.hcl"
check "the server runs as the remote user, not root" [ "$(ps -o user= -p "$(cat "$state/server.pid")" | tr -d ' ')" = "$(id -un)" ]
check "the server started without a lock on memory and says no error about it" not grep -qi 'mlock' "$state/server.log"
check "starting again reuses the live server" contains "$(openbao-setup start)" 'already running'
rc=0; err="$(dcf-secret get ssh/x 2>&1 > /dev/null)" || rc=$?
check "dcf-secret says to initialise, exit 11" [ "$rc" = 11 ]
check "and names the init task" contains "$err" 'task openbao:init'

# --- the refusals before init -------------------------------------------------------------------
refused() { [ "$1" != 0 ] && contains "$2" "refuses to run inside an agent's job"; } # <rc> <output>
for tk in init unseal seal; do
  rc=0; out="$(DEVHOST_JOB_CHILD=1 t "$tk" 2>&1 < /dev/null)" || rc=$?
  check "task openbao:$tk refuses inside the devhost's job" refused "$rc" "$out"
  rc=0; out="$(CLAUDECODE=1 t "$tk" 2>&1 < /dev/null)" || rc=$?
  check "task openbao:$tk refuses inside a Claude Code run" refused "$rc" "$out"
done
rc=0; out="$(t init 2>&1 < /dev/null)" || rc=$?
check "task openbao:init without a terminal is refused" [ "$rc" != 0 ]
check "and says it needs a terminal" contains "$out" 'needs a terminal'
check "none of the refusals touched the server (still not initialised)" [ "$(dcf-secret status 2>/dev/null)" = not-initialised ]

# --- init ---------------------------------------------------------------------------------------
term "task -t $tf init" "no backup" "$pw" "$pw" SHARES
check "task openbao:init exits 0" [ "$term_rc" = 0 ]
check "the shares were shown on the terminal" [ "$(grep -c '^Unseal Key [0-9]: ' "$work/screen.txt")" = 3 ]
check "the backup choice is recorded as no backup" grep -qx 'choice=none' "$state/backup-choice"
check "the screen says there is no backup" grep -q 'NO BACKUP' "$work/screen.txt"
check "no share is in any file of the volume" not in_files "$(sed -n 1p "$work/shares")" "$state"
check "the init output (the root token line) is nowhere in the volume" not in_files 'Initial Root Token' "$state"
check "the server is unsealed" unsealed
rc=0; dcf-secret get ssh/x > /dev/null 2>&1 || rc=$?
check "no login yet: dcf-secret is exit 12" [ "$rc" = 12 ]

# --- the Operator's login --------------------------------------------------------------------------
term "task -t $tf login -- -method=userpass username=operator" "$pw"
check "the userpass login works" [ "$(dcf-secret status)" = ready ]
check "the login token is in the volume (mode 600)" [ "$(stat -c %a "$state/token")" = 600 ]
check "the login lasts 4 hours" ttl_between 14400 14000
bao token renew -increment=24h > /dev/null 2>&1 || true
check "a renewal past the maximum is capped at 8 hours" ttl_between 28800 14400
check "the root token was revoked at the end of init (the Operator's policy cannot list auth mounts)" not bao auth list

# --- the store, and what the Operator may do --------------------------------------------------------
check "dcf-secret put works with the login" bash -c "printf 'abc def' | dcf-secret put ssh/key --field private_key"
check "and get returns it" [ "$(dcf-secret get ssh/key --field private_key)" = 'abc def' ]
check "the Operator may not use snapshot-force" not bao write -f sys/storage/raft/snapshot-force
check "the audit log exists, is in the volume and is not empty" test -s "$state/audit.log"
check "the audit log holds no secret in clear" not grep -qF 'abc def' "$state/audit.log"
out="$(t server:status)" || true
check "server:status shows unsealed" contains "$out" 'server:   unsealed'
check "and the standing no-backup warning" contains "$out" 'WARNING no backup'

# --- AppRole ---------------------------------------------------------------------------------------
# the Operator's token cannot write a policy, make or change a role, or delete one
rc=0; echo 'path "sys/storage/raft/snapshot-force" { capabilities = ["update"] }' | bao policy write approle-evil - > /dev/null 2>&1 || rc=$?
check "the Operator's token cannot write a policy (permission denied)" [ "$rc" != 0 ]
rc=0; out="$(echo 'path "x" { capabilities = ["read"] }' | bao policy write approle-evil - 2>&1)" || rc=$?
check "and the refusal is the policy's" contains "$out" 'permission denied'
rc=0; out="$(bao write auth/approle/role/evil token_policies=operator 2>&1)" || rc=$?
check "it cannot create a role" [ "$rc" != 0 ]
check "the refusal is the policy's" contains "$out" 'permission denied'
rc=0; bao read sys/policies/acl/operator > /dev/null 2>&1 || rc=$?
check "it cannot read policies either" [ "$rc" != 0 ]
# making a role asks for the shares (no terminal: refused, nothing made)
rc=0; out="$(t approle:issue ROLE=scribe POLICY_PATH=dcf/register/scribe 2>&1 < /dev/null)" || rc=$?
check "making a role without a terminal is refused" [ "$rc" != 0 ]
check "and the refusal says it needs a terminal" contains "$out" 'needs a terminal'
# making a role: the shares make a root token for that step only
term "task -t $tf approle:issue ROLE=scribe POLICY_PATH=dcf/register/scribe" "$(sed -n 1p "$work/shares")" "$(sed -n 2p "$work/shares")"
check "approle:issue of a new role through the shares exits 0" [ "$term_rc" = 0 ]
check "it said it asks for the shares" contains "$(cat "$work/screen.txt")" 'unseal shares typed at the prompt'
check "no share was echoed on the screen" excludes "$(cat "$work/screen.txt")" "$(sed -n 1p "$work/shares")"
check "the role exists" bao read auth/approle/role/scribe/role-id
check "and the root token generation is not left open" contains "$(bao operator generate-root -status 2>&1)" 'Started       false'
check "approle:issue wrote the secret id (mode 600)" [ "$(stat -c %a "$state/approle/scribe/secret_id")" = 600 ]
check "and the role id" test -s "$state/approle/scribe/role_id"
make_root
role="$(BAO_TOKEN="$rootok" bao read -format=json auth/approle/role/scribe)"
drop_root
check "the role's secret ids are bound to loopback" contains "$role" '"secret_id_bound_cidrs": ['
check "and its tokens" contains "$role" '"token_bound_cidrs": ['
check "the binding is 127.0.0.1 (twice)" [ "$(grep -c '"127.0.0.1' <<<"$role")" -ge 2 ]
check "secret ids do not expire (secret_id_ttl 0)" contains "$role" '"secret_id_ttl": 0'
printf 'only this' | dcf-secret put register/scribe --field private_key
tok="$(login_scribe)"
check "the back logs in from loopback with the files and reads its one secret" [ "$(BAO_TOKEN="$tok" dcf-secret get register/scribe --field private_key)" = 'only this' ]
rc=0; BAO_TOKEN="$tok" dcf-secret get ssh/key --field private_key > /dev/null 2>&1 || rc=$?
check "and nothing else (exit 13)" [ "$rc" = 13 ]
old_sid="$(cat "$state/approle/scribe/secret_id")"
t approle:issue ALL=1 > /dev/null 2>&1
check "ALL=1 wrote a new secret id" [ "$(cat "$state/approle/scribe/secret_id")" != "$old_sid" ]
rc=0; bao write auth/approle/login role_id="$(cat "$state/approle/scribe/role_id")" secret_id="$old_sid" > /dev/null 2>&1 || rc=$?
check "the earlier secret id no longer logs in" [ "$rc" != 0 ]
check "the new one does" login_scribe
# the CIDR bindings are enforced: the container's loopback is in them, so show the converse
make_root
BAO_TOKEN="$rootok" bao write auth/approle/role/scribe secret_id_bound_cidrs=10.0.0.0/8 > /dev/null
rc=0; out="$(login_scribe 2>&1)" || rc=$?
check "a secret id bound to another network cannot log in from loopback" [ "$rc" != 0 ]
check "and the refusal is the CIDR's" contains "$out" 'CIDR'
BAO_TOKEN="$rootok" bao write auth/approle/role/scribe secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=10.0.0.0/8 > /dev/null
drop_root
tok="$(login_scribe)"
rc=0; BAO_TOKEN="$tok" bao token lookup > /dev/null 2>&1 || rc=$?
check "a token bound to another network is refused from loopback" [ "$rc" != 0 ]
rc=0; bao delete auth/approle/role/scribe > /dev/null 2>&1 || rc=$?
check "the Operator's token cannot delete a role" [ "$rc" != 0 ]
term "task -t $tf approle:revoke ROLE=scribe" "$(sed -n 1p "$work/shares")" "$(sed -n 2p "$work/shares")"
check "approle:revoke through the shares exits 0" [ "$term_rc" = 0 ]
check "approle:revoke removed the files" test ! -e "$state/approle/scribe"
make_root
check "approle:revoke removed the role's policy" not env BAO_TOKEN="$rootok" bao read sys/policies/acl/approle-scribe
drop_root
check "the Operator's own login is still the Operator's (no root policy on it)" not contains "$(bao token lookup 2>&1)" 'root'
check "no share was echoed on the screen by revoke" excludes "$(cat "$work/screen.txt")" "$(sed -n 1p "$work/shares")"
rc=0; bao write auth/approle/login role_id=x secret_id=y > /dev/null 2>&1 || rc=$?
check "and the role no longer logs in" [ "$rc" != 0 ]

# --- seal, restart, unseal ----------------------------------------------------------------------------
t seal > /dev/null 2>&1
rc=0; out="$(dcf-secret status 2>/dev/null)" || rc=$?
check "after task openbao:seal dcf-secret is sealed (exit 11)" [ "$rc:$out" = 11:sealed ]
rc=0; err="$(dcf-secret get ssh/key 2>&1 > /dev/null)" || rc=$?
check "its line names task openbao:unseal" contains "$err" 'task openbao:unseal'
# a restart of the server: the process dies, the start hook brings it back, sealed
kill "$(cat "$state/server.pid")"
sleep 2
rc=0; out="$(dcf-secret status 2>/dev/null)" || rc=$?
check "with the server down dcf-secret is unreachable (exit 10)" [ "$rc:$out" = 10:unreachable ]
rc=0; err="$(dcf-secret get ssh/key 2>&1 > /dev/null)" || rc=$?
check "its line names task openbao:server:status" contains "$err" 'task openbao:server:status'
out="$(openbao-setup start)"
check "the start hook brings the server back sealed" contains "$out" 'sealed; the Operator runs task openbao:unseal'
rc=0; out="$(dcf-secret status 2>/dev/null)" || rc=$?
check "a restarted server is sealed (exit 11)" [ "$rc:$out" = 11:sealed ]
unseal_again
check "task openbao:unseal exits 0" [ "$term_rc" = 0 ]
check "the server is unsealed again" unsealed
check "what was written before the restart is still there (the login too)" [ "$(dcf-secret get ssh/key --field private_key)" = 'abc def' ]
check "the unseal printed no share" excludes "$(cat "$work/screen.txt")" "$(sed -n 1p "$work/shares")"

rm -rf "$work"
reportResults
