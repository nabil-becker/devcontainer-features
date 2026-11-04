#!/usr/bin/env bash
# Docker-free tests of openbao-ssh (src/openbao/openbao-ssh.sh, task openbao:ssh:*) with the real
# dcf-secret and ssh-keygen against a stub bao that keeps a small KV v2 store in a temp folder
# (kv_bao_stub.sh): new (an ed25519 record with its three fields and dated metadata, the tmpfs
# folder empty afterwards, a name never reused, the server's state first), put (stdin only),
# import FROM=file (a file, stdin, a protected key refused without a terminal), import
# FROM=ssh-agent against a key volume made in a temp folder (every key, the creation date from the
# .meta sidecar, fingerprints compared, a second run skipping what is there, a different key under
# the same name refused, the allowed_signers.history lines and the keys' own lines in
# .devcontainer/allowed_signers, the volume left as it was without a terminal), import
# FROM=agentic-register (register/<principal>), retire (the private key's versions destroyed, the
# public key kept, dated, --plan changing nothing), age and list, and the exit codes passed on from
# dcf-secret. No key is ever printed. Only throwaway keys. Part of `task lint` (`task
# test:openbao-unit`). SCRIPT points the test at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../src/openbao"
script="${SCRIPT:-$src/openbao-ssh.sh}"

T="$(mktemp -d /tmp/obssh.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store" "$T/shm" "$T/home" "$T/vol" "$T/reg/keys" "$T/feature"
install -m 0755 "$here/kv_bao_stub.sh" "$T/bin/bao"
install -m 0755 "$src/dcf-secret.sh" "$T/bin/dcf-secret"
LOG="$T/calls.log"

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

# A git repository to run in, so .devcontainer/allowed_signers has a home.
repo="$T/repo"
git init -q "$repo"

# run [VAR=value ...] -- <args>: stdout in $out, stderr in $err, exit status in $rc, from the repo.
INPUT=""
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$LOG"
  out="$(cd "$repo" && printf '%s' "$INPUT" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" BAO_STORE="$T/store" BAO_STUB_LOG="$LOG" \
    OPENBAO_FEATURE_DIR="$T/feature" OPENBAO_SSH_TMPDIR="$T/shm" OPENBAO_SSH_AGENT_SETUP=no-such-command DCF_SSH_KEY_TODAY=2026-11-04 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "${envs[@]}" bash "$script" "$@" 2>"$T/err")"
  rc=$?
  err="$(cat "$T/err")"
  INPUT=""
}
field() { cat "$T/store/dcf/$1/v$(cat "$T/store/dcf/$1/cur")/$2" 2>/dev/null; }
fp() { ssh-keygen -l -f "$1" | awk '{print $2}'; }
secretless() { # <name> <text>: no private key material in it
  lacks "$1" "PRIVATE KEY" "$2"
}

# --- new
run -- new --name alpha-sign
check "new: exit 0" 0 "$rc"
has "new: the private key is stored" "PRIVATE KEY" "$(field ssh/alpha-sign private_key)"
check "new: the public key is stored" "ssh-ed25519" "$(field ssh/alpha-sign public_key | awk '{print $1}')"
check "new: the purpose defaults to git-signing" "git-signing" "$(field ssh/alpha-sign purpose)"
check "new: the creation date is in the metadata" "2026-11-04" "$(cat "$T/store/dcf/ssh/alpha-sign/meta.created")"
check "new: the source is generated" "generated" "$(cat "$T/store/dcf/ssh/alpha-sign/meta.source")"
has "new: the record is created only if absent (-cas=0)" "kv put -cas=0 -mount=dcf ssh/alpha-sign private_key=-" "$(cat "$LOG")"
check "new: the public key alone on stdout" "$(field ssh/alpha-sign public_key)" "$out"
secretless "new: no private key on stdout or stderr" "$out$err"
lacks "new: the private key is never an argument" "PRIVATE" "$(cat "$LOG")"
check "new: the tmpfs folder is empty afterwards" "" "$(ls -A "$T/shm")"
has "new: names the next steps" "task ssh-agent:key:load NAME=ssh/alpha-sign" "$err"
run -- new --name alpha-sign
check "new: a name is never reused (exit 3)" 3 "$rc"
has "new: says so" "never reused" "$err"
run -- new --name ssh/beta-sign --comment beta --purpose register
check "new: an ssh/ prefix is accepted" 0 "$rc"
check "new: --purpose is kept" "register" "$(field ssh/beta-sign purpose)"
check "new: --comment is the key's comment" "beta" "$(field ssh/beta-sign public_key | awk '{print $3}')"
run -- new --name 'bad/name'
check "new: a name with a slash is refused (exit 2)" 2 "$rc"
run STUB_STATUS_RC=2 -- new --name gamma-sign
check "new: a sealed server is 11, from dcf-secret" 11 "$rc"
has "new: with dcf-secret's line" "task openbao:unseal" "$err"
check "new: nothing generated while sealed" "" "$(ls -A "$T/shm")"
check "new: nothing stored while sealed" "no" "$([ -d "$T/store/dcf/ssh/gamma-sign" ] && echo yes || echo no)"
run STUB_LOOKUP_RC=2 -- new --name gamma-sign
check "new: no token is 12" 12 "$rc"
run STUB_STATUS_RC=1 -- new --name gamma-sign
check "new: unreachable is 10" 10 "$rc"
run OPENBAO_SSH_TMPDIR="$T/no-such-dir" -- new --name gamma-sign
check "new: no tmpfs folder refuses (never a key on disk)" 1 "$rc"
has "new: says why" "no writable tmpfs" "$err"

# --- put: the key on stdin
ssh-keygen -q -t ed25519 -N '' -C putkey -f "$T/k-put"
INPUT="$(cat "$T/k-put")"
run -- put --name put-sign
check "put: exit 0" 0 "$rc"
check "put: the key stored byte for byte" "$(cat "$T/k-put")" "$(field ssh/put-sign private_key)"
check "put: the public key derived" "$(awk '{print $1, $2}' "$T/k-put.pub")" "$(field ssh/put-sign public_key | awk '{print $1, $2}')"
check "put: the source is import" "import" "$(cat "$T/store/dcf/ssh/put-sign/meta.source")"
lacks "put: the private key is never an argument" "PRIVATE" "$(cat "$LOG")"
INPUT="not a key"
run -- put --name put2-sign
check "put: what is not a private key is refused" 1 "$rc"
has "put: and says so" "not a private key" "$err"
check "put: nothing stored" "no" "$([ -d "$T/store/dcf/ssh/put2-sign" ] && echo yes || echo no)"
run -- put
check "put: NAME is required" 2 "$rc"

# --- import FROM=file
ssh-keygen -q -t ed25519 -N '' -C filekey -f "$T/file-sign"
run -- import --from file --file "$T/file-sign"
check "import file: exit 0" 0 "$rc"
check "import file: the name is the file's" "$(cat "$T/file-sign")" "$(field ssh/file-sign private_key)"
check "import file: the source file is left alone" "yes" "$([ -f "$T/file-sign" ] && echo yes || echo no)"
as="$repo/.devcontainer/allowed_signers"
has "import file: its line in .devcontainer/allowed_signers" "file-sign namespaces=\"git\" ssh-ed25519 $(awk '{print $2}' "$T/file-sign.pub")" "$(cat "$as")"
has "import file: the file has its header" "# Who may sign this repository's commits" "$(cat "$as")"
secretless "import file: no private key in allowed_signers" "$(cat "$as")"
ssh-keygen -q -t ed25519 -N '' -C stdinkey -f "$T/k-stdin"
INPUT="$(cat "$T/k-stdin")"
run -- import --from file --name streamed-sign
check "import file: from stdin (the launcher's stream)" 0 "$rc"
check "import file: stdin's key stored" "$(cat "$T/k-stdin")" "$(field ssh/streamed-sign private_key)"
secretless "import file: nothing printed" "$out$err"
INPUT="$(cat "$T/k-stdin")"
run -- import --from file
check "import file: stdin needs NAME" 2 "$rc"
ssh-keygen -q -t ed25519 -N 'a-passphrase' -C pp -f "$T/k-pp"
INPUT="$(cat "$T/k-pp")"
run -- import --from file --name pp-sign
check "import file: a protected key with no terminal is refused" 1 "$rc"
has "import file: says to run it in a terminal" "no terminal to ask on" "$err"
check "import file: nothing stored for it" "no" "$([ -d "$T/store/dcf/ssh/pp-sign" ] && echo yes || echo no)"
check "import file: the tmpfs folder is empty" "" "$(ls -A "$T/shm")"
run -- import --from file --file "$T/file-sign"
check "import file: the same name again is refused (exit 3)" 3 "$rc"
run -- import
check "import: FROM is required" 2 "$rc"
run -- import --from elsewhere
check "import: an unknown FROM is refused" 2 "$rc"

# --- import FROM=ssh-agent: a key volume in a temp folder
rm -f "$as"
vol="$T/vol"
ssh-keygen -q -t ed25519 -N '' -C one -f "$vol/one-sign"
printf 'created=2025-01-15\nsource=generated\n' >"$vol/one-sign.meta"
ssh-keygen -q -t ed25519 -N '' -C two -f "$vol/two-sign"
printf 'created=2025-06-01\nsource=import\n' >"$vol/two-sign.meta"
ssh-keygen -q -t ed25519 -N 'a-passphrase' -C three -f "$vol/three-sign"
ssh-keygen -q -t ed25519 -N '' -C old -f "$T/old-retired"
printf '* namespaces="git",valid-before="20250115" %s retired:old-retired:2025-01-15\n' "$(awk '{print $1, $2}' "$T/old-retired.pub")" >"$vol/allowed_signers.history"
chmod 600 "$vol"/*-sign
before="$(find "$vol" -type f -printf '%f %s %m\n' | sort | md5sum)"
run -- import --from ssh-agent --dir "$vol"
check "import ssh-agent: a key it could not import makes exit 1" 1 "$rc"
check "import ssh-agent: one-sign stored" "$(cat "$vol/one-sign")" "$(field ssh/one-sign private_key)"
check "import ssh-agent: two-sign stored" "$(cat "$vol/two-sign")" "$(field ssh/two-sign private_key)"
check "import ssh-agent: the creation date from the .meta sidecar" "2025-01-15" "$(cat "$T/store/dcf/ssh/one-sign/meta.created")"
check "import ssh-agent: the source is ssh-agent" "ssh-agent" "$(cat "$T/store/dcf/ssh/one-sign/meta.source")"
check "import ssh-agent: the fingerprints match" "$(fp "$vol/one-sign.pub")" "$(field ssh/one-sign public_key | ssh-keygen -l -f - | awk '{print $2}')"
has "import ssh-agent: the protected key is skipped without a terminal" "three-sign has a passphrase" "$err"
check "import ssh-agent: nothing stored for the protected key" "no" "$([ -d "$T/store/dcf/ssh/three-sign" ] && echo yes || echo no)"
has "import ssh-agent: the summary" "2 key(s) in OpenBao (0 already there), 1 not imported" "$err"
has "import ssh-agent: the history line carried over as it was" "retired:old-retired:2025-01-15" "$(cat "$as")"
has "import ssh-agent: a generated key's line has valid-after" "one-sign namespaces=\"git\",valid-after=\"20250115\"" "$(cat "$as")"
has "import ssh-agent: an imported key's line has none" "two-sign namespaces=\"git\" ssh-ed25519" "$(cat "$as")"
check "import ssh-agent: the volume is untouched without a terminal" "$before" "$(find "$vol" -type f -printf '%f %s %m\n' | sort | md5sum)"
has "import ssh-agent: says how to remove the volume's copy" "task ssh-agent:key:remove NAME=<key> DELETE=1" "$err"
has "import ssh-agent: without the ssh-agent Feature it says how to prove it by hand" "task ssh-agent:key:load NAME=ssh/one-sign" "$err"
secretless "import ssh-agent: no key printed" "$out$err"
lacks "import ssh-agent: no key in an argument" "PRIVATE" "$(cat "$LOG")"
check "import ssh-agent: the tmpfs folder is empty" "" "$(ls -A "$T/shm")"
if ssh-keygen -Y find-principals -s /dev/null -f "$as" >/dev/null 2>&1 || true; then
  # every line of the file parses as ssh-keygen's allowed signers format
  bad=0
  while IFS= read -r l; do
    case "$l" in '#'* | '') continue ;; esac
    printf '%s\n' "$(awk '{print $(NF-1), $NF}' <<<"$l")" | ssh-keygen -l -f - >/dev/null 2>&1 || bad=$((bad + 1))
  done < <(sed 's/ retired:[^ ]*$//' "$as")
  check "import ssh-agent: every allowed_signers line holds a public key" 0 "$bad"
fi
lines_before="$(wc -l <"$as")"
rm -f "$vol/three-sign"
run -- import --from ssh-agent --dir "$vol"
check "import ssh-agent: a second run is exit 0" 0 "$rc"
has "import ssh-agent: skips what is there" "2 key(s) in OpenBao (2 already there), 0 not imported" "$err"
check "import ssh-agent: allowed_signers is not duplicated" "$lines_before" "$(wc -l <"$as")"
ssh-keygen -q -t ed25519 -N '' -C clash -f "$T/clash"
mkdir -p "$T/vol2"
cp "$T/clash" "$T/vol2/one-sign"
run -- import --from ssh-agent --dir "$T/vol2"
check "import ssh-agent: another key under a stored name is refused" 1 "$rc"
has "import ssh-agent: and says so" "with ANOTHER key" "$err"
check "import ssh-agent: the stored key is unchanged" "$(cat "$vol/one-sign")" "$(field ssh/one-sign private_key)"
run DCF_SSH_AGENT_KEY_DIR="$T/none" -- import --from ssh-agent
check "import ssh-agent: no volume is exit 1" 1 "$rc"

# --- import FROM=agentic-register
ssh-keygen -q -t ed25519 -N '' -C '' -f "$T/reg/keys/scribe"
mkdir -p "$T/reg/keys/retired"
run AGENTIC_REGISTER_HOME="$T/reg" -- import --from agentic-register
check "import agentic-register: exit 0" 0 "$rc"
check "import agentic-register: under register/<principal>" "$(cat "$T/reg/keys/scribe")" "$(field register/scribe private_key)"
check "import agentic-register: purpose register" "register" "$(field register/scribe purpose)"
has "import agentic-register: names the AppRole step" "task openbao:approle:issue ROLE=<back>" "$err"
lacks "import agentic-register: writes no allowed_signers line" "scribe" "$(cat "$as")"

# --- retire
cur="$(cat "$T/store/dcf/ssh/alpha-sign/cur")"
pub="$(field ssh/alpha-sign public_key)"
run -- retire --name alpha-sign --plan
check "retire --plan: exit 0" 0 "$rc"
has "retire --plan: says nothing changed" "nothing was changed" "$err"
check "retire --plan: no new version" "$cur" "$(cat "$T/store/dcf/ssh/alpha-sign/cur")"
run -- retire --name ssh/alpha-sign
check "retire: exit 0" 0 "$rc"
has "retire: every version holding the private key destroyed" "kv destroy -mount=dcf -versions=1 ssh/alpha-sign" "$(cat "$LOG")"
check "retire: the current version has no private key" "" "$(field ssh/alpha-sign private_key)"
check "retire: the public key stays" "$pub" "$(field ssh/alpha-sign public_key)"
check "retire: dated in the data" "2026-11-04" "$(field ssh/alpha-sign retired)"
check "retire: dated in the metadata" "2026-11-04" "$(cat "$T/store/dcf/ssh/alpha-sign/meta.retired")"
check "retire: the creation date is kept" "2026-11-04" "$(cat "$T/store/dcf/ssh/alpha-sign/meta.created")"
run -- retire --name alpha-sign
check "retire: twice is exit 0 and says when" 0 "$rc"
has "retire: says it was retired" "was retired on 2026-11-04" "$err"
run -- retire --name no-such
check "retire: no such record is 14" 14 "$rc"

# --- age and list
run -- age
check "age: exit 0" 0 "$rc"
has "age: a live record with its date, age and fingerprint" "ssh/one-sign: created 2025-01-15, 658 day(s) old, $(fp "$vol/one-sign.pub")" "$out"
has "age: a retired record says so" "ssh/alpha-sign: created 2026-11-04, retired 2026-11-04" "$out"
has "age: an old key is warned about" "warning: ssh/one-sign is older than 365 days" "$err"
run SSH_KEY_MAX_AGE_DAYS=1000 -- age
lacks "age: SSH_KEY_MAX_AGE_DAYS moves the limit" "older than" "$err"
run -- list --active
lacks "list --active: no retired record" "ssh/alpha-sign" "$out"
has "list --active: the live ones" "ssh/one-sign" "$out"
run -- list
has "list: every record" "ssh/alpha-sign" "$out"
run -- exists ssh/one-sign
check "exists: 0 for a record" 0 "$rc"
run -- exists ssh/nope
check "exists: non-zero for none" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -rf "$T/store/dcf"
run -- age
check "age: no records is exit 0" 0 "$rc"
has "age: and says so" "no SSH key records" "$err"

secretless "no test output held a private key" "$(cat "$LOG")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
