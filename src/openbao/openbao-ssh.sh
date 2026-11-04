#!/usr/bin/env bash
# openbao-ssh: the SSH key records the openbao Feature keeps (task openbao:ssh:*). A record is a
# KV v2 secret at <DCF_SECRET_MOUNT>/ssh/<name> (mount default dcf) with the fields private_key,
# public_key and purpose, and the custom metadata created (YYYY-MM-DD), source (generated, import,
# ssh-agent, agentic-register) and, once retired, retired. Register keys use register/<principal>.
#
#   openbao-ssh new [--name N] [--comment C] [--purpose P]    make an ed25519 key (no passphrase:
#                                                             the gate is the unseal and the login)
#   openbao-ssh put --name N [--purpose P]                    the private key on stdin
#   openbao-ssh import --from file [--file F|-] [--name N]    one key from a file or stdin
#   openbao-ssh import --from ssh-agent [--dir D]             every key of ssh-agent's key volume
#   openbao-ssh import --from agentic-register [--dir D]      the register's keys/<principal>
#   openbao-ssh retire --name N [--plan]                      destroy the private key's versions,
#                                                             keep the public key and the metadata
#   openbao-ssh age                                           each record: created, age, fingerprint
#   openbao-ssh list [--active]                               the record names, one per line
#   openbao-ssh exists <name>                                 exit 0 when the record exists
#
# What this knows: OpenBao's records, ssh-keygen to make and read keys, and the allowed_signers
# lines an import carries over (ssh-agent's allowed_signers.history). What it does not: loading a
# key into an agent, git and GitHub; those are ssh-agent's and gh's tasks (proposal section 8).
# Reads go through dcf-secret, the collection's interface; the KV v2 calls dcf-secret does not
# have (a create-only record, its metadata, list, destroy) are bao's own. A private key is held in
# memory and handed to bao on stdin; the only files are on tmpfs (a new key from ssh-keygen, a
# copy whose passphrase ssh-keygen -p removes), in a private folder removed on exit. No key is
# ever printed. Exit codes are dcf-secret's (10 unreachable, 11 sealed, 12 no token, 13 denied, 14
# no such record), 1 a step failed, 2 a wrong call, 3 refused (a record exists, no terminal).
set -u

prog=openbao-ssh
ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$ob_dir/env.sh" ] && . "$ob_dir/env.sh"
mount="${DCF_SECRET_MOUNT:-dcf}"
dcf_secret="${DCF_SECRET_BIN:-dcf-secret}"
tmp_base="${OPENBAO_SSH_TMPDIR:-/dev/shm}"
priv=""

say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}
usage() {
  sed -n '7,18p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
cleanup() { [ -z "$priv" ] || rm -rf "$priv"; }
trap cleanup EXIT

command -v bao >/dev/null 2>&1 || die 10 "bao is not installed: add the openbao Feature to the devcontainer"
command -v ssh-keygen >/dev/null 2>&1 || die 1 "ssh-keygen is not installed (openssh-client)"

today() { echo "${DCF_SSH_KEY_TODAY:-$(date +%F)}"; }
epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }
have_tty() { (exec </dev/tty) 2>/dev/null; }
name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# A private folder on tmpfs for the few moments a key has to be a file; removed on exit.
private_dir() {
  [ -z "$priv" ] || return 0
  [ -d "$tmp_base" ] && [ -w "$tmp_base" ] || die 1 "no writable tmpfs at $tmp_base for the moment ssh-keygen needs a file; a key is never written to disk here"
  priv="$(umask 077 && mktemp -d "$tmp_base/openbao-ssh.XXXXXX")" || die 1 "could not make a private folder in $tmp_base"
}

# The server must be ready before anything is generated or read: dcf-secret status prints the
# one-line fix and its exit code is ours.
need_ready() {
  local rc=0
  "$dcf_secret" status >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
}

# After a bao call failed: dcf-secret's diagnosis when it has one, else bao's own words.
bao_failed() { # <what> <bao stderr>
  local rc=0
  "$dcf_secret" status >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  say "bao could not $1:"
  printf '%s\n' "$2" >&2
  exit 1
}

metadata() { bao kv metadata get -mount="$mount" -format=json "$1" 2>/dev/null; }
exists() { metadata "$1" >/dev/null; }
json_str() { # <key> : the first "key": "value" of the JSON on stdin
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}
json_num() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | head -n 1; }

pub_of() { # the private key on stdin (no passphrase) -> its public key line, or nothing
  ssh-keygen -y -P '' -f /dev/stdin 2>/dev/null
}
fp_of_pub() { printf '%s\n' "$1" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}'; }
looks_private() { head -n 1 <<<"$1" | grep -q -- '^-----BEGIN .*PRIVATE KEY-----'; }

# read_key <source>: the private key from stdin (or a file) into KEY, CRs removed, refused if it
# is not one. A key with a passphrase has it removed on a tmpfs copy at ssh-keygen -p's own prompt
# (a terminal is needed); KEY_PUB is its public key line.
read_key() { # <file or -> <label>
  local src="$1" label="$2"
  if [ "$src" = - ]; then KEY="$(tr -d '\r'; printf x)"
  else KEY="$(tr -d '\r' <"$src"; printf x)"; fi
  KEY="${KEY%x}"
  # OpenSSH reads a key only with its final newline, which a shell variable or a paste may lose.
  [ -z "$KEY" ] || [ "${KEY: -1}" = $'\n' ] || KEY="$KEY"$'\n'
  looks_private "$KEY" || { KEY=""; say "$label is not a private key (no -----BEGIN ... PRIVATE KEY----- line)"; return 1; }
  KEY_PUB="$(printf '%s' "$KEY" | pub_of)"
  [ -z "$KEY_PUB" ] || return 0
  # A passphrase (or a key ssh-keygen cannot read): ask at ssh-keygen's prompt on a tmpfs copy.
  if ! have_tty; then
    KEY=""
    say "$label has a passphrase (or ssh-keygen cannot read it) and there is no terminal to ask on; run the import in a terminal in the container, which asks at ssh-keygen's own prompt"
    return 1
  fi
  private_dir
  (umask 077 && printf '%s' "$KEY" >"$priv/key")
  KEY=""
  say "$label has a passphrase: ssh-keygen asks for it below, once, to store the key without one (the gate is OpenBao's unseal and login now)"
  if ! ssh-keygen -q -p -N '' -f "$priv/key" </dev/tty >/dev/tty 2>&1; then
    rm -f "$priv/key"
    say "the passphrase of $label was not accepted; nothing was stored"
    return 1
  fi
  KEY="$(cat "$priv/key"; printf x)"
  KEY="${KEY%x}"
  rm -f "$priv/key"
  KEY_PUB="$(printf '%s' "$KEY" | pub_of)"
  [ -n "$KEY_PUB" ] || { KEY=""; say "ssh-keygen cannot read $label"; return 1; }
}

# store <full name> <purpose> <created> <source>: KEY and KEY_PUB as a new record, create-only
# (-cas=0: a record of that name is never overwritten), the private key on bao's stdin.
store() {
  local full="$1" purpose="$2" created="$3" source="$4" err
  err="$(printf '%s' "$KEY" | bao kv put -cas=0 -mount="$mount" "$full" private_key=- public_key="$KEY_PUB" purpose="$purpose" 2>&1 >/dev/null)" ||
    bao_failed "write $full at $mount" "$err"
  err="$(bao kv metadata patch -mount="$mount" -custom-metadata=created="$created" -custom-metadata=source="$source" "$full" 2>&1 >/dev/null)" ||
    say "warning: $full is stored, but its creation date could not be recorded in its metadata (the KV created_time stands in): $err"
  KEY=""
}

default_key_name() { # <repo>-<container>-sign, [a-z0-9-] only (ssh-agent's own default)
  local top repo host
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  repo="$(basename "${top:-$PWD}")"
  host="$(hostname 2>/dev/null || echo container)"
  printf '%s-%s-sign\n' "$repo" "$host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//'
}

strip_prefix() { # <name> <prefix>: the bare name, with or without the prefix
  local n="$1"
  n="${n#"$2"/}"
  echo "$n"
}

# --------------------------------------------------------------- allowed_signers ----
# .devcontainer/allowed_signers of the repository the task runs in (ALLOWED_SIGNERS overrides it):
# who may sign the history, public keys only, committed by the host (proposal section 8).
as_file() {
  local top
  if [ -n "${ALLOWED_SIGNERS:-}" ]; then echo "$ALLOWED_SIGNERS"; return 0; fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  echo "$top/.devcontainer/allowed_signers"
}
as_header() { # <file>: made with its header when missing
  [ -f "$1" ] && return 0
  mkdir -p "$(dirname "$1")" || return 1
  cat >"$1" <<'EOF'
# Who may sign this repository's commits and tags: one line per SSH signing key, in ssh-keygen's
# ALLOWED SIGNERS format (principal, options, key type, public key), with namespaces="git" and,
# where known, valid-after / valid-before dates (YYYYMMDD). Public keys only, never a private key.
# Written by task openbao:ssh:import, ssh-agent:git:signing and ssh-agent:key:rotate; the host
# commits it. git reads it through gpg.ssh.allowedSignersFile (task ssh-agent:git:signing sets it).
EOF
}
as_has() { # <file> <blob>
  [ -f "$1" ] && awk -v b="$2" '!/^#/ { for (i = 1; i <= NF; i++) if ($i == b) f = 1 } END { exit !f }' "$1"
}
as_add_key() { # <file> <principal> <public key line> <valid-after or empty>
  local opts='namespaces="git"' type blob
  type="$(awk '{print $1}' <<<"$3")"
  blob="$(awk '{print $2}' <<<"$3")"
  [ -n "$blob" ] || return 1
  if as_has "$1" "$blob"; then say "allowed_signers: $2 is already in $1"; return 0; fi
  [ -z "$4" ] || opts="$opts,valid-after=\"${4//-/}\""
  as_header "$1" || return 1
  printf '%s %s %s %s\n' "$2" "$opts" "$type" "$blob" >>"$1"
  say "allowed_signers: added $2 to $1 (the host commits it)"
}
as_add_history() { # <file> <history file>: its lines whose key is not there yet, as they are
  local line blob n=0
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    blob="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i + 1); exit } }' <<<"$line")"
    [ -n "$blob" ] || continue
    as_has "$1" "$blob" && continue
    as_header "$1" || return 1
    printf '%s\n' "$line" >>"$1"
    n=$((n + 1))
  done <"$2"
  say "allowed_signers: $n retired key line(s) of $2 carried into $1"
}

# ------------------------------------------------------------------------ new, put ----
cmd_new() {
  local name="" comment="" purpose=git-signing
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || shift ;;
      --comment) comment="${2:-}"; shift 2 || shift ;;
      --purpose) purpose="${2:-}"; shift 2 || shift ;;
      '') shift ;;
      *) usage ;;
    esac
  done
  [ -n "$name" ] || name="$(default_key_name)"
  name="$(strip_prefix "$name" ssh)"
  name_ok "$name" || die 2 "'$name' is not a key name (letters, digits, . _ -; no slash after ssh/)"
  [ -n "$purpose" ] || purpose=git-signing
  [ -n "$comment" ] || comment="$name"
  need_ready
  exists "ssh/$name" && die 3 "ssh/$name exists at $mount (a name is never reused, also after a retire); pick another NAME"
  private_dir
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$priv/key" </dev/null >/dev/null 2>&1 || die 1 "ssh-keygen failed"
  KEY="$(cat "$priv/key"; printf x)"
  KEY="${KEY%x}"
  KEY_PUB="$(cat "$priv/key.pub")"
  rm -rf "$priv"
  priv=""
  store "ssh/$name" "$purpose" "$(today)" generated
  say "made ssh/$name (ed25519, $(fp_of_pub "$KEY_PUB")), purpose $purpose; the private key is only in OpenBao. Next: task ssh-agent:key:load NAME=ssh/$name, task gh:ssh-key:add KEY=ssh/$name (a SIGNING key at GitHub), task ssh-agent:git:signing. The public key:"
  printf '%s\n' "$KEY_PUB"
}

cmd_put() {
  local name="" purpose=git-signing
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || shift ;;
      --purpose) purpose="${2:-}"; shift 2 || shift ;;
      '') shift ;;
      *) usage ;;
    esac
  done
  name="$(strip_prefix "$name" ssh)"
  name_ok "$name" || die 2 "NAME=<key name> is required ('$name' is not one)"
  [ ! -t 0 ] || die 2 "the private key is read from stdin: pipe it in (never as an argument)"
  need_ready
  exists "ssh/$name" && die 3 "ssh/$name exists at $mount; a record is never overwritten (retire it, or pick another NAME)"
  read_key - "the key on stdin" || exit 1
  store "ssh/$name" "${purpose:-git-signing}" "$(today)" import
  say "stored ssh/$name ($(fp_of_pub "$KEY_PUB"))"
}

# -------------------------------------------------------------------------- import ----
# The ssh-agent and agentic-register imports run one key at a time: a key whose record exists
# with the same fingerprint is skipped as done (an import can be run again), one with another
# fingerprint is refused, and the import goes on with the rest.
IMPORTED=() SKIPPED=0 FAILED=0
import_one() { # <file> <prefix> <name> <purpose> <created> <source>
  local f="$1" full="$2/$3" have fp got
  if exists "$full"; then
    if ! read_key "$f" "$3"; then FAILED=$((FAILED + 1)); return 1; fi
    KEY=""
    have="$("$dcf_secret" get "$full" --field public_key 2>/dev/null)" || have=""
    if [ -n "$have" ] && [ "$(fp_of_pub "$have")" = "$(fp_of_pub "$KEY_PUB")" ]; then
      say "$full is already in OpenBao with the same key; skipped"
      SKIPPED=$((SKIPPED + 1))
      IMPORTED+=("$3")
      return 0
    fi
    say "$full is already in OpenBao with ANOTHER key; $3 was not imported (rename one of them, or retire the record)"
    FAILED=$((FAILED + 1))
    return 1
  fi
  if ! read_key "$f" "$3"; then FAILED=$((FAILED + 1)); return 1; fi
  fp="$(fp_of_pub "$KEY_PUB")"
  store "$full" "$4" "$5" "$6"
  # The proof: what OpenBao hands back is the key that was read.
  got="$("$dcf_secret" get "$full" --field public_key 2>/dev/null)" || got=""
  if [ "$(fp_of_pub "$got")" != "$fp" ]; then
    say "$full was written, but what OpenBao returns does not match $fp; keep the volume's copy and look at it"
    FAILED=$((FAILED + 1))
    return 1
  fi
  say "imported $3 as $full ($fp, created $5)"
  IMPORTED+=("$3")
}

is_private_file() {
  [ -f "$1" ] || return 1
  case "${1##*/}" in *.pub | *.meta | .* | known_hosts* | config | authorized_keys | allowed_signers*) return 1 ;; esac
  head -n 1 "$1" 2>/dev/null | grep -q -- '^-----BEGIN .*PRIVATE KEY-----'
}

meta_of() { # <key file> <field>
  [ -f "$1.meta" ] && sed -n "s/^$2=//p" "$1.meta" | head -n 1
}

# The load and verify proof of the proposal's section 10, through ssh-agent's own commands when
# the Feature is there: the key git signs with (else the first imported) for 5 minutes.
prove_with_agent() { # <prefix> <names...>
  local prefix="$1" pick="" n want pub setup="${OPENBAO_SSH_AGENT_SETUP:-ssh-agent-setup}"
  shift
  [ $# -gt 0 ] || return 0
  if ! command -v "$setup" >/dev/null 2>&1; then
    say "the ssh-agent Feature is not here: load one by hand to prove it (task ssh-agent:key:load NAME=$prefix/$1)"
    return 0
  fi
  want="$(git config --get user.signingkey 2>/dev/null || true)"
  for n in "$@"; do
    pub="$("$dcf_secret" get "$prefix/$n" --field public_key 2>/dev/null)" || continue
    case "$want" in *"$(awk '{print $2}' <<<"$pub")"*) pick="$n"; break ;; esac
  done
  if [ -z "$pick" ]; then
    "$setup" key-load "$prefix/$1" 5 || { say "loading $prefix/$1 through ssh-agent failed (above); the record is stored"; return 0; }
    say "git does not sign with an imported key here, so git:verify is not run; task ssh-agent:git:signing points it at one"
    return 0
  fi
  "$setup" key-load "$prefix/$pick" 5 || { say "loading $prefix/$pick through ssh-agent failed (above); the record is stored"; return 0; }
  "$setup" git-verify || say "git:verify did not pass with $prefix/$pick (above); the record is stored"
}

# Deleting the volume's copy: asked per key on a terminal, never by default.
offer_delete() { # <dir> <remove command> <names...>
  local dir="$1" how="$2" n
  shift 2
  for n in "$@"; do
    if have_tty && [ -z "${OPENBAO_SSH_NO_ASK:-}" ]; then
      printf '%s: delete %s from %s now (it is in OpenBao)? [y/N] ' "$prog" "$n" "$dir" >/dev/tty
      if IFS= read -r REPLY </dev/tty && [[ "$REPLY" =~ ^[Yy] ]]; then
        rm -f "${dir:?}/${n:?}" "${dir:?}/${n:?}.pub" "${dir:?}/${n:?}.meta" && say "deleted $n from $dir"
        continue
      fi
    fi
    say "$dir still holds $n: remove it once you are sure ($how)"
  done
}

cmd_import() {
  local from="" file="" name="" dir="" f n as hist prefix purpose created src
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 || shift ;;
      --file) file="${2:-}"; shift 2 || shift ;;
      --name) name="${2:-}"; shift 2 || shift ;;
      --dir) dir="${2:-}"; shift 2 || shift ;;
      '') shift ;;
      *) usage ;;
    esac
  done
  case "$from" in
    file)
      if [ -z "$file" ] || [ "$file" = - ]; then
        [ ! -t 0 ] || die 2 "FROM=file reads the key from FILE=<path> or from stdin (pipe it in; never an argument)"
        file=-
        [ -n "$name" ] || die 2 "NAME=<key name> is required when the key comes on stdin"
      else
        [ -f "$file" ] || die 2 "FILE=$file is not a file"
        [ -n "$name" ] || name="${file##*/}"
      fi
      name="$(strip_prefix "$name" ssh)"
      name_ok "$name" || die 2 "'$name' is not a key name (letters, digits, . _ -)"
      need_ready
      exists "ssh/$name" && die 3 "ssh/$name exists at $mount; a record is never overwritten (pick another NAME, or retire it)"
      read_key "$file" "$name" || exit 1
      store "ssh/$name" git-signing "$(today)" import
      say "imported $name as ssh/$name ($(fp_of_pub "$("$dcf_secret" get "ssh/$name" --field public_key 2>/dev/null)"))"
      if as="$(as_file)"; then
        as_add_key "$as" "$name" "$("$dcf_secret" get "ssh/$name" --field public_key 2>/dev/null)" "" || say "warning: could not write $as"
      else
        say "not in a git repository: no allowed_signers line written (ALLOWED_SIGNERS=<file> names one)"
      fi
      [ "$file" = - ] || say "the source file $file is left where it is; delete it yourself once you are sure"
      ;;
    ssh-agent | agentic-register)
      if [ "$from" = ssh-agent ]; then
        [ -n "$dir" ] || dir="${DCF_SSH_AGENT_KEY_DIR:-/var/lib/devcontainer-features/ssh-agent-key}"
        prefix=ssh purpose=git-signing
      else
        [ -n "$dir" ] || dir="${AGENTIC_REGISTER_HOME:-/var/lib/devcontainer-features/agentic-register}/keys"
        prefix=register purpose=register
      fi
      [ -d "$dir" ] || die 1 "no key folder at $dir (DIR=<folder> names another)"
      need_ready
      for f in "$dir"/*; do
        is_private_file "$f" || continue
        n="${f##*/}"
        name_ok "$n" || { say "skipping $n: not a usable record name"; FAILED=$((FAILED + 1)); continue; }
        created="$(meta_of "$f" created)"
        [ -n "$created" ] || created="$(date -r "$f" +%F 2>/dev/null || today)"
        src="$(meta_of "$f" source)"
        import_one "$f" "$prefix" "$n" "$purpose" "$created" "$from" || true
        if [ "$from" = ssh-agent ] && [ "${#IMPORTED[@]}" -gt 0 ] && [ "${IMPORTED[${#IMPORTED[@]} - 1]}" = "$n" ]; then
          if as="$(as_file)"; then
            # valid-after only for a key the collection generated: an imported one may have signed
            # before it reached the volume.
            if [ "$src" = generated ]; then as_add_key "$as" "$n" "$("$dcf_secret" get "ssh/$n" --field public_key 2>/dev/null)" "$created" || true
            else as_add_key "$as" "$n" "$("$dcf_secret" get "ssh/$n" --field public_key 2>/dev/null)" "" || true; fi
          fi
        fi
      done
      if [ "$from" = ssh-agent ]; then
        hist="$dir/allowed_signers.history"
        if [ -f "$hist" ]; then
          if as="$(as_file)"; then as_add_history "$as" "$hist" || say "warning: could not write $as"
          else say "not in a git repository: $hist was not carried over (ALLOWED_SIGNERS=<file> names the file)"; fi
        fi
      fi
      say "import from $from: ${#IMPORTED[@]} key(s) in OpenBao ($SKIPPED already there), $FAILED not imported"
      [ "${#IMPORTED[@]}" -gt 0 ] || { [ "$FAILED" -eq 0 ] && say "no private key in $dir"; exit $((FAILED > 0)); }
      if [ "$from" = ssh-agent ]; then
        prove_with_agent ssh "${IMPORTED[@]}"
        offer_delete "$dir" "task ssh-agent:key:remove NAME=<key> DELETE=1" "${IMPORTED[@]}"
        say "from now on: task ssh-agent:key:load NAME=ssh/<key> [MINUTES=] for a sitting; the host commits .devcontainer/allowed_signers"
      else
        offer_delete "$dir" "rm $dir/<principal>" "${IMPORTED[@]}"
        say "the backs read their keys through their own AppRole (task openbao:approle:issue ROLE=<back> POLICY_PATH=$mount/register/<principal>)"
      fi
      [ "$FAILED" -eq 0 ] || exit 1
      ;;
    '') die 2 "FROM=file, ssh-agent or agentic-register is required" ;;
    *) die 2 "FROM is file, ssh-agent or agentic-register, not '$from'" ;;
  esac
}

# -------------------------------------------------------------------- retire, age ----
cmd_retire() {
  local name="" plan="" meta cur pub purpose err versions i
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || shift ;;
      --plan) plan=1; shift ;;
      '') shift ;;
      *) usage ;;
    esac
  done
  name="$(strip_prefix "$name" ssh)"
  name_ok "$name" || die 2 "NAME=<key name> is required ('$name' is not one)"
  need_ready
  meta="$(metadata "ssh/$name")" || die 14 "no record ssh/$name at $mount (task openbao:ssh:age lists them)"
  if [ -n "$(json_str retired <<<"$meta")" ]; then say "ssh/$name was retired on $(json_str retired <<<"$meta")"; exit 0; fi
  cur="$(json_num current_version <<<"$meta")"
  [ -n "$cur" ] || die 1 "could not read the current version of ssh/$name from its metadata"
  pub="$("$dcf_secret" get "ssh/$name" --field public_key)" || exit $?
  purpose="$("$dcf_secret" get "ssh/$name" --field purpose 2>/dev/null)" || purpose=git-signing
  if [ -n "$plan" ]; then
    say "plan, retiring ssh/$name ($(fp_of_pub "$pub")):"
    say "  1. write a version that holds only the public key and the purpose, dated retired $(today)"
    say "  2. destroy versions 1 to $cur, which hold the private key (bao kv destroy; not recoverable)"
    say "  3. keep the metadata, with retired=$(today), so the record and its dates stay listed"
    say "nothing was changed."
    exit 0
  fi
  err="$(bao kv put -cas="$cur" -mount="$mount" "ssh/$name" public_key="$pub" purpose="$purpose" retired="$(today)" 2>&1 >/dev/null)" ||
    bao_failed "write the retired version of ssh/$name" "$err"
  versions=1
  for ((i = 2; i <= cur; i++)); do versions="$versions,$i"; done
  err="$(bao kv destroy -mount="$mount" -versions="$versions" "ssh/$name" 2>&1 >/dev/null)" ||
    bao_failed "destroy the private key's versions of ssh/$name (the retired version is written; run this again)" "$err"
  err="$(bao kv metadata patch -mount="$mount" -custom-metadata=retired="$(today)" "ssh/$name" 2>&1 >/dev/null)" ||
    say "warning: the retirement date could not be recorded in the metadata: $err"
  say "retired ssh/$name: its private key is destroyed; the public key stays readable for verification"
}

record_line() { # <name>: one line for age
  local n="$1" meta created ctime retired pub fp age max
  meta="$(metadata "ssh/$n")" || { say "ssh/$n: no metadata"; return 0; }
  created="$(json_str created <<<"$meta")"
  ctime="$(json_str created_time <<<"$meta")"
  [ -n "$created" ] || created="${ctime%%T*}"
  retired="$(json_str retired <<<"$meta")"
  pub="$("$dcf_secret" get "ssh/$n" --field public_key 2>/dev/null)" || pub=""
  fp="$(fp_of_pub "$pub")"
  age=$((($(epoch_of "$(today)") - $(epoch_of "$created")) / 86400))
  max="${SSH_KEY_MAX_AGE_DAYS:-365}"
  case "$max" in '' | *[!0-9]*) max=365 ;; esac
  if [ -n "$retired" ]; then
    echo "ssh/$n: created $created, retired $retired, ${fp:-no public key}"
  else
    echo "ssh/$n: created $created, $age day(s) old, ${fp:-no public key}"
    [ "$age" -le "$max" ] || say "warning: ssh/$n is older than $max days; rotate it with task ssh-agent:key:rotate NAME=ssh/$n"
  fi
}

list_names() { # the names under ssh/, one per line (folders left out)
  local out
  # No record at all is an empty list, which bao reports with a non-zero exit like a failure:
  # a server that dcf-secret calls ready is taken as having none.
  out="$(bao kv list -mount="$mount" -format=json ssh 2>/dev/null)" || {
    "$dcf_secret" status >/dev/null || exit $?
    return 0
  }
  grep -o '"[^"]*"' <<<"$out" | tr -d '"' | grep -v '/$' || true
}

cmd_age() {
  local n any=0
  need_ready
  for n in $(list_names); do any=1; record_line "$n"; done
  [ "$any" -eq 1 ] || say "no SSH key records at $mount/ssh (task openbao:ssh:new makes one, task openbao:ssh:import brings one in)"
  return 0
}

cmd_list() {
  local n active=""
  [ "${1:-}" = --active ] && active=1
  need_ready
  for n in $(list_names); do
    if [ -n "$active" ] && [ -n "$(metadata "ssh/$n" | json_str retired)" ]; then continue; fi
    echo "ssh/$n"
  done
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  new) cmd_new "$@" ;;
  put) cmd_put "$@" ;;
  import) cmd_import "$@" ;;
  retire) cmd_retire "$@" ;;
  age) cmd_age ;;
  list) cmd_list "$@" ;;
  exists)
    [ $# -eq 1 ] || usage
    exists "$1"
    ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
