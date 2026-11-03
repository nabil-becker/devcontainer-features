#!/bin/sh
# openbao-token-helper: the token helper the openbao Feature gives `bao` (config `token_helper`,
# found through BAO_CONFIG_PATH, both set by the Feature). bao calls it with one argument:
#   get    print the stored token (nothing, exit 0, when there is none)
#   store  keep the token read from stdin
#   erase  forget the token (bao token revoke -self, bao logout)
# The token lives at $OPENBAO_STATE_DIR/token, mode 0600, in the Feature's volume, so a rebuild
# keeps the login. The internal helper bao uses otherwise writes ~/.vault-token by a rename, which
# no link can follow; this is the CLI's own way to keep the token elsewhere. It prints no token
# except on `get`, and writes the file atomically (a temp file in the same folder, then a rename).
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
file="$dir/token"

case "${1:-}" in
  get)
    [ -f "$file" ] || exit 0
    cat "$file"
    ;;
  store)
    umask 077
    mkdir -p "$dir" || exit 1
    tmp="$file.tmp.$$"
    cat > "$tmp" || { rm -f "$tmp"; exit 1; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; exit 1; }
    ;;
  erase)
    rm -f "$file" || exit 1
    ;;
  *)
    echo "usage: openbao-token-helper get|store|erase (it is called by bao, see token_helper)" >&2
    exit 2
    ;;
esac
