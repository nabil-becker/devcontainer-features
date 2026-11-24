#!/usr/bin/env bash
# Installs the component-registry Feature: the dcf-registry command (resolve, explain, handover,
# refresh, render), minijinja-cli (1.11.0, ADR-0077: the template engine that renders each
# vendor's files, one pinned static binary checked against its sha256), the registry sources this release ships (registry-source-git,
# registry-source-path, registry-source-http, which reads dcf-curl.sh from the share folder, and
# registry-source-db, 1.5.0, which needs sqlite3 or psql in the image for its driver), the built-in base layer with the utility skills, the postStartCommand
# component-registry-setup, the dcf-persist helper and the Feature Taskfile.
# Feature options arrive as upper-cased environment variables (see devcontainer-feature.json):
# REGISTRYFILE, INSTALLTASKFILE.
#
# One download at build (1.11.0): minijinja-cli, pinned below with its sha256 per architecture and
# fetched through dcf_curl (ADR-0034); a mismatch stops the build. The http source fetches layers at
# run time through dcf_curl. The scripts are bash, awk and sed (NFR-7);
# the git source needs git and the http source curl, which this Feature does not install (the git Feature or the image
# brings it; without it a git source fails with a plain line and the other layers still resolve).
#
# Never writes into /var/lib/devcontainer-features/component-registry: the volume is not mounted
# at image build; component-registry-setup makes it usable, owner-only, at start.
set -euo pipefail

# shellcheck source=src/component-registry/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

# minijinja-cli (ADR-0077): the version and the sha256 of each static (musl) build, from the
# publisher's .sha256 files of that release, checked again when the pin moves. Not an option: the
# base templates are tested against this version.
MINIJINJA_VERSION=3.1.0
MINIJINJA_SHA256_X86_64=94b815a17dc3b7a4e11e348c62a916c85fc1728bc7a9b731edd905af2a818324
MINIJINJA_SHA256_AARCH64=c4c297180bc73ccac86afd63f39de9b06a89d6bb53527b515eec0f48d52a2580

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
install -m 0755 "$feature_dir/registry-source-http.sh" /usr/local/bin/registry-source-http
install -m 0755 "$feature_dir/registry-source-db.sh" /usr/local/bin/registry-source-db
install -m 0644 "$feature_dir/dcf-curl.sh" "$share/dcf-curl.sh"
install -m 0755 "$feature_dir/component-registry-setup.sh" /usr/local/bin/component-registry-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# minijinja-cli (1.11.0, ADR-0077): renders the resolved view through the winning templates at each
# hand-over. A static build for x86_64 and aarch64; on another architecture nothing is installed
# and a hand-over to a CLI with templates fails with one line (its CLI keeps the skills it has).
case "$(uname -m)" in
  x86_64 | amd64) mj_arch=x86_64 mj_sum="$MINIJINJA_SHA256_X86_64" ;;
  aarch64 | arm64) mj_arch=aarch64 mj_sum="$MINIJINJA_SHA256_AARCH64" ;;
  *) mj_arch='' mj_sum='' ;;
esac
if [ -z "$mj_arch" ]; then
  echo "component-registry: no static minijinja-cli build for $(uname -m); a hand-over to a CLI with templates will fail until one is on PATH" >&2
elif [ -x /usr/local/bin/minijinja-cli ] && [ "$(/usr/local/bin/minijinja-cli --version 2>/dev/null)" = "minijinja-cli $MINIJINJA_VERSION" ]; then
  echo "component-registry: minijinja-cli $MINIJINJA_VERSION already installed"
else
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v xz >/dev/null 2>&1 || missing+=(xz-utils)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  if [ "${#missing[@]}" -gt 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends "${missing[@]}"
      rm -rf /var/lib/apt/lists/*
    else
      echo "component-registry: missing ${missing[*]} and no apt-get to install them." >&2
      exit 1
    fi
  fi
  mj_asset="minijinja-cli-${mj_arch}-unknown-linux-musl"
  mj_tmp="$(mktemp -d)"
  trap 'rm -rf "$mj_tmp"' EXIT
  echo "component-registry: downloading minijinja-cli ${MINIJINJA_VERSION} (${mj_asset})..."
  dcf_curl -fsSL -o "$mj_tmp/$mj_asset.tar.xz" "https://github.com/mitsuhiko/minijinja/releases/download/${MINIJINJA_VERSION}/${mj_asset}.tar.xz"
  echo "$mj_sum  $mj_tmp/$mj_asset.tar.xz" | sha256sum -c -
  tar -xJf "$mj_tmp/$mj_asset.tar.xz" -C "$mj_tmp"
  install -m 0755 "$mj_tmp/$mj_asset/minijinja-cli" /usr/local/bin/minijinja-cli
  /usr/local/bin/minijinja-cli --version
fi

# The built-in base layer (1.1.0): the utility skills /registry-refresh and
# /registry-explain, read by dcf-registry resolve as layer rank 0 (id component-registry, at /);
# and (1.11.0, ADR-0077) the base templates, templates/<vendor>/<file>.j2.
rm -rf "$share/base"
cp -R "$feature_dir/base" "$share/base"
find "$share/base" -type d -exec chmod 0755 {} +
find "$share/base" -type f -exec chmod 0644 {} +

# zip layers (an http source with archive: zip) need unzip; tar.gz needs only tar.
if ! command -v unzip >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq --no-install-recommends unzip && rm -rf /var/lib/apt/lists/* ||
      echo "component-registry: could not install unzip; a zip layer will be refused until it is (apt-get install unzip)" >&2
  else
    echo "component-registry: no unzip and no apt-get; a zip layer will be refused until unzip is added" >&2
  fi
fi
command -v flock >/dev/null 2>&1 || echo "component-registry: flock (util-linux) is not in the image; dcf-registry resolve needs it" >&2
command -v sqlite3 >/dev/null 2>&1 || command -v psql >/dev/null 2>&1 || echo "component-registry: neither sqlite3 nor psql in the image; a db layer source will fail until one is added (apt-get install sqlite3 or postgresql-client)"
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
