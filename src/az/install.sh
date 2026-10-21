#!/usr/bin/env bash
# Augments the Azure CLI (https://learn.microsoft.com/cli/azure) that
# ghcr.io/devcontainers/features/azure-cli installs from Microsoft's apt
# repository (a dependsOn of this Feature, so it is always there), with the pieces that make it part of this collection's
# ecosystem: the dcf-persist helper, the post-create setup of
# AZURE_CONFIG_DIR and the bicep setting (az-setup), and the Feature
# Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): BICEPFROMPATH.
#
# az itself comes from the dependsOn: Microsoft publishes it through its apt
# repository (signed packages), which is what the official Feature uses, and
# there is no better verified source to re-implement. A missing az (a
# tool that ignores dependsOn) is a loud warning rather than a failure;
# az-setup reports the absence again at post-create.
#
# Never writes into AZURE_CONFIG_DIR: the volume is not mounted at image
# build; az-setup makes it usable at post-create.
set -euo pipefail

BICEPFROMPATH="${BICEPFROMPATH:-true}"

if [ "$(id -u)" -ne 0 ]; then
  echo "az: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

# az from an earlier Feature or the base image: on PATH, or where the
# official Feature's apt package puts it when PATH is minimal at build time.
az_bin="$(command -v az 2>/dev/null || true)"
[ -n "$az_bin" ] || { [ -x /usr/bin/az ] && az_bin=/usr/bin/az; } || true
if [ -n "$az_bin" ]; then
  # Report the version from a throwaway config dir: az writes logs and a
  # command index into AZURE_CONFIG_DIR on every run, and that must not land
  # in the image under root (it would be copied into the fresh volume).
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "az: $(AZURE_CONFIG_DIR="$tmp" "$az_bin" version -o tsv --only-show-errors 2>/dev/null | cut -f1 || echo '(version unknown)') at $az_bin"
else
  echo "az: WARNING - az not found; this Feature's dependsOn on ghcr.io/devcontainers/features/azure-cli:1 should have installed it (check the build log for that Feature). The az-setup hook, dcf-persist and the Taskfile are installed anyway." >&2
fi

# ------------------------------------------------------- ecosystem pieces ----
# dcf-persist makes the state directory usable (verbatim copy of
# src/common/dcf-persist.sh); az-setup is this Feature's postCreateCommand
# (see devcontainer-feature.json) and reads its option defaults from
# options.env, so the hook and `task az:setup` behave the same.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/az-feature
mkdir -p "$share"
{
  echo "# Written by the az Feature's install.sh from its options; sourced by az-setup."
  printf 'BICEPFROMPATH=%q\n' "$BICEPFROMPATH"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/az-setup.sh" /usr/local/bin/az-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/az.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
