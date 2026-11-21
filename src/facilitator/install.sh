#!/usr/bin/env bash
# The facilitator Feature (NOTES.md). Installs the facilitator node bundle (bundles/facilitator, ADR-0067) and
# what only a devcontainer needs around it:
#   /opt/facilitator/                         the bundle: bin/facilitator, bin/dirctl, bin/slimctl (mode node only),
#                                             python/ (its own CPython), lib/site-packages/ (slim-bindings),
#                                             lib/facilitator, registerengine, signpacket, types.d, agntcy,
#                                             MANIFEST.json
#   /opt/facilitator/lib/options.env          the options as installed (a variable of the same name wins, NFR-6)
#   /usr/local/bin/facilitator, dirctl, slimctl   links into /opt/facilitator/bin (slimctl in mode node only)
#   /usr/local/bin/facilitator-setup, facilitator-start   the two devcontainer hooks
#   /usr/local/libexec/facilitator/dcf-persist   the state-folder helper, this Feature's own copy
#   /usr/local/lib/register-engine/types.d/facilitator.py   the conversation type, when register-engine is installed
#   /usr/local/share/go-task/includes.d/facilitator.yml   the Taskfile (installTaskfile)
#
# Where the bundle comes from, the first that applies (NOTES.md "The bundle"):
#   1. FACILITATOR_BUNDLE=<tarball> (tests, offline): a bundle file with its SHA256SUMS beside it;
#   2. bundle/<asset> in this Feature's folder (staged by `task bundle:stage`, git-ignored; tests only);
#   3. FACILITATOR_ASSETS=<folder> holding <asset> (offline builds);
#   4. the GitHub release facilitator-bundle-v<bundleVersion>, when digests.txt pins <asset>;
#   5. otherwise the bundle is built here from this folder's own source by bundle-build.sh (a copy of
#      bundles/facilitator/install.sh), every upstream download checked against the SHA-256 pinned in it.
# A bundle file is checked against the digest pinned in digests.txt when there is one, and refused when it
# differs; an unpinned local file (1 to 3) is checked against its SHA256SUMS and said to be unpinned.
# Options arrive as upper-cased environment variables. Tests only: DESTDIR installs under another root as a
# user and skips the system steps.
set -euo pipefail

feature_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/facilitator/dcf-curl.sh
. "$feature_dir/dcf-curl.sh"

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
BACKEND="${BACKEND:-agntcy}"
MODE="${MODE:-node}"
BUNDLEVERSION="${BUNDLEVERSION:-latest}"
DIRVERSION="${DIRVERSION:-}"
SLIMVERSION="${SLIMVERSION:-}"
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
ASSETS="${FACILITATOR_ASSETS:-}"
BUNDLE_FILE="${FACILITATOR_BUNDLE:-}"
REPO=nabil-becker/devcontainer-features

say() { echo "facilitator: $*"; }
die() { echo "facilitator: $*" >&2; exit 1; }

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  die "install.sh must run as root (the devcontainer Feature lifecycle does this)."
fi

version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n1)"
# The bundle this Feature version was made with: the application version in its own source.
source_bundle="$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$feature_dir/facilitator/__init__.py")"

# ---------------------------------------------------------------- what this version does not do yet, and the options
case "$BACKEND" in
  agntcy) ;;
  lean) die "backend lean: not yet: slice 5 (the lean hatch on packet-relay). This version runs agntcy only." ;;
  *) die "backend '$BACKEND': agntcy (lean comes in slice 5)" ;;
esac
[ "$IDENTITY" = "true" ] && die "identity true: not yet: slice 7 (AGNTCY Identity, which needs Docker)."
case "$MODE" in
  node | leaf) ;;
  *) die "mode '$MODE': node (the default: the Directory, SLIM and the ssh-agent run here) or leaf (the thin client only)" ;;
esac
for pair in "hopLimit:$HOPLIMIT" "messageBudget:$MESSAGEBUDGET" "rateLimit:$RATELIMIT" \
  "receiveWaitSeconds:$RECEIVEWAITSECONDS" "staleSeconds:$STALESECONDS" "facilitatorBudget:$FACILITATORBUDGET"; do
  case "${pair#*:}" in '' | *[!0-9]*) die "${pair%%:*} '${pair#*:}' is not a whole number" ;; esac
done

BUNDLEVERSION="${BUNDLEVERSION#v}"
if [ "$BUNDLEVERSION" = latest ]; then
  BUNDLEVERSION="$source_bundle"
  say "bundleVersion latest resolves to $BUNDLEVERSION, the bundle this Feature version was made with"
fi
case "$BUNDLEVERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "bundleVersion '$BUNDLEVERSION': a version (e.g. $source_bundle) or latest" ;;
esac

# Deprecated in 0.3.0 (removed in 1.0.0): the bundle fixes dirctl's and slimctl's versions. The versions the bundle
# carries, or latest, are accepted (unchanged behaviour); any other was refused before too, for want of a pin.
deprecated=""
for pair in "dirVersion:$DIRVERSION:1.9.1" "slimVersion:$SLIMVERSION:3.4.6"; do
  name="${pair%%:*}" rest="${pair#*:}"
  value="${rest%%:*}" carried="${rest#*:}"
  value="${value#v}"
  [ -n "$value" ] || continue
  echo "facilitator: $name is deprecated: use bundleVersion (removed in 1.0.0)" >&2
  deprecated="${deprecated:+$deprecated }$name"
  case "$value" in
    latest | "$carried") ;;
    *) die "$name $value: the bundle carries $carried; set bundleVersion to the bundle that carries the version you need" ;;
  esac
done

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "unsupported architecture $(uname -m) (linux amd64 and arm64 only)" ;;
esac
asset="facilitator-$BUNDLEVERSION-linux-$arch.tar.gz"
pin="$(awk -v n="$asset" '$2 == n { print $1; exit }' "$feature_dir/digests.txt" 2>/dev/null || true)"

# ---------------------------------------------------------------- system packages (no Python: the bundle has its own)
if [ -z "$DESTDIR" ]; then
  missing=()
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
  if [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; then
    die "needs glibc (the bundle's CPython, slimctl and slim-bindings are the gnu/manylinux builds); musl is not supported"
  fi
fi

opt="$DESTDIR/opt/facilitator"
bin="$DESTDIR/usr/local/bin"
libexec="$DESTDIR/usr/local/libexec/facilitator"
mkdir -p "$DESTDIR/opt" "$bin" "$libexec"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- the bundle, verified before it is unpacked
check_local() { # <bundle file>: the pin when there is one, else the SHA256SUMS beside it
  local file="$1" sums want got
  [ -f "$file" ] || die "no bundle at $file"
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ -n "$pin" ]; then
    [ "$got" = "$pin" ] || die "$asset: the SHA-256 does not match the one pinned in digests.txt; nothing installed"
    return 0
  fi
  sums="$(dirname "$file")/SHA256SUMS"
  want="$(awk -v n="$(basename "$file")" '$2 == n { print $1; exit }' "$sums" 2>/dev/null || true)"
  [ -n "$want" ] || die "$(basename "$file"): no line for it in $sums, and no pin in digests.txt; nothing installed"
  [ "$got" = "$want" ] || die "$(basename "$file"): the SHA-256 does not match its SHA256SUMS; nothing installed"
  say "using an unpinned local bundle $(basename "$file") (checked against its SHA256SUMS; tests and offline builds only)"
}

bundle=""
if [ -n "$BUNDLE_FILE" ]; then
  check_local "$BUNDLE_FILE"
  bundle="$BUNDLE_FILE"
elif [ -f "$feature_dir/bundle/$asset" ]; then
  check_local "$feature_dir/bundle/$asset"
  bundle="$feature_dir/bundle/$asset"
elif [ -n "$ASSETS" ] && [ -f "$ASSETS/$asset" ]; then
  check_local "$ASSETS/$asset"
  bundle="$ASSETS/$asset"
elif [ -n "$pin" ]; then
  say "downloading the facilitator bundle $BUNDLEVERSION ($arch)..."
  dcf_curl -fsSL -o "$tmp/$asset" "https://github.com/$REPO/releases/download/facilitator-bundle-v$BUNDLEVERSION/$asset"
  echo "$pin  $tmp/$asset" | sha256sum -c - >/dev/null \
    || die "$asset: the SHA-256 does not match the one pinned in digests.txt; nothing installed"
  bundle="$tmp/$asset"
elif [ "$BUNDLEVERSION" = "$source_bundle" ]; then
  say "no released bundle $BUNDLEVERSION is pinned in digests.txt: building it from this Feature's source"
  bash "$feature_dir/bundle-build.sh" --source "$feature_dir" --arch "$arch" --install-to "$tmp/tree/facilitator" \
    ${ASSETS:+--assets "$ASSETS"}
else
  die "bundleVersion $BUNDLEVERSION: no digest for $asset in digests.txt, and this Feature's source is bundle $source_bundle"
fi

mkdir -p "$tmp/tree"
if [ -n "$bundle" ]; then
  # The tarball holds one folder, facilitator/; leaf leaves the SLIM node out (it runs no daemon).
  excl=()
  [ "$MODE" = leaf ] && excl=(--exclude=facilitator/bin/slimctl)
  tar -xzf "$bundle" -C "$tmp/tree" --no-same-owner "${excl[@]}"
  [ -f "$tmp/tree/facilitator/MANIFEST.json" ] || die "$asset holds no facilitator/MANIFEST.json; nothing installed"
fi
[ "$MODE" = leaf ] && rm -f "$tmp/tree/facilitator/bin/slimctl"
rm -rf "$opt.new"
mv "$tmp/tree/facilitator" "$opt.new"
rm -rf "$opt"
mv "$opt.new" "$opt"
chmod 0755 "$opt"

cat >"$opt/lib/options.env" <<EOF
# The facilitator Feature's options as installed ($version). A variable of the same name in the
# command line, .env, .devcontainer/.env or the environment wins (NFR-6).
FACILITATOR_BACKEND=$BACKEND
FACILITATOR_MODE=$MODE
FACILITATOR_HOP_LIMIT=$HOPLIMIT
FACILITATOR_MESSAGE_BUDGET=$MESSAGEBUDGET
FACILITATOR_RATE_LIMIT=$RATELIMIT
FACILITATOR_RECEIVE_WAIT_SECONDS=$RECEIVEWAITSECONDS
FACILITATOR_STALE_SECONDS=$STALESECONDS
FACILITATOR_BUDGET=$FACILITATORBUDGET
FACILITATOR_AUTOSTART=$AUTOSTART
FACILITATOR_DIR_ONLINE_CHECK=$DIRONLINECHECK
FACILITATOR_DEPRECATED=$deprecated
EOF
chmod 0644 "$opt/lib/options.env"

# ---------------------------------------------------------------- links, hooks, the conversation type
for b in facilitator dirctl slimctl; do
  rm -f "$bin/$b"
  if [ -e "$opt/bin/$b" ]; then ln -s "../../../opt/facilitator/bin/$b" "$bin/$b"; fi
done
re_types="$DESTDIR/usr/local/lib/register-engine/types.d"
if [ -d "$re_types" ]; then
  install -m 0644 "$opt/lib/types.d/facilitator.py" "$re_types/facilitator.py"
fi
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

say "$version installed (mode $MODE, bundle $BUNDLEVERSION linux-$arch, backend $BACKEND, taskfile: $INSTALLTASKFILE)"
