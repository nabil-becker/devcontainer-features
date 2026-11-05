#!/usr/bin/env bash
# ssh-agent-setup: the ssh-agent Feature's postStartCommand (a socket has to be
# checked, and an in-container agent restarted, on every start, not only at create),
# also behind `task ssh-agent:setup` and `task ssh-agent:check`.
#
#   ssh-agent-setup                  set up for DCF_HOST_SSH_AGENT and report (never fatal: exit 0); the
#                                    start hook: never asks for a passphrase, skips a protected key with a warning
#   ssh-agent-setup setup --ask      the same, and ask for each protected key's passphrase on the terminal
#                                    (waits up to the passphrase timeout, then skips it with a warning)
#   ssh-agent-setup check            only report; exit 0 when an agent answers, 1 when none does
#   ssh-agent-setup keys             list what the agent holds (fingerprints and comments)
# Key mode only (the opt-in that keeps a key in the container's volume):
#   ssh-agent-setup key-load         (re)load every key of the key volume into the agent
#   ssh-agent-setup key-add FILE     copy a private key FILE (and its .pub beside it) in, then load
#   ssh-agent-setup key-new [NAME] [COMMENT] [EMPTY_PASSPHRASE]  generate an ed25519 signing key
#   ssh-agent-setup key-stdin NAME   the key bytes on stdin into the volume (the host task
#                                    devcontainer:ssh-key-import feeds this; never on a command line)
#   ssh-agent-setup key-remove NAME [DELETE]  drop a key from the agent (and the volume with DELETE=1)
#   ssh-agent-setup key-unlock NAME [MINUTES]  load that one key for MINUTES (default 15, at most 480), asking
#                                    for its passphrase on the terminal; the agent drops it then (ssh-add -t)
#   ssh-agent-setup key-lock NAME    drop that one key from the agent now, leaving it in the volume
#   ssh-agent-setup key-rotate [--name OLD] [--new NEW] [--revoke 1] [--scope S] [--empty 1] [--plan]
#                                    new key, registered as a signing key, git pointed at it and
#                                    verified, and only then the old one retired (steps below)
#   ssh-agent-setup key-retire --name KEY [--revoke 1] [--plan]  the last step of a rotation alone
#   ssh-agent-setup key-age          each key of the volume: creation date, age, fingerprint
# Any mode (needs only the public key the agent lists):
#   ssh-agent-setup git-signing [KEY] [SCOPE] [ALLOWED_SIGNERS]  configure git to sign with the agent
#                                    (and, where the file is, add the key to .devcontainer/allowed_signers)
#   ssh-agent-setup git-verify       sign and verify a throwaway message, without committing
# From OpenBao (the openbao Feature's dcf-secret; any mode with an agent, key mode starts one):
#   ssh-agent-setup key-load ssh/<key> [MINUTES]  dcf-secret get ... | ssh-add -t <life> -: the key
#                                    in agent memory only, never a file, for at most what is left
#                                    of the login (and 480 minutes); MINUTES shortens it
#   ssh-agent-setup key-lock ssh/<key>  take it out of the agent now (ssh-add -d -)
#   ssh-agent-setup key-rotate --name ssh/<key> ...  the same four steps on OpenBao records
# The key volume's commands above (key mode) are deprecated: each prints one line naming what
# replaces it, and they go in ssh-agent 2.0 (task openbao:ssh:import FROM=ssh-agent moves the keys).
#
# Everything here concerns the one fixed path, SSH_SOCK. The launcher mounts the host's
# agent socket onto it (DCF_HOST_SSH_AGENT=socket); in key mode this script starts an
# agent inside the container on it and loads the keys found in the key volume. A forwarded
# SSH_AUTH_SOCK that some other tool (VS Code) puts in a terminal's own environment is
# never touched: this script stands down from anything but the fixed path.
# No key material is ever printed; a key is generated only by key-new and key-rotate.
# Test hooks (not options): DCF_GH names the gh binary (default gh), DCF_SSH_KEY_TODAY fixes
# today's date (YYYY-MM-DD), DCF_SSH_KEY_NOW the time stamp of allowed_signers lines
# (YYYYMMDDHHMMSS); DCF_SECRET_BIN, DCF_OPENBAO_SSH and DCF_GH_SSH_KEY_ADD name the openbao and gh
# Features' commands; DCF_SSH_AGENT_LOADED_DIR is where the public keys of loaded keys are noted.
set -u

# Defaults baked by install.sh from the Feature options; SSH_AGENT_SETUP_* in the
# environment override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/ssh-agent-feature/options.env ] && source /usr/local/share/ssh-agent-feature/options.env
# keyMode and SSH_AGENT_SETUP_KEY_MODE are deprecated (removed in 2.0) for the `mode` option.
key_option="${SSH_AGENT_SETUP_KEY_MODE-${KEYMODE:-false}}"
# The Feature option `mode` (auto | socket | key | none; SSH_AGENT_SETUP_MODE overrides it). An empty
# or unknown value is auto, with one warning from the start hook (option_notes), because
# ${localEnv:SSH_AGENT_MODE:auto} can produce odd values.
mode_raw="${SSH_AGENT_SETUP_MODE-${MODE:-auto}}"
case "$mode_raw" in
  auto | socket | key | none) opt_mode="$mode_raw" ;;
  *) opt_mode=auto ;;
esac
# Seconds the hook waits for a passphrase typed at ssh-add's prompt (0: never prompt).
passphrase_wait="${SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT:-${PASSPHRASETIMEOUT:-120}}"
# Overridable so the Docker-free unit test can run against temp folders.
SSH_SOCK="${DCF_SSH_AGENT_SOCK:-/var/lib/devcontainer-features/ssh-agent/agent.sock}"
KEY_DIR="${DCF_SSH_AGENT_KEY_DIR:-/var/lib/devcontainer-features/ssh-agent-key}"
gh_bin="${DCF_GH:-gh}"
KEY_HISTORY="allowed_signers.history"
dcf_secret="${DCF_SECRET_BIN:-dcf-secret}"
openbao_ssh="${DCF_OPENBAO_SSH:-openbao-ssh}"
gh_key_add="${DCF_GH_SSH_KEY_ADD:-gh-ssh-key-add}"
# The public key of each key loaded from OpenBao, so key:lock works while the server is sealed.
# Public keys only; never a private key.
LOADED_DIR="${DCF_SSH_AGENT_LOADED_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ssh-agent-feature-$(id -u 2>/dev/null || echo 0)}"
default_key_names="id_ed25519 id_ecdsa id_rsa id_dsa id_ed25519_sk id_ecdsa_sk"
# shellcheck disable=SC2016  # the text is meant literally
KEY_HOWTO='"mode": "${localEnv:SSH_AGENT_MODE:auto}" in the ssh-agent entry of devcontainer.json plus SSH_AGENT_MODE=key in .devcontainer/.env on the workstation, then rebuild'
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
  say "ways round: a terminal in VS Code (it forwards the agent itself), or the opt-in key mode ($KEY_HOWTO), which keeps a signing key in the container's volume and so breaks 'the private key never enters the container'. See task ssh-agent:key:add."
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

# add_key <file>: load one private key into the agent at SSH_SOCK; 0 when loaded. A key without a
# passphrase is added at once. A protected key is NEVER asked for by the start hook (ask_ok=0): the
# hook has no business waiting for a person (the devcontainer CLI runs every start hook together and
# waits for all of them), so it skips the key with one warning and the start goes on. The explicit
# commands (task ssh-agent:setup, key:load, key:add, key:new, key:rotate) set ask_ok=1: ssh-add's own
# prompt ("Enter passphrase for <key>:", on the terminal, never read by this script) is waited for
# up to passphrase_wait seconds, and ssh-add re-asks after a wrong one as it always does. With no
# terminal, wait 0, a timeout or a skipped passphrase it prints ONE warning (the key is not loaded
# and the command to load it) and returns 1; nothing here ever fails the start.
# add_key <file> [seconds]: with seconds, the key is added with a lifetime (ssh-add -t) and the agent drops it then.
ask_ok=0
key_protected() { ! ssh-keygen -y -P '' -f "$1" </dev/null >/dev/null 2>&1; }
have_tty() { ( exec </dev/tty ) 2>/dev/null; }
add_key() {
  local f="$1" name="${1##*/}" life="${2:-}" rc err later wait="$passphrase_wait"
  local -a lifeopt=()
  later="run task ssh-agent:setup from a terminal in the container"
  if [ -n "$life" ]; then lifeopt=(-t "$life"); later="run task ssh-agent:key:unlock NAME=$name from a terminal in the container"; fi
  case "$wait" in '' | *[!0-9]*) wait=120 ;; esac
  if ! key_protected "$f"; then
    SSH_ASKPASS_REQUIRE=never SSH_AUTH_SOCK="$SSH_SOCK" ssh-add "${lifeopt[@]}" "$f" </dev/null >/dev/null 2>&1 && return 0
    warn "could not add $name to the agent; the start continues. Try again: $later"
    return 1
  fi
  if [ "$ask_ok" -ne 1 ]; then
    warn "$name has a passphrase and the start hook never asks for one, so it is not loaded; the start continues. Load it: $later"
    return 1
  fi
  if ! have_tty; then
    warn "$name has a passphrase and there is no terminal to ask for it, so it is not loaded; the start continues. Load it: $later"
    return 1
  fi
  if [ "$wait" -eq 0 ]; then
    warn "$name has a passphrase and the wait for it is off (passphrase timeout 0), so it is not loaded; the start continues. Load it: $later"
    return 1
  fi
  say "$name has a passphrase: ssh-add asks for it below; waiting up to ${wait}s (SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT), then it is skipped."
  if command -v timeout >/dev/null 2>&1; then
    err="$(SSH_ASKPASS_REQUIRE=never SSH_AUTH_SOCK="$SSH_SOCK" timeout --foreground "$wait" ssh-add "${lifeopt[@]}" "$f" </dev/null 2>&1 >/dev/null)"; rc=$?
  else
    err="$(SSH_ASKPASS_REQUIRE=never SSH_AUTH_SOCK="$SSH_SOCK" ssh-add "${lifeopt[@]}" "$f" </dev/null 2>&1 >/dev/null)"; rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
  [ -t 2 ] && echo >&2
  if [ "$rc" -eq 124 ]; then
    warn "no passphrase for $name within ${wait}s, so it is not loaded; the start continues. Load it: $later"
  else
    warn "$name was not loaded (the passphrase was not accepted or was skipped${err:+; ssh-add said: ${err##*$'\n'}}); the start continues. Load it: $later"
  fi
  return 1
}

load_keys() { # adds every private key of KEY_DIR; prints one line per refusal, then a summary
  local f mode_bits loaded=0 refused=0 failed=0 total=0
  if [ ! -d "$KEY_DIR" ]; then say "key mode: no key volume at $KEY_DIR (the Feature declares it; was the container created without it?)"; return 0; fi
  for f in "$KEY_DIR"/*; do
    is_private_key "$f" || continue
    total=$((total + 1))
    warn_default_name "${f##*/}"

    mode_bits="$(stat -c %a "$f" 2>/dev/null || echo 777)"
    if [ $((8#$mode_bits & 8#077)) -ne 0 ]; then
      refused=$((refused + 1))
      warn "refusing ${f##*/}: mode $mode_bits lets group or others read it; run chmod 600 on it (or add it again with task ssh-agent:key:add)"
      continue
    fi
    if add_key "$f"; then loaded=$((loaded + 1)); else failed=$((failed + 1)); fi
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
  [ -z "$(list_keys)" ] || warn "deprecated: the key volume ($KEY_DIR) goes in ssh-agent 2.0; move its keys into OpenBao with task openbao:ssh:import FROM=ssh-agent, then load one for a sitting with task ssh-agent:key:load NAME=ssh/<key>"
}

# --- the verdicts --------------------------------------------------------------
effective_mode() { # sets EFF: key | socket | none | unknown
  case "$opt_mode" in
    socket) EFF=socket; return 0 ;; # pinned: the host's agent, whatever the launcher said
    none) EFF=none; return 0 ;;     # pinned: no agent
  esac
  case "$mode" in key) EFF=key ;; socket) EFF=socket ;; none) EFF=none ;; *) EFF=unknown ;; esac
  # mode key, or auto with the deprecated keyMode: true: the in-container agent, unless the launcher
  # really mounted a host socket (that wins).
  if want_key && { [ "$EFF" = none ] || [ "$EFF" = unknown ]; }; then EFF=key; fi
}

want_key() { [ "$opt_mode" = key ] || { [ "$opt_mode" = auto ] && [ "$key_option" = true ]; }; }

option_notes() { # one line per odd or deprecated setting, from the start hook only
  case "$mode_raw" in
    auto | socket | key | none) ;;
    *) warn "the ssh-agent option mode is '$mode_raw', which is not auto, socket, key or none; treating it as auto (check SSH_AGENT_MODE in .devcontainer/.env)" ;;
  esac
  if [ "$key_option" = true ]; then
    warn "deprecated: keyMode / SSH_AGENT_SETUP_KEY_MODE go in ssh-agent 2.0; use the option mode: $KEY_HOWTO$([ "$opt_mode" = auto ] || echo " (keyMode is ignored while mode is $opt_mode)")"
  fi
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
    *) say "not reachable, and the host is unknown (DCF_HOST_SSH_AGENT is unset): start through task devcontainer:up so the launcher can mount the agent, or opt into the key mode ($KEY_HOWTO)." ;;
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
    warn "key mode is off in this container, nothing was changed. Turn it on with $KEY_HOWTO. With a host agent (socket mode), load keys on the host: task devcontainer:ssh-add -- <key>."
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

# --- key hygiene: default names, creation dates, age --------------------------------
today() { echo "${DCF_SSH_KEY_TODAY:-$(date +%F)}"; }
epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }

warn_default_name() { # <key name>: a general-purpose name is a sign the key is not a dedicated one
  local d
  for d in $default_key_names; do
    if [ "$1" = "$d" ]; then
      warn "warning: $1 has the default name of a general-purpose key. Import only a dedicated signing key (named <repo>-<container>-sign) that opens nothing else; see 'Dedicated keys' in the Feature's notes, and task ssh-agent:key:rotate to replace it."
      return 0
    fi
  done
  return 0
}

list_keys() { # prints the file name of each private key in the key volume
  local f
  [ -d "$KEY_DIR" ] || return 0
  for f in "$KEY_DIR"/*; do is_private_key "$f" && echo "${f##*/}"; done
  return 0
}

write_meta() { # <name> <source>: the sidecar that records when the key came to this volume (never overwritten)
  [ -e "$KEY_DIR/$1.meta" ] && return 0
  printf 'created=%s\nsource=%s\n' "$(today)" "$2" > "$KEY_DIR/$1.meta" 2>/dev/null || true
}

key_created() { # <name>: YYYY-MM-DD from the sidecar, else the file's modification date
  local c=''
  [ -f "$KEY_DIR/$1.meta" ] && c="$(sed -n 's/^created=//p' "$KEY_DIR/$1.meta" | head -n 1)"
  [ -n "$c" ] || c="$(date -r "$KEY_DIR/$1" +%F 2>/dev/null || echo 1970-01-01)"
  echo "$c"
}

key_age_days() { echo $((($(epoch_of "$(today)") - $(epoch_of "$(key_created "$1")")) / 86400)); }

max_age_days() { case "${SSH_KEY_MAX_AGE_DAYS:-}" in '' | *[!0-9]*) echo 365 ;; *) echo "$SSH_KEY_MAX_AGE_DAYS" ;; esac; }

key_fp() { # <name>: fingerprint of a key of the volume (the .pub when there is one)
  if [ -f "$KEY_DIR/$1.pub" ]; then fingerprint_of "$KEY_DIR/$1.pub"; else fingerprint_of "$KEY_DIR/$1"; fi
}

key_hygiene() { # the warnings for what sits in the key volume: default names and old keys
  local n max
  max="$(max_age_days)"
  for n in $(list_keys); do
    warn_default_name "$n"
    if [ "$(key_age_days "$n")" -gt "$max" ]; then
      warn "warning: key $n is older than $max days; task ssh-agent:key:rotate NAME=$n (created $(key_created "$n"))"
    fi
  done
  return 0
}

host_rotation_guidance() { # keys held by the host's agent (socket mode): the Feature cannot touch them
  say "keys held by the host's agent are not this Feature's to rotate. To rotate one: (1) make a new dedicated key on the host and add it to the host agent (task devcontainer:ssh-add -- <new key>); (2) register its public key at GitHub as a SIGNING key, not an authentication key; (3) point git at it (task ssh-agent:git:signing KEY=<its .pub>) and run task ssh-agent:git:verify; (4) only then remove the old key from the host agent (ssh-add -d on the host) and from GitHub if you want its old commits unverified (they stay verified while it is registered)."
}

cmd_key_age() {
  local n any=0
  if [ ! -d "$KEY_DIR" ]; then say "no key volume at $KEY_DIR"; return 0; fi
  for n in $(list_keys); do
    any=1
    say "$n: created $(key_created "$n"), $(key_age_days "$n") day(s) old, $(key_fp "$n")"
  done
  [ "$any" -eq 1 ] || say "no private key in $KEY_DIR"
  say "keys older than $(max_age_days) days are flagged by task ssh-agent:check (SSH_KEY_MAX_AGE_DAYS changes the limit); rotate with task ssh-agent:key:rotate."
  return 0
}

default_key_name() { # <repo>-<container>-sign, [a-z0-9-] only
  local top repo host
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  repo="$(basename "${top:-$PWD}")"
  host="$(hostname 2>/dev/null || echo container)"
  printf '%s-%s-sign\n' "$repo" "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//'
}

generate_key() { # <name> <comment> <empty passphrase>: ed25519 into the volume, sidecar written
  local name="$1" comment="$2" empty="$3" args
  [ -n "$comment" ] || comment="$name@$(hostname 2>/dev/null || echo container)"
  args=(-t ed25519 -f "$KEY_DIR/$name" -C "$comment")
  case "$empty" in 1 | true | yes) args+=(-N '') ;; esac
  ssh-keygen "${args[@]}" >/dev/null || { warn "ssh-keygen failed"; return 1; }
  chmod 0600 "$KEY_DIR/$name"
  write_meta "$name" generated
}

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
  write_meta "$name" import
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
    write_meta "$name" import
    warn_default_name "$name"
    say "key mode: stored $name in $KEY_DIR (mode 0600), fingerprint $(fingerprint_of "$KEY_DIR/$name")"
  else say "key mode: stored $name in $KEY_DIR"; fi
}

cmd_key_new() { # [name] [comment] [empty passphrase]
  local name="${1:-}" comment="${2:-}" empty="${3:-}"
  [ -n "$name" ] || name="$(default_key_name)"
  safe_name "$name" || exit 1
  require_key_mode
  prepare_key_mode
  [ ! -e "$KEY_DIR/$name" ] || { warn "$KEY_DIR/$name exists; pick another NAME or remove it first (task ssh-agent:key:remove NAME=$name DELETE=1)"; exit 1; }
  generate_key "$name" "$comment" "$empty" || exit 1
  say "key mode: generated $name (ed25519) in $KEY_DIR; the private key stays there."
  load_keys
  say "public key: register it at GitHub (Settings > SSH and GPG keys > New SSH key) as a SIGNING key, not an authentication key (key type: Signing Key), titled $name:"
  cat "$KEY_DIR/$name.pub"
  say "register as a SIGNING key, not an authentication key: a signing-only key cannot log in to anything if it leaks. Replace it later with task ssh-agent:key:rotate."
}

unload_key() { # <name>: drop the key from the agent at SSH_SOCK (the .pub when there is one, so a protected key is never asked for); says which; 0 when it was loaded
  local name="$1" ref="$KEY_DIR/$1"
  [ -f "$ref.pub" ] && ref="$ref.pub"
  if SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -d "$ref" >/dev/null 2>&1; then say "removed $name from the agent"; return 0; fi
  say "$name was not in the agent (or no agent answers on $SSH_SOCK)"
  return 1
}

cmd_key_remove() { # <name> [delete]
  local name="${1:-}" del="${2:-}"
  safe_name "$name" || exit 1
  [ -f "$KEY_DIR/$name" ] || { warn "no key $name in $KEY_DIR"; exit 1; }
  unload_key "$name"
  case "$del" in
    1 | true | yes) drop_key_files "$name"; say "deleted $name from $KEY_DIR" ;;
    *) say "$name is still in $KEY_DIR and returns at the next start; DELETE=1 removes it from the volume" ;;
  esac
}

max_unlock_minutes=480
cmd_key_unlock() { # <name> [minutes]: one key into the agent for a sitting
  local name="${1:-}" minutes="${2:-15}" f
  safe_name "$name" || exit 1
  require_key_mode
  case "$minutes" in '' | *[!0-9]* | 0 | 0[0-9]*) warn "MINUTES must be a positive whole number (got '$minutes'); nothing was loaded"; exit 1 ;; esac
  [ "${#minutes}" -le 4 ] && [ "$minutes" -le "$max_unlock_minutes" ] || { warn "MINUTES $minutes is over the limit of $max_unlock_minutes (8 hours); a longer-lived key is a key:load; nothing was loaded"; exit 1; }
  f="$KEY_DIR/$name"
  is_private_key "$f" || { warn "no private key $name in $KEY_DIR (task ssh-agent:keys lists what is loaded; the file names are the ones in the volume); nothing was loaded"; exit 1; }
  prepare_key_mode
  if add_key "$f" $((minutes * 60)); then
    say "$name is in the agent for $minutes minute(s), until about $(date -d "+$minutes minutes" +%H:%M 2>/dev/null || echo "$minutes minutes from now"); lock it sooner with task ssh-agent:key:lock NAME=$name"
  else
    exit 1
  fi
}

cmd_key_lock() { # <name>: unload one key, keep the file
  local name="${1:-}"
  safe_name "$name" || exit 1
  require_key_mode
  [ -f "$KEY_DIR/$name" ] || { warn "no key $name in $KEY_DIR"; exit 1; }
  unload_key "$name"
  say "$name is still in $KEY_DIR; task ssh-agent:key:unlock NAME=$name loads it again"
}

# --- git signing ----------------------------------------------------------------
pubkey_lines() { SSH_AUTH_SOCK="$ACTIVE" ssh-add -L 2>/dev/null; }

default_scope() { # sets DEFAULT_SCOPE and DEFAULT_WHY
  case "${GIT_CONFIG_GLOBAL:-}" in
    /var/lib/devcontainer-features/*) DEFAULT_SCOPE=global; DEFAULT_WHY="the git Feature keeps the container's own global config in a volume" ;;
    *)
      case "$host_type" in
        windows-*) DEFAULT_SCOPE=global; DEFAULT_WHY="on a Windows host the repository's config can be shared with Windows git, which would sign with a key its agent does not hold" ;;
        *) DEFAULT_SCOPE=repo; DEFAULT_WHY="no git Feature volume found" ;;
      esac
      ;;
  esac
}

# --- allowed_signers: .devcontainer/allowed_signers in the repository -----------------
# Who may sign the history (proposal section 8): one line per key, namespaces="git", valid-after
# and valid-before stamps; public keys only; the host commits it. git finds it through
# gpg.ssh.allowedSignersFile in the repository's config as the work-tree-relative path, which git
# resolves against the top of the work tree from any folder (and so does Windows git on the same
# repository config, ADR 0020); ALLOWED_SIGNERS=<file> names another file.
AS_REL=".devcontainer/allowed_signers"
stamp_now() { echo "${DCF_SSH_KEY_NOW:-$(date +%Y%m%d%H%M%S)}"; }
as_path() { # [given]: sets AS_FILE (to write) and AS_CFG (what gpg.ssh.allowedSignersFile says); 1 when none
  local top
  AS_FILE='' AS_CFG=''
  if [ -n "${1:-}" ]; then AS_FILE="$1"; AS_CFG="$1"; return 0; fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  AS_FILE="$top/$AS_REL"
  AS_CFG="$AS_REL"
}
as_header() { # <file>
  [ -f "$1" ] && return 0
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  cat >"$1" <<'EOF_AS'
# Who may sign this repository's commits and tags: one line per SSH signing key, in ssh-keygen's
# ALLOWED SIGNERS format (principal, options, key type, public key), with namespaces="git" and,
# where known, valid-after / valid-before dates (YYYYMMDD). Public keys only, never a private key.
# Written by task openbao:ssh:import, ssh-agent:git:signing and ssh-agent:key:rotate; the host
# commits it. git reads it through gpg.ssh.allowedSignersFile (task ssh-agent:git:signing sets it).
EOF_AS
}
as_has() { # <file> <blob>
  [ -f "$1" ] && awk -v b="$2" '!/^#/ { for (i = 1; i <= NF; i++) if ($i == b) f = 1 } END { exit !f }' "$1"
}
as_principal() { # <comment>: a plain name (no @, so no address lands in the repository), else signer
  case "$1" in '' | *@* | *[!A-Za-z0-9._-]*) echo signer ;; *) echo "$1" ;; esac
}
as_add() { # <file> <principal> <type blob> [valid-after stamp]
  local opts='namespaces="git"' blob
  blob="$(awk '{print $2}' <<<"$3")"
  [ -n "$blob" ] || return 1
  if as_has "$1" "$blob"; then say "allowed_signers: the key is already in $1"; return 0; fi
  as_header "$1" || { warn "could not write $1"; return 1; }
  [ -z "${4:-}" ] || opts="$opts,valid-after=\"$4\""
  printf '%s %s %s\n' "$2" "$opts" "$3" >>"$1"
  say "allowed_signers: added $2 to $1 (the host commits it)"
}
as_retire() { # <file> <blob> <stamp>: valid-before on the key's lines that have none yet
  local tmpf
  [ -f "$1" ] && as_has "$1" "$2" || return 0
  tmpf="$(mktemp "$1.XXXXXX")" || return 1
  awk -v b="$2" -v t="$3" '!/^#/ { for (i = 3; i <= NF; i++) if ($i == b && $2 !~ /valid-before=/) { $2 = $2 ",valid-before=\"" t "\""; break } } { print }' "$1" >"$tmpf" && mv -f "$tmpf" "$1"
  say "allowed_signers: the old key is valid before $3 in $1, so its signatures still verify"
}

cmd_git_signing() { # [key] [scope] [allowed signers file]
  local key="${1:-}" scope="${2:-}" as_given="${3:-}" lines n pub line fp want cfg comment=''
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
  comment="$(printf '%s\n' "$pub" | awk '{print $3}')"
  pub="$(printf '%s\n' "$pub" | awk '{print $1 " " $2}')"
  case "$pub" in ssh-* | ecdsa-* | sk-*) ;; *) warn "that does not look like a public key"; exit 1 ;; esac

  if [ -z "$scope" ]; then
    default_scope
    scope="$DEFAULT_SCOPE"
    say "SCOPE not given: using $scope ($DEFAULT_WHY)."
  fi
  case "$scope" in
    global) cfg=(--global) ;;
    repo)
      git rev-parse --git-dir >/dev/null 2>&1 || { warn "SCOPE=repo needs a git repository in the current directory"; exit 1; }
      cfg=(--local)
      say "SCOPE=repo writes into this repository's own git config, which in this collection can be shared with the Windows host (a git dir kept under .git-dirs); SCOPE=global writes only the container's config."
      say "if this git dir is shared with Windows, use SCOPE=global: Windows git would read user.signingkey key::<public key> and sign through a Windows agent that does not hold the key, so commits on the host fail."
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
  # allowed_signers: only where the repository has the file (or one is named, or a rotation asks
  # for it), so a repository that never chose one gets no new file.
  if as_path "$as_given" && { [ -f "$AS_FILE" ] || [ -n "$as_given" ] || [ -n "${AS_CREATE:-}" ]; }; then
    as_add "$AS_FILE" "$(as_principal "$comment")" "$pub" "${AS_VALID_AFTER:-}" || exit 1
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git config --local gpg.ssh.allowedSignersFile "$AS_CFG" || { warn "could not set gpg.ssh.allowedSignersFile"; exit 1; }
      say "git (repo) verifies signatures against $AS_CFG (gpg.ssh.allowedSignersFile; a relative path is read from the top of the work tree)"
    else
      git config "${cfg[@]}" gpg.ssh.allowedSignersFile "$AS_CFG" || { warn "could not set gpg.ssh.allowedSignersFile"; exit 1; }
    fi
  else
    say "to verify signatures with git log --show-signature, also set gpg.ssh.allowedSignersFile (a repository with $AS_REL gets it here; ALLOWED_SIGNERS=<file> names one); task ssh-agent:git:verify tests signing now."
  fi
}

cmd_git_verify() {
  # tmp is deliberately not local: the EXIT trap below runs after this
  # function has returned, and set -u would abort on an unbound name.
  local format key pub why
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

# --- rotation and retirement ---------------------------------------------------
gh_ready() { command -v "$gh_bin" >/dev/null 2>&1 && "$gh_bin" auth status </dev/null >/dev/null 2>&1; }

pub_blob() { awk '{print $2}' "$1" 2>/dev/null | head -n 1; }

gh_key_ids() { # <pub file>: the GitHub ids of the keys registered with that public key
  gh_key_ids_blob "$(pub_blob "$1")"
}
gh_key_ids_blob() { # <public key blob>
  local blob="$1"
  [ -n "$blob" ] || return 0
  "$gh_bin" ssh-key list </dev/null 2>/dev/null | awk -F'\t' -v b="$blob" 'index($0, b) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { print $i; break } }'
}

is_true() { case "${1:-}" in 1 | true | yes) return 0 ;; *) return 1 ;; esac; }

key_loaded() { # <name>: the agent on the fixed path holds it
  local fp
  fp="$(key_fp "$1")"
  [ -n "$fp" ] && SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -l 2>/dev/null | grep -qF -- "$fp"
}

load_one() { # <name>: add it to the agent; a passphrase is asked for as add_key does
  add_key "$KEY_DIR/$1"
}

drop_key_files() { # <name>: the private key, its public half and its sidecar leave the volume
  rm -f "${KEY_DIR:?}/${1:?}" "${KEY_DIR:?}/${1:?}.pub" "${KEY_DIR:?}/${1:?}.meta"
}

history_append() { # <name>: the retired key's public half, with the date, into the history file
  local pubf="$KEY_DIR/$1.pub" blob d tmpf=''
  if [ ! -f "$pubf" ]; then
    tmpf="$(mktemp "$KEY_DIR/.hist.XXXXXX")" || return 1
    if ssh-keygen -y -P '' -f "$KEY_DIR/$1" </dev/null > "$tmpf" 2>/dev/null; then pubf="$tmpf"; fi
  fi
  if [ ! -s "$pubf" ]; then
    [ -z "$tmpf" ] || rm -f "$tmpf"
    warn "no public key for $1 (and its private key needs a passphrase to derive one); nothing was changed"
    return 1
  fi
  blob="$(pub_blob "$pubf")"
  d="$(today)"
  if [ -f "$KEY_DIR/$KEY_HISTORY" ] && grep -qF -- "$blob" "$KEY_DIR/$KEY_HISTORY"; then
    say "$1 is already in $KEY_DIR/$KEY_HISTORY"
  else
    printf '* namespaces="git",valid-before="%s" %s %s %s\n' "${d//-/}" "$(awk '{print $1}' "$pubf")" "$blob" "retired:$1:$d" >> "$KEY_DIR/$KEY_HISTORY"
    say "appended $1 (valid before ${d//-/}) to $KEY_DIR/$KEY_HISTORY, so its old signatures still verify locally (set gpg.ssh.allowedSignersFile to that file)"
  fi
  [ -z "$tmpf" ] || rm -f "$tmpf"
  return 0
}

retire_plan() { # <name> <revoke>
  say "plan, retiring $1 ($(key_fp "$1")):"
  say "  1. append its public key, dated, to $KEY_DIR/$KEY_HISTORY"
  if is_true "$2"; then say "  2. remove it from GitHub (gh ssh-key delete <id> --yes, id found by its public key); old commits then show unverified at GitHub"
  else say "  2. keep it registered at GitHub, so old commits keep their verified badge (REVOKE=1 removes it)"; fi
  say "  3. unload it from the agent, delete the private key and its sidecar from $KEY_DIR"
  say "nothing was changed."
}

do_retire() { # <name> <revoke>: the last step; any failure stops before something is removed
  local name="$1" revoke="$2" ids id pubf eff blob
  history_append "$name" || return 1
  pubf="$KEY_DIR/$name.pub"
  blob="$(pub_blob "$pubf")"
  eff="$(git config --get user.signingkey 2>/dev/null || true)"
  if [ -n "$blob" ] && [ -n "$eff" ]; then
    case "$eff" in *"$blob"*) warn "warning: git still signs with $name (user.signingkey); point it at another key (task ssh-agent:git:signing) or signing will fail" ;; esac
  fi
  if is_true "$revoke"; then
    gh_ready || { warn "REVOKE needs gh installed and logged in (gh auth login); nothing was removed. Without REVOKE=1 the key stays registered at GitHub."; return 1; }
    [ -f "$pubf" ] || { warn "no $name.pub to find the key on GitHub by; nothing was removed"; return 1; }
    ids="$(gh_key_ids "$pubf")"
    if [ -z "$ids" ]; then warn "$name is not in gh ssh-key list; remove it at GitHub by hand if it is registered. Nothing was removed locally."; return 1; fi
    for id in $ids; do
      "$gh_bin" ssh-key delete "$id" --yes </dev/null >/dev/null 2>&1 || { warn "gh ssh-key delete $id failed; nothing was removed locally"; return 1; }
      say "removed $name from GitHub (key id $id)"
    done
  else
    say "$name stays registered at GitHub, so old commits keep their verified badge; remove it there later (Settings > SSH and GPG keys) once nothing needs them verified."
  fi
  if [ -f "$pubf" ]; then
    if SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -d "$pubf" >/dev/null 2>&1; then say "unloaded $name from the agent"; else say "$name was not in the agent"; fi
  else SSH_AUTH_SOCK="$SSH_SOCK" ssh-add -d "$KEY_DIR/$name" >/dev/null 2>&1 || true; fi
  drop_key_files "$name"
  say "retired $name: its private key is deleted from $KEY_DIR"
}

parse_rotation_args() { # sets A_NAME A_NEW A_REVOKE A_SCOPE A_EMPTY A_PLAN
  A_NAME='' A_NEW='' A_REVOKE='' A_SCOPE='' A_EMPTY='' A_PLAN='' A_AS=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) A_PLAN=1; shift ;;
      --name) A_NAME="${2:-}"; shift 2 || shift ;;
      --new) A_NEW="${2:-}"; shift 2 || shift ;;
      --revoke) A_REVOKE="${2:-}"; shift 2 || shift ;;
      --scope) A_SCOPE="${2:-}"; shift 2 || shift ;;
      --empty) A_EMPTY="${2:-}"; shift 2 || shift ;;
      --allowed-signers) A_AS="${2:-}"; shift 2 || shift ;;
      '') shift ;;
      *) warn "unknown argument '$1' (use -- --plan to only print the steps)"; exit 1 ;;
    esac
  done
}

one_key_or_name() { # <given name>: sets KEYNAME, or exits 1 when it cannot be told which
  local n count cands
  if [ -n "$1" ]; then
    safe_name "$1" || exit 1
    [ -f "$KEY_DIR/$1" ] || { warn "no key $1 in $KEY_DIR (task ssh-agent:key:age lists them)"; exit 1; }
    KEYNAME="$1"; return 0
  fi
  # a NEW that already exists (a resumed rotation) is not a candidate for the old key
  cands="$(list_keys | grep -vxF -- "${A_NEW:-/}" || true)"
  count="$(printf '%s\n' "$cands" | grep -c .)"
  if [ "$count" -eq 1 ]; then KEYNAME="$cands"; return 0; fi
  warn "$count keys in $KEY_DIR; say which with NAME=<key>:"
  for n in $cands; do warn "  $n"; done
  exit 1
}

cmd_key_retire() {
  parse_rotation_args "$@"
  require_key_mode
  one_key_or_name "$A_NAME"
  if [ -n "$A_PLAN" ]; then retire_plan "$KEYNAME" "$A_REVOKE"; exit 0; fi
  prepare_key_mode
  do_retire "$KEYNAME" "$A_REVOKE" || exit 1
}

stop_rotation() { # <step> <old> <new> <why>
  warn "rotation stopped at step $1: $4. Nothing of the old key $2 was removed. To finish: fix that, then task ssh-agent:key:rotate NAME=$2 NEW=$3 (it resumes with the new key already made)."
  exit 1
}

cfg_flag() { if [ "$1" = global ]; then echo --global; else echo --local; fi; }

# save_cfg <scope>: remember the four signing settings of that scope (SAVED_SET, SAVED_VAL)
save_cfg() {
  local k flag
  flag="$(cfg_flag "$1")"
  SAVED_SET=() SAVED_VAL=()
  for k in gpg.format user.signingkey commit.gpgsign tag.gpgsign; do
    if SAVED_V="$(git config "$flag" --get "$k" 2>/dev/null)"; then SAVED_SET+=(1); SAVED_VAL+=("$SAVED_V")
    else SAVED_SET+=(0); SAVED_VAL+=(''); fi
  done
}

restore_cfg() { # <scope>: the settings saved by save_cfg come back
  local k flag i=0
  flag="$(cfg_flag "$1")"
  for k in gpg.format user.signingkey commit.gpgsign tag.gpgsign; do
    if [ "${SAVED_SET[$i]}" = 1 ]; then git config "$flag" "$k" "${SAVED_VAL[$i]}" 2>/dev/null
    else git config "$flag" --unset-all "$k" 2>/dev/null; fi
    i=$((i + 1))
  done
  return 0
}

cmd_key_rotate() {
  local old new base resume='' scope pub fp_old fp_new eff
  parse_rotation_args "$@"
  require_key_mode
  one_key_or_name "$A_NAME"
  old="$KEYNAME"
  base="${old%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
  if [ -n "$A_NEW" ]; then
    new="$A_NEW"
    safe_name "$new" || exit 1
    [ "$new" != "$old" ] || { warn "NEW is the old key's own name"; exit 1; }
    [ -f "$KEY_DIR/$new" ] && resume=1
  else
    new="$base-$(today | tr -d -)"
    [ "$new" != "$old" ] || { warn "today's name $new is the old key's own; pass NEW=<another name>"; exit 1; }
    if [ -e "$KEY_DIR/$new" ]; then warn "$new already exists (an earlier rotation stopped?). Resume it with task ssh-agent:key:rotate NAME=$old NEW=$new, or pick another NEW."; exit 1; fi
  fi
  scope="$A_SCOPE"
  if [ -z "$scope" ]; then default_scope; scope="$DEFAULT_SCOPE"; fi
  case "$scope" in global | repo) ;; *) warn "SCOPE is repo or global, not '$scope'"; exit 1 ;; esac
  fp_old="$(key_fp "$old")"

  if [ -n "$A_PLAN" ]; then
    say "plan, rotating $old ($fp_old) into $new$([ -n "$resume" ] && echo ' (already made, resuming)'):"
    if [ -z "$resume" ]; then say "  1. make the new ed25519 key $new in $KEY_DIR and load it; $old stays loaded"
    else say "  1. $new exists: load it if it is not loaded; $old stays loaded"; fi
    if gh_ready; then say "  2. gh is logged in: register $new.pub at GitHub as a SIGNING key (gh ssh-key add --type signing) unless it is registered already"
    elif [ -n "$resume" ]; then say "  2. gh is not available: take your word that $new is registered as a signing key (you asked to resume)"
    else say "  2. gh is not available or not logged in: print the public key and the manual step, then STOP (exit 1); register it, then task ssh-agent:key:rotate NAME=$old NEW=$new"; fi
    say "  3. point git ($scope scope) at $new and run git:verify; a failure puts git back as it was and stops"
    if is_true "$A_REVOKE"; then say "  4. only then retire $old: unload it, append it dated to $KEY_DIR/$KEY_HISTORY, delete its private key, and remove it from GitHub (REVOKE=1)"
    else say "  4. only then retire $old: unload it, append it dated to $KEY_DIR/$KEY_HISTORY, delete its private key; it stays registered at GitHub (REVOKE=1 would remove it)"; fi
    say "nothing was changed."
    exit 0
  fi

  prepare_key_mode
  # step 1: the new key; the old one stays
  if [ -z "$resume" ]; then
    say "step 1/4: making $new"
    generate_key "$new" "" "$A_EMPTY" || stop_rotation 1 "$old" "$new" "ssh-keygen failed"
  else say "step 1/4: $new exists, resuming"; fi
  key_loaded "$new" || load_one "$new" || true
  key_loaded "$new" || stop_rotation 1 "$old" "$new" "$new could not be loaded into the agent (a passphrase needs a terminal: run task ssh-agent:key:load)"
  pub="$KEY_DIR/$new.pub"
  fp_new="$(key_fp "$new")"
  say "step 1/4 done: $new ($fp_new) is loaded next to $old"

  # step 2: register it as a signing key
  if gh_ready; then
    if [ -n "$(gh_key_ids "$pub")" ]; then say "step 2/4: $new is already registered at GitHub"
    else
      say "step 2/4: registering $new at GitHub as a signing key"
      "$gh_bin" ssh-key add "$pub" --type signing --title "$new" </dev/null >/dev/null 2>&1 || stop_rotation 2 "$old" "$new" "gh ssh-key add failed (does the gh login have the admin:ssh_signing_key scope? gh auth refresh -s admin:ssh_signing_key)"
    fi
  elif [ -n "$resume" ]; then
    say "step 2/4: gh is not available here; taking your word that $new is registered at GitHub as a SIGNING key"
  else
    warn "step 2/4: gh is not installed or not logged in here, so $new cannot be registered from this container. Register this public key at GitHub (Settings > SSH and GPG keys > New SSH key, key type Signing Key, title $new), a SIGNING key and not an authentication key:"
    cat "$pub"
    warn "finish by registering it, then run key:rotate again with NEW=$new: task ssh-agent:key:rotate NAME=$old NEW=$new. Nothing of $old was removed; $new stays loaded."
    exit 1
  fi

  # step 3: git signs with the new key, and proves it
  save_cfg "$scope"
  say "step 3/4: pointing git ($scope scope) at $new and verifying"
  if ! ( cmd_git_signing "$pub" "$scope" ); then restore_cfg "$scope"; stop_rotation 3 "$old" "$new" "git:signing failed; git's settings are back as they were"; fi
  eff="$(git config --get user.signingkey 2>/dev/null || true)"
  case "$eff" in
    *"$(pub_blob "$pub")"*) ;;
    *) restore_cfg "$scope"; stop_rotation 3 "$old" "$new" "another git config level still names a different signing key (see git config --show-origin --get user.signingkey); git's settings are back as they were" ;;
  esac
  if ! ( cmd_git_verify ); then restore_cfg "$scope"; stop_rotation 3 "$old" "$new" "git:verify did not pass; git's settings are back as they were"; fi

  # step 4: only now the old key goes
  say "step 4/4: retiring $old"
  do_retire "$old" "$A_REVOKE" || stop_rotation 4 "$old" "$new" "retiring $old failed (git already signs with $new; task ssh-agent:key:retire NAME=$old finishes it)"
  say "rotated: $old is retired, git signs with $new ($fp_new). Old signatures verify with gpg.ssh.allowedSignersFile set to $KEY_DIR/$KEY_HISTORY."
}

# --- keys from OpenBao ----------------------------------------------------------------
# The key comes from the openbao Feature's dcf-secret on a pipe into `ssh-add -`: it is in agent
# memory only, never in a file, and the agent drops it after the lifetime (ssh-add -t). The
# lifetime is at most what is left of the OpenBao login (dcf-secret ttl) and at most 480 minutes;
# MINUTES shortens it. Its public key is noted in LOADED_DIR so key:lock works while sealed.
is_bao_name() { case "$1" in */*) return 0 ;; *) return 1 ;; esac; }
bao_name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$ ]] || { warn "'$1' is not an OpenBao name (ssh/<key> or register/<principal>)"; return 1; }; }
need_cmd() { # <command> <Feature>: refuse plainly when another Feature's command is missing
  command -v "$1" >/dev/null 2>&1 || { warn "$1 is not installed: add the $2 Feature to the devcontainer (OpenBao keeps the keys)"; exit 1; }
}
loaded_note() { echo "$LOADED_DIR/${1//\//__}.pub"; }

deprecated() { # <what> <instead>: one line, the volume's command still runs
  warn "deprecated: $1 uses the key volume, which goes in ssh-agent 2.0; use $2 (task openbao:ssh:import FROM=ssh-agent moves the volume's keys into OpenBao)"
}

# bao_agent: sets ACTIVE (the agent to load into) and WHERE (container, workstation, forwarded);
# in key mode with no agent yet it starts the in-container one; otherwise refuses with the verdict.
bao_agent() {
  effective_mode
  active_sock
  probe "$ACTIVE"
  if [ "$PROBE_RC" -le 1 ]; then
    if [ "$ACTIVE" != "$SSH_SOCK" ]; then WHERE=forwarded
    elif [ "$EFF" = socket ]; then WHERE=workstation
    else WHERE=container; fi
    return 0
  fi
  if [ "$EFF" = key ]; then
    start_agent
    [ "$AGENT_STATE" != failed ] || exit 1
    ACTIVE="$SSH_SOCK" WHERE=container
    return 0
  fi
  verdict
  exit 1
}

cmd_bao_load() { # <name> [minutes]
  local name="$1" minutes="${2:-}" ttl cap life out rcs pub until note
  bao_name_ok "$name" || exit 1
  need_cmd "$dcf_secret" openbao
  if [ -n "$minutes" ]; then
    case "$minutes" in *[!0-9]* | 0 | 0[0-9]*) warn "MINUTES must be a positive whole number (got '$minutes'); nothing was loaded"; exit 1 ;; esac
    [ "${#minutes}" -le 4 ] && [ "$minutes" -le "$max_unlock_minutes" ] || { warn "MINUTES $minutes is over the limit of $max_unlock_minutes (8 hours); nothing was loaded"; exit 1; }
  fi
  ttl="$("$dcf_secret" ttl)" || exit $?
  cap=$((max_unlock_minutes * 60))
  if [ "$ttl" -gt 0 ] && [ "$ttl" -lt "$cap" ]; then cap="$ttl"; fi
  life="$cap"
  if [ -n "$minutes" ]; then
    life=$((minutes * 60))
    if [ "$life" -gt "$cap" ]; then
      life="$cap"
      say "MINUTES=$minutes is longer than the OpenBao login has left; the key lives $((cap / 60)) minute(s), as long as the login"
    fi
  fi
  [ "$life" -ge 60 ] || { warn "the OpenBao login has less than a minute left: log in again (task openbao:login), then load; nothing was loaded"; exit 12; }
  bao_agent
  # dcf-secret's own line goes to stderr as it is; ssh-add's is kept for the message. The key
  # passes on the pipe only.
  out="$({ "$dcf_secret" get "$name" --field private_key 2>&3 | SSH_ASKPASS_REQUIRE=never SSH_AUTH_SOCK="$ACTIVE" ssh-add -t "$life" - 2>&1 >/dev/null; echo "rcs=${PIPESTATUS[0]},${PIPESTATUS[1]}"; } 3>&2)"
  rcs="${out##*rcs=}"
  out="${out%rcs=*}"
  [ "${rcs%,*}" -eq 0 ] || exit "${rcs%,*}"
  if [ "${rcs#*,}" -ne 0 ]; then
    warn "ssh-add did not take $name from OpenBao${out:+: ${out%$'\n'}}; nothing was loaded"
    exit 1
  fi
  pub="$("$dcf_secret" get "$name" --field public_key 2>/dev/null)" || pub=''
  note="$(loaded_note "$name")"
  if [ -n "$pub" ] && (umask 077 && mkdir -p "$LOADED_DIR") 2>/dev/null; then printf '%s\n' "$pub" >"$note" 2>/dev/null || true; fi
  until="$(date -d "+$life seconds" +%H:%M 2>/dev/null || echo "$((life / 60)) minutes from now")"
  case "$WHERE" in
    workstation) say "loaded $name into the workstation's agent until $until ($((life / 60)) minute(s)); it lives in the workstation's agent, not in the container. task ssh-agent:key:lock NAME=$name drops it sooner." ;;
    forwarded) say "loaded $name into the agent this shell forwards ($ACTIVE, the workstation's) until $until ($((life / 60)) minute(s)); task ssh-agent:key:lock NAME=$name drops it sooner." ;;
    *) say "$name is in the container's agent until $until ($((life / 60)) minute(s)), in memory only; task ssh-agent:key:lock NAME=$name drops it sooner." ;;
  esac
}

cmd_bao_lock() { # <name>
  local name="$1" note pub
  bao_name_ok "$name" || exit 1
  note="$(loaded_note "$name")"
  if [ -f "$note" ]; then pub="$(head -n 1 "$note")"
  else
    need_cmd "$dcf_secret" openbao
    pub="$("$dcf_secret" get "$name" --field public_key)" || { warn "which key $name is cannot be told without OpenBao (above); ssh-add -D drops every key"; exit 1; }
  fi
  active_sock
  if printf '%s\n' "$pub" | SSH_AUTH_SOCK="$ACTIVE" ssh-add -d - >/dev/null 2>&1; then say "removed $name from the agent"
  else say "$name was not in the agent (or no agent answers on $ACTIVE)"; fi
  rm -f "$note"
}

bao_fp() { printf '%s\n' "$1" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}'; }

cmd_bao_rotate() { # after parse_rotation_args; A_NAME is ssh/<key> or empty (exactly one record)
  local old new base resume='' scope pub_old pub_new fp_new eff cands count stamp ids id regdir
  need_cmd "$openbao_ssh" openbao
  need_cmd "$dcf_secret" openbao
  if [ -n "$A_NAME" ]; then old="${A_NAME#ssh/}"
  else
    cands="$("$openbao_ssh" list --active)" || exit $?
    count="$(printf '%s\n' "$cands" | grep -c .)"
    [ "$count" -eq 1 ] || { warn "$count active SSH key records in OpenBao; say which with NAME=ssh/<key> (task openbao:ssh:age lists them)"; exit 1; }
    old="${cands#ssh/}"
  fi
  "$openbao_ssh" exists "ssh/$old" || { warn "no record ssh/$old in OpenBao (task openbao:ssh:age lists them)"; exit 1; }
  base="${old%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
  if [ -n "$A_NEW" ]; then new="${A_NEW#ssh/}"; else new="$base-$(today | tr -d -)"; fi
  [ "$new" != "$old" ] || { warn "the new name $new is the old key's own; pass NEW=<another name>"; exit 1; }
  if "$openbao_ssh" exists "ssh/$new"; then
    [ -n "$A_NEW" ] || { warn "ssh/$new already exists (an earlier rotation stopped?). Resume it with task ssh-agent:key:rotate NAME=ssh/$old NEW=ssh/$new, or pick another NEW."; exit 1; }
    resume=1
  fi
  scope="$A_SCOPE"
  if [ -z "$scope" ]; then default_scope; scope="$DEFAULT_SCOPE"; fi
  case "$scope" in global | repo) ;; *) warn "SCOPE is repo or global, not '$scope'"; exit 1 ;; esac
  pub_old="$("$dcf_secret" get "ssh/$old" --field public_key)" || exit $?
  if [ -n "$A_PLAN" ]; then
    say "plan, rotating ssh/$old ($(bao_fp "$pub_old")) into ssh/$new$([ -n "$resume" ] && echo ' (already made, resuming)'):"
    if [ -z "$resume" ]; then say "  1. make the record ssh/$new (task openbao:ssh:new) and load it from OpenBao for the login's time; ssh/$old stays loaded"
    else say "  1. ssh/$new exists: load it from OpenBao; ssh/$old stays loaded"; fi
    say "  2. register it at GitHub as a SIGNING key (the gh Feature's task gh:ssh-key:add, else gh, else print it and STOP)"
    say "  3. point git ($scope scope) at it, add it to $AS_REL (valid after now), and run git:verify; a failure puts git back"
    if is_true "$A_REVOKE"; then say "  4. only then retire ssh/$old (task openbao:ssh:retire: its private key destroyed), mark it valid-before now in $AS_REL, unload it, and remove it from GitHub (REVOKE=1)"
    else say "  4. only then retire ssh/$old (task openbao:ssh:retire: its private key destroyed), mark it valid-before now in $AS_REL, unload it; it stays registered at GitHub (REVOKE=1 would remove it)"; fi
    say "nothing was changed."
    exit 0
  fi

  # step 1: the new record, loaded; the old one stays
  if [ -z "$resume" ]; then
    say "step 1/4: making ssh/$new in OpenBao"
    "$openbao_ssh" new --name "$new" --purpose git-signing >/dev/null || stop_rotation 1 "ssh/$old" "ssh/$new" "openbao:ssh:new failed (above)"
  else say "step 1/4: ssh/$new exists, resuming"; fi
  (cmd_bao_load "ssh/$new") || stop_rotation 1 "ssh/$old" "ssh/$new" "ssh/$new could not be loaded from OpenBao (above)"
  pub_new="$("$dcf_secret" get "ssh/$new" --field public_key)" || stop_rotation 1 "ssh/$old" "ssh/$new" "its public key could not be read"
  fp_new="$(bao_fp "$pub_new")"
  say "step 1/4 done: ssh/$new ($fp_new) is loaded next to ssh/$old"

  # step 2: a signing key at GitHub, through the gh Feature's task when it is there
  if command -v "$gh_key_add" >/dev/null 2>&1; then
    say "step 2/4: registering ssh/$new at GitHub as a signing key (gh:ssh-key:add)"
    printf '%s\n' "$pub_new" | "$gh_key_add" --title "$new" || stop_rotation 2 "ssh/$old" "ssh/$new" "gh:ssh-key:add failed (above)"
  elif gh_ready; then
    if [ -n "$(gh_key_ids_blob "$(awk '{print $2}' <<<"$pub_new")")" ]; then say "step 2/4: ssh/$new is already registered at GitHub"
    else
      say "step 2/4: registering ssh/$new at GitHub as a signing key"
      regdir="$(mktemp -d)" || stop_rotation 2 "ssh/$old" "ssh/$new" "no temporary folder for the public key"
      printf '%s\n' "$pub_new" >"$regdir/$new.pub"
      if ! "$gh_bin" ssh-key add "$regdir/$new.pub" --type signing --title "$new" </dev/null >/dev/null 2>&1; then
        rm -rf "$regdir"
        stop_rotation 2 "ssh/$old" "ssh/$new" "gh ssh-key add failed (does the gh login have the admin:ssh_signing_key scope? gh auth refresh -s admin:ssh_signing_key)"
      fi
      rm -rf "$regdir"
    fi
  elif [ -n "$resume" ]; then
    say "step 2/4: gh is not available here; taking your word that ssh/$new is registered at GitHub as a SIGNING key"
  else
    warn "step 2/4: gh is not installed or not logged in here, so ssh/$new cannot be registered from this container. Register this public key at GitHub (Settings > SSH and GPG keys > New SSH key, key type Signing Key, title $new), a SIGNING key and not an authentication key:"
    printf '%s\n' "$pub_new"
    warn "finish by registering it, then run key:rotate again: task ssh-agent:key:rotate NAME=ssh/$old NEW=ssh/$new. Nothing of ssh/$old was removed; ssh/$new stays loaded until its lifetime ends."
    exit 1
  fi

  # step 3: git signs with it, it is an allowed signer from now, and it is proven
  stamp="$(stamp_now)"
  save_cfg "$scope"
  say "step 3/4: pointing git ($scope scope) at ssh/$new and verifying"
  if ! (AS_CREATE=1 AS_VALID_AFTER="$stamp" cmd_git_signing "$fp_new" "$scope" "${A_AS:-}"); then restore_cfg "$scope"; stop_rotation 3 "ssh/$old" "ssh/$new" "git:signing failed; git's settings are back as they were"; fi
  eff="$(git config --get user.signingkey 2>/dev/null || true)"
  case "$eff" in
    *"$(awk '{print $2}' <<<"$pub_new")"*) ;;
    *) restore_cfg "$scope"; stop_rotation 3 "ssh/$old" "ssh/$new" "another git config level still names a different signing key (see git config --show-origin --get user.signingkey); git's settings are back as they were" ;;
  esac
  if ! (cmd_git_verify); then restore_cfg "$scope"; stop_rotation 3 "ssh/$old" "ssh/$new" "git:verify did not pass; git's settings are back as they were"; fi

  # step 4: only now the old record goes
  say "step 4/4: retiring ssh/$old"
  "$openbao_ssh" retire --name "$old" || stop_rotation 4 "ssh/$old" "ssh/$new" "openbao:ssh:retire failed (git already signs with ssh/$new; task openbao:ssh:retire NAME=ssh/$old finishes it)"
  # The old key signed the history up to now: it gets its line if it had none, then its end.
  if as_path "${A_AS:-}"; then
    as_has "$AS_FILE" "$(awk '{print $2}' <<<"$pub_old")" || as_add "$AS_FILE" "$(as_principal "$(awk '{print $3}' <<<"$pub_old")")" "$(awk '{print $1, $2}' <<<"$pub_old")" || true
    as_retire "$AS_FILE" "$(awk '{print $2}' <<<"$pub_old")" "$stamp" || warn "could not mark ssh/$old in $AS_FILE"
  fi
  if is_true "$A_REVOKE"; then
    if gh_ready; then
      ids="$(gh_key_ids_blob "$(awk '{print $2}' <<<"$pub_old")")"
      if [ -z "$ids" ]; then warn "ssh/$old is not in gh ssh-key list; remove it at GitHub by hand if it is registered"
      else
        for id in $ids; do
          if "$gh_bin" ssh-key delete "$id" --yes </dev/null >/dev/null 2>&1; then say "removed ssh/$old from GitHub (key id $id)"
          else warn "gh ssh-key delete $id failed; remove it at GitHub by hand"; fi
        done
      fi
    else warn "REVOKE needs gh installed and logged in (gh auth login); ssh/$old stays registered at GitHub"; fi
  else
    say "ssh/$old stays registered at GitHub; commits GitHub verified stay verified either way (GitHub keeps a verified commit verified in its repository's network)."
  fi
  active_sock
  printf '%s\n' "$pub_old" | SSH_AUTH_SOCK="$ACTIVE" ssh-add -d - >/dev/null 2>&1 && say "unloaded ssh/$old from the agent"
  rm -f "$(loaded_note "ssh/$old")"
  say "rotated: ssh/$old is retired, git signs with ssh/$new ($fp_new). The host commits $AS_REL."
}

cmd="${1:-setup}"
# Only an explicit command may ask for a passphrase; the start hook (no arguments) never does.
case "$cmd" in
  key-load | key-add | key-new | key-rotate | key-unlock) ask_ok=1 ;;
  setup) [ "${2:-}" = --ask ] && ask_ok=1 ;;
esac
case "$cmd" in
  check) verdict; rc=$?; key_hygiene; [ "$EFF" = socket ] && host_rotation_guidance; exit "$rc" ;;
  keys) cmd_keys; exit 0 ;;
  key-load)
    if [ -n "${2:-}" ]; then
      is_bao_name "$2" || { warn "NAME is an OpenBao name (ssh/<key>, register/<principal>); a key of the key volume is loaded with task ssh-agent:key:unlock NAME=$2 (deprecated) or by key:load with no NAME"; exit 1; }
      cmd_bao_load "$2" "${3:-}"; exit 0
    fi
    deprecated "task ssh-agent:key:load with no NAME" "task ssh-agent:key:load NAME=ssh/<key> [MINUTES=]"
    cmd_key_load; exit 0 ;;
  key-add) deprecated "task ssh-agent:key:add" "task openbao:ssh:import FROM=file FILE=<path>"; cmd_key_add "${2:-}"; exit 0 ;;
  key-stdin) deprecated "task devcontainer:ssh-key-import" "task devcontainer:openbao-ssh-import FILE=<path> on the workstation"; cmd_key_stdin "${2:-}"; exit 0 ;;
  key-new) deprecated "task ssh-agent:key:new" "task openbao:ssh:new"; cmd_key_new "${2:-}" "${3:-}" "${4:-}"; exit 0 ;;
  key-unlock)
    if is_bao_name "${2:-}"; then cmd_bao_load "$2" "${3:-}"; exit 0; fi
    deprecated "task ssh-agent:key:unlock" "task ssh-agent:key:load NAME=ssh/<key> [MINUTES=]"
    cmd_key_unlock "${2:-}" "${3:-}"; exit 0 ;;
  key-lock)
    if is_bao_name "${2:-}"; then cmd_bao_lock "$2"; exit 0; fi
    deprecated "task ssh-agent:key:lock NAME=<file>" "task ssh-agent:key:lock NAME=ssh/<key>"
    cmd_key_lock "${2:-}"; exit 0 ;;
  key-remove)
    is_true "${3:-}" && deprecated "task ssh-agent:key:remove DELETE=1" "task openbao:ssh:retire NAME=ssh/<key>"
    cmd_key_remove "${2:-}" "${3:-}"; exit 0 ;;
  key-rotate)
    parse_rotation_args "${@:2}"
    effective_mode
    if is_bao_name "$A_NAME" || { [ -z "$A_NAME" ] && [ "$EFF" != key ] && command -v "$openbao_ssh" >/dev/null 2>&1; }; then
      cmd_bao_rotate; exit 0
    fi
    deprecated "task ssh-agent:key:rotate on the key volume" "task ssh-agent:key:rotate NAME=ssh/<key>"
    cmd_key_rotate "${@:2}"; exit 0 ;;
  key-retire) deprecated "task ssh-agent:key:retire" "task openbao:ssh:retire NAME=ssh/<key> (or key:rotate NAME=ssh/<key>)"; cmd_key_retire "${@:2}"; exit 0 ;;
  key-age) deprecated "task ssh-agent:key:age" "task openbao:ssh:age"; cmd_key_age; exit 0 ;;
  git-signing) cmd_git_signing "${2:-}" "${3:-}" "${4:-}"; exit 0 ;;
  git-verify) cmd_git_verify; exit 0 ;;
  setup) ;;
  *) warn "unknown command '$cmd' (see the header of $0)"; exit 0 ;;
esac

effective_mode
option_notes
if [ "$mode" = socket ] && [ "$opt_mode" != socket ] && want_key; then
  say "key mode is on, but the launcher mounted a host agent socket, which wins; to use the key mode instead, start the launcher with SSH_AGENT_MODE=key (task devcontainer:up SSH_AGENT_MODE=key), which suppresses that mount."
fi
if [ -z "$mode" ]; then
  say "host unknown: DCF_HOST_SSH_AGENT is empty (the launcher did not run, or the repository's containerEnv does not map it); start through task devcontainer:up. Probing $SSH_SOCK anyway."
fi
case "$EFF" in
  key) do_key_mode ;;
  *) verdict ;;
esac
exit 0
