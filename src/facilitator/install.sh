#!/usr/bin/env bash
# The facilitator Feature (NOTES.md). Installs:
#   /usr/local/bin/dirctl                     the AGNTCY Directory CLI and daemon (release asset, SHA-256 pinned below)
#   /usr/local/bin/slimctl                    slimctl, which carries the SLIM node (release tarball, SHA-256 pinned below)
#   /usr/local/lib/facilitator/venv/          the Feature's own venv: slim-bindings, from its wheel (SHA-256 pinned
#                                             below, then pip --require-hashes, no index)
#   /usr/local/lib/facilitator/facilitator/   the application: intake, guard, router, dispatcher, collector, the MCP
#                                             server, the model wrapper, chat, infra, verify
#   /usr/local/lib/facilitator/registerengine/, signpacket/   this Feature's own copies of register-engine's and
#                                             sign-packet's libraries (ADR-0062: each Feature installs alone)
#   /usr/local/lib/facilitator/types.d/facilitator.py   the conversation register type (also into
#                                             /usr/local/lib/register-engine/types.d/ when register-engine is installed)
#   /usr/local/lib/facilitator/agntcy/        the Directory's and SLIM's config templates (every port on loopback)
#   /usr/local/lib/facilitator/options.env    the options as installed (a variable of the same name wins, NFR-6)
#   /usr/local/bin/facilitator, facilitator-setup, facilitator-start   the command and the two lifecycle hooks
#   /usr/local/libexec/facilitator/dcf-persist   the state-folder helper, this Feature's own copy
#   /usr/local/share/go-task/includes.d/facilitator.yml   the Taskfile (installTaskfile)
# Options arrive as upper-cased environment variables.
# Tests only: DESTDIR installs under another root as a user and skips the system steps;
# FACILITATOR_SKIP_DOWNLOADS=1 skips the binaries and the venv; FACILITATOR_ASSETS=<folder> takes the
# downloads from a folder instead of the network (still checked against the pinned SHA-256).
set -euo pipefail

feature_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/facilitator/dcf-curl.sh
. "$feature_dir/dcf-curl.sh"

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
BACKEND="${BACKEND:-agntcy}"
DIRVERSION="${DIRVERSION:-1.9.1}"
SLIMVERSION="${SLIMVERSION:-3.4.6}"
HOPLIMIT="${HOPLIMIT:-6}"
MESSAGEBUDGET="${MESSAGEBUDGET:-40}"
RATELIMIT="${RATELIMIT:-10}"
RECEIVEWAITSECONDS="${RECEIVEWAITSECONDS:-300}"
STALESECONDS="${STALESECONDS:-900}"
FACILITATORBUDGET="${FACILITATORBUDGET:-20}"
IDENTITY="${IDENTITY:-false}"
AUTOSTART="${AUTOSTART:-true}"
DIRONLINECHECK="${DIRONLINECHECK:-false}"
DESTDIR="${DESTDIR:-}"
SKIP_DOWNLOADS="${FACILITATOR_SKIP_DOWNLOADS:-}"
ASSETS="${FACILITATOR_ASSETS:-}"

say() { echo "facilitator: $*"; }
die() { echo "facilitator: $*" >&2; exit 1; }

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  die "install.sh must run as root (the devcontainer Feature lifecycle does this)."
fi

version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n1)"

# ---------------------------------------------------------------- what this version does not do yet
case "$BACKEND" in
  agntcy) ;;
  lean) die "backend lean: not yet: slice 5 (the lean hatch on packet-relay). This version runs agntcy only." ;;
  *) die "backend '$BACKEND': agntcy (lean comes in slice 5)" ;;
esac
[ "$IDENTITY" = "true" ] && die "identity true: not yet: slice 7 (AGNTCY Identity, which needs Docker)."
for pair in "hopLimit:$HOPLIMIT" "messageBudget:$MESSAGEBUDGET" "rateLimit:$RATELIMIT" \
  "receiveWaitSeconds:$RECEIVEWAITSECONDS" "staleSeconds:$STALESECONDS" "facilitatorBudget:$FACILITATORBUDGET"; do
  case "${pair#*:}" in '' | *[!0-9]*) die "${pair%%:*} '${pair#*:}' is not a whole number" ;; esac
done

# ---------------------------------------------------------------- versions and their pinned checksums
DIRVERSION="${DIRVERSION#v}"
SLIMVERSION="${SLIMVERSION#v}"
[ "$DIRVERSION" = latest ] && DIRVERSION=1.9.1 && say "dirVersion latest resolves to 1.9.1, the version pinned here"
[ "$SLIMVERSION" = latest ] && SLIMVERSION=3.4.6 && say "slimVersion latest resolves to 3.4.6, the version pinned here"
SLIM_BINDINGS=3.3.9

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 wheel_arch=x86_64 ;;
  aarch64 | arm64) arch=arm64 wheel_arch=aarch64 ;;
  *) die "unsupported architecture $(uname -m) (linux amd64 and arm64 only)" ;;
esac

# Where each hash came from (checked 2026-11-20, NOTES.md "How the download is verified"):
# dirctl: the GitHub release API's asset digest and the subject of the release's SLSA provenance
#   (dirctl-v1.9.1.intoto.jsonl) agree with the download; the project publishes no checksum file.
# slimctl: the release API's asset digest agrees with the download, whose sigstore bundle was verified
#   by identity (the release-rust workflow of agntcy/slim) in the spike, 2026-11-19.
# slim-bindings: PyPI's sha256 for the wheel (pypi.org/pypi/slim-bindings/3.3.9/json).
case "dir/$DIRVERSION/$arch" in
  dir/1.9.1/amd64) dir_sha=adf2cbf7a5a9145d46532c0a625b38f8035ecc66554e69e9d3c98ce00c76b3c4 ;;
  dir/1.9.1/arm64) dir_sha=cd998d001bd44c015b64407e17cf79b9769509eb0cc70b153ebb93c4d612c701 ;;
  *) die "no pinned checksum for dirctl $DIRVERSION on $arch; add it to install.sh" ;;
esac
case "slim/$SLIMVERSION/$arch" in
  slim/3.4.6/amd64) slim_sha=9b2ffe445a15d8bec75c3e0a41e99aca1df77a6088d3e27ba25ba19eca29184a ;;
  slim/3.4.6/arm64) slim_sha=39295e450812726a39f1b0284266c6d1c6752daa6a913c47867e3f640cfb30df ;;
  *) die "no pinned checksum for slimctl $SLIMVERSION on $arch; add it to install.sh" ;;
esac
case "$SLIM_BINDINGS/$wheel_arch" in
  3.3.9/x86_64)
    wheel_sha=440e54264db47da1c3bfb5c95e4055a7bdaf406ea3bd9c80af90c4cad6f5e3c4
    wheel_url=https://files.pythonhosted.org/packages/74/c2/54c9e7e11c397d8f7bdd4f50170ab8fcecd00c8fc3c03be9ee67f59d902f/slim_bindings-3.3.9-py3-none-manylinux_2_28_x86_64.whl
    ;;
  3.3.9/aarch64)
    wheel_sha=7e8d2f4057c86390b382678a3793b280d12481eea5acc60581aabda806d4a348
    wheel_url=https://files.pythonhosted.org/packages/02/bd/a6e3c80afef05c2553d73c7b729223cdcce24b508c46d92b971c3c57e95b/slim_bindings-3.3.9-py3-none-manylinux_2_28_aarch64.whl
    ;;
esac
wheel="${wheel_url##*/}"

# ---------------------------------------------------------------- system packages
need_python() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
}
need_venv() { python3 -c 'import venv, ensurepip' >/dev/null 2>&1; }
if [ -z "$DESTDIR" ]; then
  missing=()
  need_python || missing+=(python3)
  { need_python && need_venv; } || missing+=(python3-venv)
  command -v ssh-keygen >/dev/null 2>&1 || missing+=(openssh-client)
  command -v ssh-agent >/dev/null 2>&1 || missing+=(openssh-client)
  command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v gzip >/dev/null 2>&1 || missing+=(gzip)
  if [ "${#missing[@]}" -gt 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      # shellcheck disable=SC2046
      apt-get install -y -qq --no-install-recommends $(printf '%s\n' "${missing[@]}" | sort -u)
      rm -rf /var/lib/apt/lists/*
    else
      die "missing ${missing[*]} and no apt-get to install them"
    fi
  fi
  need_python || die "needs Python 3.11 or later (add ghcr.io/devcontainers/features/python, or a newer base image)"
  if [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; then
    die "needs glibc (the pinned slimctl and slim-bindings builds are the gnu/manylinux ones); musl is not supported"
  fi
fi

lib="$DESTDIR/usr/local/lib/facilitator"
bin="$DESTDIR/usr/local/bin"
libexec="$DESTDIR/usr/local/libexec/facilitator"
mkdir -p "$lib" "$bin" "$libexec"
chmod 0755 "$lib"

# ---------------------------------------------------------------- downloads, verified before use
fetch() { # <url> <file> <sha256>
  local url="$1" out="$2" sha="$3"
  if [ -n "$ASSETS" ]; then
    cp "$ASSETS/$(basename "$out")" "$out" || die "no $(basename "$out") in $ASSETS"
  else
    dcf_curl -fsSL -o "$out" "$url"
  fi
  echo "$sha  $out" | sha256sum -c - >/dev/null || die "$(basename "$out"): the SHA-256 does not match the one pinned in install.sh; nothing installed"
}

if [ -z "$SKIP_DOWNLOADS" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  say "downloading dirctl v$DIRVERSION, slimctl $SLIMVERSION and slim-bindings $SLIM_BINDINGS ($arch)..."
  fetch "https://github.com/agntcy/dir/releases/download/v$DIRVERSION/dirctl-linux-$arch" "$tmp/dirctl-linux-$arch" "$dir_sha"
  fetch "https://github.com/agntcy/slim/releases/download/slimctl-v$SLIMVERSION/slimctl-linux-$arch-gnu.tar.gz" \
    "$tmp/slimctl-linux-$arch-gnu.tar.gz" "$slim_sha"
  mkdir -p "$tmp/wheels"
  fetch "$wheel_url" "$tmp/wheels/$wheel" "$wheel_sha"
  install -m 0755 "$tmp/dirctl-linux-$arch" "$bin/dirctl"
  mkdir -p "$tmp/slim"
  tar -xzf "$tmp/slimctl-linux-$arch-gnu.tar.gz" -C "$tmp/slim"
  slimctl_file="$(find "$tmp/slim" -type f -name slimctl | head -n1)"
  [ -n "$slimctl_file" ] || die "no slimctl in slimctl-linux-$arch-gnu.tar.gz"
  install -m 0755 "$slimctl_file" "$bin/slimctl"

  # The Feature's own venv: made again when its Python is not the system's current one.
  venv="$lib/venv"
  if [ ! -x "$venv/bin/python3" ] || ! "$venv/bin/python3" -c 'import sys' >/dev/null 2>&1 \
    || [ "$("$venv/bin/python3" -c 'import sys; print(sys.version_info[:2])')" != "$(python3 -c 'import sys; print(sys.version_info[:2])')" ]; then
    rm -rf "$venv"
    python3 -m venv "$venv"
  fi
  printf 'slim-bindings==%s --hash=sha256:%s\n' "$SLIM_BINDINGS" "$wheel_sha" >"$tmp/requirements.txt"
  "$venv/bin/python3" -m pip install --quiet --disable-pip-version-check --no-index --no-deps --require-hashes \
    --find-links "$tmp/wheels" -r "$tmp/requirements.txt"
  install -m 0644 "$tmp/requirements.txt" "$lib/requirements.txt"
  python_line="#!$venv/bin/python3 -I"
  [ -n "$DESTDIR" ] && python_line="#!/usr/bin/env -S $venv/bin/python3 -I"
else
  python_line="#!/usr/bin/env -S python3 -I"
fi

# ---------------------------------------------------------------- the library, the command, the hooks
for d in facilitator registerengine signpacket types.d agntcy; do
  rm -rf "${lib:?}/$d"
  mkdir -p "$lib/$d"
  chmod 0755 "$lib/$d"
done
for f in "$feature_dir"/facilitator/*.py; do install -m 0644 "$f" "$lib/facilitator/"; done
for f in "$feature_dir"/registerengine/*.py; do install -m 0644 "$f" "$lib/registerengine/"; done
for f in "$feature_dir"/signpacket/*.py; do install -m 0644 "$f" "$lib/signpacket/"; done
install -m 0644 "$feature_dir/types.d/facilitator.py" "$lib/types.d/facilitator.py"
install -m 0644 "$feature_dir"/agntcy/*.in "$lib/agntcy/"
cat >"$lib/options.env" <<EOF
# The facilitator Feature's options as installed ($version). A variable of the same name in the
# command line, .env, .devcontainer/.env or the environment wins (NFR-6).
FACILITATOR_BACKEND=$BACKEND
FACILITATOR_HOP_LIMIT=$HOPLIMIT
FACILITATOR_MESSAGE_BUDGET=$MESSAGEBUDGET
FACILITATOR_RATE_LIMIT=$RATELIMIT
FACILITATOR_RECEIVE_WAIT_SECONDS=$RECEIVEWAITSECONDS
FACILITATOR_STALE_SECONDS=$STALESECONDS
FACILITATOR_BUDGET=$FACILITATORBUDGET
FACILITATOR_AUTOSTART=$AUTOSTART
FACILITATOR_DIR_ONLINE_CHECK=$DIRONLINECHECK
EOF
chmod 0644 "$lib/options.env"
# The conversation type for register-engine's own command too, when it is installed (it orders before this one).
re_types="$DESTDIR/usr/local/lib/register-engine/types.d"
if [ -d "$re_types" ]; then
  install -m 0644 "$feature_dir/types.d/facilitator.py" "$re_types/facilitator.py"
fi
{ echo "$python_line"; tail -n +2 "$feature_dir/bin/facilitator"; } >"$bin/facilitator"
chmod 0755 "$bin/facilitator"
install -m 0755 "$feature_dir/facilitator-setup.sh" "$bin/facilitator-setup"
install -m 0755 "$feature_dir/facilitator-start.sh" "$bin/facilitator-start"
install -m 0755 "$feature_dir/dcf-persist.sh" "$libexec/dcf-persist"

# ---------------------------------------------------- Feature Taskfile ----
includes="$DESTDIR/usr/local/share/go-task/includes.d"
if [ "$INSTALLTASKFILE" = "true" ]; then
  mkdir -p "$includes"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes/facilitator.yml"
  if [ -z "$DESTDIR" ] && command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
else
  rm -f "$includes/facilitator.yml"
fi

say "$version installed (backend $BACKEND, dirctl ${DIRVERSION}, slimctl ${SLIMVERSION}, slim-bindings ${SLIM_BINDINGS}, taskfile: $INSTALLTASKFILE)"
