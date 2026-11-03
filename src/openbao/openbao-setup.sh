#!/usr/bin/env bash
# openbao-setup: the openbao Feature's postCreateCommand, run as the remote user from the
# workspace folder after every create/rebuild; also behind `task openbao:setup`. Idempotent, never
# fatal: a problem is reported, not allowed to abort the rest of post-create.
#
# 1. dcf-persist makes OPENBAO_STATE_DIR (the Feature's named volume, or a bind mount a repo put on
#    the same target) exist and belong to the remote user.
# 2. bao keeps its token there through the token helper the Feature configures (BAO_CONFIG_PATH in
#    containerEnv, set for every process): the login survives a rebuild. A token already in
#    ~/.vault-token (a login from before this Feature, or from a process without the variable) is
#    moved into the state dir once, when the state dir has none and the helper is in effect.
# 3. Says which mode it runs in and what is known without asking the server: the address, whether
#    the token helper is in effect, whether a login is saved. It never contacts the server (an
#    unreachable one must not hold post-create).
set -u

# Defaults baked by install.sh from the Feature options. OPENBAO_SETUP_* in the environment
# (containerEnv) override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/openbao-feature/options.env ] && source /usr/local/share/openbao-feature/options.env
mode="${OPENBAO_SETUP_MODE-${MODE:-client}}"
dir="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
old="$HOME/.vault-token"
target="$dir/token"
feature_config=/usr/local/share/openbao-feature/bao-config.hcl

dcf-persist --label openbao "$dir"

case "$mode" in
  client) echo "openbao: mode client (the bao CLI and dcf-secret; BAO_ADDR names the server)" ;;
  *) echo "openbao: mode '$mode' is not available in this version (client only); running as client" >&2 ;;
esac

# Only with the token helper in effect is a token moved: otherwise bao still reads ~/.vault-token.
helper=0
[ "${BAO_CONFIG_PATH:-}" = "$feature_config" ] && helper=1

if [ ! -w "$dir" ]; then
  echo "openbao: $dir is not writable, so the login cannot be kept in it and will not survive a rebuild" >&2
elif [ "$helper" -eq 1 ] && [ -f "$old" ] && [ ! -L "$old" ]; then
  if [ -e "$target" ]; then
    echo "openbao: $old is left where it is: the state dir already has a login, and bao uses that one"
  elif (umask 077; mv "$old" "$target") 2>/dev/null; then
    chmod 0600 "$target" 2>/dev/null || true
    echo "openbao: login token moved from $old into the state dir (once)"
  else
    echo "openbao: could not move $old into $dir; that login will not survive a rebuild" >&2
  fi
fi

if [ "$helper" -eq 1 ]; then
  echo "openbao: token helper in effect (BAO_CONFIG_PATH), the login is kept in $dir"
elif [ -z "${BAO_CONFIG_PATH:-}" ]; then
  echo "openbao: BAO_CONFIG_PATH is not set, so bao keeps its token in ~/.vault-token and a rebuild logs you out; this Feature sets it in containerEnv (a repo's own containerEnv may have removed it)" >&2
else
  echo "openbao: BAO_CONFIG_PATH is $BAO_CONFIG_PATH, not this Feature's $feature_config; put token_helper = \"/usr/local/bin/openbao-token-helper\" in that file to keep the login in $dir" >&2
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
