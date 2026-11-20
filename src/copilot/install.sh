#!/usr/bin/env bash
# Adds what the official GitHub Copilot CLI Feature lacks and makes the CLI a member of this
# collection's ecosystem: agent-adapter-copilot (the participant component's adapter for the
# Copilot CLI), the participants option (the participant component, one shared copy), the attach
# option (the facilitator's MCP entry, registered at post-create through `copilot mcp add`), the
# dcf-persist helper and the post-create setup of COPILOT_HOME (copilot-setup), and the Feature
# Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): PARTICIPANTS, ATTACH, INSTALLTASKFILE.
#
# The copilot binary itself comes from the dependsOn on ghcr.io/devcontainers/features/copilot-cli
# (NFR-4, ruled by the Operator 2026-11-20): this Feature installs no binary and downloads nothing.
# A missing copilot (a tool that ignores dependsOn) is a loud warning rather than a failure;
# copilot-setup reports the absence again at post-create.
#
# Never writes into COPILOT_HOME: the volume is not mounted at image build; copilot-setup makes it
# usable at post-create.
set -euo pipefail

PARTICIPANTS="${PARTICIPANTS:-false}"
ATTACH="${ATTACH:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "copilot: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

case "$ATTACH" in
  '' | facilitator) ;;
  *)
    echo "copilot: invalid attach option '$ATTACH' ('facilitator', or empty for none; other values are reserved)" >&2
    exit 1
    ;;
esac
case "$PARTICIPANTS" in
  true | false) ;;
  *)
    echo "copilot: invalid participants option '$PARTICIPANTS' (true or false)" >&2
    exit 1
    ;;
esac

# copilot from the official Feature (or the base image): on PATH, or where the official Feature puts
# it (/usr/local/bin) when PATH is minimal at build time.
bin="$(command -v copilot 2>/dev/null || true)"
[ -n "$bin" ] || { [ -x /usr/local/bin/copilot ] && bin=/usr/local/bin/copilot; } || true
if [ -n "$bin" ]; then
  # The official Feature unpacks the release archive as root, and tar keeps the archive's owner
  # (the publisher's CI user, uid 1001): a user with that uid in the image could replace the
  # binary. A copilot in /usr/local/bin that root does not own is handed to root (found while
  # building this Feature; nothing else of the official install is touched).
  owner="$(stat -c %u "$bin" 2>/dev/null || echo 0)"
  if [ "$bin" = /usr/local/bin/copilot ] && [ -f "$bin" ] && [ ! -L "$bin" ] && [ "$owner" != 0 ]; then
    chown root:root "$bin" && echo "copilot: $bin was owned by uid $owner (from the release archive); now root's"
  fi
  # --version writes nothing into COPILOT_HOME here: a throwaway home, so nothing lands in the image.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT
  chmod 0700 "$tmp"
  echo "copilot: $(COPILOT_HOME="$tmp" "$bin" --version 2>/dev/null | head -n 1 || echo '(version unknown)') at $bin"
else
  echo "copilot: WARNING - copilot not found; this Feature's dependsOn on ghcr.io/devcontainers/features/copilot-cli:1 should have installed it (check the build log for that Feature). The adapter, copilot-setup, dcf-persist and the Taskfile are installed anyway." >&2
fi

# ------------------------------------------------------- ecosystem pieces ----
# dcf-persist makes the state directory usable (verbatim copy of src/common/dcf-persist.sh);
# copilot-setup is this Feature's postCreateCommand (see devcontainer-feature.json) and reads the
# options from options.env, so the hook and `task copilot:setup` behave the same.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/copilot-feature
mkdir -p "$share"
{
  echo "# Written by the copilot Feature's install.sh from its options; sourced by copilot-setup."
  printf 'ATTACH=%q\n' "$ATTACH"
  printf 'PARTICIPANTS=%q\n' "$PARTICIPANTS"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/copilot-setup.sh" /usr/local/bin/copilot-setup
install -m 0755 "$feature_dir/agent-adapter-copilot.sh" /usr/local/bin/agent-adapter-copilot
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# ---------------------------------------------------------- participants ----
# The participants option installs the participant component (the agents command, the agents:
# tasks; components/participant, vendored in participant/) into /usr/local/lib/dcf-participant,
# once: when claude-code, the deprecated agents Feature or another Feature put the same or a newer
# copy there, nothing is copied. Copilot has no resident agents, so no post-start hook is needed.
if [ "$PARTICIPANTS" = "true" ]; then
  bash "$feature_dir/participant/install-participant.sh" --by copilot --taskfile "${INSTALLTASKFILE:-true}"
fi

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes_d/copilot.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
