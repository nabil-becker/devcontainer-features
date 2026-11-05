# shellcheck shell=sh
# openbao-feature/env.sh: sourced (never run) by dcf-secret, openbao-setup, openbao-server and
# openbao-run, so they agree on two things: which mode this container is in, and the server
# address. POSIX sh only, because the Taskfile's shell and dash source it too.
#
# The mode is the Feature option, baked into options.env by install.sh, unless OPENBAO_SETUP_MODE
# in the environment (containerEnv) overrides it. In server mode BAO_ADDR defaults to the local
# listener when nothing sets it; a Feature cannot set BAO_ADDR in containerEnv by option (its
# metadata is static, and client mode must keep the CLI's own default), so every command of this
# Feature applies the default itself. A bare `bao` does not: set BAO_ADDR for it.
_ob_dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"

openbao_mode() {
  (
    MODE=client
    # shellcheck disable=SC1091  # written by install.sh at image build
    [ -f "$_ob_dir/options.env" ] && . "$_ob_dir/options.env"
    printf '%s' "${OPENBAO_SETUP_MODE-${MODE:-client}}"
  )
}

# How a server-mode store is opened (the unlock option): operator (the default: typed shares and a
# password) or keyfile (the OpenBao key file the workstation's launcher sends). OPENBAO_SETUP_UNLOCK
# overrides the option; an unknown value reads as operator.
openbao_unlock() {
  (
    UNLOCK=operator
    # shellcheck disable=SC1091  # written by install.sh at image build
    [ -f "$_ob_dir/options.env" ] && . "$_ob_dir/options.env"
    _u="${OPENBAO_SETUP_UNLOCK:-${UNLOCK:-operator}}"
    [ "$_u" = keyfile ] || _u=operator
    printf '%s' "$_u"
  )
}

if [ -z "${BAO_ADDR:-}" ] && [ "$(openbao_mode)" = server ]; then
  BAO_ADDR=http://127.0.0.1:8200
  export BAO_ADDR
  OPENBAO_ADDR_DEFAULTED=1
  export OPENBAO_ADDR_DEFAULTED
fi
