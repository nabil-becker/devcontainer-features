#!/bin/bash
# Scenario 'backup_restore' (see scenarios.json): backup and restore against a real server
# (mode=server, OpenBao 2.7.1), remoteUser=vscode. A terminal is played with script(1), as in
# server_mode.sh. What it checks:
#   - init makes the backup role (a secret id and role id in the volume, mode 600) and the role may
#     read the snapshot and nothing more (no snapshot-force);
#   - task openbao:backup: the file name openbao-<machine>-<UTC time>.snap, the sha256 printed and
#     recorded, never an overwrite (two backups in a second), backupKeep removing only this
#     machine's own pattern, the temporary folder empty after success and after a failure, the exit
#     codes 11 (sealed), 20 (no folder), and the status line (age and place);
#   - the timer (backupInterval) writes into its destination and skips a sealed server;
#   - task openbao:restore on a store in use (a root token from two shares (as_root), started with the Operator's
#     login, the snapshot installed, sealed under its shares, unsealed, the Operator logs in, the
#     roles reissued) run twice, and on an empty server (the throwaway init), and after a half-done
#     one (restore.pending): the data of the backup is back, the login of the restored store works,
#     the backup role works again, and no share or password is in any file of the volume or on the
#     screen after the prompts;
#   - the refusals for restore and backup:role inside an agent's job and without a terminal.
set -e
trap '' PIPE # a command that ended before its answers were typed is a failed check, not a silent kill
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:8200
unset BAO_TOKEN
state="$OPENBAO_STATE_DIR"
tf="${OPENBAO_TEST_TASKFILE:-/usr/local/share/go-task/includes.d/openbao.yml}"
t() { task -t "$tf" "$@"; }
work="$(mktemp -d)"
pw='correct horse battery staple'
export OPENBAO_BACKUP_TMP="$work/tmpfs"
mkdir -p "$OPENBAO_BACKUP_TMP" "$work/dest" "$work/dest2"
export OPENBAO_MACHINE=testbox

# term <command> <answer>...: run the command under a pseudo-terminal, typing the answers one by
# one (ENTER is an empty line, SHARES reads shares 1 and 2 off the screen when init asks to press
# Enter); the screen is $work/screen.txt and the exit code $term_rc.
term() {
  local cmd="$1" a s1 s2 n_seen shares_typed
  local -A seen=()
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
        printf '\n' >&3 2>/dev/null || true
        sleep 1
        printf '%s\n' "$s1" >&3 2>/dev/null || true
        sleep 1
        printf '%s\n' "$s2" >&3 2>/dev/null || true
        ;;
      ENTER) printf '\n' >&3 2>/dev/null || true ;;
      UNSEAL_THEN_PASSWORD)
        # The restored store is sealed when the snapshot came from another store, and stays unsealed
        # when it holds the same unseal key (restoring a store onto itself): type the two shares at
        # each "Unseal Key" prompt that comes, until the password prompt shows
        shares_typed=0
        for _ in $(seq 1 240); do
          grep -aq 'Password (will' "$work/screen" 2>/dev/null && break
          if [ "$(grep -ac 'Unseal Key (will' "$work/screen" 2>/dev/null || true)" -gt "$shares_typed" ]; then
            sleep 0.5
            shares_typed=$((shares_typed + 1))
            if [ "$shares_typed" = 1 ]; then printf '%s\n' "$(s1)" >&3 2>/dev/null || true; else printf '%s\n' "$(s2)" >&3 2>/dev/null || true; fi
          fi
          sleep 0.5
        done
        sleep 0.5
        continue
        ;;
      @*) # @<text>: wait until the screen shows <text> once more than at the last wait for it, then a
          # moment for the prompt to turn echo off (what is typed earlier is echoed on the screen)
        n_seen="${seen[$a]:-0}"
        for _ in $(seq 1 120); do
          [ "$(grep -ac -- "${a#@}" "$work/screen" 2>/dev/null || true)" -gt "$n_seen" ] && break
          sleep 0.5
        done
        seen[$a]="$(grep -ac -- "${a#@}" "$work/screen" 2>/dev/null || true)"
        sleep 0.5
        continue
        ;;
      *) printf '%s\n' "$a" >&3 2>/dev/null || true ;;
    esac
    sleep "${TERM_DELAY:-1.2}"
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
s1() { sed -n 1p "$work/shares"; }
s2() { sed -n 2p "$work/shares"; }
snaps() { find "$1" -maxdepth 1 -name 'openbao-testbox-[0-9]*Z.snap' | sort; } # <folder>
nsnaps() { snaps "$1" | wc -l | tr -d ' '; }
login() { term "task -t $tf login -- -method=userpass username=operator" "$pw"; }

# --- init, with the backup folder named -----------------------------------------------------------
openbao-setup > /dev/null
openbao-setup start
term "task -t $tf init" "$work/dest" "$pw" "$pw" SHARES
check "task openbao:init exits 0 with a backup folder" [ "$term_rc" = 0 ]
check "the folder is recorded" grep -qx "dest=$work/dest" "$state/backup-choice"
check "init made the backup role's secret id (mode 600)" [ "$(stat -c %a "$state/approle/backup/secret_id")" = 600 ]
check "and its role id" test -s "$state/approle/backup/role_id"
login
check "the Operator can log in" [ "$(dcf-secret status)" = ready ]
check "the Operator may start a root token generation (the two generate-root-token paths in the operator policy)" bash -c "bao token capabilities sys/generate-root-token/update | grep -qw update"
check "but not use snapshot-force" bash -c "! bao write -f sys/storage/raft/snapshot-force"
printf 'before the backup' | dcf-secret put ssh/key --field private_key
role_token() { bao write -field=token auth/approle/login role_id="@$state/approle/backup/role_id" secret_id="@$state/approle/backup/secret_id"; }
check "the backup role logs in from loopback" role_token
check "the backup role may read the snapshot" bash -c "BAO_TOKEN=$(role_token) bao token capabilities sys/storage/raft/snapshot | grep -qw read"
check "but not snapshot-force" bash -c "! BAO_TOKEN=$(role_token) bao write -f sys/storage/raft/snapshot-force"
check "and not a secret" bash -c "! BAO_TOKEN=$(role_token) dcf-secret get ssh/key --field private_key"

# --- backup ---------------------------------------------------------------------------------------
out="$(t backup 2>&1)"; rc=$?
check "task openbao:backup exits 0" [ "$rc" = 0 ]
f1="$(snaps "$work/dest" | head -n 1)"
check "the file is openbao-<machine>-<UTC time>.snap" bash -c "[[ '$f1' =~ /openbao-testbox-[0-9]{8}T[0-9]{6}Z\\.snap\$ ]]"
check "the output names the file and its sha256" contains "$out" "backup written: $f1"
sum="$(sha256sum "$f1" | cut -d' ' -f1)"
check "the printed sha256 is the file's" contains "$out" "sha256: $sum"
check "last-backup records the file and the sha256" grep -qx "sha256=$sum" "$state/last-backup"
check "the temporary snapshot folder is empty after a success" [ -z "$(ls -A "$OPENBAO_BACKUP_TMP")" ]
check "no part file is left in the destination" [ -z "$(find "$work/dest" -name '.openbao-backup-*')" ]
check "a snapshot file is not readable by others" [ "$(stat -c %a "$f1")" = 600 ]
check "the snapshot holds no secret in clear" not grep -qaF 'before the backup' "$f1"
st="$(t server:status)" || true
check "server:status shows the age and the place" contains "$st" "last backup"
check "and the file" contains "$st" "$f1"
check "and no warning" excludes "$st" 'WARNING'
t backup > /dev/null 2>&1; t backup > /dev/null 2>&1
check "backups in the same second never overwrite: three files, three names" [ "$(nsnaps "$work/dest")" = 3 ]
check "the first file is unchanged" [ "$(sha256sum "$f1" | cut -d' ' -f1)" = "$sum" ]
# retention: only this machine's pattern
echo x > "$work/dest/other.snap"
echo x > "$work/dest/openbao-otherbox-20200101T000000Z.snap"
echo x > "$work/dest/openbao-testbox-notatime.snap"
echo x > "$work/dest/notes.txt"
out="$(t backup KEEP=2 2>&1)"
check "KEEP=2 leaves this machine's two newest" [ "$(nsnaps "$work/dest")" = 2 ] # the two newest (the non-time name is not counted by snaps)
check "the first file is gone" test ! -e "$f1"
check "it says what it removed" contains "$out" 'removed'
check "another file is untouched" test -e "$work/dest/other.snap"
check "another machine's backup is untouched" test -e "$work/dest/openbao-otherbox-20200101T000000Z.snap"
check "a name that is not the pattern is untouched" test -e "$work/dest/openbao-testbox-notatime.snap"
check "a note is untouched" test -e "$work/dest/notes.txt"
rc=0; t -x backup DEST="$work/nonexistent" > /dev/null 2>&1 || rc=$?
check "DEST missing: exit 20" [ "$rc" = 20 ]
check "and no temporary snapshot is left after the failure" [ -z "$(ls -A "$OPENBAO_BACKUP_TMP")" ]
chmod 500 "$work/dest2"
if [ "$(id -u)" != 0 ]; then
  rc=0; t -x backup DEST="$work/dest2" > /dev/null 2>&1 || rc=$?
  check "DEST not writable: exit 20" [ "$rc" = 20 ]
fi
chmod 700 "$work/dest2"
t seal > /dev/null 2>&1
rc=0; t -x backup DEST="$work/dest2" > /dev/null 2>&1 || rc=$?
check "a sealed server: exit 11" [ "$rc" = 11 ]
check "and nothing was written" [ "$(nsnaps "$work/dest2")" = 0 ]
st="$(t server:status)" || true
check "server:status on a sealed server still shows the last backup" contains "$st" "last backup"
term "task -t $tf unseal" "$(s1)" "$(s2)"
check "unseal again" [ "$term_rc" = 0 ]

# --- the timer --------------------------------------------------------------------------------------
OPENBAO_SETUP_BACKUP_INTERVAL=5m OPENBAO_SETUP_BACKUP_DEST="$work/dest2" OPENBAO_TIMER_SLEEP=3 openbao-setup start | grep -q 'backup timer started'
for _ in $(seq 1 20); do [ "$(nsnaps "$work/dest2")" -ge 1 ] && break; sleep 1; done
check "the timer wrote a backup into its destination" [ "$(nsnaps "$work/dest2")" -ge 1 ]
check "backup.log says it" grep -q 'scheduled backup done' "$state/backup.log"
out="$(OPENBAO_SETUP_BACKUP_INTERVAL=5m OPENBAO_SETUP_BACKUP_DEST="$work/dest2" openbao-setup start)"
check "a second start reuses the live timer" contains "$out" 'timer already running'
kill "$(cat "$state/backup-timer.pid")" 2>/dev/null || true

# --- the refusals -----------------------------------------------------------------------------------
refused() { [ "$1" != 0 ] && contains "$2" "refuses to run inside an agent's job"; }
for tk in restore backup:role; do
  rc=0; out="$(DEVHOST_JOB_CHILD=1 t "$tk" FROM="$f1" 2>&1 < /dev/null)" || rc=$?
  check "task openbao:$tk refuses inside the devhost's job" refused "$rc" "$out"
  rc=0; out="$(CLAUDECODE=1 t "$tk" FROM="$f1" 2>&1 < /dev/null)" || rc=$?
  check "task openbao:$tk refuses inside a Claude Code run" refused "$rc" "$out"
  rc=0; out="$(t "$tk" FROM="$f1" 2>&1 < /dev/null)" || rc=$?
  check "task openbao:$tk without a terminal is refused" [ "$rc" != 0 ]
  check "and says it needs a terminal" contains "$out" 'needs a terminal'
done
check "the refusals changed nothing: the server is unsealed" unsealed

# --- restore on a store in use, twice ------------------------------------------------------------------
snap="$(snaps "$work/dest" | tail -n 1)"
printf 'after the backup' | dcf-secret put ssh/key --field private_key
check "the secret was changed after the backup" [ "$(dcf-secret get ssh/key --field private_key)" = 'after the backup' ]
rc=0; out="$(t restore FROM="$work/nothing.snap" 2>&1 < /dev/null)" || rc=$?
check "restore of a file that is not there is refused" [ "$rc" != 0 ]
old_sid="$(cat "$state/approle/backup/secret_id")"
restore_in_use() {
  # the confirmation, two shares for the root token, two to unseal the restored store, the password
  term "task -t $tf restore FROM=$snap" @'Type: restore' restore @'Unseal share 1 of' "$(s1)" @'Unseal share 2 of' "$(s2)" UNSEAL_THEN_PASSWORD "$pw"
}
show_if_failed() { # the screen of a command that did not exit 0, shares and password masked
  [ "$term_rc" = 0 ] && return 0
  echo "--- the screen (shares and password masked):" >&2
  sed "s|$(s1)|<SHARE-1>|g; s|$(s2)|<SHARE-2>|g; s|$pw|<PASSWORD>|g" "$work/screen.txt" | head -c 3500 >&2
}
restore_fresh() { # no confirmation; two shares to unseal, the password
  term "task -t $tf restore FROM=$snap" UNSEAL_THEN_PASSWORD "$pw"
}
restore_in_use
show_if_failed
check "task openbao:restore on a store in use exits 0" [ "$term_rc" = 0 ]
check "it asked for the confirmation first" grep -q 'REPLACES every secret' "$work/screen.txt"
check "the server is unsealed again" unsealed
if grep -qF -- "$(s1)" "$work/screen.txt"; then
  echo "--- the screen of the restore, share 1 masked:" >&2
  sed "s|$(s1)|<SHARE-1>|g; s|$(s2)|<SHARE-2>|g" "$work/screen.txt" | head -c 3500 >&2
fi
check "the screen shows no share" bash -c "! grep -qF '$(s1)' $work/screen.txt"
check "the screen shows no password" bash -c "! grep -qF '$pw' $work/screen.txt"
check "the Operator is logged in by the restore" [ "$(dcf-secret status)" = ready ]
check "the secret is what the backup held" [ "$(dcf-secret get ssh/key --field private_key)" = 'before the backup' ]
check "the backup role has a new secret id" [ "$(cat "$state/approle/backup/secret_id")" != "$old_sid" ]
check "and logs in" role_token
rc=0; bao write auth/approle/login role_id="@$state/approle/backup/role_id" secret_id="$old_sid" > /dev/null 2>&1 || rc=$?
check "the old secret id does not" [ "$rc" != 0 ]
check "no throwaway marker is left" test ! -e "$state/restore.pending"
check "last-restore is recorded" test -s "$state/last-restore"
t backup DEST="$work/dest2" > /dev/null 2>&1
check "a backup after the restore works (the role was reissued)" [ "$(nsnaps "$work/dest2")" -ge 2 ]
printf 'again after' | dcf-secret put ssh/key --field private_key
restore_in_use; show_if_failed
check "restore run a second time exits 0" [ "$term_rc" = 0 ]
check "and the data is the backup's again" [ "$(dcf-secret get ssh/key --field private_key)" = 'before the backup' ]

# --- restore on an empty server (the throwaway init), and after a half-done one -----------------------
t seal > /dev/null 2>&1
kill "$(cat "$state/server.pid")"; sleep 2
rm -rf "$state/raft"
rm -f "$state/token"
openbao-setup start > /dev/null
rc=0; out="$(dcf-secret status 2>/dev/null)" || rc=$?
check "an emptied volume: the server is not initialised (exit 11)" [ "$rc:$out" = 11:not-initialised ]
restore_fresh
check "restore on an empty server exits 0 (no confirmation asked)" [ "$term_rc" = 0 ]
check "it said it initialises with a throwaway share" grep -q 'one throwaway share' "$work/screen.txt"
check "the server is unsealed" unsealed
check "the Operator's login of the restored store works" [ "$(dcf-secret status)" = ready ]
check "the data is the backup's" [ "$(dcf-secret get ssh/key --field private_key)" = 'before the backup' ]
check "the backup role logs in" role_token
check "no marker is left" test ! -e "$state/restore.pending"
echo "from=x" > "$state/restore.pending"
restore_fresh_after_marker() { term "task -t $tf restore FROM=$snap" "$(s1)" "$(s2)" "$pw"; }
restore_fresh_after_marker
check "restore after a half-done one (restore.pending) exits 0" [ "$term_rc" = 0 ]
check "it said the earlier restore did not finish" grep -q 'did not finish' "$work/screen.txt"
check "and the marker is gone" test ! -e "$state/restore.pending"
check "the data is the backup's" [ "$(dcf-secret get ssh/key --field private_key)" = 'before the backup' ]
# a snapshot from another machine is warned about, and stopped unless confirmed
cp "$snap" "$work/dest/openbao-otherbox-20260101T000000Z.snap"
term "task -t $tf restore FROM=$work/dest/openbao-otherbox-20260101T000000Z.snap" no
check "a snapshot from another machine, not confirmed: stopped" [ "$term_rc" != 0 ]
check "with the warning naming onboarding" grep -q 'onboarding' "$work/screen.txt"
check "and the server untouched" unsealed
# backup:role on a store that has it
term "task -t $tf backup:role" "$(s1)" "$(s2)"
check "task openbao:backup:role exits 0" [ "$term_rc" = 0 ]
check "the role logs in after it" role_token

# --- nothing secret at rest ---------------------------------------------------------------------------
check "no share is in any file of the volume" not in_files "$(s1)" "$state"
check "no share is in the backup folders" not in_files "$(s1)" "$work/dest"
check "the temporary snapshot folder is empty at the end" [ -z "$(ls -A "$OPENBAO_BACKUP_TMP")" ]

rm -rf "$work"
reportResults
