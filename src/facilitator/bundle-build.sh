#!/usr/bin/env bash
# The facilitator node bundle's build script (proposal facilitator-node, section 6.1; ADR-0067). One portable
# script, with no devcontainer assumptions: it needs bash, curl, tar, gzip and sha256sum, never root, and
# writes nothing outside its work folder and its output. It builds, for one architecture:
#
#   facilitator/                       the tree, installed at /opt/facilitator (the fixed prefix in bin/facilitator)
#     bin/facilitator                  the command (its first line names python/bin/python3 -I)
#     bin/dirctl  bin/slimctl          the AGNTCY Directory CLI and daemon, and slimctl (carries the SLIM node)
#     python/                          python-build-standalone, unchanged but for one .pth line naming lib/site-packages
#     lib/site-packages/               slim-bindings, from its hashed wheel (pip --require-hashes, no index)
#     lib/facilitator/ registerengine/ signpacket/ types.d/ agntcy/
#                                      the application and its libraries, taken from the source folder (src/facilitator),
#                                      so the copy checks (task signpacket:check, registerengine:check) cover them
#     MANIFEST.json                    the bundle's version and architecture, and each upstream piece: version, URL, sha256
#
# and packs it as facilitator-<version>-linux-<arch>.tar.gz beside a SHA256SUMS line in --out.
#
#   install.sh --arch amd64|arm64 --out <dir> [--source <dir>] [--assets <dir>] [--prefix /opt/facilitator]
#   install.sh --arch amd64|arm64 --install-to <dir> [...]   the tree itself, no tarball (the Feature's source build)
#   install.sh --version [--source <dir>]                    print the bundle version the source would build
#
# --source: the facilitator's source folder (default: the folder of this script when it holds facilitator/,
#   else ../../src/facilitator from it). --assets: a folder holding the upstream downloads under their release
#   names (offline builds); each is still checked against the SHA-256 pinned below. Every download goes through
#   the vendored dcf-curl and is checked before use. FACILITATOR_SKIP_DOWNLOADS=1 (unit tests only) builds a
#   skeleton with no interpreter, no binaries and no wheel, whose command runs the system python3.
#   The same inputs give the same bytes on one build host (names sorted, owner 0, times clamped to the source
#   commit's, gzip -n); across hosts that is not checked.
#
# The canonical file is bundles/facilitator/install.sh; src/facilitator/bundle-build.sh is a byte-identical copy
# so that the Feature can build the bundle from its own source (task bundle:sync; lint's bundle:check).
set -euo pipefail

say() { echo "facilitator-bundle: $*"; }
die() { echo "facilitator-bundle: $*" >&2; exit 1; }

self_dir="$(cd "$(dirname "$0")" && pwd)"
ARCH=""
OUT=""
SOURCE=""
ASSETS="${FACILITATOR_ASSETS:-}"
INSTALL_TO=""
PREFIX=/opt/facilitator
PRINT_VERSION=""
SKIP_DOWNLOADS="${FACILITATOR_SKIP_DOWNLOADS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --assets) ASSETS="${2:-}"; shift 2 ;;
    --install-to) INSTALL_TO="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --version) PRINT_VERSION=1; shift ;;
    -h | --help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (--help)" ;;
  esac
done

if [ -z "$SOURCE" ]; then
  if [ -f "$self_dir/facilitator/__init__.py" ]; then SOURCE="$self_dir"; else SOURCE="$self_dir/../../src/facilitator"; fi
fi
[ -f "$SOURCE/facilitator/__init__.py" ] || die "no facilitator source in $SOURCE (--source <src/facilitator>)"
SOURCE="$(cd "$SOURCE" && pwd)"
version="$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$SOURCE/facilitator/__init__.py")"
[ -n "$version" ] || die "no __version__ in $SOURCE/facilitator/__init__.py"
if [ -n "$PRINT_VERSION" ]; then echo "$version"; exit 0; fi

case "${ARCH:-$(uname -m)}" in
  amd64 | x86_64) arch=amd64 march=x86_64 ;;
  arm64 | aarch64) arch=arm64 march=aarch64 ;;
  *) die "unsupported architecture '${ARCH:-$(uname -m)}' (linux amd64 and arm64)" ;;
esac
case "$PREFIX" in /*) ;; *) die "--prefix must be absolute" ;; esac
[ -n "$OUT" ] || [ -n "$INSTALL_TO" ] || die "--out <dir> or --install-to <dir> (--help)"
for tool in tar gzip sha256sum; do command -v "$tool" >/dev/null 2>&1 || die "needs $tool"; done
# shellcheck source=src/facilitator/dcf-curl.sh
. "$SOURCE/dcf-curl.sh"

# ---------------------------------------------------------------- what the bundle carries, and where each pin came from
# python-build-standalone 20261026, CPython 3.13.18, install_only_stripped: the release's SHA256SUMS, the GitHub
#   release API's asset digest and the download agree, and its GitHub build attestation verifies
#   (gh attestation verify --repo astral-sh/python-build-standalone), checked 2026-11-20.
# dirctl 1.9.1: the release API's asset digest and the subject of the release's SLSA provenance
#   (dirctl-v1.9.1.intoto.jsonl) agree with the download; the project publishes no checksum file (spike, 2026-11-19).
# slimctl 3.4.6: the release API's asset digest agrees with the download, whose sigstore bundle was verified by
#   identity (the release-rust workflow of agntcy/slim) in the spike, 2026-11-19.
# slim-bindings 3.3.9: PyPI's sha256 for the wheel (pypi.org/pypi/slim-bindings/3.3.9/json).
PY_RELEASE=20261026
PY_VERSION=3.13.18
DIR_VERSION=1.9.1
SLIM_VERSION=3.4.6
SLIM_BINDINGS=3.3.9
py_asset="cpython-${PY_VERSION}+${PY_RELEASE}-${march}-unknown-linux-gnu-install_only_stripped.tar.gz"
py_url="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/cpython-${PY_VERSION}%2B${PY_RELEASE}-${march}-unknown-linux-gnu-install_only_stripped.tar.gz"
dir_asset="dirctl-linux-$arch"
dir_url="https://github.com/agntcy/dir/releases/download/v$DIR_VERSION/$dir_asset"
slim_asset="slimctl-linux-$arch-gnu.tar.gz"
slim_url="https://github.com/agntcy/slim/releases/download/slimctl-v$SLIM_VERSION/$slim_asset"
case "$arch" in
  amd64)
    py_sha=df15fe60d3ff55bf9dcf25824b5572756bb8816ff93865a273d3301d7066a8b7
    dir_sha=adf2cbf7a5a9145d46532c0a625b38f8035ecc66554e69e9d3c98ce00c76b3c4
    slim_sha=9b2ffe445a15d8bec75c3e0a41e99aca1df77a6088d3e27ba25ba19eca29184a
    wheel_sha=440e54264db47da1c3bfb5c95e4055a7bdaf406ea3bd9c80af90c4cad6f5e3c4
    wheel_url=https://files.pythonhosted.org/packages/74/c2/54c9e7e11c397d8f7bdd4f50170ab8fcecd00c8fc3c03be9ee67f59d902f/slim_bindings-3.3.9-py3-none-manylinux_2_28_x86_64.whl
    ;;
  arm64)
    py_sha=578d9da1983463ffb0c8c98ab0da2f18177f44069328eb0af847860c1eb05c3e
    dir_sha=cd998d001bd44c015b64407e17cf79b9769509eb0cc70b153ebb93c4d612c701
    slim_sha=39295e450812726a39f1b0284266c6d1c6752daa6a913c47867e3f640cfb30df
    wheel_sha=7e8d2f4057c86390b382678a3793b280d12481eea5acc60581aabda806d4a348
    wheel_url=https://files.pythonhosted.org/packages/02/bd/a6e3c80afef05c2553d73c7b729223cdcce24b508c46d92b971c3c57e95b/slim_bindings-3.3.9-py3-none-manylinux_2_28_aarch64.whl
    ;;
esac
wheel_asset="${wheel_url##*/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dl="$work/dl"
tree="$work/facilitator"
mkdir -p "$dl" "$tree/bin" "$tree/lib"

fetch() { # <url> <name> <sha256>: into $dl, checked before anything uses it
  local url="$1" name="$2" sha="$3"
  if [ -n "$ASSETS" ]; then
    cp "$ASSETS/$name" "$dl/$name" 2>/dev/null || die "no $name in $ASSETS"
  else
    dcf_curl -fsSL -o "$dl/$name" "$url"
  fi
  echo "$sha  $dl/$name" | sha256sum -c - >/dev/null || die "$name: the SHA-256 does not match the one pinned in the bundle script; nothing built"
}

# ---------------------------------------------------------------- upstream pieces
if [ -z "$SKIP_DOWNLOADS" ]; then
  say "building $version for linux-$arch: CPython $PY_VERSION, dirctl $DIR_VERSION, slimctl $SLIM_VERSION, slim-bindings $SLIM_BINDINGS"
  fetch "$py_url" "$py_asset" "$py_sha"
  fetch "$dir_url" "$dir_asset" "$dir_sha"
  fetch "$slim_url" "$slim_asset" "$slim_sha"
  fetch "$wheel_url" "$wheel_asset" "$wheel_sha"

  tar -xzf "$dl/$py_asset" -C "$tree" --no-same-owner
  [ -x "$tree/python/bin/python3" ] || die "no python/bin/python3 in $py_asset"
  install -m 0755 "$dl/$dir_asset" "$tree/bin/dirctl"
  mkdir -p "$work/slim"
  tar -xzf "$dl/$slim_asset" -C "$work/slim" --no-same-owner
  slimctl_file="$(find "$work/slim" -type f -name slimctl | head -n1)"
  [ -n "$slimctl_file" ] || die "no slimctl in $slim_asset"
  install -m 0755 "$slimctl_file" "$tree/bin/slimctl"

  # slim-bindings into lib/site-packages, by hash, with no index. The bundle's own interpreter installs it when
  # it runs here (a native build); otherwise (a cross build) the build host's python3 does, for the target's
  # platform tag. The wheel is pure Python plus one shared library, so both give the same files. -B: nothing
  # compiled into the interpreter's own tree at build time.
  printf 'slim-bindings==%s --hash=sha256:%s\n' "$SLIM_BINDINGS" "$wheel_sha" >"$work/requirements.txt"
  pip_args=(install --quiet --disable-pip-version-check --no-index --no-deps --require-hashes --no-compile
    --find-links "$dl" --target "$tree/lib/site-packages" -r "$work/requirements.txt")
  if "$tree/python/bin/python3" -I -B -c "import sys" >/dev/null 2>&1; then
    "$tree/python/bin/python3" -I -B -m pip "${pip_args[@]}"
  else
    command -v python3 >/dev/null 2>&1 || die "a cross build ($arch on $(uname -m)) needs python3 with pip on the build host"
    say "cross build: slim-bindings installed by the build host's python3 for manylinux_2_28_$march"
    python3 -I -B -m pip "${pip_args[@]}" --platform "manylinux_2_28_$march" --implementation cp \
      --python-version "${PY_VERSION%.*}" --only-binary=:all:
  fi
  # The wheel's example console scripts carry the build host's work path in their first line: dropped, with
  # their RECORD lines, so the same inputs give the same bytes.
  rm -rf "$tree/lib/site-packages/bin"
  for rec in "$tree"/lib/site-packages/*.dist-info/RECORD; do
    grep -v '^\.\./\.\./bin/' "$rec" >"$rec.new" || true
    mv "$rec.new" "$rec"
  done
  install -m 0644 "$work/requirements.txt" "$tree/lib/requirements.txt"
  # One line, relative to the interpreter's own site-packages, so `python3 -I` finds slim-bindings wherever the
  # tree is unpacked (python/lib/python3.13/site-packages -> ../../../../lib/site-packages).
  pydir="$(find "$tree/python/lib" -mindepth 1 -maxdepth 1 -type d -name 'python3.*' -printf '%f\n' | head -n1)"
  printf '../../../../lib/site-packages\n' >"$tree/python/lib/$pydir/site-packages/facilitator-bundle.pth"
  python_line="#!$PREFIX/python/bin/python3 -I"
else
  say "skeleton $version for linux-$arch (FACILITATOR_SKIP_DOWNLOADS: no interpreter, binaries or wheel; tests only)"
  python_line="#!/usr/bin/env -S python3 -I"
fi

# ---------------------------------------------------------------- the application and its libraries, from the source
for d in facilitator registerengine signpacket types.d agntcy; do mkdir -p "$tree/lib/$d"; done
for f in "$SOURCE"/facilitator/*.py; do install -m 0644 "$f" "$tree/lib/facilitator/"; done
for f in "$SOURCE"/registerengine/*.py; do install -m 0644 "$f" "$tree/lib/registerengine/"; done
for f in "$SOURCE"/signpacket/*.py; do install -m 0644 "$f" "$tree/lib/signpacket/"; done
install -m 0644 "$SOURCE/types.d/facilitator.py" "$tree/lib/types.d/facilitator.py"
install -m 0644 "$SOURCE"/agntcy/*.in "$tree/lib/agntcy/"
{ echo "$python_line"; tail -n +2 "$SOURCE/bin/facilitator"; } >"$tree/bin/facilitator"
chmod 0755 "$tree/bin/facilitator"

re_version="$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$SOURCE/registerengine/__init__.py")"
sp_version="$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$SOURCE/signpacket/__init__.py")"
commit="$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -z "$SKIP_DOWNLOADS" ]; then
  components="$(printf '    "python": {"version": "%s", "release": "%s", "url": "%s", "sha256": "%s"},\n    "dirctl": {"version": "%s", "url": "%s", "sha256": "%s"},\n    "slimctl": {"version": "%s", "url": "%s", "sha256": "%s"},\n    "slim-bindings": {"version": "%s", "url": "%s", "sha256": "%s"}' \
    "$PY_VERSION" "$PY_RELEASE" "$py_url" "$py_sha" "$DIR_VERSION" "$dir_url" "$dir_sha" \
    "$SLIM_VERSION" "$slim_url" "$slim_sha" "$SLIM_BINDINGS" "$wheel_url" "$wheel_sha")"
else
  components='    "skeleton": {"version": "none", "url": "", "sha256": ""}'
fi
cat >"$tree/MANIFEST.json" <<EOF
{
  "bundle": "facilitator",
  "version": "$version",
  "os": "linux",
  "arch": "$arch",
  "prefix": "$PREFIX",
  "source_commit": "$commit",
  "libraries": {"register-engine": "$re_version", "sign-packet": "$sp_version"},
  "components": {
$components
  }
}
EOF
chmod -R u+rwX,go+rX,go-w "$tree"

# ---------------------------------------------------------------- the tree in place, or the tarball and its SHA256SUMS line
if [ -n "$INSTALL_TO" ]; then
  mkdir -p "$(dirname "$INSTALL_TO")"
  rm -rf "$INSTALL_TO.new"
  mv "$tree" "$INSTALL_TO.new"
  rm -rf "$INSTALL_TO"
  mv "$INSTALL_TO.new" "$INSTALL_TO"
  say "$version (linux-$arch) built into $INSTALL_TO"
  exit 0
fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
asset="facilitator-$version-linux-$arch.tar.gz"
epoch="${SOURCE_DATE_EPOCH:-$(git -C "$SOURCE" log -1 --format=%ct 2>/dev/null || echo 0)}"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" --clamp-mtime --format=gnu \
  -C "$work" -cf - facilitator | gzip -n -6 >"$OUT/$asset.part"
mv "$OUT/$asset.part" "$OUT/$asset"
sum="$(cd "$OUT" && sha256sum "$asset")"
touch "$OUT/SHA256SUMS"
{ grep -v "  $asset\$" "$OUT/SHA256SUMS" || true; echo "$sum"; } | sort -k2 >"$OUT/SHA256SUMS.new"
mv "$OUT/SHA256SUMS.new" "$OUT/SHA256SUMS"
say "$OUT/$asset ($(du -h "$OUT/$asset" | cut -f1)); $sum"
