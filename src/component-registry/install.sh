#!/usr/bin/env bash
# Installs the component-registry Feature: the dcf-registry command (resolve, explain, handover,
# refresh, remember), the two registry sources this release ships (registry-source-git,
# registry-source-path), the built-in base layer with the utility skills, the postStartCommand
# component-registry-setup, the dcf-persist helper and the Feature Taskfile.
# Feature options arrive as upper-cased environment variables (see devcontainer-feature.json):
# REGISTRYFILE, INSTALLTASKFILE.
#
# Nothing is downloaded, so there is nothing to verify: the scripts are bash, awk and sed (NFR-7);
# the git source needs git, which this Feature does not install (the git Feature or the image
# brings it; without it a git source fails with a plain line and the other layers still resolve).
#
# Never writes into /var/lib/devcontainer-features/component-registry: the volume is not mounted
# at image build; component-registry-setup makes it usable, owner-only, at start.
set -euo pipefail

REGISTRYFILE="${REGISTRYFILE:-.devcontainer/registry.yml}"

if [ "$(id -u)" -ne 0 ]; then
  echo "component-registry: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n 1)"

case "$REGISTRYFILE" in
  '' | *$'\n'*) echo "component-registry: registryFile must be one path" >&2; exit 1 ;;
esac

share=/usr/local/share/component-registry-feature
mkdir -p "$share"
printf '%s\n' "${version:-unknown}" > "$share/version"
{
  echo "# Written by the component-registry Feature's install.sh from its options; read by dcf-registry."
  printf 'REGISTRYFILE=%q\n' "$REGISTRYFILE"
} > "$share/options.env"
chmod 0644 "$share/version" "$share/options.env"

install -m 0755 "$feature_dir/dcf-registry.sh" /usr/local/bin/dcf-registry
install -m 0755 "$feature_dir/registry-source-git.sh" /usr/local/bin/registry-source-git
install -m 0755 "$feature_dir/registry-source-path.sh" /usr/local/bin/registry-source-path
install -m 0755 "$feature_dir/component-registry-setup.sh" /usr/local/bin/component-registry-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# The built-in base layer (1.1.0): the utility skills /registry-refresh, /registry-explain and
# /registry-remember, read by dcf-registry resolve as layer rank 0 (id component-registry, at /).
rm -rf "$share/base"
cp -R "$feature_dir/base" "$share/base"
find "$share/base" -type d -exec chmod 0755 {} +
find "$share/base" -type f -exec chmod 0644 {} +

command -v flock >/dev/null 2>&1 || echo "component-registry: flock (util-linux) is not in the image; dcf-registry resolve needs it" >&2
command -v git >/dev/null 2>&1 || echo "component-registry: no git in the image; a git layer source will fail until one is added (the git Feature)"
echo "component-registry: installed ${version:-unknown}; layer list ${REGISTRYFILE} (COMPONENT_REGISTRY_FILE overrides)"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/component-registry.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
