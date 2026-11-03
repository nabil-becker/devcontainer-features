#!/bin/sh
# openbao-run <command> [args...]: run a command (a bao call of the Feature's Taskfile) with this
# Feature's environment defaults applied: in server mode, BAO_ADDR is the local listener when
# nothing sets it (env.sh). Nothing else changes; in client mode it is exec "$@".
dir="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}"
# shellcheck disable=SC1091  # installed by install.sh
[ -f "$dir/env.sh" ] && . "$dir/env.sh"
[ $# -ge 1 ] || { echo "usage: openbao-run <command> [args...]" >&2; exit 2; }
exec "$@"
