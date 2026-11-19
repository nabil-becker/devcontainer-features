#!/usr/bin/env bash
# Installs the agents Feature, deprecated since 2.2.0 in favour of the claude-code Feature's
# participants option (ADR-0061). Its code is the participant component (components/participant,
# vendored here in participant/ by `task components:sync`): the `agents` command (the agent list,
# the kinds, the verbs and the fallbacks; also the postStartCommand `agents up --post-start`) and
# the Feature Taskfile (agents: namespace). The component installs once, into
# /usr/local/lib/dcf-participant: when claude-code (participants: true) or another Feature put the
# same or a newer copy there, this Feature installs nothing of it; otherwise it installs it as up to
# 2.1.3 (the same command, tasks, state folders and paths). Nothing is downloaded, so there is
# nothing to verify. No adapter is installed here: each CLI Feature brings its own
# (agent-adapter-<cli>; the claude-code Feature has agent-adapter-claude).
#
# What stays this Feature's own, in /usr/local/share/agents-feature: its version (shown by
# `task agents:version`, which with this file present also prints the one deprecation line, as
# `task agents:check` does) and its sessionName option.
#
# State: none that must survive a rebuild. The agents live in each CLI's own state (claude-code's
# volume). /var/lib/devcontainer-features/agents holds the once-per-container-start markers used
# when an adapter cannot list its sessions, and leases/ (2.0), one folder per stateful agent that
# runs. It is deliberately not a volume (NFR-1 exception, NOTES "State"): a lease that survived a
# rebuild would be stale by definition, and markers and leases both record the container start,
# so a stale one never counts.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "agents: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n 1)"

# The component: the agents command, the state folders and (installTaskfile) the Taskfile, once.
bash "$feature_dir/participant/install-participant.sh" --by agents --taskfile "${INSTALLTASKFILE:-true}"

mkdir -p /usr/local/share/agents-feature
printf '%s\n' "${version:-unknown}" > /usr/local/share/agents-feature/version
chmod 0644 /usr/local/share/agents-feature/version
# The sessionName option (2.1): the template of the session names, read by `agents` when no
# AGENTS_SESSION_NAME, .env or task variable says otherwise.
session_name="${SESSIONNAME:-}"
[ -n "$session_name" ] || session_name='{handle}'
printf '%s\n' "$session_name" > /usr/local/share/agents-feature/session-name
chmod 0644 /usr/local/share/agents-feature/session-name
echo "agents: installed agents ${version:-unknown} (deprecated: use claude-code participants: true)"
