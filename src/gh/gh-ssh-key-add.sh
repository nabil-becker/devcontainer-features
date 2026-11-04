#!/usr/bin/env bash
# gh-ssh-key-add: register a public key at GitHub as a SIGNING key (task gh:ssh-key:add), the
# GitHub step of a signing key's life (ssh-agent's key:rotate calls it; proposal section 8).
#
#   gh-ssh-key-add [--file <.pub>] [--key <OpenBao name>] [--title <title>]
#
# The public key comes from --file, from OpenBao with --key ssh/<name> (the openbao Feature's
# dcf-secret, field public_key), or from stdin. Only a public key is ever read; a private key is
# refused. A key already registered as a signing key is left as it is (exit 0). A signing key can
# only sign: it logs in to nothing if it leaks, which is why the type is fixed. The gh login needs
# the admin:ssh_signing_key scope (gh auth refresh -s admin:ssh_signing_key). Exit 0 registered
# or already there, 1 gh failed or is not logged in, 2 a wrong call, and dcf-secret's own codes
# when OpenBao says no. Test hook: DCF_GH names the gh binary.
set -u

prog=gh-ssh-key-add
gh_bin="${DCF_GH:-gh}"
dcf_secret="${DCF_SECRET_BIN:-dcf-secret}"

say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}

file="" key="" title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file) file="${2:-}"; shift 2 || shift ;;
    --key) key="${2:-}"; shift 2 || shift ;;
    --title) title="${2:-}"; shift 2 || shift ;;
    '') shift ;;
    *) die 2 "usage: gh-ssh-key-add [--file <.pub>] [--key ssh/<name>] [--title <title>] (or the public key on stdin)" ;;
  esac
done
[ -z "$file" ] || [ -z "$key" ] || die 2 "FILE and KEY name the key twice; give one"

if [ -n "$file" ]; then
  [ -f "$file" ] || die 2 "FILE=$file is not a file"
  pub="$(head -n 1 "$file")"
elif [ -n "$key" ]; then
  command -v "$dcf_secret" >/dev/null 2>&1 || die 1 "dcf-secret is not installed: add the openbao Feature to read KEY=$key from OpenBao, or give FILE=<.pub>"
  pub="$("$dcf_secret" get "$key" --field public_key)" || exit $?
  [ -n "$title" ] || title="${key##*/}"
else
  [ ! -t 0 ] || die 2 "give FILE=<.pub>, KEY=ssh/<name>, or the public key on stdin"
  pub="$(head -n 1)"
fi
case "$pub" in
  *PRIVATE\ KEY*) die 2 "that is a private key; only a public key is registered (the .pub, or KEY=ssh/<name>)" ;;
  ssh-* | ecdsa-* | sk-*) ;;
  *) die 2 "that does not look like a public key (ssh-ed25519 AAAA... expected)" ;;
esac
blob="$(awk '{print $2}' <<<"$pub")"
[ -n "$title" ] || title="$(awk '{print $3}' <<<"$pub")"
[ -n "$title" ] || title="signing key"

command -v "$gh_bin" >/dev/null 2>&1 || die 1 "gh is not installed (the gh Feature): register the key by hand at GitHub, Settings > SSH and GPG keys > New SSH key, key type Signing Key"
"$gh_bin" auth status </dev/null >/dev/null 2>&1 || die 1 "gh is not logged in: task gh:login, then gh auth refresh -s admin:ssh_signing_key"

# Already a signing key? The list's lines carry the key and its type (authentication or signing).
if "$gh_bin" ssh-key list </dev/null 2>/dev/null | awk -v b="$blob" 'index($0, b) && /signing/ { f = 1 } END { exit !f }'; then
  say "the key is already registered at GitHub as a signing key; nothing to do"
  exit 0
fi

# gh reads the key from a file: a public key, in a private temporary folder removed on exit.
tmp="$(umask 077 && mktemp -d)" || die 1 "no temporary folder"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$pub" >"$tmp/key.pub"
if ! err="$("$gh_bin" ssh-key add "$tmp/key.pub" --type signing --title "$title" </dev/null 2>&1 >/dev/null)"; then
  say "gh ssh-key add failed: ${err##*$'\n'}"
  die 1 "does the gh login have the admin:ssh_signing_key scope? gh auth refresh -s admin:ssh_signing_key"
fi
say "registered '$title' at GitHub as a SIGNING key ($(printf '%s\n' "$pub" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}'))"
