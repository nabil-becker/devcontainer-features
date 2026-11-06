#!/usr/bin/env bash
# Installs the OpenBao CLI (https://openbao.org) from GitHub releases,
# verified against the release's checksums.txt, plus the pieces that make it part of this
# collection's ecosystem: dcf-secret, dcf-persist, the post-create setup (openbao-setup) and the
# Feature Taskfile. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): VERSION, MODE, UNLOCK, BACKUPDEST, BACKUPKEEP, BACKUPINTERVAL, BACKUPWARNAFTER.
set -euo pipefail

# Every download goes through dcf_curl (dcf-curl.sh, the collection's retry helper, vendored from
# src/common): curl with --retry and, on curl 7.71+, --retry-all-errors.
# shellcheck source=src/openbao/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

VERSION="${VERSION:-latest}"
MODE="${MODE:-client}"
UNLOCK="${UNLOCK:-operator}"
BACKUPDEST="${BACKUPDEST:-}"
BACKUPKEEP="${BACKUPKEEP:-30}"
BACKUPINTERVAL="${BACKUPINTERVAL:-}"
BACKUPWARNAFTER="${BACKUPWARNAFTER:-7d}"
repo="openbao/openbao"

if [ "$(id -u)" -ne 0 ]; then
  echo "openbao: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

if [ "$MODE" != "client" ] && [ "$MODE" != "server" ]; then
  echo "openbao: mode '$MODE' is not known (client or server)." >&2
  exit 1
fi

if [ "$UNLOCK" != "operator" ] && [ "$UNLOCK" != "keyfile" ]; then
  echo "openbao: unlock '$UNLOCK' is not known (operator or keyfile)." >&2
  exit 1
fi

# The backup options (server mode; they are written down whatever the mode, and read only by it).
if [[ ! "$BACKUPKEEP" =~ ^[0-9]+$ ]]; then
  echo "openbao: backupKeep '$BACKUPKEEP' is not a whole number (0 keeps every backup)." >&2
  exit 1
fi
if [ -n "$BACKUPINTERVAL" ] && [[ ! "$BACKUPINTERVAL" =~ ^[1-9][0-9]*[mhd]$ ]]; then
  echo "openbao: backupInterval '$BACKUPINTERVAL' is not a number and m, h or d (5m, 6h, 1d), or empty for no timer." >&2
  exit 1
fi
if [[ ! "$BACKUPWARNAFTER" =~ ^[1-9][0-9]*[mhd]$ ]]; then
  echo "openbao: backupWarnAfter '$BACKUPWARNAFTER' is not a number and m, h or d (12h, 7d)." >&2
  exit 1
fi
if [ -n "$BACKUPDEST" ] && [[ "$BACKUPDEST" != /* ]]; then
  echo "openbao: backupDest '$BACKUPDEST' is not an absolute path (the folder inside the container)." >&2
  exit 1
fi

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
command -v tar >/dev/null 2>&1 || missing+=(tar)
command -v jq >/dev/null 2>&1 || missing+=(jq)
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "openbao: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "openbao: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

# Resolve "latest" through the GitHub redirect rather than the API (no token,
# no rate limit): releases/latest 302s to releases/tag/v<version>.
if [ "$VERSION" = "latest" ]; then
  VERSION="$(dcf_curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" | sed -E 's#.*/tag/v?##')"
fi
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "openbao: could not resolve an OpenBao version from '$VERSION'" >&2
  exit 1
fi

# Server mode declares its audit device in the server config (the audit stanza, OpenBao 2.4.0 and
# later); an older server would refuse the config, so the build says so instead.
if [ "$MODE" = "server" ] && [ "$(printf '%s\n%s\n' 2.4.0 "${VERSION%%[-+]*}" | sort -V | head -n 1)" != "2.4.0" ]; then
  echo "openbao: mode server needs OpenBao 2.4.0 or newer (its config declares the audit device); got ${VERSION}. Pin version 2.4.0 or later." >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/v${VERSION}"
asset="openbao_${VERSION}_linux_${arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "openbao: downloading OpenBao v${VERSION} (${asset})..."
dcf_curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
dcf_curl -fsSL -o "$tmp/checksums.txt" "$base_url/checksums.txt"
(cd "$tmp" && grep -E "  ${asset}\$" checksums.txt | sha256sum -c -)

mkdir -p "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x" bao
install -m 0755 "$tmp/x/bao" /usr/local/bin/bao

/usr/local/bin/bao version

# ------------------------------------------------------- ecosystem pieces ----
# dcf-secret is the interface every caller uses to ask for a secret; dcf-persist (verbatim copy of
# src/common/dcf-persist.sh) makes the state directory usable; openbao-setup is this Feature's
# postCreateCommand and, as `openbao-setup start`, its postStartCommand (see
# devcontainer-feature.json) and reads its option defaults from options.env, so the hooks and
# `task openbao:setup` behave the same; openbao-server is what the server-mode tasks run,
# openbao-onboard what the onboarding tasks (export, claim, wrap, unwrap) run,
# openbao-run what the others run so that server mode's BAO_ADDR default applies, and env.sh is the
# snippet they all source (the mode, that default). Nothing is written into
# OPENBAO_STATE_DIR here: the volume is not mounted at image build.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/openbao-feature
mkdir -p "$share"
{
  echo "# Written by the openbao Feature's install.sh from its options; sourced by openbao-setup."
  printf 'MODE=%q\n' "$MODE"
  printf 'UNLOCK=%q\n' "$UNLOCK"
  printf 'BACKUPDEST=%q\n' "$BACKUPDEST"
  printf 'BACKUPKEEP=%q\n' "$BACKUPKEEP"
  printf 'BACKUPINTERVAL=%q\n' "$BACKUPINTERVAL"
  printf 'BACKUPWARNAFTER=%q\n' "$BACKUPWARNAFTER"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/dcf-secret.sh" /usr/local/bin/dcf-secret
# dcf-ssh-sign: the one way to ask the SSH certificate authority in OpenBao for a user certificate.
install -m 0755 "$feature_dir/dcf-ssh-sign.sh" /usr/local/bin/dcf-ssh-sign
install -m 0755 "$feature_dir/openbao-setup.sh" /usr/local/bin/openbao-setup
install -m 0755 "$feature_dir/openbao-server.sh" /usr/local/bin/openbao-server
install -m 0755 "$feature_dir/openbao-onboard.sh" /usr/local/bin/openbao-onboard
install -m 0755 "$feature_dir/openbao-run.sh" /usr/local/bin/openbao-run
# openbao-keyfile: the OpenBao key file's container side (openbao-setup unlock|keyfile|renew hand over to it).
install -m 0755 "$feature_dir/openbao-keyfile.sh" /usr/local/bin/openbao-keyfile
# openbao-ssh: the SSH key records (task openbao:ssh:*) and the import of keys kept elsewhere.
install -m 0755 "$feature_dir/openbao-ssh.sh" /usr/local/bin/openbao-ssh
install -m 0644 "$feature_dir/env.sh" "$share/env.sh"
install -m 0644 "$feature_dir/openbao-lib.sh" "$share/openbao-lib.sh"
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist
# bao's token helper: the CLI's own way to keep its token elsewhere than ~/.vault-token. bao finds
# the config through BAO_CONFIG_PATH (containerEnv of this Feature, so it holds for every process,
# `devcontainer exec` included); the helper keeps the token in OPENBAO_STATE_DIR.
install -m 0755 "$feature_dir/openbao-token-helper.sh" /usr/local/bin/openbao-token-helper
printf '%s\n' '# Written by the openbao Feature: bao keeps its login token in the Feature'"'"'s volume.' \
  'token_helper = "/usr/local/bin/openbao-token-helper"' > "$share/bao-config.hcl"
chmod 0644 "$share/bao-config.hcl"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/openbao.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
