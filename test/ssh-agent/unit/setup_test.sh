#!/usr/bin/env bash
# Docker-free tests of ssh-agent-setup (src/ssh-agent/ssh-agent-setup.sh): the verdict per
# DCF_HOST_SSH_AGENT (socket, none, key, unknown), key mode (an agent started on the fixed path,
# keys loaded from the key folder, a group/world-readable key refused, key-new, key-stdin,
# key-remove), the refusal when key mode is off, git-signing (KEY by fingerprint or .pub, SCOPE
# and its default) and git-verify (a real sign and verify round trip through the agent). It uses
# the real OpenSSH tools and git against temp folders: the script's fixed socket and key folder
# are redirected with DCF_SSH_AGENT_SOCK and DCF_SSH_AGENT_KEY_DIR, and only throwaway keys
# made here exist. Part of `task lint` (`task test:ssh-agent-unit`). SETUP_SH points the tests
# at another copy of the script (used to show a test fails when the code it covers is broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/ssh-agent/ssh-agent-setup.sh}"
for t in ssh-agent ssh-add ssh-keygen git; do
  command -v "$t" >/dev/null 2>&1 || { echo "setup_test: $t is required"; exit 1; }
done

# A short path: a unix socket path is limited to about 100 characters.
T="$(mktemp -d /tmp/sshat.XXXXXX)"
cleanup() { pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/home" "$T/keys"
SOCK="$T/agent.sock"
KEYS="$T/keys"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>: the output contains the text
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
lacks() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}

# run [VAR=value ...] -- <script args>: out = stdout+stderr, rc = exit status. Clean environment.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out="$(cd "$REPO" && env -i PATH="$PATH" HOME="$T/home" DCF_SSH_AGENT_SOCK="$SOCK" DCF_SSH_AGENT_KEY_DIR="$KEYS" \
    "${envs[@]}" setsid -w timeout 30 bash "$setup_sh" "$@" 2>&1)"
  rc=$?
}

mkdir -p "$T/repo"
git -C "$T/repo" init -q
REPO="$T/repo"

# --- no agent anywhere
run -- check
check 'unknown host, no agent: check exits 1' 1 "$rc"
has 'unknown host says how to start properly' 'host is unknown' "$out"
run -- setup
check 'setup never fails' 0 "$rc"
has 'setup on an unknown host says so' 'host unknown' "$out"

run DCF_HOST_SSH_AGENT=none DCF_HOST_TYPE=windows-docker -- setup
check 'none: setup exits 0' 0 "$rc"
has 'none names the host type' 'host type windows-docker' "$out"
has 'none names the VS Code way round' 'VS Code' "$out"
has 'none names the key mode way round' 'key mode' "$out"
run DCF_HOST_SSH_AGENT=none DCF_HOST_TYPE=windows-wslc -- check
check 'none: check exits 1' 1 "$rc"

run DCF_HOST_SSH_AGENT=socket DCF_HOST_TYPE=linux -- check
check 'socket, nothing answers: check exits 1' 1 "$rc"
has 'socket, nothing answers: says not reachable' 'not reachable' "$out"

# --- a host agent (simulated by an agent started here on the fixed path)
ssh-agent -a "$SOCK" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C 'throwaway-a' -f "$T/a" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C 'throwaway-b' -f "$T/b" >/dev/null
SSH_AUTH_SOCK="$SOCK" ssh-add -q "$T/a"
run DCF_HOST_SSH_AGENT=socket DCF_HOST_TYPE=linux -- setup
check 'socket: setup exits 0' 0 "$rc"
has "socket: reports the host's agent with its key count" "the host's agent reachable at $SOCK, 1 key(s) loaded" "$out"
run DCF_HOST_SSH_AGENT=socket -- check
check 'socket: check exits 0' 0 "$rc"
run -- keys
has 'keys lists the fingerprint and comment' 'throwaway-a' "$out"
run DCF_HOST_SSH_AGENT=none DCF_HOST_TYPE=windows-docker -- check
check 'none but an agent answers anyway: reported reachable, exit 0' 0 "$rc"
run DCF_HOST_SSH_AGENT=socket SSH_AUTH_SOCK=/nonexistent/forwarded -- check
check 'a dead SSH_AUTH_SOCK in this shell does not hide the fixed path' 0 "$rc"
run -- key-load
check 'key-load refuses when key mode is off' 1 "$rc"
has 'the refusal says how to turn key mode on' 'keyMode: true' "$out"
run DCF_HOST_SSH_AGENT=socket -- key-add "$T/b"
check 'key-add refuses in socket mode' 1 "$rc"
check 'key-add copied nothing in socket mode' 0 "$(find "$KEYS" -type f | wc -l)"
run DCF_HOST_SSH_AGENT=socket -- key-new
check 'key-new refuses in socket mode' 1 "$rc"
printf 'x\n' > "$T/x"
run DCF_HOST_SSH_AGENT=socket -- key-stdin b < "$T/x"
check 'key-stdin refuses in socket mode' 1 "$rc"
has 'the refusal points socket users at the host ssh-add' 'task devcontainer:ssh-add' "$out"

# --- git signing through that agent
SSH_AUTH_SOCK="$SOCK" ssh-add -q "$T/b"
fp_a="$(ssh-keygen -l -f "$T/a.pub" | awk '{print $2}')"
fp_b="$(ssh-keygen -l -f "$T/b.pub" | awk '{print $2}')"
run -- git-signing
check 'git-signing with two keys and no KEY exits 1' 1 "$rc"
has 'it lists the keys and asks for KEY' 'KEY=' "$out"
run -- git-signing "$fp_b" repo
check 'git-signing by fingerprint exits 0' 0 "$rc"
check 'gpg.format is ssh' ssh "$(git -C "$T/repo" config --local gpg.format)"
check 'user.signingkey is the chosen public key' "key::$(awk '{print $1 " " $2}' "$T/b.pub")" "$(git -C "$T/repo" config --local user.signingkey)"
check 'commit.gpgsign is true' true "$(git -C "$T/repo" config --local commit.gpgsign)"
check 'tag.gpgsign is true' true "$(git -C "$T/repo" config --local tag.gpgsign)"
has 'SCOPE=repo warns that the config may be shared with the host' 'can be shared with the Windows host' "$out"
run -- git-signing "$T/a.pub" repo
check 'git-signing by .pub path exits 0' 0 "$rc"
check 'user.signingkey follows the .pub path' "key::$(awk '{print $1 " " $2}' "$T/a.pub")" "$(git -C "$T/repo" config --local user.signingkey)"
run -- git-signing "SHA256:nosuchfingerprint" repo
check 'git-signing with an unknown fingerprint exits 1' 1 "$rc"
run -- git-signing "$fp_a" nowhere
check 'git-signing with a bad SCOPE exits 1' 1 "$rc"
run GIT_CONFIG_GLOBAL="$T/gitconfig" -- git-signing "$fp_a" global
check 'SCOPE=global writes the global config' ssh "$(git config --file "$T/gitconfig" gpg.format)"
git -C "$T/repo" config --local --unset-all gpg.format
run -- git-signing "$fp_a"
has 'default scope without a git Feature volume is repo' 'using repo' "$out"
run GIT_CONFIG_GLOBAL=/var/lib/devcontainer-features/git/config -- git-signing "$fp_a"
has 'default scope with the git Feature volume is global' 'using global' "$out"

git -C "$T/repo" config --local user.signingkey "key::$(awk '{print $1 " " $2}' "$T/a.pub")"
git -C "$T/repo" config --local gpg.format ssh
run -- git-verify
check 'git-verify exits 0 with the key in the agent' 0 "$rc"
has 'git-verify says ok' 'ok: signed a throwaway message' "$out"
git -C "$T/repo" config --local user.signingkey "key::$(awk '{print $1 " " $2}' "$T/a.pub")"
ssh-keygen -q -t ed25519 -N '' -C 'not-loaded' -f "$T/c" >/dev/null
git -C "$T/repo" config --local user.signingkey "key::$(awk '{print $1 " " $2}' "$T/c.pub")"
run -- git-verify
check 'git-verify exits 1 with a key the agent does not hold' 1 "$rc"
has 'git-verify says why' 'signing failed' "$out"
git -C "$T/repo" config --local --unset-all gpg.format
run -- git-verify
check 'git-verify without ssh signing configured exits 1' 1 "$rc"

# --- key mode: the in-container agent on the fixed path
pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -f "$SOCK"
run DCF_HOST_SSH_AGENT=key -- setup
check 'key mode: setup exits 0' 0 "$rc"
has 'key mode: starts an agent on the fixed path' 'started an agent inside the container' "$out"
has 'key mode: no key yet' 'no private key' "$out"
has 'key mode says it breaks the no-key rule' "the key never enters the container" "$out"
run DCF_HOST_SSH_AGENT=key -- setup
has 'key mode is idempotent: a live agent is reused' 'already answers' "$out"
# a stale socket (the agent died) is removed and replaced
pkill -f "ssh-agent -a $T/"; sleep 0.3
run DCF_HOST_SSH_AGENT=key -- setup
has 'key mode replaces a stale socket' 'started an agent' "$out"

run DCF_HOST_SSH_AGENT=key -- key-new signing 'test key' 1
check 'key-new exits 0' 0 "$rc"
check 'key-new put a 0600 private key in the volume' 600 "$(stat -c %a "$KEYS/signing")"
has 'key-new prints the public key' 'ssh-ed25519 ' "$out"
lacks 'key-new never prints the private key' 'PRIVATE KEY' "$out"
run DCF_HOST_SSH_AGENT=key -- keys
has 'the new key is in the agent' 'test key' "$out"
run DCF_HOST_SSH_AGENT=key -- key-new signing
check 'key-new refuses to overwrite' 1 "$rc"
run DCF_HOST_SSH_AGENT=key -- key-new ../evil '' 1
check 'key-new refuses a path as NAME' 1 "$rc"

# a key with group/world access is refused, a 0600 one loads
cp "$T/b" "$KEYS/loose"; chmod 644 "$KEYS/loose"
run DCF_HOST_SSH_AGENT=key -- key-load
check 'key-load exits 0' 0 "$rc"
has 'a 0644 key is refused with a clear message' 'refusing loose: mode 644' "$out"
has 'the summary counts the refusal' '1 refused' "$out"
SSH_AUTH_SOCK="$SOCK" ssh-add -L | grep -q "$(awk '{print $2}' "$T/b.pub")" && loose_loaded=yes || loose_loaded=no
check 'the refused key is not in the agent' no "$loose_loaded"
chmod 600 "$KEYS/loose"
run DCF_HOST_SSH_AGENT=key -- key-load
has 'once chmod 600 it loads' '2 of 2 key(s)' "$out"

run DCF_HOST_SSH_AGENT=key -- git-signing '' repo
check 'git-signing in key mode with two keys needs KEY' 1 "$rc"
run DCF_HOST_SSH_AGENT=key -- key-remove loose 1
check 'key-remove exits 0' 0 "$rc"
check 'key-remove DELETE=1 deletes it from the volume' no "$([ -e "$KEYS/loose" ] && echo yes || echo no)"
run DCF_HOST_SSH_AGENT=key -- git-signing '' repo
check 'with one key left git-signing needs no KEY' 0 "$rc"
run DCF_HOST_SSH_AGENT=key -- git-verify
check 'key mode: git-verify signs and verifies through the in-container agent' 0 "$rc"
run DCF_HOST_SSH_AGENT=key -- key-remove signing
check 'key-remove without DELETE keeps the file' yes "$([ -e "$KEYS/signing" ] && echo yes || echo no)"
has 'and says it returns at the next start' 'returns at the next start' "$out"

# key-add: copies the private key (0600) and the .pub beside it
cp "$T/c" "$T/c2"; cp "$T/c.pub" "$T/c2.pub"
run DCF_HOST_SSH_AGENT=key -- key-add "$T/c2"
check 'key-add exits 0' 0 "$rc"
check 'key-add stores the key 0600' 600 "$(stat -c %a "$KEYS/c2")"
check 'key-add brings the .pub along' yes "$([ -e "$KEYS/c2.pub" ] && echo yes || echo no)"
run DCF_HOST_SSH_AGENT=key -- key-add "$T/c.pub"
check 'key-add refuses a public key file' 1 "$rc"

# key-stdin: bytes on stdin, never an argument; CRLF is normalised; junk refused
sed 's/$/\r/' "$T/b" > "$T/b.crlf"
run DCF_HOST_SSH_AGENT=key -- key-stdin imported < "$T/b.crlf"
check 'key-stdin exits 0' 0 "$rc"
check 'key-stdin stores 0600' 600 "$(stat -c %a "$KEYS/imported")"
check 'key-stdin removed the carriage returns' 0 "$(grep -c "$(printf '\r')" "$KEYS/imported")"
has 'key-stdin prints the fingerprint' "$fp_b" "$out"
lacks 'key-stdin never prints key material' 'PRIVATE KEY' "$out"
echo 'not a key' > "$T/junk.in"
run DCF_HOST_SSH_AGENT=key -- key-stdin junk < "$T/junk.in"
check 'key-stdin refuses what is not a private key' 1 "$rc"
check 'nothing kept for the refused input' no "$([ -e "$KEYS/junk" ] && echo yes || echo no)"
check 'no temp file left behind' 0 "$(find "$KEYS" -name '.in.*' | wc -l)"

# --- key hygiene, rotation and retirement (stubbed gh; the real OpenSSH tools and git)
# A fresh key volume and repository. Stubs sit first on PATH: gh (never the real one: DCF_GH names it, or a
# missing path to simulate its absence), hostname, and thin ssh-keygen / ssh-add wrappers that log the calls
# that matter to $EV (events, in order) and delegate to the real tools; STUB_FAIL_SIGN=1 makes signing fail.
pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -f "$SOCK"
KEYS="$T/keys2"; mkdir -p "$KEYS"
REPO="$T/repo2"; mkdir -p "$REPO"; git -C "$REPO" init -q
STUBS="$T/stubs"; mkdir -p "$STUBS"
EV="$T/events"; GHLIST="$T/ghlist"; : > "$EV"
real_keygen="$(command -v ssh-keygen)"; real_add="$(command -v ssh-add)"
cat > "$STUBS/gh" <<'STUB'
#!/bin/sh
echo "gh $*" >> "$DCF_TEST_EVENTS"
case "$1 $2" in
  "auth status") exit "${STUB_GH_AUTH:-0}" ;;
  "ssh-key list") [ -f "$STUB_GH_LIST" ] && cat "$STUB_GH_LIST"; exit 0 ;;
  "ssh-key add") [ "${STUB_GH_ADD_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
STUB
cat > "$STUBS/hostname" <<'STUB'
#!/bin/sh
echo "Box_01.Example"
STUB
cat > "$STUBS/ssh-keygen" <<STUB
#!/bin/sh
case "\$*" in
  *"-Y sign"*) echo keygen-sign >> "\$DCF_TEST_EVENTS"; if [ "\${STUB_FAIL_SIGN:-}" = 1 ]; then echo "stub: signing refused" >&2; exit 1; fi ;;
  *"-t ed25519"*) echo keygen-new >> "\$DCF_TEST_EVENTS" ;;
esac
exec "$real_keygen" "\$@"
STUB
cat > "$STUBS/ssh-add" <<STUB
#!/bin/sh
[ "\$1" = -d ] && echo ssh-add-d >> "\$DCF_TEST_EVENTS"
exec "$real_add" "\$@"
STUB
chmod +x "$STUBS"/*
ENVR=(DCF_HOST_SSH_AGENT=key "PATH=$STUBS:$PATH" "DCF_TEST_EVENTS=$EV" "DCF_GH=$STUBS/gh" "STUB_GH_LIST=$GHLIST" "GIT_CONFIG_GLOBAL=$T/gitconfig2" DCF_SSH_KEY_TODAY=2026-10-24)
rr() { run "${ENVR[@]}" "$@"; } # rr [VAR=value ...] -- args
agent_has() { SSH_AUTH_SOCK="$SOCK" ssh-add -L 2>/dev/null | grep -qF "$(awk '{print $2}' "$1")" && echo yes || echo no; }
tree_sum() { { (cd "$KEYS" && find . -type f -exec sha256sum {} + | sort); cat "$T/gitconfig2" 2>/dev/null; SSH_AUTH_SOCK="$SOCK" ssh-add -L 2>/dev/null; } | sha256sum; }
line_of() { grep -n -m1 -- "$1" "$EV" | cut -d: -f1; }
blob_of() { awk '{print $2}' "$1"; }
gh_registers() { # <pub> <id>: the gh list shows this key registered
  printf 'a title\t%s\t%s\tsigning\tabout now\n' "$2" "$(awk '{print $1 " " $2}' "$1")" >> "$GHLIST"
}

rr -- setup
has 'rotation section: key mode agent up' 'started an agent' "$out"

# key:new default name: <repo>-<container>-sign, sanitised
rr -- key-new '' '' 1
check 'key-new with no NAME exits 0' 0 "$rc"
check 'key-new default name is <repo>-<container>-sign, sanitised to [a-z0-9-]' yes "$([ -f "$KEYS/repo2-box-01-example-sign" ] && echo yes || echo no)"
has 'key-new says to register as a SIGNING key, not an authentication key' 'register as a SIGNING key, not an authentication key' "$out"
lacks 'key-new with a dedicated name does not warn about a default name' 'default name' "$out"
lacks 'key-new never prints the private key' 'PRIVATE KEY' "$out"
check 'key-new records the creation date in a sidecar' 'created=2026-10-24' "$(sed -n 1p "$KEYS/repo2-box-01-example-sign.meta")"
rr -- key-remove repo2-box-01-example-sign 1
check 'key-remove DELETE=1 also drops the sidecar' no "$([ -e "$KEYS/repo2-box-01-example-sign.meta" ] && echo yes || echo no)"

# default-name warnings (key:load, key:add, key-stdin and check; a warning, never a block)
rr -- key-new old-sign 'old' 1
ssh-keygen -q -t ed25519 -N '' -C dflt -f "$T/id_ed25519" >/dev/null
rr -- key-add "$T/id_ed25519"
check 'key-add of a default-named key still succeeds' 0 "$rc"
has 'key-add warns about the default name' 'id_ed25519 has the default name of a general-purpose key' "$out"
rr -- key-load
has 'key-load warns about the default name' 'id_ed25519 has the default name' "$out"
check 'key-load still loads it (warn, never block)' yes "$(agent_has "$KEYS/id_ed25519.pub")"
rr -- check
has 'check warns about the default name' 'id_ed25519 has the default name' "$out"
lacks 'a dedicated name is not warned about' 'old-sign has the default name' "$out"
rr -- key-remove id_ed25519 1

# key:age and the age warning
printf 'created=2025-01-01\nsource=generated\n' > "$KEYS/old-sign.meta"
days=$((($(date -d 2026-10-24 +%s) - $(date -d 2025-01-01 +%s)) / 86400))
rr -- key-age
check 'key-age exits 0' 0 "$rc"
has 'key-age shows the key, its creation date and age' "old-sign: created 2025-01-01, $days day(s) old, SHA256:" "$out"
rr -- check
has 'check says a key older than 365 days should be rotated' 'older than 365 days; task ssh-agent:key:rotate' "$out"
rr SSH_KEY_MAX_AGE_DAYS=2000 -- check
lacks 'SSH_KEY_MAX_AGE_DAYS raises the limit' 'older than' "$out"
cp "$T/b" "$KEYS/imported-old"; : > "$KEYS/imported-old.meta"; touch -d 2024-01-01 "$KEYS/imported-old"
rr -- key-age
has 'a key without a sidecar is dated by its file' 'imported-old: created 2024-01-01' "$out"
rr DCF_HOST_SSH_AGENT=socket -- check
has 'socket mode: check prints the rotation steps for host-held keys' "not this Feature's to rotate" "$out"
rm -f "$KEYS/imported-old" "$KEYS/imported-old.meta"
printf 'created=2026-10-24\nsource=generated\n' > "$KEYS/old-sign.meta"
rr -- check
lacks 'a fresh key is not flagged' 'older than' "$out"

# a signature made by the old key, to verify after the rotation
OLD="$KEYS/old-sign.pub"
cp "$OLD" "$T/old.pub.keep"
printf 'old message\n' > "$T/oldmsg"
SSH_AUTH_SOCK="$SOCK" "$real_keygen" -Y sign -f "$OLD" -n git "$T/oldmsg" >/dev/null 2>&1
rr -- git-signing "$OLD" global
check 'git signs with the old key before the rotation' "key::$(awk '{print $1 " " $2}' "$OLD")" "$(git config --file "$T/gitconfig2" user.signingkey)"

# --plan changes nothing
: > "$GHLIST"; gh_registers "$OLD" 4242
before="$(tree_sum)"
rr -- key-rotate --name old-sign --scope global --plan
check 'rotate --plan exits 0' 0 "$rc"
has 'rotate --plan names the new key (dated)' 'old-sign-20261024' "$out"
has 'rotate --plan lists the four steps' '4. only then retire old-sign' "$out"
has 'rotate --plan says it changed nothing' 'nothing was changed' "$out"
check 'rotate --plan changed no file, git setting or agent key' "$before" "$(tree_sum)"
rr -- key-retire --name old-sign --plan
has 'retire --plan says it changed nothing' 'nothing was changed' "$out"
check 'retire --plan changed nothing' "$before" "$(tree_sum)"

# the happy path: old key registered at GitHub, kept there by default
: > "$EV"
rr -- key-rotate --name old-sign --scope global --empty 1
check 'rotate exits 0' 0 "$rc"
NEW1="$KEYS/old-sign-20261024"
check 'rotate made the new key, dated' yes "$([ -f "$NEW1" ] && echo yes || echo no)"
check 'rotate deleted the old private key' no "$([ -e "$KEYS/old-sign" ] && echo yes || echo no)"
check 'rotate loaded the new key' yes "$(agent_has "$NEW1.pub")"
check 'rotate unloaded the old key' no "$(agent_has "$T/old.pub.keep")"
check 'git signs with the new key' "key::$(awk '{print $1 " " $2}' "$NEW1.pub")" "$(git config --file "$T/gitconfig2" user.signingkey)"
has 'the allowed_signers history has the old key' "$(blob_of "$T/old.pub.keep")" "$(cat "$KEYS/allowed_signers.history")"
has 'the history line is dated (valid-before)' 'valid-before="20261024"' "$(cat "$KEYS/allowed_signers.history")"
lacks 'the history holds no private key' 'PRIVATE KEY' "$(cat "$KEYS/allowed_signers.history")"
check 'old signatures still verify against the history' 0 "$(ssh-keygen -Y verify -f "$KEYS/allowed_signers.history" -I anyone -n git -Overify-time=20261023 -s "$T/oldmsg.sig" < "$T/oldmsg" >/dev/null 2>&1; echo $?)"
has 'the new key was registered as a signing key through gh' "ssh-key add $NEW1.pub --type signing --title old-sign-20261024" "$(cat "$EV")"
lacks 'by default the old key is kept at GitHub (no delete)' 'ssh-key delete' "$(cat "$EV")"
has 'the output says the old key stays registered' 'stays registered at GitHub' "$out"
lacks 'rotate never prints a private key' 'PRIVATE KEY' "$out"
l_new="$(line_of keygen-new)"; l_add="$(line_of 'gh ssh-key add')"; l_ver="$(line_of keygen-sign)"; l_del="$(line_of ssh-add-d)"
check 'order: new key before registering' yes "$([ -n "$l_new" ] && [ -n "$l_add" ] && [ "$l_new" -lt "$l_add" ] && echo yes || echo no)"
check 'order: registering before verifying' yes "$([ -n "$l_ver" ] && [ "$l_add" -lt "$l_ver" ] && echo yes || echo no)"
check 'order: the old key is unloaded only after verify' yes "$([ -n "$l_del" ] && [ "$l_ver" -lt "$l_del" ] && echo yes || echo no)"

# REVOKE=1 also deletes the old key at GitHub, by the id matched on its public key
cp "$NEW1.pub" "$T/new1.pub.keep"
: > "$GHLIST"; gh_registers "$T/other.pub" 1 2>/dev/null; gh_registers "$NEW1.pub" 777
sed -i '1d' "$GHLIST" 2>/dev/null; : > "$EV"
rr DCF_SSH_KEY_TODAY=2026-10-25 -- key-rotate --scope global --empty 1 --revoke 1
check 'rotate with REVOKE=1 exits 0' 0 "$rc"
has 'REVOKE=1 deletes the old key at GitHub with the matched id' 'gh ssh-key delete 777 --yes' "$(cat "$EV")"
check 'REVOKE=1: the old key is gone locally too' no "$([ -e "$NEW1" ] && echo yes || echo no)"
check 'NAME is optional with exactly one key (the dated name is stripped, a new date added)' yes "$([ -f "$KEYS/old-sign-20261025" ] && echo yes || echo no)"

# gh absent: stop after step 1 with the resume message, remove nothing
NEW2="$KEYS/old-sign-20261025"; cp "$NEW2.pub" "$T/new2.pub.keep"
: > "$EV"
sg_before="$(git config --file "$T/gitconfig2" user.signingkey)"
rr DCF_GH=/nonexistent/gh DCF_SSH_KEY_TODAY=2026-10-26 -- key-rotate --scope global --empty 1
check 'rotate without gh exits 1' 1 "$rc"
has 'it says how to finish and resume' 'finish by registering it, then run key:rotate again with NEW=old-sign-20261026' "$out"
has 'it prints the public key to register' 'ssh-ed25519 ' "$out"
check 'the old key is still there' yes "$([ -f "$NEW2" ] && echo yes || echo no)"
check 'the old key is still loaded' yes "$(agent_has "$NEW2.pub")"
check 'the new key was made and is loaded' yes "$([ -f "$KEYS/old-sign-20261026" ] && [ "$(agent_has "$KEYS/old-sign-20261026.pub")" = yes ] && echo yes || echo no)"
check 'git signing is untouched' "$sg_before" "$(git config --file "$T/gitconfig2" user.signingkey)"
lacks 'nothing was unloaded' 'ssh-add-d' "$(cat "$EV")"
lacks 'no history entry yet' "$(blob_of "$T/new2.pub.keep")" "$(cat "$KEYS/allowed_signers.history")"
lacks 'rotate without gh never prints a private key' 'PRIVATE KEY' "$out"
# the resume path: NEW=<name> with the key already made, gh still absent, takes the operator's word
rr DCF_GH=/nonexistent/gh -- key-rotate --name old-sign-20261025 --new old-sign-20261026 --scope global
check 'resume with NEW exits 0' 0 "$rc"
has 'resume says it takes the operator at their word' 'taking your word' "$out"
check 'resume retired the old key' no "$([ -e "$NEW2" ] && echo yes || echo no)"
check 'resume points git at the new key' "key::$(awk '{print $1 " " $2}' "$KEYS/old-sign-20261026.pub")" "$(git config --file "$T/gitconfig2" user.signingkey)"
check 'resume appended the old key to the history' 1 "$(grep -cF "$(blob_of "$T/new2.pub.keep")" "$KEYS/allowed_signers.history")"

# gh refusing the registration stops at step 2
NEW3="$KEYS/old-sign-20261026"
rr STUB_GH_ADD_FAIL=1 DCF_SSH_KEY_TODAY=2026-10-27 -- key-rotate --scope global --empty 1
check 'a failing gh ssh-key add stops the rotation' 1 "$rc"
has 'the stop names step 2' 'rotation stopped at step 2' "$out"
check 'the old key survives a failed registration' yes "$([ -f "$NEW3" ] && echo yes || echo no)"
rr -- key-remove old-sign-20261027 1

# verify failing: stop, keep the old key, put git back
: > "$EV"
sg_before="$(git config --file "$T/gitconfig2" user.signingkey)"
rr STUB_FAIL_SIGN=1 DCF_SSH_KEY_TODAY=2026-10-27 -- key-rotate --new old-sign-20261027 --scope global
check 'rotate with a failing verify exits 1' 1 "$rc"
has 'the stop names step 3' 'rotation stopped at step 3' "$out"
check 'the old key is kept when verify fails' yes "$([ -f "$NEW3" ] && echo yes || echo no)"
check 'the old key stays loaded when verify fails' yes "$(agent_has "$NEW3.pub")"
lacks 'the old key was not unloaded' 'ssh-add-d' "$(cat "$EV")"
check 'git is put back on the old key' "$sg_before" "$(git config --file "$T/gitconfig2" user.signingkey)"
has 'the message says how to resume' 'NEW=old-sign-20261027' "$out"
# ... and the resume with a working verify finishes it
rr -- key-rotate --new old-sign-20261027 --scope global
check 'rotate resumes after a verify failure' 0 "$rc"
check 'and then retires the old key' no "$([ -e "$NEW3" ] && echo yes || echo no)"

# an overriding repo-level signing key makes step 3 fail (it would keep signing with the old key)
NEW4="$KEYS/old-sign-20261027"
git -C "$REPO" config --local user.signingkey "key::$(awk '{print $1 " " $2}' "$NEW4.pub")"
rr DCF_SSH_KEY_TODAY=2026-10-28 -- key-rotate --scope global --empty 1
check 'a repo-level config naming another key stops the rotation' 1 "$rc"
has 'and says why' 'another git config level still names a different signing key' "$out"
check 'the old key is kept' yes "$([ -f "$NEW4" ] && echo yes || echo no)"
git -C "$REPO" config --local --unset-all user.signingkey
rm -f "$KEYS/old-sign-20261028" "$KEYS/old-sign-20261028.pub" "$KEYS/old-sign-20261028.meta"

# key:retire alone
rr -- key-new solo '' 1
: > "$EV"; : > "$GHLIST"
cp "$KEYS/solo.pub" "$T/solo.pub.keep"
rr -- key-retire --name solo
check 'retire alone exits 0' 0 "$rc"
check 'retire deleted the key' no "$([ -e "$KEYS/solo" ] && echo yes || echo no)"
check 'retire appended it to the history' 1 "$(grep -cF "$(blob_of "$T/solo.pub.keep")" "$KEYS/allowed_signers.history")"
lacks 'retire alone does not touch GitHub by default' 'gh ' "$(cat "$EV")"
rr -- key-retire --name nosuchkey
check 'retire of an unknown key exits 1' 1 "$rc"
rr -- key-new solo2 '' 1
rr DCF_GH=/nonexistent/gh -- key-retire --name solo2 --revoke 1
check 'retire REVOKE=1 without gh stops' 1 "$rc"
check 'and removes nothing' yes "$([ -f "$KEYS/solo2" ] && echo yes || echo no)"
gh_registers "$KEYS/solo2.pub" 55
rr -- key-retire --name solo2 --revoke 1
check 'retire REVOKE=1 exits 0 with gh' 0 "$rc"
has 'retire REVOKE=1 deleted the matched id' 'gh ssh-key delete 55 --yes' "$(cat "$EV")"
rr DCF_HOST_SSH_AGENT=socket -- key-rotate --plan
check 'rotate refuses outside key mode' 1 "$rc"
rr DCF_HOST_SSH_AGENT=socket -- key-retire --name x
check 'retire refuses outside key mode' 1 "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
