#!/usr/bin/env bash
# copilot-setup: the copilot Feature's postCreateCommand, run as the remote user from the
# workspace folder after every create/rebuild; also behind `task copilot:setup`. Idempotent,
# never fatal: a problem is reported, not allowed to abort the rest of post-create.
#
# 1. dcf-persist makes COPILOT_HOME (the Feature's named volume, or a bind mount a repo put on the
#    same target) exist and belong to the remote user, so a `copilot login` keeps across rebuilds.
#    Copilot refuses a home that is writable by group or other ("The storage directory is writable
#    by group or other users"), so the folder is made owner-only here (chmod go-w on the top level
#    only; the CLI keeps its own files private).
# 2. With attach=facilitator, registers the facilitator's MCP entry through Copilot's own command
#    (agent-adapter-copilot mcp-attach). That needs no login.
# 3. Reports the copilot version and where its login comes from, never the token. The Feature never
#    logs in and never stores a token (NFR-13): `copilot login`, or COPILOT_GITHUB_TOKEN, GH_TOKEN
#    or GITHUB_TOKEN in the environment.
#
# `copilot-setup attach` runs step 2 alone (task copilot:attach), whatever the option says.
set -u

# Defaults baked by install.sh from the Feature options. COPILOT_SETUP_ATTACH in the environment
# (containerEnv) overrides the option without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/copilot-feature/options.env ] && source /usr/local/share/copilot-feature/options.env
attach="${COPILOT_SETUP_ATTACH-${ATTACH:-}}"
dir="${COPILOT_HOME:-$HOME/.copilot}"

attach_now() {
  command -v agent-adapter-copilot >/dev/null 2>&1 || { echo "copilot: agent-adapter-copilot is missing; rebuild" >&2; return 0; }
  agent-adapter-copilot mcp-attach facilitator || echo "copilot: the facilitator entry was not registered (see above); task copilot:attach tries again"
}

if [ "${1:-}" = attach ]; then
  dcf-persist --label copilot "$dir" >/dev/null
  chmod go-w "$dir" 2>/dev/null || true
  attach_now
  exit 0
fi

dcf-persist --label copilot "$dir"
chmod go-w "$dir" 2>/dev/null || true

if ! command -v copilot >/dev/null 2>&1; then
  echo "copilot: not found on PATH; the copilot Feature gets it through its dependsOn on ghcr.io/devcontainers/features/copilot-cli:1 - rebuild the container and check the build log for that Feature" >&2
  exit 0
fi

echo "copilot: $(copilot --version 2>/dev/null | head -n 1 || echo '(version unknown)')"
if [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then echo "copilot: login from COPILOT_GITHUB_TOKEN in the environment"
elif [ -n "${GH_TOKEN:-}" ]; then echo "copilot: login from GH_TOKEN in the environment (a fine-grained token with the Copilot Requests permission)"
elif [ -n "${GITHUB_TOKEN:-}" ]; then echo "copilot: login from GITHUB_TOKEN in the environment (a fine-grained token with the Copilot Requests permission)"
else echo "copilot: no token in the environment; run copilot login once (it persists in $dir) or set COPILOT_GITHUB_TOKEN"
fi

case "$attach" in
  '') ;;
  facilitator) attach_now ;;
  *) echo "copilot: attach='$attach' is not known; nothing registered" >&2 ;;
esac
exit 0
