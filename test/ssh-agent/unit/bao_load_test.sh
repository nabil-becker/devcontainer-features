#!/usr/bin/env bash
# Docker-free tests of ssh-agent 1.4.0's keys from OpenBao (src/ssh-agent/ssh-agent-setup.sh) with
# the real ssh-agent, ssh-add, ssh-keygen and git, the real dcf-secret and openbao-ssh of the
# openbao Feature, and a stub bao that keeps a KV v2 store in a temp folder
# (test/openbao/unit/kv_bao_stub.sh):
#   key:load NAME=ssh/<key>: the key reaches the agent on a pipe into `ssh-add -t <life> -`, never
#     a file (TMPDIR stays empty and no file outside the stub's store holds a private key), the
#     lifetime is the login's remaining time capped at 480 minutes and MINUTES shortens it, the
#     message names the agent (the container's, the workstation's in socket mode), dcf-secret's
#     exit codes are passed on (11 sealed, 12 no token, 14 no such key) with nothing loaded, the
#     refusals (no dcf-secret, a name without a slash, MINUTES out of range, no agent outside key
#     mode); key:lock drops it, also while the server is sealed;
#   the deprecation lines of the key volume's tasks, the old behaviour kept;
#   key:rotate NAME=ssh/<key>: the four steps on OpenBao records against a stub gh:ssh-key:add
#     (the new record made, loaded and registered from stdin, git pointed at it and verified, the
#     old record retired and unloaded only after that, allowed_signers written), --plan changing
#     nothing, a stop at step 2 leaving the old key whole;
#   allowed_signers (proposal section 8): git resolves the work-tree-relative
#     gpg.ssh.allowedSignersFile from the top of the work tree, from a subfolder and with -C, so a
#     commit signed with the old key before the rotation and one signed with the new key after both
#     verify; git:signing adds a line only where the file is; the repository's own
#     .devcontainer/allowed_signers holds only well-formed public key lines.
# Only throwaway keys made here. Part of `task lint` (`task test:ssh-agent-unit`).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
setup_sh="${SETUP_SH:-$root/src/ssh-agent/ssh-agent-setup.sh}"
for t in ssh-agent ssh-add ssh-keygen git; do
  command -v "$t" >/dev/null 2>&1 || { echo "bao_load_test: $t is required"; exit 1; }
done

T="$(mktemp -d /tmp/sshbao.XXXXXX)"
cleanup() { pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/store" "$T/shm" "$T/home" "$T/tmp" "$T/keys" "$T/loaded" "$T/feature" "$T/gh"
SOCK="$T/agent.sock"
install -m 0755 "$root/test/openbao/unit/kv_bao_stub.sh" "$T/bin/bao"
install -m 0755 "$root/src/openbao/dcf-secret.sh" "$T/bin/dcf-secret"
install -m 0755 "$root/src/openbao/openbao-ssh.sh" "$T/bin/openbao-ssh"
# shellcheck disable=SC2016  # the shims' own variables
# ssh-add through a shim that logs its arguments (never its stdin), to see the lifetime asked for.
real_add="$(command -v ssh-add)"
printf '#!/bin/sh\necho "$*" >> "%s/ssh-add.log"\nexec "%s" "$@"\n' "$T" "$real_add" >"$T/bin/ssh-add"
# shellcheck disable=SC2016
# gh:ssh-key:add of the gh Feature, stubbed: it records the public key it gets on stdin and its
# arguments; GH_ADD_RC makes it fail.
printf '#!/bin/sh\necho "$*" > "%s/gh/args"\ncat > "%s/gh/stdin"\nexit "${GH_ADD_RC:-0}"\n' "$T" "$T" >"$T/bin/gh-ssh-key-add"
chmod +x "$T/bin/ssh-add" "$T/bin/gh-ssh-key-add"

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

REPO="$T/repo"
git init -q "$REPO"
mkdir -p "$REPO/sub"
GITENV=(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid)
: >"$T/home/.gitconfig"

# run [VAR=value ...] -- <script args>: out = stdout+stderr, rc = exit status, from the repo.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$T/ssh-add.log"
  out="$(cd "$REPO" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" BAO_STORE="$T/store" \
    OPENBAO_FEATURE_DIR="$T/feature" OPENBAO_SSH_TMPDIR="$T/shm" DCF_SSH_AGENT_SOCK="$SOCK" DCF_SSH_AGENT_KEY_DIR="$T/keys" \
    DCF_SSH_AGENT_LOADED_DIR="$T/loaded" DCF_SSH_KEY_TODAY=2026-11-04 "${GITENV[@]}" "${envs[@]}" \
    setsid -w timeout 60 bash "$setup_sh" "$@" 2>&1)"
  rc=$?
}
obssh() { (cd "$REPO" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" BAO_STORE="$T/store" OPENBAO_FEATURE_DIR="$T/feature" \
  OPENBAO_SSH_TMPDIR="$T/shm" DCF_SSH_KEY_TODAY=2026-11-04 "${GITENV[@]}" bash "$T/bin/openbao-ssh" "$@" 2>&1); }
field() { cat "$T/store/dcf/$1/v$(cat "$T/store/dcf/$1/cur")/$2" 2>/dev/null; }
agent_fps() { SSH_AUTH_SOCK="$SOCK" "$real_add" -l 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2}'; }
fp_of() { printf '%s\n' "$1" | ssh-keygen -l -f - | awk '{print $2}'; }
# No file outside the stub's store (OpenBao's side) holds a private key.
key_files() { grep -rlF --exclude-dir=store --exclude-dir=bin -e "PRIVATE KEY" "$T" 2>/dev/null | tee "$T/key_files.last" | wc -l; }
KEYMODE=(SSH_AGENT_SETUP_KEY_MODE=true DCF_HOST_SSH_AGENT=key)

obssh new --name alpha-sign >/dev/null
obssh new --name beta-sign >/dev/null
alpha_pub="$(field ssh/alpha-sign public_key)"
alpha_fp="$(fp_of "$alpha_pub")"

# --- key:load from OpenBao, key mode: the agent is started, the key comes on the pipe
run "${KEYMODE[@]}" -- key-load ssh/alpha-sign
check 'load: exit 0' 0 "$rc"
has 'load: the key is in the agent' "$alpha_fp" "$(agent_fps)"
has 'load: ssh-add read it from stdin with the login''s lifetime (4 hours)' '-t 14400 -' "$(cat "$T/ssh-add.log")"
has 'load: says it is in the container''s agent, in memory, until when' "ssh/alpha-sign is in the container's agent until" "$out"
check 'load: TMPDIR stays empty' '' "$(ls -A "$T/tmp")"
check 'load: no file outside OpenBao holds a private key' 0 "$(key_files)"
lacks 'load: no key printed' 'PRIVATE KEY' "$out"
check 'load: the public key is noted for key:lock' "$alpha_pub" "$(cat "$T/loaded/ssh__alpha-sign.pub")"

run "${KEYMODE[@]}" STUB_TTL=600 -- key-load ssh/beta-sign
has 'load: never longer than the login has left' '-t 600 -' "$(cat "$T/ssh-add.log")"
run "${KEYMODE[@]}" STUB_TTL=600 -- key-load ssh/beta-sign 5
has 'load: MINUTES shortens it' '-t 300 -' "$(cat "$T/ssh-add.log")"
run "${KEYMODE[@]}" STUB_TTL=600 -- key-load ssh/beta-sign 60
has 'load: MINUTES past the login is cut to the login' '-t 600 -' "$(cat "$T/ssh-add.log")"
has 'load: and says so' 'longer than the OpenBao login has left' "$out"
run "${KEYMODE[@]}" STUB_TTL=0 -- key-load ssh/beta-sign
has 'load: a token without expiry is capped at 480 minutes' '-t 28800 -' "$(cat "$T/ssh-add.log")"
run "${KEYMODE[@]}" STUB_TTL=30 -- key-load ssh/beta-sign
check 'load: under a minute of login left is 12' 12 "$rc"
has 'load: says to log in again' 'task openbao:login' "$out"
run "${KEYMODE[@]}" -- key-load ssh/beta-sign abc
check 'load: MINUTES not a number is refused' 1 "$rc"
run "${KEYMODE[@]}" -- key-load ssh/beta-sign 481
check 'load: MINUTES over 480 is refused' 1 "$rc"
run "${KEYMODE[@]}" -- key-load beta-sign
check 'load: a name without a slash is refused' 1 "$rc"
has 'load: says what NAME is' 'NAME is an OpenBao name' "$out"

SSH_AUTH_SOCK="$SOCK" "$real_add" -D >/dev/null 2>&1
run "${KEYMODE[@]}" STUB_STATUS_RC=2 -- key-load ssh/alpha-sign
check 'load: sealed is 11, from dcf-secret' 11 "$rc"
has 'load: with its line' 'task openbao:unseal' "$out"
check 'load: nothing loaded while sealed' '' "$(agent_fps)"
run "${KEYMODE[@]}" STUB_LOOKUP_RC=2 -- key-load ssh/alpha-sign
check 'load: no token is 12' 12 "$rc"
run "${KEYMODE[@]}" -- key-load ssh/no-such
check 'load: no such key is 14' 14 "$rc"
check 'load: nothing loaded for a missing key' '' "$(agent_fps)"
run "${KEYMODE[@]}" DCF_SECRET_BIN=no-dcf-secret -- key-load ssh/alpha-sign
check 'load: without the openbao Feature it refuses' 1 "$rc"
has 'load: and names the Feature' 'add the openbao Feature' "$out"
check 'load: after every failure no file holds a private key' 0 "$(key_files)"

# --- key:lock: drops it, also while the server is sealed (the noted public key)
run "${KEYMODE[@]}" -- key-load ssh/alpha-sign
run "${KEYMODE[@]}" STUB_STATUS_RC=2 -- key-lock ssh/alpha-sign
check 'lock: exit 0 while sealed' 0 "$rc"
has 'lock: says it is removed' 'removed ssh/alpha-sign from the agent' "$out"
lacks 'lock: the key is gone from the agent' "$alpha_fp" "$(agent_fps)"
check 'lock: the note is gone' 'no' "$([ -f "$T/loaded/ssh__alpha-sign.pub" ] && echo yes || echo no)"
run "${KEYMODE[@]}" -- key-lock ssh/alpha-sign
has 'lock: a key not loaded says so' 'was not in the agent' "$out"
rm -f "$T/loaded/ssh__beta-sign.pub"
run "${KEYMODE[@]}" STUB_STATUS_RC=2 -- key-lock ssh/beta-sign
check 'lock: no note and sealed: cannot tell which key' 1 "$rc"
has 'lock: says how to drop everything' 'ssh-add -D' "$out"

# --- socket mode: the workstation's agent (simulated by one started here on the fixed path)
pkill -f "ssh-agent -a $T/" 2>/dev/null
rm -f "$SOCK"
ssh-agent -a "$SOCK" >/dev/null
run DCF_HOST_SSH_AGENT=socket DCF_HOST_TYPE=linux -- key-load ssh/alpha-sign 10
check 'socket: exit 0' 0 "$rc"
has 'socket: says it is the workstation''s agent' "loaded ssh/alpha-sign into the workstation's agent until" "$out"
has 'socket: with the lifetime' '-t 600 -' "$(cat "$T/ssh-add.log")"
run DCF_HOST_SSH_AGENT=socket DCF_HOST_TYPE=linux -- key-lock ssh/alpha-sign
pkill -f "ssh-agent -a $T/" 2>/dev/null
rm -f "$SOCK"
run DCF_HOST_SSH_AGENT=none DCF_HOST_TYPE=windows-docker -- key-load ssh/alpha-sign
check 'none: no agent and key mode off is refused' 1 "$rc"
has 'none: with the verdict' 'no agent is forwarded' "$out"

# --- deprecations: one line each, the volume's command still works
ssh-keygen -q -t ed25519 -N '' -C vol -f "$T/keys/vol-sign"
run "${KEYMODE[@]}" -- key-load
check 'deprecated key:load with no NAME still loads the volume' 0 "$rc"
has 'deprecated key:load: one line' 'deprecated: task ssh-agent:key:load with no NAME uses the key volume, which goes in ssh-agent 2.0; use task ssh-agent:key:load NAME=ssh/<key>' "$out"
check 'deprecated key:load: exactly one deprecation line' 1 "$(grep -c 'deprecated:' <<<"$out")"
run "${KEYMODE[@]}" -- key-age
has 'deprecated key:age names openbao:ssh:age' 'use task openbao:ssh:age' "$out"
has 'deprecated key:age still lists' 'vol-sign: created' "$out"
run "${KEYMODE[@]}" -- key-new new-vol-sign '' 1
has 'deprecated key:new names openbao:ssh:new' 'use task openbao:ssh:new' "$out"
check 'deprecated key:new still makes the key' yes "$([ -f "$T/keys/new-vol-sign" ] && echo yes || echo no)"
run "${KEYMODE[@]}" -- key-add "$T/keys/vol-sign"
has 'deprecated key:add names the import' 'use task openbao:ssh:import FROM=file FILE=<path>' "$out"
run "${KEYMODE[@]}" -- key-stdin x-sign <"$T/keys/vol-sign"
has 'deprecated key-stdin (the old host import) names the new host task' 'task devcontainer:openbao-ssh-import' "$out"
run "${KEYMODE[@]}" -- key-unlock vol-sign 5
has 'deprecated key:unlock names key:load' 'use task ssh-agent:key:load NAME=ssh/<key> [MINUTES=]' "$out"
run "${KEYMODE[@]}" -- key-lock vol-sign
has 'deprecated key:lock of a file names key:lock NAME=ssh/<key>' 'use task ssh-agent:key:lock NAME=ssh/<key>' "$out"
run "${KEYMODE[@]}" -- key-remove x-sign 1
has 'deprecated key:remove DELETE=1 names openbao:ssh:retire' 'use task openbao:ssh:retire NAME=ssh/<key>' "$out"
run "${KEYMODE[@]}" -- key-remove vol-sign
lacks 'key:remove without DELETE has no deprecation line' 'deprecated' "$out"
run "${KEYMODE[@]}" -- key-retire --name new-vol-sign --plan
has 'deprecated key:retire names openbao:ssh:retire' 'use task openbao:ssh:retire' "$out"
run "${KEYMODE[@]}" -- key-rotate --name vol-sign -- --plan
run "${KEYMODE[@]}" -- key-rotate --name vol-sign --plan
has 'deprecated key:rotate on the volume names NAME=ssh/<key>' 'use task ssh-agent:key:rotate NAME=ssh/<key>' "$out"
has 'deprecated key:rotate on the volume still plans the old way' 'plan, rotating vol-sign' "$out"
run "${KEYMODE[@]}" -- setup
has 'the start hook in key mode says the volume is deprecated' 'deprecated: the key volume' "$out"
check 'the start hook still exits 0' 0 "$rc"
rm -f "$T/keys"/*
run "${KEYMODE[@]}" -- setup
lacks 'an empty volume gets no key-volume deprecation line' 'deprecated: the key volume' "$out"
SSH_AUTH_SOCK="$SOCK" "$real_add" -D >/dev/null 2>&1

# --- key:rotate on OpenBao records
signing_fp() { fp_of "$(env "${GITENV[@]}" git -C "$REPO" config --get user.signingkey | sed 's/^key:://')"; }
run "${KEYMODE[@]}" -- key-load ssh/alpha-sign
run "${KEYMODE[@]}" -- git-signing "$alpha_fp" global
check 'git:signing with an OpenBao key: exit 0' 0 "$rc"
check 'git:signing: no allowed_signers file is made where there is none' no "$([ -f "$REPO/.devcontainer/allowed_signers" ] && echo yes || echo no)"
# A commit signed with the old key, dated before the rotation.
old_date="$(date -d '-1 hour' '+%Y-%m-%dT%H:%M:%S')"
(cd "$REPO" && env "${GITENV[@]}" SSH_AUTH_SOCK="$SOCK" GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" git commit -q --allow-empty -m before) ||
  echo "FAIL - could not make the signed commit before the rotation"

run "${KEYMODE[@]}" -- key-rotate --name ssh/alpha-sign --new ssh/alpha-sign-20261104 --scope global --plan
check 'rotate --plan: exit 0' 0 "$rc"
has 'rotate --plan: the four steps' 'only then retire ssh/alpha-sign' "$out"
check 'rotate --plan: no new record' no "$([ -d "$T/store/dcf/ssh/alpha-sign-20261104" ] && echo yes || echo no)"

run "${KEYMODE[@]}" GH_ADD_RC=1 -- key-rotate --name ssh/alpha-sign --scope global
check 'rotate: a failed registration stops at step 2' 1 "$rc"
has 'rotate: says where it stopped and how to resume' 'rotation stopped at step 2' "$out"
has 'rotate: the resume names the new record' 'NEW=ssh/alpha-sign-20261104' "$out"
check 'rotate: the old record keeps its private key' yes "$(field ssh/alpha-sign private_key | grep -q 'PRIVATE KEY' && echo yes || echo no)"
check 'rotate: git still signs with the old key' "$alpha_fp" "$(signing_fp)"

run "${KEYMODE[@]}" -- key-rotate --name ssh/alpha-sign --new ssh/alpha-sign-20261104 --scope global
check 'rotate: resumed, exit 0' 0 "$rc"
new_pub="$(field ssh/alpha-sign-20261104 public_key)"
new_fp="$(fp_of "$new_pub")"
has 'rotate: step 1 resumed the made record' 'ssh/alpha-sign-20261104 exists, resuming' "$out"
check 'rotate: gh:ssh-key:add got the new public key on stdin' "$new_pub" "$(cat "$T/gh/stdin")"
check 'rotate: with the title' '--title alpha-sign-20261104' "$(cat "$T/gh/args")"
check 'rotate: git signs with the new key' "$new_fp" "$(signing_fp)"
has 'rotate: the new key is loaded' "$new_fp" "$(agent_fps)"
lacks 'rotate: the old key is unloaded' "$alpha_fp" "$(agent_fps)"
check 'rotate: the old record has no private key any more' '' "$(field ssh/alpha-sign private_key)"
check 'rotate: the old record keeps its public key' "$alpha_pub" "$(field ssh/alpha-sign public_key)"
as="$REPO/.devcontainer/allowed_signers"
has 'rotate: allowed_signers has the new key, valid after the rotation' "alpha-sign-20261104 namespaces=\"git\",valid-after=\"" "$(cat "$as")"
check 'rotate: gpg.ssh.allowedSignersFile is the work-tree-relative path in the repo config' '.devcontainer/allowed_signers' "$(git -C "$REPO" config --local --get gpg.ssh.allowedSignersFile)"
check 'rotate: no file outside OpenBao holds a private key' 0 "$(key_files)"
check 'rotate: TMPDIR is empty' '' "$(ls -A "$T/tmp")"

has 'rotate: the old key, which had no line, gets one before its end' "alpha-sign namespaces=\"git\",valid-before=\"" "$(cat "$as")"

# --- section 8: how git resolves the relative gpg.ssh.allowedSignersFile
new_date="$(date -d '+1 hour' '+%Y-%m-%dT%H:%M:%S')"
(cd "$REPO" && env "${GITENV[@]}" SSH_AUTH_SOCK="$SOCK" GIT_AUTHOR_DATE="$new_date" GIT_COMMITTER_DATE="$new_date" git commit -q --allow-empty -m after) ||
  echo "FAIL - could not make the signed commit after the rotation"
v_top="$(cd "$REPO" && env "${GITENV[@]}" git log --show-signature -2 2>&1)"
v_sub="$(cd "$REPO/sub" && env "${GITENV[@]}" git log --show-signature -2 2>&1)"
v_c="$(cd / && env "${GITENV[@]}" git -C "$REPO/sub" log --show-signature -2 2>&1)"
check 'allowed_signers: from the top, both commits verify' 2 "$(grep -c '^Good "git" signature for alpha-sign' <<<"$v_top")"
check 'allowed_signers: from a subfolder, the same' 2 "$(grep -c '^Good "git" signature for alpha-sign' <<<"$v_sub")"
check 'allowed_signers: with git -C, the same' 2 "$(grep -c '^Good "git" signature for alpha-sign' <<<"$v_c")"
(cd "$REPO/sub" && env "${GITENV[@]}" git verify-commit HEAD~1 >/dev/null 2>&1)
check 'allowed_signers: git verify-commit of the old commit from a subfolder' 0 "$?"
# The old key may not sign after its valid-before stamp.
late="$(date -d '+2 hour' '+%Y-%m-%dT%H:%M:%S')"
run "${KEYMODE[@]}" -- key-load ssh/beta-sign
beta_fp="$(fp_of "$(field ssh/beta-sign public_key)")"
printf 'stale namespaces="git",valid-before="20000101" %s\n' "$(field ssh/beta-sign public_key | awk '{print $1, $2}')" >>"$as"
(cd "$REPO" && env "${GITENV[@]}" git config user.signingkey "key::$(field ssh/beta-sign public_key | awk '{print $1, $2}')" &&
  env "${GITENV[@]}" SSH_AUTH_SOCK="$SOCK" GIT_AUTHOR_DATE="$late" GIT_COMMITTER_DATE="$late" git commit -q --allow-empty -m stale)
lacks 'allowed_signers: a key past its valid-before does not verify' 'Good "git" signature for stale' "$(cd "$REPO" && env "${GITENV[@]}" git log --show-signature -1 2>&1)"
: "$beta_fp"

# git:signing adds a line where the file exists, and only once
sed -i '/^stale /d' "$as"
run "${KEYMODE[@]}" -- git-signing "$beta_fp" global
has 'git:signing: adds the key to an existing allowed_signers' 'allowed_signers: added beta-sign' "$out"
n_before="$(wc -l <"$as")"
run "${KEYMODE[@]}" -- git-signing "$beta_fp" global
check 'git:signing: never twice' "$n_before" "$(wc -l <"$as")"
run "${KEYMODE[@]}" -- git-signing "$beta_fp" global "$T/elsewhere"
check 'git:signing: ALLOWED_SIGNERS names another file, made if missing' yes "$(grep -q beta-sign "$T/elsewhere" 2>/dev/null && echo yes || echo no)"
check 'git:signing: and git points at it' "$T/elsewhere" "$(git -C "$REPO" config --local --get gpg.ssh.allowedSignersFile)"
lacks 'allowed_signers never holds a private key' 'PRIVATE KEY' "$(cat "$as" "$T/elsewhere")"

# --- the repository's own .devcontainer/allowed_signers: well-formed public key lines only
own="$root/.devcontainer/allowed_signers"
check 'the repository has .devcontainer/allowed_signers' yes "$([ -f "$own" ] && echo yes || echo no)"
bad=0
while IFS= read -r l; do
  case "$l" in '' | '#'*) continue ;; esac
  grep -q 'namespaces="git"' <<<"$l" || bad=$((bad + 1))
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i, $(i + 1); exit } }' <<<"$l" | ssh-keygen -l -f - >/dev/null 2>&1 || bad=$((bad + 1))
done <"$own"
check 'its every line is a git-namespace public key' 0 "$bad"
lacks 'it holds no private key' 'PRIVATE KEY' "$(cat "$own")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
