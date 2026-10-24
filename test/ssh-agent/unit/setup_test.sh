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
  out="$(cd "$T/repo" && env -i PATH="$PATH" HOME="$T/home" DCF_SSH_AGENT_SOCK="$SOCK" DCF_SSH_AGENT_KEY_DIR="$KEYS" \
    "${envs[@]}" setsid -w timeout 30 bash "$setup_sh" "$@" 2>&1)"
  rc=$?
}

mkdir -p "$T/repo"
git -C "$T/repo" init -q

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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
