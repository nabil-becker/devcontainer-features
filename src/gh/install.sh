#!/usr/bin/env bash
# Installs the GitHub CLI (https://cli.github.com) and the pieces that make
# it part of this collection's ecosystem: the dcf-persist helper, the
# post-create setup of GH_CONFIG_DIR and the git credential helper
# (gh-setup), and the Feature Taskfile. Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): INSTALL, VERSION,
# GITCREDENTIALHELPER.
#
# Augment, don't duplicate: with install=auto (the default) a `gh` that is
# already in the image - put there by the official
# ghcr.io/devcontainers/features/github-cli (apt, ordered before this Feature
# by installsAfter) or by a base image - is left alone and only the ecosystem
# pieces are added. The release binary is installed only when no gh exists
# (or install=native): downloaded from the cli/cli GitHub release, checked
# against the publisher's checksums file, pinnable with `version`.
#
# Never writes into GH_CONFIG_DIR: the volume is not mounted at image build;
# gh-setup makes it usable at post-create.
set -euo pipefail

INSTALL="${INSTALL:-auto}"
VERSION="${VERSION:-latest}"
GITCREDENTIALHELPER="${GITCREDENTIALHELPER:-true}"

if [ "$(id -u)" -ne 0 ]; then
  echo "gh: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

# A gh from an earlier Feature or the base image: on PATH, or where the
# official Feature's apt package puts it when PATH is minimal at build time.
existing_gh() {
  local c
  c="$(command -v gh 2>/dev/null || true)"
  if [ -n "$c" ] && [ "$c" != /usr/local/bin/gh ]; then
    echo "$c"
    return 0
  fi
  if [ -x /usr/bin/gh ]; then
    echo /usr/bin/gh
    return 0
  fi
  return 1
}

install_native() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  if [ ${#missing[@]} -gt 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends "${missing[@]}"
      rm -rf /var/lib/apt/lists/*
    else
      echo "gh: ${missing[*]} required and apt-get is unavailable." >&2
      exit 1
    fi
  fi

  local arch asset base
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    armv6l | armv7l) arch="armv6" ;;
    *)
      echo "gh: unsupported architecture $(uname -m)" >&2
      exit 1
      ;;
  esac

  # Resolve 'latest' through the GitHub redirect (no API call, no token,
  # no rate limit): releases/latest 302s to releases/tag/v<version>.
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed -E 's#.*/tag/v?##')"
  fi
  VERSION="${VERSION#v}"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "gh: could not resolve a GitHub CLI version from '$VERSION'" >&2
    exit 1
  fi

  # tmp is deliberately not local: the EXIT trap runs after this function
  # has returned, and set -u would abort on an unbound name.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  asset="gh_${VERSION}_linux_${arch}.tar.gz"
  base="https://github.com/cli/cli/releases/download/v${VERSION}"
  echo "gh: downloading GitHub CLI v${VERSION} (linux/${arch})..."
  curl -fsSL -o "$tmp/$asset" "$base/$asset"
  curl -fsSL -o "$tmp/checksums.txt" "$base/gh_${VERSION}_checksums.txt"
  # Verify against the publisher's checksums file before anything is installed.
  (cd "$tmp" && grep -E "  ${asset}\$" checksums.txt | sha256sum -c -)
  tar -xzf "$tmp/$asset" -C "$tmp" "gh_${VERSION}_linux_${arch}/bin/gh"
  install -m 0755 "$tmp/gh_${VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh
  /usr/local/bin/gh --version
}

case "$INSTALL" in
  native) install_native ;;
  none) echo "gh: install=none, not installing the binary (expected from another Feature or the image)." ;;
  auto)
    if found="$(existing_gh)"; then
      echo "gh: keeping the gh already in the image ($found); version '$VERSION' is ignored. Set install=native to replace it with the verified release binary."
    else
      install_native
    fi
    ;;
  *)
    echo "gh: invalid install option '$INSTALL' (auto, native, none)" >&2
    exit 1
    ;;
esac

# ------------------------------------------------------- ecosystem pieces ----
# dcf-persist makes the state directory usable (verbatim copy of
# src/common/dcf-persist.sh); gh-setup is this Feature's postCreateCommand
# (see devcontainer-feature.json) and reads its option defaults from
# options.env, so the hook and `task gh:setup` behave the same.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/gh-feature
mkdir -p "$share"
{
  echo "# Written by the gh Feature's install.sh from its options; sourced by gh-setup."
  printf 'GITCREDENTIALHELPER=%q\n' "$GITCREDENTIALHELPER"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/gh-setup.sh" /usr/local/bin/gh-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/gh.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
