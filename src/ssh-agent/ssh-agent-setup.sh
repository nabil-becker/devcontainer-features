#!/usr/bin/env bash
# ssh-agent-setup: the ssh-agent Feature's postStartCommand (a socket has to be
# checked, and an in-container agent restarted, on every start, not only at create),
# also behind `task ssh-agent:setup` and `task ssh-agent:check`.
#
#   ssh-agent-setup                  set up for DCF_HOST_SSH_AGENT and report (never fatal: exit 0)
#   ssh-agent-setup check            only report; exit 0 when an agent answers, 1 when none does
#   ssh-agent-setup keys             list what the agent holds (fingerprints and comments)
# Key mode only (the opt-in that keeps a key in the container's volume):
#   ssh-agent-setup key-load         (re)load every key of the key volume into the agent
#   ssh-agent-setup key-add FILE     copy a private key FILE (and its .pub beside it) in, then load
#   ssh-agent-setup key-new [NAME] [COMMENT] [EMPTY_PASSPHRASE]  generate an ed25519 signing key
#   ssh-agent-setup key-stdin NAME   the key bytes on stdin into the volume (the host task
#                                    devcontainer:ssh-key-import feeds this; never on a command line)
#   ssh-agent-setup key-remove NAME [DELETE]  drop a key from the agent (and the volume with DELETE=1)
# Any mode (needs only the public key the agent lists):
#   ssh-agent-setup git-signing [KEY] [SCOPE]  configure git to sign with the agent
#   ssh-agent-setup git-verify       sign and verify a throwaway message, without committing
#
# Everything here concerns the one fixed path, SSH_SOCK. The launcher mounts the host's
# agent socket onto it (DCF_HOST_SSH_AGENT=socket); in key mode this script starts an
# agent inside the container on it and loads the keys found in the key volume. A forwarded
# SSH_AUTH_SOCK that some other tool (VS Code) puts in a terminal's own environment is
# never touched: this script stands down from anything but the fixed path.
# No key material is ever printed or generated.
set -u

# Defaults baked by install.sh from the Feature options; SSH_AGENT_SETUP_* in the
# environment override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/ssh-agent-feature/options.env ] && source /usr/local/share/ssh-agent-feature/options.env
key_option="${SSH_AGENT_SETUP_KEY_MODE-${KEYMODE:-false}}"
# Overridable so the Docker-free unit test can run against temp folders.
SSH_SOCK="${DCF_SSH_AGENT_SOCK:-/var/lib/devcontainer-features/ssh-agent/agent.sock}"
KEY_DIR="${DCF_SSH_AGENT_KEY_DIR:-/var/lib/devcontainer-features/ssh-agent-key}"
host_type="${DCF_HOST_TYPE:-}"
mode="${DCF_HOST_SSH_AGENT:-}"

say() { echo "ssh-agent: $*"; }
warn() { echo "ssh-agent: $*" >&2; }

# probe <socket>: PROBE_RC = ssh-add -l exit status (0 keys listed, 1 agent with no
# keys, 2 not reachable; 3 when ssh-add is missing), PROBE_KEYS = how many keys.
probe() {
  local out
  PROBE_KEYS=0
  if ! command -v ssh-add >/dev/null 2>&1; then PROBE_RC=3; return 0; fi
  if command -v timeout >/dev/null 2>&1; then
    out="$(SSH_AUTH_SOCK="$1" timeout 5 ssh-add -l 2>/dev/null)"
  else
    out="$(SSH_AUTH_SOCK="$1" ssh-add -l 2>/dev/null)"
  fi
  PROBE_RC=$?
  [ "$PROBE_RC" -eq 124 ] && PROBE_RC=2
  [ "$PROBE_RC" -eq 0 ] && PROBE_KEYS="$(printf '%s\n' "$out" | grep -c .)"
  return 0
}

host_name() { if [ -n "$host_type" ]; then echo "$host_type"; else echo "an unknown host"; fi; }

report_reachable() { # <what>
  if [ "$PROBE_RC" -eq 0 ]; then say "$1 reachable at $SSH_SOCK, $PROBE_KEYS key(s) loaded"
  else say "$1 reachable at $SSH_SOCK, no keys loaded"; fi
}

explain_none() {
  say "no agent is forwarded: host type $(host_name) cannot hand the host's SSH agent to the container without a process left running on the host, which this collection does not do (the Windows agent is a named pipe)."
  say "ways round: a terminal in VS Code (it forwards the agent itself), or the opt-in key mode (SSH_AGENT_MODE=key at task devcontainer:up, or Feature option keyMode: true), which keeps a signing key in the container's volume and so breaks 'the private key never enters the container'. See task ssh-agent:key:add."
}

# --- key mode ----------------------------------------------------------------
is_private_key() { # <file>: looks like a private key (header only; nothing is read further)
  [ -f "$1" ] || return 1
  case "${1##*/}" in *.pub | known_hosts* | config | authorized_keys) return 1 ;; esac
  head -n 1 "$1" 2>/dev/null | grep -q -- '^-----BEGIN .*PRIVATE KEY-----'
}

start_agent() { # sets AGENT_STATE: reused | started | failed
  probe "$SSH_SOCK"
  if [ "$PROBE_RC" -le 1 ]; then AGENT_STATE=reused; return 0; fi
  if [ "$PROBE_RC" -eq 3 ]; then AGENT_STATE=failed; warn "ssh-add not found; the Feature's installer should have added openssh-client"; return 0; fi
  if [ -e "$SSH_SOCK" ] || [ -L "$SSH_SOCK" ]; then
    if ! rm -f "$SSH_SOCK" 2>/dev/null; then
      AGENT_STATE=failed
      warn "$SSH_SOCK exists and cannot be replaced (a socket mounted from the host? start with SSH_AGENT_MODE=key, which suppresses that mount)"
      return 0
    fi
  fi
  mkdir -p "$(dirname "$SSH_SOCK")" 2>/dev/null || true
  if command -v ssh-agent >/dev/null 2>&1 && ssh-agent -a "$SSH_SOCK" >/dev/null 2>&1; then AGENT_STATE=started
  else AGENT_STATE=failed; warn "could not start ssh-agent on $SSH_SOCK"; fi
}

load_keys() { # adds every private key of KEY_DIR; prints one line per refusal, then a summary
  local f mode_bits loaded=0 refused=0 failed=0 total=0
  if [ ! -d "$KEY_DIR" ]; then say "key mode: no key volume at $KEY_DIR (the Feature declares it; was the container created without it?)"; return 0; fi
  for f in "$KEY_DIR"/*; do
    is_private_key "$f" || continue
    total=$((total + 1))
    mode_bits="$(stat -c %a "$f" 2>/dev/null || echo 777)"
    if [ $((8#$mode_bits & 8#077)) -ne 0 ]; then
      refused=$((refused + 1))
      warn "refusing ${f##*/}: mode $mode_bits lets group or others read it; run chmod 600 on it (or add it again with task ssh-agent:key:add)"
      continue
    fi
    if SSH_AUTH_SOCK="$SSH_SOCK" ssh-add "$f" </dev/null >/dev/null 2>&1; then loaded=$((loaded + 1))
    else failed=$((failed + 1)); warn "could not add ${f##*/} (a passphrase-protected key needs task ssh-agent:setup from a terminal)"; fi
  done
  if [ "$total" -eq 0 ]; then say "key mode: no private key in $KEY_DIR yet; copy one in with task ssh-agent:key:add FILE=<path>"
  else say "key mode: $loaded of $total key(s) from $KEY_DIR loaded ($refused refused, $failed failed)"; fi
}

do_key_mode() {
  command -v dcf-persist >/dev/null 2>&1 && dcf-persist --label ssh-agent-key "$KEY_DIR" 2>/dev/null
  start_agent
  case "$AGENT_STATE" in
    reused) say "key mode: an agent already answers on $SSH_SOCK, kept" ;;
    started) say "key mode: started an agent inside the container on $SSH_SOCK (it lives only as long as the container runs)" ;;
  esac
  [ "$AGENT_STATE" = failed ] && return 0
  load_keys
  probe "$SSH_SOCK"
  report_reachable "key mode: the container's own agent"
  say "key mode keeps a private key in this container's volume (the opt-in that breaks 'the key never enters the container'; temporary, until a host-side answer exists)."
}

# --- the verdicts --------------------------------------------------------------
effective_mode() { # sets EFF: key | socket | none | unknown
  case "$mode" in key) EFF=key ;; socket) EFF=socket ;; none) EFF=none ;; *) EFF=unknown ;; esac
  if [ "$key_option" = true ] && { [ "$EFF" = none ] || [ "$EFF" = unknown ]; }; then EFF=key; fi
}

verdict() { # the plain report for the current state, no changes; returns 0 when an agent answers
  local rc other
  effective_mode
  probe "$SSH_SOCK"
  rc=$PROBE_RC
  # A forwarded SSH_AUTH_SOCK of this shell that is not the fixed path: another tool's, left alone.
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ "$SSH_AUTH_SOCK" != "$SSH_SOCK" ]; then
    other="$SSH_AUTH_SOCK"
    probe "$other"
    if [ "$PROBE_RC" -le 1 ]; then
      say "this shell uses a forwarded agent at $other ($PROBE_KEYS key(s)), probably VS Code's; the Feature does not touch it."
      return 0
    fi
    PROBE_RC=$rc
  fi
  probe "$SSH_SOCK"
  if [ "$PROBE_RC" -le 1 ]; then
    case "$EFF" in
      socket) report_reachable "the host's agent" ;;
      key) report_reachable "the container's own agent" ;;
      *) report_reachable "an agent" ;;
    esac
    return 0
  fi
  case "$EFF" in
    socket) say "not reachable: the launcher mounted a host socket at $SSH_SOCK but no agent answers on it. Is the host's agent running with a key added (ssh-add on the host)? The mount is made at 'up': start the agent, then restart the container (task devcontainer:up)." ;;
    none) explain_none ;;
    key) say "not reachable: key mode is on but no agent answers on $SSH_SOCK; run task ssh-agent:setup." ;;
    *) say "not reachable, and the host is unknown (DCF_HOST_SSH_AGENT is unset): start through task devcontainer:up so the launcher can mount the agent, or opt into the key mode (keyMode: true)." ;;
  esac
  return 1
}

# --- the agent in use ---------------------------------------------------------
# The fixed path, unless this shell carries another working agent (VS Code's forwarding).
active_sock() {
  ACTIVE="$SSH_SOCK"
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ "$SSH_AUTH_SOCK" != "$SSH_SOCK" ]; then
    probe "$SSH_AUTH_SOCK"
    [ "$PROBE_RC" -le 1 ] && ACTIVE="$SSH_AUTH_SOCK"
  fi
  return 0
}

require_key_mode() { # refuses (exit 1) unless the key mode is on
  effective_mode
  if [ "$EFF" != key ]; then
    warn "key mode is off in this container, nothing was changed. Turn it on with the Feature option keyMode: true in devcontainer.json (then rebuild), or start with SSH_AGENT_MODE=key (task devcontainer:up SSH_AGENT_MODE=key, with DCF_HOST_SSH_AGENT mapped by containerEnv). With a host agent (socket mode), load keys on the host: task devcontainer:ssh-add -- <key>."
    exit 1
  fi
}

prepare_key_dir() { # a usable key dir
  if command -v dcf-persist >/dev/null 2>&1; then dcf-persist --label ssh-agent-key "$KEY_DIR" >/dev/null 2>&1; fi
  mkdir -p "$KEY_DIR" 2>/dev/null
}

prepare_key_mode() { # a usable key dir and a live agent, or exit 1
  prepare_key_dir
  start_agent
  [ "$AGENT_STATE" != failed ] || exit 1
}

safe_name() { # a plain file name, no path parts
  case "$1" in '' | */* | .* | *..*) warn "'$1' is not a plain key name (no slashes, no leading dot)"; return 1 ;; esac
}

fingerprint_of() { ssh-keygen -l -f "$1" 2>/dev/null </dev/null | awk '{print $2}'; }

cmd_keys() {
  active_sock
  probe "$ACTIVE"
  case "$PROBE_RC" in
    0) say "the agent at $ACTIVE holds $PROBE_KEYS key(s):"; SSH_AUTH_SOCK="$ACTIVE" ssh-add -l ;;
    1) say "the agent at $ACTIVE is reachable and holds no keys. Socket mode: load one on the host (task devcontainer:ssh-add -- <key>). Key mode: task ssh-agent:key:new or key:add." ;;
    *) verdict; exit 1 ;;
  esac
}

cmd_key_load() {
  require_key_mode
  prepare_key_mode
  load_keys
  probe "$SSH_SOCK"
  report_reachable "key mode: the container's own agent"
}

cmd_key_add() { # <file>
  local f="${1:-}" name
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    warn "usage: ssh-agent-setup key-add <private key file>"
    exit 1
  fi
  require_key_mode
  is_private_key "$f" || { warn "${f##*/} does not look like a private key (no -----BEGIN ... PRIVATE KEY----- header)"; exit 1; }
  name="${f##*/}"
  safe_name "$name" || exit 1
  prepare_key_mode
  install -m 0600 "$f" "$KEY_DIR/$name" || { warn "could not copy $name into $KEY_DIR"; exit 1; }
  [ -f "$f.pub" ] && install -m 0644 "$f.pub" "$KEY_DIR/$name.pub"
  say "key mode: copied $name into $KEY_DIR (mode 0600). This puts a private key in the container's volume; remove it with task ssh-agent:key:remove NAME=$name DELETE=1."
  load_keys
  probe "$SSH_SOCK"
  report_reachable "key mode: the container's own agent"
}

cmd_key_stdin() { # <name>: key bytes on stdin; the refusal comes before anything is read
  local name="${1:-}" tmp pub=''
  safe_name "$name" || exit 1
  require_key_mode
  case "$name" in *.pub) pub=1 ;; esac
  prepare_key_dir
  tmp="$(mktemp "$KEY_DIR/.in.XXXXXX")" || { warn "could not write into $KEY_DIR"; exit 1; }
  chmod 0600 "$tmp"
  tr -d '\r' > "$tmp"
  if [ -z "$pub" ] && ! is_private_key "$tmp"; then rm -f "$tmp"; warn "what arrived on stdin is not a private key (no -----BEGIN ... PRIVATE KEY----- header); nothing kept"; exit 1; fi
  if [ -n "$pub" ]; then chmod 0644 "$tmp"; fi
  mv -f "$tmp" "$KEY_DIR/$name"
  if [ -z "$pub" ]; then
    say "key mode: stored $name in $KEY_DIR (mode 0600), fingerprint $(fingerprint_of "$KEY_DIR/$name")"
  else say "key mode: stored $name in $KEY_DIR"; fi
}

cmd_key_new() { # [name] [comment] [empty passphrase]
  local name="${1:-signing}" comment="${2:-}" empty="${3:-}" args
  safe_name "$name" || exit 1
  require_key_mode
  prepare_key_mode
  [ ! -e "$KEY_DIR/$name" ] || { warn "$KEY_DIR/$name exists; pick another NAME or remove it first (task ssh-agent:key:remove NAME=$name DELETE=1)"; exit 1; }
  [ -n "$comment" ] || comment="$name@$(hostname 2>/dev/null || echo container)"
  args=(-t ed25519 -f "$KEY_DIR/$name" -C "$comment")
  case "$empty" in 1 | true | yes) args+=(-N '') ;; esac
  ssh-keygen "${args[@]}" >/dev/null || { warn "ssh-keygen failed"; exit 1; }
  chmod 0600 "$KEY_DIR/$name"
  say "key mode: generated $name (ed25519) in $KEY_DIR; the private key stays there."
  load_keys
  say "public key (add it to GitHub as a signing key, Settings > SSH and GPG keys > New SSH key, type Signing Key):"
  cat "$KEY_DIR/$name.pub"
}

cmd_key_remove() { # <name> [delete]
  local name="${1:-}" del="${2:-}"
  safe_name "$name" || exit 1
  [ -f "$KEY_DIR/$name" ] || { warn "no key $name in $KEY_DIR"; exit 1; }
  if SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -d "$KEY_DIR/$name" >/dev/null 2>&1; then say "removed $name from the agent"
  else say "$name was not in the agent (or no agent answers on $SSH_SOCK)"; fi
  case "$del" in
    1 | true | yes) rm -f "$KEY_DIR/$name" "$KEY_DIR/$name.pub"; say "deleted $name from $KEY_DIR" ;;
    *) say "$name is still in $KEY_DIR and returns at the next start; DELETE=1 removes it from the volume" ;;
  esac
}

# --- git signing ----------------------------------------------------------------
pubkey_lines() { SSH_AUTH_SOCK="$ACTIVE" ssh-add -L 2>/dev/null; }

cmd_git_signing() { # [key] [scope]
  local key="${1:-}" scope="${2:-}" lines n pub line fp want why cfg
  command -v git >/dev/null 2>&1 || { warn "git is not installed in this container"; exit 1; }
  active_sock
  probe "$ACTIVE"
  case "$PROBE_RC" in
    0) ;;
    1) warn "the agent holds no keys, so there is nothing to sign with. Socket mode: task devcontainer:ssh-add -- <key> on the host. Key mode: task ssh-agent:key:new."; exit 1 ;;
    *) verdict; exit 1 ;;
  esac
  lines="$(pubkey_lines)"
  n="$(printf '%s\n' "$lines" | grep -c .)"
  if [ -z "$key" ]; then
    if [ "$n" -eq 1 ]; then pub="$lines"
    else
      warn "the agent holds $n keys; say which with KEY=<fingerprint or path of the .pub>:"
      SSH_AUTH_SOCK="$ACTIVE" ssh-add -l >&2
      exit 1
    fi
  elif [ -f "$key" ]; then pub="$(head -n 1 "$key")"
  else
    want="${key#SHA256:}"
    pub=''
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      fp="$(printf '%s\n' "$line" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}')"
      if [ "${fp#SHA256:}" = "$want" ]; then pub="$line"; break; fi
    done <<<"$lines"
    [ -n "$pub" ] || { warn "no key in the agent has the fingerprint $key; see task ssh-agent:keys"; exit 1; }
  fi
  pub="$(printf '%s\n' "$pub" | awk '{print $1 " " $2}')"
  case "$pub" in ssh-* | ecdsa-* | sk-*) ;; *) warn "that does not look like a public key"; exit 1 ;; esac

  if [ -z "$scope" ]; then
    case "${GIT_CONFIG_GLOBAL:-}" in
      /var/lib/devcontainer-features/*) scope=global; why="the git Feature keeps the container's own global config in a volume" ;;
      *) scope=repo; why="no git Feature volume found" ;;
    esac
    say "SCOPE not given: using $scope ($why)."
  fi
  case "$scope" in
    global) cfg=(--global) ;;
    repo)
      git rev-parse --git-dir >/dev/null 2>&1 || { warn "SCOPE=repo needs a git repository in the current directory"; exit 1; }
      cfg=(--local)
      say "SCOPE=repo writes into this repository's own git config, which in this collection can be shared with the Windows host (a git dir kept under .git-dirs); SCOPE=global writes only the container's config."
      ;;
    *) warn "SCOPE is repo or global, not '$scope'"; exit 1 ;;
  esac
  if ! { git config "${cfg[@]}" gpg.format ssh &&
    git config "${cfg[@]}" user.signingkey "key::$pub" &&
    git config "${cfg[@]}" commit.gpgsign true &&
    git config "${cfg[@]}" tag.gpgsign true; }; then
    warn "git config failed (is the $scope config writable?)"
    exit 1
  fi
  say "git ($scope) signs commits and tags with the agent's key $(printf '%s\n' "$pub" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}'): gpg.format ssh, user.signingkey key::<public key>, commit.gpgsign and tag.gpgsign true."
  say "to verify signatures with git log --show-signature, also set gpg.ssh.allowedSignersFile; task ssh-agent:git:verify tests signing now."
}

cmd_git_verify() {
  local format key pub tmp why
  command -v git >/dev/null 2>&1 || { warn "git is not installed in this container"; exit 1; }
  command -v ssh-keygen >/dev/null 2>&1 || { warn "ssh-keygen is not installed in this container"; exit 1; }
  format="$(git config --get gpg.format 2>/dev/null || true)"
  key="$(git config --get user.signingkey 2>/dev/null || true)"
  if [ "$format" != ssh ] || [ -z "$key" ]; then warn "git is not set up for ssh signing here (gpg.format='$format', user.signingkey $([ -n "$key" ] && echo set || echo empty)); run task ssh-agent:git:signing"; exit 1; fi
  case "$key" in
    key::*) pub="${key#key::}" ;;
    ssh-* | ecdsa-* | sk-*) pub="$key" ;;
    *) if [ -f "${key/#\~/$HOME}" ]; then pub="$(head -n 1 "${key/#\~/$HOME}")"; else warn "user.signingkey is neither a public key nor a readable file"; exit 1; fi ;;
  esac
  pub="$(printf '%s\n' "$pub" | awk '{print $1 " " $2}')"
  active_sock
  tmp="$(mktemp -d)" || exit 1
  trap 'rm -rf "$tmp"' EXIT
  printf '%s\n' "$pub" > "$tmp/key.pub"
  printf 'ssh-agent git:verify throwaway message\n' > "$tmp/msg"
  printf 'dcf-verify %s\n' "$pub" > "$tmp/allowed_signers"
  if ! why="$(SSH_AUTH_SOCK="$ACTIVE" ssh-keygen -Y sign -f "$tmp/key.pub" -n git "$tmp/msg" 2>&1)"; then
    say "signing failed: ${why##*$'\n'}. Is the key loaded in the agent at $ACTIVE (task ssh-agent:keys)?"
    exit 1
  fi
  if why="$(ssh-keygen -Y verify -f "$tmp/allowed_signers" -I dcf-verify -n git -s "$tmp/msg.sig" < "$tmp/msg" 2>&1)"; then
    say "ok: signed a throwaway message through the agent and verified it with the configured key"
  else
    say "signed, but the signature does not verify: ${why##*$'\n'}"
    exit 1
  fi
}

cmd="${1:-setup}"
case "$cmd" in
  check) verdict; exit $? ;;
  keys) cmd_keys; exit 0 ;;
  key-load) cmd_key_load; exit 0 ;;
  key-add) cmd_key_add "${2:-}"; exit 0 ;;
  key-stdin) cmd_key_stdin "${2:-}"; exit 0 ;;
  key-new) cmd_key_new "${2:-}" "${3:-}" "${4:-}"; exit 0 ;;
  key-remove) cmd_key_remove "${2:-}" "${3:-}"; exit 0 ;;
  git-signing) cmd_git_signing "${2:-}" "${3:-}"; exit 0 ;;
  git-verify) cmd_git_verify; exit 0 ;;
  setup) ;;
  *) warn "unknown command '$cmd' (see the header of $0)"; exit 0 ;;
esac

effective_mode
if [ "$mode" = socket ] && [ "$key_option" = true ]; then
  say "keyMode is on, but the launcher mounted a host agent socket, which wins; set SSH_AGENT_MODE=key at task devcontainer:up to use the key mode instead."
fi
if [ -z "$mode" ]; then
  say "host unknown: DCF_HOST_SSH_AGENT is empty (the launcher did not run, or the repository's containerEnv does not map it); start through task devcontainer:up. Probing $SSH_SOCK anyway."
fi
case "$EFF" in
  key) do_key_mode ;;
  *) verdict ;;
esac
exit 0
