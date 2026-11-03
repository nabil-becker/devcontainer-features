#!/usr/bin/env bash
# openbao-setup: the openbao Feature's postCreateCommand, run as the remote user from the
# workspace folder after every create/rebuild; also behind `task openbao:setup`. Idempotent, never
# fatal: a problem is reported, not allowed to abort the rest of post-create.
#
# 1. dcf-persist makes OPENBAO_STATE_DIR (the Feature's named volume, or a bind mount a repo put on
#    the same target) exist and belong to the remote user.
# 2. ~/.vault-token, where `bao login` keeps its token, is made a link to <state dir>/token, so
#    the login survives a rebuild. A real file there (a login made after `bao token revoke -self`
#    removed the link, which is newer than the volume's copy) is moved into the volume first.
# 3. Says which mode it runs in and what is known without asking the server: the address, whether
#    a login is saved. It never contacts the server (an unreachable one must not hold post-create).
set -u

# Defaults baked by install.sh from the Feature options. OPENBAO_SETUP_* in the environment
# (containerEnv) override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/openbao-feature/options.env ] && source /usr/local/share/openbao-feature/options.env
mode="${OPENBAO_SETUP_MODE-${MODE:-client}}"
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
link="$HOME/.vault-token"
target="$dir/token"

dcf-persist --label openbao "$dir"

case "$mode" in
  client) echo "openbao: mode client (the bao CLI and dcf-secret; BAO_ADDR names the server)" ;;
  *) echo "openbao: mode '$mode' is not available in this version (client only); running as client" >&2 ;;
esac

if [ ! -w "$dir" ]; then
  echo "openbao: $dir is not writable, so the login is not linked into it and will not survive a rebuild" >&2
elif [ -L "$link" ]; then
  if [ "$(readlink "$link")" = "$target" ]; then
    echo "openbao: login token linked into the state dir ($link, kept)"
  else
    echo "openbao: $link is a link to $(readlink "$link"), left alone; the login will not survive a rebuild" >&2
  fi
elif [ -e "$link" ]; then
  if [ -f "$link" ] && mv -f "$link" "$target" 2>/dev/null && ln -s "$target" "$link" 2>/dev/null; then
    chmod 0600 "$target" 2>/dev/null || true
    echo "openbao: login token moved into the state dir and linked ($link)"
  else
    echo "openbao: could not move $link into $dir; the login will not survive a rebuild" >&2
  fi
elif ln -s "$target" "$link" 2>/dev/null; then
  echo "openbao: login token linked into the state dir ($link)"
else
  echo "openbao: could not link $link to $target (is \$HOME writable?)" >&2
fi

if ! command -v bao >/dev/null 2>&1; then
  echo "openbao: bao not found on PATH; rebuild the container and check the build log for this Feature" >&2
  exit 0
fi
echo "openbao: $(bao version 2>/dev/null | head -n 1) at $(command -v bao)"
echo "openbao: BAO_ADDR ${BAO_ADDR:-is not set (bao falls back to https://127.0.0.1:8200); put it in containerEnv}"
if [ -n "${BAO_TOKEN:-}" ]; then
  echo "openbao: BAO_TOKEN is set in the environment and takes precedence over the saved login"
elif [ -s "$target" ]; then
  echo "openbao: a login is saved in $dir (it may have expired; dcf-secret status checks it)"
else
  echo "openbao: no login yet; run 'bao login' (or task openbao:login) once, it persists in $dir"
fi
exit 0
