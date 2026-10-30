#!/usr/bin/env bash
# Installs the pieces that let a devcontainer sign and authenticate with an SSH
# agent: the OpenSSH client tools if the image lacks them (ssh-add, ssh-keygen,
# ssh-agent), the fixed socket folder, ssh-agent-setup (the postStartCommand)
# and the Feature Taskfile. Feature options arrive as upper-cased environment
# variables (see devcontainer-feature.json): KEYMODE, PASSPHRASETIMEOUT.
#
# Nothing is downloaded outside the distribution's own package manager
# (openssh-client from apt, only when missing), so there is nothing to verify
# here beyond what apt already checks.
#
# The agent socket's folder is created here and NOT declared as a volume: the
# launcher bind-mounts the host's agent socket onto
# /var/lib/devcontainer-features/ssh-agent/agent.sock, which a volume over the
# folder would hide. The opt-in key mode keeps its key in a separate volume
# (ssh-agent-key, see devcontainer-feature.json), which install.sh must not
# write into: it is not mounted at image build.
set -euo pipefail

KEYMODE="${KEYMODE:-false}"
PASSPHRASETIMEOUT="${PASSPHRASETIMEOUT:-120}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ssh-agent: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

if ! command -v ssh-add >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v ssh-agent >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends openssh-client
    rm -rf /var/lib/apt/lists/*
  else
    echo "ssh-agent: ssh-add/ssh-keygen/ssh-agent are missing and apt-get is unavailable; add an OpenSSH client to the image." >&2
    exit 1
  fi
fi

# World-writable with the sticky bit: the remote user (any uid) can start an
# in-container agent here in key mode; a bind-mounted socket lands on this path too.
mkdir -p /var/lib/devcontainer-features/ssh-agent
chmod 1777 /var/lib/devcontainer-features/ssh-agent

# ------------------------------------------------------- ecosystem pieces ----
# dcf-persist makes the key volume usable (verbatim copy of
# src/common/dcf-persist.sh); ssh-agent-setup is the postStartCommand and reads
# its option default from options.env, so the hook and `task ssh-agent:setup` agree.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/ssh-agent-feature
mkdir -p "$share"
{
  echo "# Written by the ssh-agent Feature's install.sh from its options; sourced by ssh-agent-setup."
  printf 'KEYMODE=%q\n' "$KEYMODE"
  printf 'PASSPHRASETIMEOUT=%q\n' "$PASSPHRASETIMEOUT"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/ssh-agent-setup.sh" /usr/local/bin/ssh-agent-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

ssh -V 2>&1 | head -n 1 || true

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/ssh-agent.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
