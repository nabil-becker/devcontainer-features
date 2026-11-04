#!/usr/bin/env bash
# Docker-free tests of the backup and restore half of openbao-server (src/openbao/openbao-server.sh)
# against a stub `bao` that keeps a small state and logs every call with the token it got. That the
# real bao gives the signals the stub plays (snapshot save and restore -force, the throwaway init,
# generate-root-token, the 403s) is checked by the container test test/openbao/backup_restore.sh
# (CI) and was run piece by piece against a real bao 2.7.2 server while this was written. Covered:
#  - openbao:backup: the file name openbao-<machine>-<UTC time>.snap and its content, the sha256
#    printed and recorded, never an overwrite (a name that exists), backupKeep / KEEP removing only
#    this machine's own pattern (never another machine's, a note, a name that is no time), 0 keeping
#    all, the option and its twin, the destination from DEST, the option or the choice recorded at
#    init, the exit codes (0, 10, 11 sealed and not initialised, 12, 13, 20, 2, 1), the backup role
#    logging in with files and never an argument, the temporary snapshot folder empty after success
#    and after every failure, no part file left in the destination;
#  - after-write: a reminder when there is no destination, the backup when there is one, and exit 0
#    when the backup fails (the write stands);
#  - the timer: its checks, one run writing a backup, a sealed server skipped and logged;
#  - server:status: the last backup's age and place, the warning past backupWarnAfter;
#  - openbao:restore: the refusals (an agent's job in each of the three ways, no terminal, client
#    mode, no file), a fresh server (the throwaway init, the snapshot installed, the root token
#    revoked, sealed, unsealed, the login, every role reissued, no marker left), a failed restore
#    leaving the marker and revoking the token, a half-done one starting again from empty, a store
#    in use (the confirmation, the root token from shares with the Operator's login, a login that
#    lacks the policy refused), run twice, another machine's file asking before it goes on;
#  - openbao:backup:role: the refusals and the role made with a root token from shares.
# Part of `task lint` (`task test:openbao-unit`). SCRIPT points the test at another copy of the
# script (used to show a test fails when the code it covers is broken). Needs script(1) for the
# terminal tests (skipped without it).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
script="${SCRIPT:-$root/src/openbao/openbao-server.sh}"

T="$(mktemp -d /tmp/obbak.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/feat-server" "$T/feat-client" "$T/state" "$T/dest" "$T/tmpfs" "$T/src"
cp "$root/src/openbao/env.sh" "$T/feat-server/env.sh"
cp "$root/src/openbao/openbao-lib.sh" "$T/feat-server/openbao-lib.sh"
cp "$root/src/openbao/env.sh" "$T/feat-client/env.sh"
cp "$root/src/openbao/openbao-lib.sh" "$T/feat-client/openbao-lib.sh"
printf 'MODE=server\n' > "$T/feat-server/options.env"
printf 'MODE=client\n' > "$T/feat-client/options.env"
install -m 0755 "$script" "$T/bin/openbao-server"
LOG="$T/calls.log"

cat > "$T/bin/bao" <<'STUB'
#!/bin/bash
# Stub bao. $STUB_DIR/stubstate is uninit, sealed, unsealed or down; $STUB_DIR/have lists what exists.
echo "$*" >> "$STUB_LOG"
echo "$1 $2 token=${BAO_TOKEN-unset}" >> "$STUB_DIR/tokens.log"
st="$(cat "$STUB_DIR/stubstate" 2>/dev/null || echo unsealed)"
have() { grep -qxF "$1" "$STUB_DIR/have" 2>/dev/null; }
add() { echo "$1" >> "$STUB_DIR/have"; }
bump() { local n; n=$(( $(cat "$STUB_DIR/$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/$1"; echo "$n"; }
case "$1 $2" in
  "status -format=json")
    case "$st" in
      uninit) echo '{"initialized": false, "sealed": true}'; exit 2 ;;
      sealed) echo '{"initialized": true, "sealed": true}'; exit 2 ;;
      down) exit 1 ;;
      *) echo '{"initialized": true, "sealed": false}'; exit 0 ;;
    esac ;;
  "token lookup") exit "${STUB_LOOKUP_RC:-0}" ;;
  "token revoke") exit 0 ;;
  "token capabilities")
    case "$3" in
      sys/storage/raft/snapshot) echo "${STUB_CAPS:-read}" ;;
      *) echo deny ;;
    esac; exit 0 ;;
  "write -field=token")
    echo "login: $*" >> "$STUB_DIR/login.log"
    [ "${STUB_LOGIN_RC:-0}" -eq 0 ] || { echo "Error: invalid role or secret ID" >&2; exit 2; }
    printf 'ROLE-TOKEN'; exit 0 ;;
  "operator raft")
    case "$4" in
      save)
        [ -z "${STUB_SAVE_FAIL:-}" ] || { echo "Error taking the snapshot: stub" >&2; exit 2; }
        echo "SNAPSHOT-$(bump snap.n)" > "$5"; exit 0 ;;
      restore)
        [ -z "${STUB_RESTORE_FAIL:-}" ] || { echo "Error installing the snapshot: stub" >&2; exit 2; }
        [ "$5" = -force ] || { echo "stub: restore without -force" >&2; exit 2; }
        echo "$6" > "$STUB_DIR/restored.from"
        echo sealed > "$STUB_DIR/stubstate"; echo 0 > "$STUB_DIR/unseal.n"; exit 0 ;;
    esac ;;
  "operator init")
    [ "$st" = uninit ] || exit 2
    [ -z "${STUB_INIT_FAIL:-}" ] || { echo "Error initializing: stub" >&2; exit 2; }
    echo sealed > "$STUB_DIR/stubstate"
    printf '{\n  "unseal_keys_b64": [\n    "THROWAWAY-KEY"\n  ],\n  "root_token": "s.THROWAWAY-ROOT"\n}\n'; exit 0 ;;
  "operator unseal")
    if [ "$3" = -reset ]; then echo 0 > "$STUB_DIR/unseal.n"; exit 0; fi
    if [ -n "${3:-}" ]; then echo unsealed > "$STUB_DIR/stubstate"; exit 0; fi
    n="$(bump unseal.n)"
    if [ "$n" -ge 2 ]; then echo unsealed > "$STUB_DIR/stubstate"; echo "Sealed false"; else echo "Unseal Progress 1/2"; fi
    exit 0 ;;
  "operator seal") echo sealed > "$STUB_DIR/stubstate"; exit 0 ;;
  "operator generate-root")
    case "$3" in
      -cancel) exit 0 ;;
      -generate-otp) echo "OTP-PAD"; exit 0 ;;
      -init) [ -z "${STUB_GR_INIT_FAIL:-}" ] || { echo "Error: permission denied" >&2; exit 2; }; exit 0 ;;
      -decode=-) cat > /dev/null; echo "s.ROOT-FROM-SHARES"; exit 0 ;;
      *)
        [ -z "${STUB_GR_FAIL:-}" ] || { echo "Error: wrong key" >&2; exit 2; }
        n="$(bump gr.n)"
        echo "Operation nonce: abc"
        if [ $(( n % 2 )) -eq 0 ]; then echo '{"nonce":"abc","complete":true,"encoded_token":"ENCODED"}'; else echo '{"nonce":"abc","complete":false,"encoded_token":""}'; fi
        exit 0 ;;
    esac ;;
  "login -no-print")
    [ -z "${STUB_PW_FAIL:-}" ] || { echo "Error authenticating: invalid username or password" >&2; exit 2; }
    echo "login ok" >> "$STUB_DIR/logins"; exit 0 ;;
  "read -format=json") echo '{"data": {"is_self": true}}'; exit 0 ;;
  "policy write") cat > "$STUB_DIR/policy.$3"; exit 0 ;;
  "list auth/approle/role")
    roles="$(sed -n 's#^auth/approle/role/##p' "$STUB_DIR/have" 2>/dev/null)"
    [ -n "$roles" ] || { echo "No value found" >&2; exit 2; }
    printf 'Keys\n----\n%s\n' "$roles"; exit 0 ;;
esac
case "$1" in
  read)
    case "$2" in
      -field=role_id) r="${3#auth/approle/role/}"; echo "ROLEID-${r%/role-id}"; exit 0 ;;
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
        n="$(bump sid.n)"; echo "ACC-$n" >> "$STUB_DIR/acc.$r"
        printf 'SECRETID-%s' "$n"; exit 0 ;;
      "auth/approle/role/"*) add "$2"; exit 0 ;;
    esac ;;
esac
echo "stub bao: unexpected call: $*" >&2
exit 99
STUB
cat > "$T/bin/date" <<'STUB'
#!/bin/bash
# a date that moves one second per call of the file-name format when STUB_DATE_SEQ is set, or stands
# still when STUB_DATE_FIXED is set
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "+%Y%m%dT%H%M%SZ" ]; then
  if [ -n "${STUB_DATE_FIXED:-}" ]; then echo "$STUB_DATE_FIXED"; exit 0; fi
  if [ -n "${STUB_DATE_SEQ:-}" ]; then
    n=$(( $(cat "$STUB_DIR/date.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/date.n"
    printf '20260101T0000%02dZ\n' "$n"; exit 0
  fi
fi
exec /usr/bin/date "$@"
STUB
cat > "$T/bin/sleep" <<'STUB'
#!/bin/bash
[ -z "${STUB_FAST_SLEEP:-}" ] || exit 0
exec /usr/bin/sleep "$@"
STUB
# openbao-setup start, as the restore runs it after clearing a half-done store: the server comes back empty
cat > "$T/bin/openbao-setup" <<'STUB'
#!/bin/bash
echo "setup $*" >> "$STUB_LOG"
mkdir -p "$OPENBAO_STATE_DIR/raft"
echo uninit > "$STUB_DIR/stubstate"
STUB
chmod +x "$T/bin/bao" "$T/bin/date" "$T/bin/sleep" "$T/bin/openbao-setup"

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
  rm -rf "${T:?}/state" "${T:?}"/acc.* "${T:?}"/sid.n "${T:?}"/unseal.n "${T:?}"/gr.n "${T:?}"/snap.n "${T:?}"/date.n \
    "${T:?}"/policy.* "${T:?}"/have "${T:?}"/tokens.log "${T:?}"/login.log "${T:?}"/logins "${T:?}"/restored.from "${T:?}"/dest "${T:?}"/tmpfs
  mkdir -p "$T/state/approle/backup" "$T/dest" "$T/tmpfs"
  printf 'ROLEID' > "$T/state/approle/backup/role_id"
  printf 'SECRETID-0' > "$T/state/approle/backup/secret_id"
  printf '%s\n' auth/approle/role/backup auth/approle/role/scribe > "$T/have"
  echo "${1:-unsealed}" > "$T/stubstate"
  printf 'MODE=server\n' > "$T/feat-server/options.env"
  : > "$LOG"
}
envs() {
  echo "PATH=$T/bin:/usr/local/bin:/usr/bin:/bin" "HOME=$T/home" "STUB_LOG=$LOG" "STUB_DIR=$T" "OPENBAO_STATE_DIR=$T/state" \
    "OPENBAO_FEATURE_DIR=$T/feat-${MODE_FEAT:-server}" "OPENBAO_BACKUP_TMP=$T/tmpfs" "OPENBAO_MACHINE=testbox" "STUB_FAST_SLEEP=1" "STUB_DATE_SEQ=1"
}
MODE_FEAT=server
run() { # [VAR=value ...] -- <args>: output in $out, exit status in $rc, no terminal
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  # shellcheck disable=SC2046  # envs prints words
  out="$(env -i $(envs) "${e[@]}" bash "$T/bin/openbao-server" "$@" 2>&1)"
  rc=$?
}
have_script=0
command -v script >/dev/null 2>&1 && have_script=1
term() { # <input: answers separated by ';'> [VAR=value ...] -- <args>
  local input="$1"
  shift
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  local cmd
  # shellcheck disable=SC2046  # envs prints words
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
snaps() { find "$1" -maxdepth 1 -name 'openbao-testbox-*.snap' | sort; }
nsnaps() { snaps "$1" | wc -l | tr -d ' '; }
tmp_empty() { [ -z "$(ls -A "$T/tmpfs")" ] && echo yes || echo no; }

# ================================================================================ backup ====
reset unsealed
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup: exit 0" 0 "$rc"
f="$(snaps "$T/dest" | head -n 1)"
check "backup: one file in the destination" 1 "$(nsnaps "$T/dest")"
check "backup: named openbao-<machine>-<UTC time>.snap" 1 "$(grep -cE '/openbao-testbox-[0-9]{8}T[0-9]{6}Z\.snap$' <<<"$f")"
check "backup: the file holds the snapshot" "SNAPSHOT-1" "$(cat "$f")"
sum="$(sha256sum "$f" | cut -d' ' -f1)"
has "backup: prints the path" "backup written: $f" "$out"
has "backup: prints the sha256" "sha256: $sum" "$out"
check "backup: last-backup records the sha256" "sha256=$sum" "$(grep '^sha256=' "$T/state/last-backup")"
check "backup: and the file" "file=$f" "$(grep '^file=' "$T/state/last-backup")"
has "backup: and the time" "time=20" "$(cat "$T/state/last-backup")"
check "backup: the first ISO UTC stamp in last-backup is the time the devhost briefing reads (briefing.py last_backup_age)" 1 "$(head -n 1 "$T/state/last-backup" | grep -cE '^time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
check "backup: last-backup is written atomically (no temporary file left)" 0 "$(find "$T/state" -name 'last-backup.tmp.*' | wc -l | tr -d ' ')"
check "backup: the file is mode 600" 600 "$(stat -c %a "$f")"
check "backup: the temporary folder is empty after a success" yes "$(tmp_empty)"
check "backup: no part file is left in the destination" 0 "$(find "$T/dest" -name '.openbao-backup-*' | wc -l | tr -d ' ')"
check "backup: logged in with the backup role, by files, never a secret in an argument" 1 "$(grep -c 'role_id=@.*/approle/backup/role_id secret_id=@.*/approle/backup/secret_id' "$T/login.log")"
lacks "backup: the secret id is in no argument" "SECRETID-0" "$(calls)"
check "backup: the snapshot is taken with the role's token" 1 "$(grep -c '^operator raft token=ROLE-TOKEN' "$T/tokens.log")"
check "backup: and the capability checked with it" 1 "$(grep -c '^token capabilities token=ROLE-TOKEN' "$T/tokens.log")"
lacks "backup: the Operator's login is not used when the role exists" "token lookup" "$(calls)"

# machine name and a destination from the places that can hold one
reset unsealed
run OPENBAO_MACHINE='my box/1' OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup: a machine name is made safe for a file name" 1 "$(find "$T/dest" -name 'openbao-my-box-1-*.snap' | wc -l | tr -d ' ')"
reset unsealed
run -- backup
check "backup with no destination: exit 2" 2 "$rc"
has "backup: says where one is named" "backupDest" "$out"
check "backup with no destination: bao is never called" "" "$(calls)"
printf 'choice=path\ndest=%s\ndate=2026-11-03T10:00:00Z\n' "$T/dest" > "$T/state/backup-choice"
run -- backup
check "backup: the destination recorded at init is the default" "0 1" "$rc $(nsnaps "$T/dest")"
reset unsealed
printf 'MODE=server\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-server/options.env"
run -- backup
check "backup: the backupDest option is the default" "0 1" "$rc $(nsnaps "$T/dest")"
mkdir -p "$T/dest2"
run OPENBAO_SETUP_BACKUP_DEST="$T/dest2" -- backup
check "backup: its twin overrides the option" "0 1" "$rc $(nsnaps "$T/dest2")"
run OPENBAO_SETUP_BACKUP_DEST="$T/dest2" OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup: DEST overrides both" "0 2" "$rc $(nsnaps "$T/dest")"
rm -rf "$T/dest2"

# never an overwrite
reset unsealed
echo "PRECIOUS" > "$T/dest/openbao-testbox-20260101T000000Z.snap"
run OPENBAO_TASK_DEST="$T/dest" STUB_DATE_FIXED=20260101T000000Z -- backup
check "backup: a name that exists is never overwritten: exit 1" 1 "$rc"
check "backup: the file that was there is untouched" "PRECIOUS" "$(cat "$T/dest/openbao-testbox-20260101T000000Z.snap")"
has "backup: says nothing was overwritten" "nothing was overwritten" "$out"
check "backup: no part file left after it" 0 "$(find "$T/dest" -name '.openbao-backup-*' | wc -l | tr -d ' ')"
check "backup: the temporary folder is empty after that failure" yes "$(tmp_empty)"
run OPENBAO_TASK_DEST="$T/dest" STUB_DATE_SEQ=1 -- backup
run OPENBAO_TASK_DEST="$T/dest" STUB_DATE_SEQ=1 -- backup
check "backup: two backups get two names" 3 "$(nsnaps "$T/dest")"

# retention (the old files are older than any new one, as in life)
reset unsealed
for i in 1 2 3 4 5; do echo "old$i" > "$T/dest/openbao-testbox-2025010${i}T000000Z.snap"; done
echo x > "$T/dest/openbao-otherbox-20200101T000000Z.snap"
echo x > "$T/dest/openbao-testbox-notatime.snap"
echo x > "$T/dest/openbao-testbox-20250101T000000Z.snap.bak"
echo x > "$T/dest/notes.txt"
mkdir "$T/dest/openbao-testbox-20250102T000000Z.snap.d"
run OPENBAO_TASK_DEST="$T/dest" OPENBAO_TASK_KEEP=3 -- backup
check "backup KEEP=3: this machine's three newest are left (the new one, and old 4 and 5)" "20250104 20250105 20260101" "$(for x in "$T"/dest/openbao-testbox-20*Z.snap; do b="${x##*/}"; echo "${b:16:8}"; done | paste -sd' ')"
has "backup KEEP=3: says what it removed" "removed 3 older" "$out"
for x in openbao-otherbox-20200101T000000Z.snap openbao-testbox-notatime.snap openbao-testbox-20250101T000000Z.snap.bak notes.txt openbao-testbox-20250102T000000Z.snap.d; do
  check "backup KEEP=3: $x is untouched" yes "$([ -e "$T/dest/$x" ] && echo yes || echo no)"
done
reset unsealed
for i in 1 2 3; do echo "old$i" > "$T/dest/openbao-testbox-2025010${i}T000000Z.snap"; done
run OPENBAO_TASK_DEST="$T/dest" OPENBAO_TASK_KEEP=0 -- backup
check "backup KEEP=0 keeps every backup" 4 "$(nsnaps "$T/dest")"
reset unsealed
for i in 1 2 3; do echo "old$i" > "$T/dest/openbao-testbox-2025010${i}T000000Z.snap"; done
printf 'MODE=server\nBACKUPKEEP=2\n' > "$T/feat-server/options.env"
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup: the backupKeep option keeps the newest 2" 2 "$(nsnaps "$T/dest")"
for i in 1 2 3; do echo "old$i" > "$T/dest/openbao-testbox-2025010${i}T000000Z.snap"; done
run OPENBAO_TASK_DEST="$T/dest" OPENBAO_SETUP_BACKUP_KEEP=1 -- backup
check "backup: its twin overrides it" 1 "$(nsnaps "$T/dest")"
run OPENBAO_TASK_DEST="$T/dest" OPENBAO_TASK_KEEP=abc -- backup
check "backup: a KEEP that is not a number: exit 2" 2 "$rc"
reset unsealed
for i in $(seq 1 31); do printf 'x' > "$T/dest/openbao-testbox-202501$(printf %02d "$i")T000000Z.snap"; done
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup: with nothing set the default keeps 30" 30 "$(nsnaps "$T/dest")"

# exit codes
reset sealed
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup on a sealed server: exit 11" 11 "$rc"
has "backup: names the unseal task" "task openbao:unseal" "$out"
check "backup sealed: nothing written" 0 "$(nsnaps "$T/dest")"
check "backup sealed: no snapshot call" 0 "$(grep -c 'snapshot save' "$LOG")"
reset uninit
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup on a server not initialised: exit 11" 11 "$rc"
reset down
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup with the server unreachable: exit 10" 10 "$rc"
reset unsealed
run OPENBAO_TASK_DEST="$T/nonexistent" -- backup
check "backup with DEST missing: exit 20" 20 "$rc"
has "backup: says the folder" "$T/nonexistent" "$out"
check "backup DEST missing: no snapshot was taken" 0 "$(grep -c 'snapshot save' "$LOG")"
check "backup DEST missing: the temporary folder is empty" yes "$(tmp_empty)"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/ro"; chmod 500 "$T/ro"
  run OPENBAO_TASK_DEST="$T/ro" -- backup
  check "backup with DEST not writable: exit 20" 20 "$rc"
  chmod 700 "$T/ro"; rmdir "$T/ro"
fi
reset unsealed
run OPENBAO_TASK_DEST="$T/dest" STUB_LOGIN_RC=2 -- backup
check "backup with a role that cannot log in: exit 12" 12 "$rc"
has "backup: says the role and the reissue" "approle:issue ROLE=backup" "$out"
check "backup login failed: nothing written" 0 "$(nsnaps "$T/dest")"
reset unsealed
run OPENBAO_TASK_DEST="$T/dest" STUB_CAPS=deny -- backup
check "backup with the snapshot read denied: exit 13" 13 "$rc"
check "backup denied: no snapshot call" 0 "$(grep -c 'snapshot save' "$LOG")"
check "backup denied: the temporary folder is empty" yes "$(tmp_empty)"
reset unsealed
run OPENBAO_TASK_DEST="$T/dest" STUB_SAVE_FAIL=1 -- backup
check "backup when bao cannot take the snapshot: exit 1" 1 "$rc"
has "backup: shows bao's message" "Error taking the snapshot" "$out"
check "backup save failed: nothing written" 0 "$(nsnaps "$T/dest")"
check "backup save failed: the temporary folder is empty" yes "$(tmp_empty)"
reset unsealed
run OPENBAO_BACKUP_TMP="$T/no-such-tmpfs" OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup without a tmpfs folder: exit 1, and nothing touches the disk" "1 0" "$rc $(grep -c 'snapshot save' "$LOG")"
# no role (a store made before 1.3.0): the sitting's login, and a line saying so
reset unsealed
rm -rf "$T/state/approle"
run OPENBAO_TASK_DEST="$T/dest" -- backup
check "backup with no backup role files: uses the login, exit 0" 0 "$rc"
has "backup: says so, and names the role task" "task openbao:backup:role" "$out"
reset unsealed
rm -rf "$T/state/approle"
run OPENBAO_TASK_DEST="$T/dest" STUB_LOOKUP_RC=2 -- backup
check "backup with no role and no login: exit 12" 12 "$rc"
# client mode: the sitting's token, no role
MODE_FEAT=client
reset unsealed
run OPENBAO_TASK_DEST="$T/dest" BAO_ADDR=https://bao.example.test BAO_TOKEN=s.owners -- backup
check "backup in client mode: exit 0" 0 "$rc"
check "backup in client mode: the token of the sitting is used, no role login" "0 1" "$(grep -c 'approle/login' "$LOG") $(grep -c '^operator raft token=s.owners' "$T/tokens.log")"
MODE_FEAT=server

# ============================================================================ after-write ====
# a client has no store of its own: nothing printed, nothing run, exit 0
MODE_FEAT=client
reset unsealed
printf 'MODE=client\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-client/options.env"
run -- after-write
check "after-write in client mode: exit 0, silent, no backup" "0  0" "$rc $out $(grep -c 'snapshot save' "$LOG")"
printf 'MODE=client\n' > "$T/feat-client/options.env"
MODE_FEAT=server
# the write tasks end with it (go-task stops at a failing first command, so a failed write never
# reaches it): the order in the Taskfile
for tk in ssh:new ssh:put ssh:import ssh:retire onboard:claim; do
  last="$(awk -v t="  $tk:" '$0 == t { f = 1; next } f && /^  [a-z]/ { f = 0 } f && /^      - / { l = $0 } f && /^      - / { n++; if (n > 0) prev2 = prev; prev = l } END { print l }' "$root/src/openbao/taskfile.yml")"
  check "task $tk ends with openbao-server after-write" "      - openbao-server after-write" "$last"
done
check "task ssh:age (a read) does not" 0 "$(awk '$0 == "  ssh:age:" { f = 1; next } f && /^  [a-z]/ { f = 0 } f && /after-write/' "$root/src/openbao/taskfile.yml" | wc -l | tr -d ' ')"
reset unsealed
run -- after-write
check "after-write with no destination: exit 0" 0 "$rc"
has "after-write: the reminder names the backup task" "not backed up since ever; task openbao:backup DEST=" "$out"
check "after-write with no destination: no backup is taken" 0 "$(grep -c 'snapshot save' "$LOG")"
printf 'time=2026-11-03T10:00:00Z\nepoch=1\nfile=x\nsha256=y\n' > "$T/state/last-backup"
run -- after-write
has "after-write: says since when" "not backed up since 2026-11-03T10:00:00Z" "$out"
printf 'MODE=server\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-server/options.env"
run -- after-write
check "after-write with a destination: exit 0 and a backup" "0 1" "$rc $(nsnaps "$T/dest")"
reset sealed
printf 'MODE=server\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-server/options.env"
run -- after-write
check "a write task whose backup fails (sealed) still exits 0" 0 "$rc"
has "after-write: says the write stands" "the write stands" "$out"
has "after-write: and the backup's exit code and meaning" "failed with exit 11" "$out"
reset unsealed
printf 'MODE=server\nBACKUPDEST=%q\n' "$T/nonexistent" > "$T/feat-server/options.env"
run -- after-write
check "a write task whose backup fails (no folder) still exits 0" 0 "$rc"
has "after-write: the folder's meaning" "failed with exit 20" "$out"
check "after-write failing: the temporary folder is empty" yes "$(tmp_empty)"

# ================================================================================ the timer ====
reset unsealed
run -- backup-timer-start
check "timer: no interval, no timer, silent" "0 " "$rc $out"
printf 'MODE=server\nBACKUPINTERVAL=1h\n' > "$T/feat-server/options.env"
run -- backup-timer-start
check "timer: no destination: exit 0, no timer" 0 "$rc"
has "timer: says it needs a destination" "no destination" "$out"
printf 'MODE=server\nBACKUPINTERVAL=soon\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-server/options.env"
run -- backup-timer-start
check "timer: a bad interval: exit 0, no timer" 0 "$rc"
has "timer: says what an interval looks like" "is not 5m, 6h, 1d" "$out"
printf 'MODE=server\nBACKUPINTERVAL=2m\nBACKUPDEST=%q\n' "$T/dest" > "$T/feat-server/options.env"
run -- backup-timer-start
has "timer: under 5 minutes is refused" "under 5 minutes" "$out"
MODE_FEAT=client
run OPENBAO_SETUP_BACKUP_INTERVAL=1h -- backup-timer-start
check "timer in client mode: silent, exit 0" "0 " "$rc $out"
MODE_FEAT=server
reset unsealed
run OPENBAO_SETUP_BACKUP_INTERVAL=1h OPENBAO_SETUP_BACKUP_DEST="$T/dest" OPENBAO_TIMER_SLEEP=1 OPENBAO_TIMER_TICKS=1 STUB_FAST_SLEEP= -- backup-timer-start
has "timer: starts and says where and how often" "backup timer started (every 1h into $T/dest" "$out"
for _ in $(seq 1 20); do [ "$(nsnaps "$T/dest")" -ge 1 ] && break; /usr/bin/sleep 0.5; done
check "timer: a tick wrote a backup" 1 "$(nsnaps "$T/dest")"
for _ in $(seq 1 20); do grep -q 'scheduled backup done' "$T/state/backup.log" 2>/dev/null && break; /usr/bin/sleep 0.5; done
has "timer: backup.log says it" "scheduled backup done" "$(cat "$T/state/backup.log")"
reset sealed
run OPENBAO_SETUP_BACKUP_INTERVAL=1h OPENBAO_TASK_DEST="$T/dest" OPENBAO_TIMER_SLEEP=0 OPENBAO_TIMER_TICKS=2 -- backup-timer-run
check "timer: a sealed server does not stop it (two ticks, exit 0)" 0 "$rc"
check "timer: each skipped tick is one line in backup.log" 2 "$(grep -c 'skipped or failed, exit 11' "$T/state/backup.log")"
has "timer: with the meaning" "the Operator runs task openbao:unseal" "$(cat "$T/state/backup.log")"
check "timer: nothing was written while sealed" 0 "$(nsnaps "$T/dest")"
check "timer: no retry loop (two snapshot attempts at most, none here)" 0 "$(grep -c 'snapshot save' "$LOG")"
# a second start while one lives
reset unsealed
( OPENBAO_STATE_DIR="$T/state" exec -a "x backup-timer-run" /usr/bin/sleep 30 ) &
tpid=$!
echo "$tpid" > "$T/state/backup-timer.pid"
/usr/bin/sleep 0.3
if tr '\0' ' ' < "/proc/$tpid/cmdline" | grep -q backup-timer-run; then
  run OPENBAO_SETUP_BACKUP_INTERVAL=1h OPENBAO_SETUP_BACKUP_DEST="$T/dest" -- backup-timer-start
  has "timer: a live one is reused" "already running" "$out"
else
  echo "skip - cannot name a process for the live timer test"
fi
kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null

# ============================================================================== status ====
reset unsealed
now="$(date -u +%s)"
printf 'choice=path\ndest=%s\ndate=2026-11-03T10:00:00Z\n' "$T/dest" > "$T/state/backup-choice"
printf 'time=2026-11-04T10:00:00Z\nepoch=%s\nfile=%s/openbao-testbox-x.snap\nsha256=abcdef0123456789\n' "$((now - 7200))" "$T/dest" > "$T/state/last-backup"
run -- status
has "status: the last backup's age" "last backup 2h ago" "$out"
has "status: and its place" "$T/dest/openbao-testbox-x.snap" "$out"
lacks "status: a recent backup is no warning" "WARNING" "$out"
printf 'time=x\nepoch=%s\nfile=y\nsha256=z\n' "$((now - 10 * 86400))" > "$T/state/last-backup"
run -- status
has "status: past 7 days is a warning" "WARNING last backup 10d ago (more than backupWarnAfter 7d)" "$out"
printf 'MODE=server\nBACKUPWARNAFTER=30d\n' > "$T/feat-server/options.env"
run -- status
lacks "status: backupWarnAfter moves the threshold" "WARNING" "$out"
run OPENBAO_SETUP_BACKUP_WARN_AFTER=1d -- status
has "status: its twin overrides it" "more than backupWarnAfter 1d" "$out"
printf 'choice=none\ndate=2026-11-03T10:00:00Z\n' > "$T/state/backup-choice"
printf 'MODE=server\n' > "$T/feat-server/options.env"
printf 'time=x\nepoch=%s\nfile=y\nsha256=z\n' "$((now - 30000))" > "$T/state/last-backup"
run -- status
has "status: an ad hoc backup is shown even with no destination chosen" "last backup 8h ago" "$out"

# ============================================================================== restore ====
snap="$T/src/openbao-testbox-20260101T000000Z.snap"
reset sealed
echo "SNAPSHOT-X" > "$snap"
for v in DEVHOST_JOB_CHILD CLAUDECODE; do
  run "$v=1" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore refuses inside an agent's job ($v): exit 3" 3 "$rc"
  has "restore ($v): names the variable" "refuses to run inside an agent's job ($v is set)" "$out"
  check "restore ($v): bao is never called" "" "$(calls)"
  run "$v=1" -- backup-role
  check "backup-role refuses inside an agent's job ($v): exit 3" 3 "$rc"
  check "backup-role ($v): bao is never called" "" "$(calls)"
done
run OPENBAO_AGENT_JOB_VARS="MYCLI" MYCLI=1 OPENBAO_TASK_FROM="$snap" -- restore
check "restore refuses for a variable named in OPENBAO_AGENT_JOB_VARS" 3 "$rc"
if command -v task >/dev/null 2>&1; then
  # shellcheck disable=SC2046  # envs prints words
  out="$(cd "$T" && env -i $(envs) DEVHOST_JOB_CHILD=1 task -t "$root/src/openbao/taskfile.yml" restore FROM="$snap" 2>&1)"
  rc=$?
  check "task openbao:restore refuses inside an agent's job" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  has "task openbao:restore: the refusal is the one shown" "refuses to run inside an agent's job (DEVHOST_JOB_CHILD is set)" "$out"
  check "task openbao:restore: bao is never called" "" "$(calls)"
  # shellcheck disable=SC2046
  out="$(cd "$T" && env -i $(envs) task -t "$root/src/openbao/taskfile.yml" restore 2>&1)"
  rc=$?
  check "task openbao:restore without FROM is refused by the Taskfile" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  # shellcheck disable=SC2046
  out="$(cd "$T" && env -i $(envs) OPENBAO_FEATURE_DIR="$T/feat-server" task -t "$root/src/openbao/taskfile.yml" backup 2>&1)"
  has "task openbao:backup runs the script (no destination named)" "no destination" "$out"
fi
reset sealed
run OPENBAO_TASK_FROM="$snap" -- restore
check "restore without a terminal: exit 3" 3 "$rc"
has "restore without a terminal: says so" "needs a terminal" "$out"
check "restore without a terminal: bao is never called" "" "$(calls)"
MODE_FEAT=client
run OPENBAO_TASK_FROM="$snap" -- restore
check "restore in client mode: exit 3" 3 "$rc"
has "restore in client mode: says why" "this container runs no server" "$out"
MODE_FEAT=server

if [ "$have_script" -eq 1 ]; then
  reset uninit
  term "" -- restore
  check "restore with no FROM: exit 2" 2 "$rc"
  term "" OPENBAO_TASK_FROM="$T/dest/nothing.snap" -- restore
  check "restore of a file that is not there: exit 2" 2 "$rc"
  check "restore refusals call no bao" "" "$(calls)"
  : > "$T/src/empty.snap"
  term "" OPENBAO_TASK_FROM="$T/src/empty.snap" -- restore
  check "restore of an empty file: exit 2" 2 "$rc"

  # a fresh server: the throwaway init, the snapshot, the shares, the login, every role reissued
  reset uninit
  echo "SNAPSHOT-X" > "$snap"
  term ";;secret-pw" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore on a fresh server: exit 0" 0 "$rc"
  order="$(grep -E '^(operator init|operator unseal|operator raft snapshot restore|token revoke|login)' "$LOG" | awk '{print $1" "$2" "$3}' | paste -sd'|')"
  check "restore fresh: the throwaway init, its unseal, the restore, then the unseal prompts, the login" \
    "operator init -key-shares=1|operator unseal THROWAWAY-KEY|operator raft snapshot|token revoke -self|operator unseal -reset|operator unseal |operator unseal |login -no-print -method=userpass" \
    "$(grep -E '^(operator init|operator unseal|operator raft snapshot restore|token revoke|login)' "$LOG" | sed -E 's/^(operator unseal THROWAWAY-KEY).*/\1/; s/^(operator raft snapshot restore).*/operator raft snapshot/; s/^(operator init -key-shares=1).*/\1/; s/^operator unseal$/operator unseal /; s/^(login -no-print -method=userpass).*/\1/' | paste -sd'|')"
  : "$order"
  has "restore fresh: installed with -force" "operator raft snapshot restore -force $snap" "$(calls)"
  check "restore fresh: with the throwaway root token" 1 "$(grep -c '^operator raft token=s.THROWAWAY-ROOT' "$T/tokens.log")"
  check "restore fresh: the throwaway token is revoked" 1 "$(grep -c '^token revoke token=s.THROWAWAY-ROOT' "$T/tokens.log")"
  check "restore fresh: no marker is left" no "$([ -e "$T/state/restore.pending" ] && echo yes || echo no)"
  check "restore fresh: last-restore is recorded" 1 "$(grep -c "^from=$snap" "$T/state/last-restore")"
  check "restore fresh: the server ends unsealed" unsealed "$(cat "$T/stubstate")"
  check "restore fresh: every role was reissued (backup and scribe)" "SECRETID-1 SECRETID-2" "$(cat "$T/state/approle/backup/secret_id") $(cat "$T/state/approle/scribe/secret_id")"
  check "restore fresh: no root token from shares was needed (the Operator's login reissues)" 0 "$(grep -c 'generate-root' "$LOG")"
  lacks "restore fresh: the throwaway key is not shown" "THROWAWAY" "$out"
  lacks "restore fresh: the throwaway token is not shown" "s.THROWAWAY" "$out"
  lacks "restore fresh: no password in any argument" "secret-pw" "$(calls)"
  check "restore fresh: nothing of the throwaway init is in the volume" "" "$(grep -rl 'THROWAWAY' "$T/state" 2>/dev/null)"
  has "restore fresh: says it is logged in" "you are logged in as the Operator" "$out"
  has "restore fresh: says the volume has no backup choice yet" "no backup choice yet" "$out"

  # a failed restore: the marker stays, the throwaway token is revoked, and the next run starts from empty
  reset uninit
  term "" OPENBAO_TASK_FROM="$snap" STUB_RESTORE_FAIL=1 -- restore
  check "restore failing in bao: exit 1" 1 "$rc"
  check "restore failed: the marker stays" yes "$([ -e "$T/state/restore.pending" ] && echo yes || echo no)"
  check "restore failed: the throwaway token is revoked" 1 "$(grep -c '^token revoke token=s.THROWAWAY-ROOT' "$T/tokens.log")"
  echo sealed > "$T/stubstate"  # the store is initialised with a share nobody has
  mkdir -p "$T/state/raft"; echo junk > "$T/state/raft/data"
  term ";;secret-pw" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore after a half-done one: exit 0" 0 "$rc"
  has "restore: says the earlier one did not finish" "did not finish" "$out"
  check "restore: the raft folder was cleared and the server started again" "1 0" "$(grep -c '^setup start' "$LOG") $(find "$T/state/raft" -mindepth 1 | wc -l | tr -d ' ')"
  check "restore: the marker is gone after the second run" no "$([ -e "$T/state/restore.pending" ] && echo yes || echo no)"

  # a failed init step leaves the marker too, and bao's init failing does not go on
  reset uninit
  term "" OPENBAO_TASK_FROM="$snap" STUB_INIT_FAIL=1 -- restore
  check "restore when the throwaway init fails: exit 1" 1 "$rc"
  check "restore: no snapshot was installed" 0 "$(grep -c 'snapshot restore' "$LOG")"

  # a store in use: the confirmation, a root token from shares made with the Operator's login
  reset unsealed
  term "no" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore on a store in use: anything but 'restore' stops: exit 3" 3 "$rc"
  has "restore: says it replaces everything" "REPLACES every secret" "$out"
  check "restore stopped: no root token was made, no snapshot installed" 0 "$(grep -c -E 'generate-root|snapshot restore' "$LOG")"
  reset unsealed
  term "restore;;;;;;pw" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore on a store in use: exit 0" 0 "$rc"
  check "restore in use: the root token generation was started once and not cancelled" "1 0" "$(grep -c '^operator generate-root -init' "$LOG") $(grep -c 'generate-root -cancel' "$LOG")"
  check "restore in use: the snapshot is installed with the root token from the shares" 1 "$(grep -c '^operator raft token=s.ROOT-FROM-SHARES' "$T/tokens.log")"
  check "restore in use: and that token is revoked" 1 "$(grep -c '^token revoke token=s.ROOT-FROM-SHARES' "$T/tokens.log")"
  lacks "restore in use: no throwaway init on a store that exists" "operator init" "$(calls)"
  lacks "restore in use: the root token is not shown" "s.ROOT-FROM-SHARES" "$out"
  check "restore in use: ends unsealed" unsealed "$(cat "$T/stubstate")"
  check "restore in use: every role reissued" "SECRETID-1 SECRETID-2" "$(cat "$T/state/approle/backup/secret_id") $(cat "$T/state/approle/scribe/secret_id")"
  # twice: it is safe
  term "restore;;;;;;pw" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore run a second time: exit 0" 0 "$rc"
  check "restore twice: ends unsealed, roles reissued again" "unsealed SECRETID-3 SECRETID-4" "$(cat "$T/stubstate") $(cat "$T/state/approle/backup/secret_id") $(cat "$T/state/approle/scribe/secret_id")"
  # a sealed store in use is unsealed first
  reset sealed
  term "restore;;;;;;;;pw" OPENBAO_TASK_FROM="$snap" -- restore
  check "restore on a sealed store in use: exit 0" 0 "$rc"
  has "restore sealed: asked to unseal the current store first" "enter shares of the current store" "$out"
  # the Operator's login may not start a generation (a server made by an unreleased 1.2.0): refused before any share
  reset unsealed
  term "restore" OPENBAO_TASK_FROM="$snap" STUB_GR_INIT_FAIL=1 -- restore
  check "restore in use when the generation cannot start: exit 3" 3 "$rc"
  check "restore refused: the store is untouched, and no attempt of another is cancelled" 0 "$(grep -c -E 'snapshot restore|generate-root -cancel' "$LOG")"
  reset unsealed
  term "restore" OPENBAO_TASK_FROM="$snap" STUB_LOOKUP_RC=2 -- restore
  check "restore in use without a login: exit 12" 12 "$rc"
  # a wrong share cancels the generation
  reset unsealed
  term "restore;;" OPENBAO_TASK_FROM="$snap" STUB_GR_FAIL=1 -- restore
  check "restore with a wrong share: exit 1" 1 "$rc"
  check "restore: the generation is cancelled and nothing installed" "yes 0" "$(grep -q 'generate-root -cancel' "$LOG" && echo yes) $(grep -c 'snapshot restore' "$LOG")"
  # the login after the restore fails
  reset uninit
  term "" OPENBAO_TASK_FROM="$snap" STUB_PW_FAIL=1 -- restore
  check "restore when the Operator login fails: exit 1" 1 "$rc"
  has "restore: names the two steps that finish it" "task openbao:approle:issue ALL=1" "$out"
  check "restore: the snapshot is nevertheless installed and unsealed" "unsealed 1" "$(cat "$T/stubstate") $(grep -c 'snapshot restore' "$LOG")"
  # another machine's file asks first
  reset uninit
  other="$T/src/openbao-otherbox-20260101T000000Z.snap"
  echo "SNAPSHOT-O" > "$other"
  term "no" OPENBAO_TASK_FROM="$other" -- restore
  check "restore of another machine's file, not confirmed: exit 3" 3 "$rc"
  has "restore: the warning names the machine and onboarding" "written on 'otherbox'" "$out"
  has "restore: and says what an onboarding hand-over is" "onboarding-<machine>-<time>.snap" "$out"
  check "restore: nothing was done" 0 "$(grep -c -E 'operator init|snapshot restore' "$LOG")"
  reset uninit
  term "restore;;secret-pw" OPENBAO_TASK_FROM="$other" -- restore
  check "restore of another machine's file, confirmed: exit 0" 0 "$rc"
  # a file that is not one of ours has no machine to warn about
  reset uninit
  cp "$snap" "$T/src/raft.snap"
  term ";;secret-pw" OPENBAO_TASK_FROM="$T/src/raft.snap" -- restore
  check "restore of a file with another name: no warning, exit 0" 0 "$rc"
  lacks "restore: no warning for it" "written on" "$out"

  # an onboarding snapshot (the file name prefix): said so, no other-machine warning or confirmation,
  # unsealed under its own shares, and none of the token-needing tail (no login, no reissue)
  reset uninit
  rm -rf "$T/state/approle"
  onb="$T/src/onboarding-otherbox-20260101T000000Z.snap"
  echo "SNAPSHOT-ONB" > "$onb"
  term ";;" OPENBAO_TASK_FROM="$onb" -- restore
  check "restore of an onboarding snapshot: exit 0" 0 "$rc"
  has "restore onboarding: says it is an onboarding snapshot from the machine" "onboarding snapshot, made on 'otherbox'" "$out"
  has "restore onboarding: points to the claim" "task openbao:onboard:claim" "$out"
  lacks "restore onboarding: not the other-machine warning" "WARNING" "$out"
  has "restore onboarding: installed with -force" "operator raft snapshot restore -force $onb" "$(calls)"
  check "restore onboarding: the server is left unsealed" unsealed "$(cat "$T/stubstate")"
  check "restore onboarding: no login and no root token from shares" 0 "$(grep -c -E '^login|generate-root' "$LOG")"
  check "restore onboarding: no role reissued, no secret id written" "" "$(find "$T/state/approle" -type f 2>/dev/null)"
  lacks "restore onboarding: nothing asked about the Operator's login" "log in as the Operator" "$out"
  check "restore onboarding: last-restore is recorded" 1 "$(grep -c "^from=$onb" "$T/state/last-restore")"
  # the same file name on a store in use still asks before it replaces anything
  reset unsealed
  term "no" OPENBAO_TASK_FROM="$onb" -- restore
  check "restore of an onboarding snapshot on a store in use asks first: exit 3" 3 "$rc"

  # backup:role
  reset unsealed
  rm -f "$T/have"; : > "$T/have"
  term ";;" -- backup-role
  check "backup-role: exit 0" 0 "$rc"
  has "backup-role: the policy is read on the snapshot path only" 'path "sys/storage/raft/snapshot"' "$(cat "$T/policy.approle-backup")"
  lacks "backup-role: nothing more in the policy" "update" "$(cat "$T/policy.approle-backup")"
  has "backup-role: the role is bound to loopback" "secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32" "$(calls)"
  has "backup-role: short tokens" "token_ttl=5m token_max_ttl=15m" "$(calls)"
  check "backup-role: written with the root token from the shares, which is revoked" "1 1" "$(grep -c '^write auth/approle/role/backup token=s.ROOT-FROM-SHARES' "$T/tokens.log") $(grep -c '^token revoke token=s.ROOT-FROM-SHARES' "$T/tokens.log")"
  check "backup-role: the secret id is in the volume" "SECRETID-1" "$(cat "$T/state/approle/backup/secret_id")"
  reset sealed
  term ";;" -- backup-role
  check "backup-role on a sealed server: exit 11" 11 "$rc"
else
  echo "skip - restore and backup-role under a terminal (no script(1))"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
