#!/usr/bin/env bash
# The facilitator node bundle's build script (proposal facilitator-node, section 6.1; ADR-0067). One portable
# script, with no devcontainer assumptions: it needs bash, curl, tar, gzip and sha256sum, never root, and
# writes nothing outside its work folder and its output. It builds, for one architecture:
#
#   facilitator/                       the tree, installed at /opt/facilitator (the fixed prefix in bin/facilitator)
#     bin/facilitator                  the command (its first line names python/bin/python3 -I)
#     bin/dirctl  bin/slimctl          the AGNTCY Directory CLI and daemon, and slimctl (carries the SLIM node)
#     python/                          python-build-standalone, unchanged but for one .pth line naming lib/site-packages
#     lib/site-packages/               slim-bindings, and the `mcp` library with its 27 dependencies (the `http` module,
#                                      slice N4), each from its hashed wheel (pip --require-hashes, no index)
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
# mcp 2.3.0 (MIT) and the 27 wheels `pip download mcp==2.3.0` resolved for CPython 3.13 on 2026-11-23: PyPI's sha256 and
#   URL for each (pypi.org/pypi/<name>/<version>/json). Pure wheels are the same on both architectures ("any"); the
#   four with native code (cffi, cryptography, pydantic_core, rpds_py) have one wheel per architecture, the oldest
#   manylinux tag PyPI offers (2014 or 2_17: under the bundle's glibc floor). To move to another mcp version or to
#   check this table: task bundle:mcp-wheels (bundles/facilitator/mcp-wheels.py); an unlisted wheel is never fetched.
HTTP_WHEELS="$(cat <<'WHEELS'
any|annotated_types-0.8.0-py3-none-any.whl|f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0|https://files.pythonhosted.org/packages/99/91/8acff4f5e50511b911bbccb72b8628a49c68ce14148cd9f6431094859a90/annotated_types-0.8.0-py3-none-any.whl
any|anyio-4.16.0-py3-none-any.whl|c66ae634e0b8228396b801741beb3294326d4b6102f7bba4041c0dfb58c29026|https://files.pythonhosted.org/packages/a9/16/7757fb84c819accc7d7e9af5291b261e4abb8627ee040f99e7d35ef2457a/anyio-4.16.0-py3-none-any.whl
any|attrs-26.1.0-py3-none-any.whl|c647aa4a12dfbad9333ca4e71fe62ddc36f4e63b2d260a37a8b83d2f043ac309|https://files.pythonhosted.org/packages/64/b4/17d4b0b2a2dc85a6df63d1157e028ed19f90d4cd97c36717afef2bc2f395/attrs-26.1.0-py3-none-any.whl
x86_64|cffi-2.1.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|a931079504ecc49efed7744c476a5c343a92fabf66dec2db95edb1b2fdc770e2|https://files.pythonhosted.org/packages/95/95/86342356ff5953b3fb06f7ef7c5bee212d45e770abc7218d451b9148313c/cffi-2.1.1-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
aarch64|cffi-2.1.1-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl|f16c709686a78c727bbbf059f92b0bf41c6fc60deec706d2dc19f529175a6125|https://files.pythonhosted.org/packages/37/6f/3b5ce4c3b2192d250f04908f2bfd91ef34552ec8f7716a5d4abdb8d67bb2/cffi-2.1.1-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl
any|click-8.5.1-py3-none-any.whl|8bb5376d2006950386f8c6427613334a2acadc5f559cb80e638d00b4df957e37|https://files.pythonhosted.org/packages/31/7d/164b7ffc8624fe9efb4221bf9af485d5c1e41b9ae118045d2b6dc5457d8b/click-8.5.1-py3-none-any.whl
x86_64|cryptography-50.0.2-cp311-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|630ebfea3bf689d075f82316324ff7433dc447fe6bc1bfc76524b74b4a9567d2|https://files.pythonhosted.org/packages/21/69/64cef1f702bf6657e0cc186ed1a2891d50d29fb41586b254e1c07adea261/cryptography-50.0.2-cp311-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
aarch64|cryptography-50.0.2-cp311-abi3-manylinux2014_aarch64.manylinux_2_17_aarch64.whl|79def8d059362e7831389ed3be0ecdf58a89386e1271e35dd9f5af84e81bffd0|https://files.pythonhosted.org/packages/d9/69/c9bd862c3bf43d6399c433caf002df16e2dffd4be49bdf515cda38038711/cryptography-50.0.2-cp311-abi3-manylinux2014_aarch64.manylinux_2_17_aarch64.whl
any|h11-0.16.0-py3-none-any.whl|63cf8bbe7522de3bf65932fda1d9c2772064ffb3dae62d55932da54b31cb6c86|https://files.pythonhosted.org/packages/04/4b/29cac41a4d98d144bf5f6d33995617b185d14b22401f75ca86f384e87ff1/h11-0.16.0-py3-none-any.whl
any|httpcore2-2.16.2-py3-none-any.whl|16051ae2a42f776007543f32de9349a317b23d2cbb4e1456b4bac0e88b87419a|https://files.pythonhosted.org/packages/2a/e8/009c347feac27f8960605aa98d55ed263b5870dd4fd80b82fd1d00d5716c/httpcore2-2.16.2-py3-none-any.whl
any|httpx2-2.16.2-py3-none-any.whl|f05c13aade4c45dbf1c9060647a1058f0acad62398fad96e741269edb33d46f5|https://files.pythonhosted.org/packages/77/de/8c4306a3d6aa2495111986addf33a9e561eff4c47552e4c4b9251160d0ad/httpx2-2.16.2-py3-none-any.whl
any|idna-3.20-py3-none-any.whl|ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c|https://files.pythonhosted.org/packages/58/a2/bb081bab032533a855d44de1d56f8e8426114ff1ba5d1f07a438a0a654f8/idna-3.20-py3-none-any.whl
any|jsonschema-4.26.0-py3-none-any.whl|d489f15263b8d200f8387e64b4c3a75f06629559fb73deb8fdfb525f2dab50ce|https://files.pythonhosted.org/packages/69/90/f63fb5873511e014207a475e2bb4e8b2e570d655b00ac19a9a0ca0a385ee/jsonschema-4.26.0-py3-none-any.whl
any|jsonschema_specifications-2025.9.1-py3-none-any.whl|98802fee3a11ee76ecaca44429fda8a41bff98b00a0f2838151b113f210cc6fe|https://files.pythonhosted.org/packages/41/45/1a4ed80516f02155c51f51e8cedb3c1902296743db0bbc66608a0db2814f/jsonschema_specifications-2025.9.1-py3-none-any.whl
any|mcp-2.3.0-py3-none-any.whl|dd0c44c089d16453e8ae31a3877a0054d7a2314caaa81f5e0541b9b1734b2377|https://files.pythonhosted.org/packages/20/d7/4a2878f128df729db3ca04e71bfce26405cc2e0c9ebe19c592feeb4c61b9/mcp-2.3.0-py3-none-any.whl
any|mcp_types-2.3.0-py3-none-any.whl|968efdbdaedfab06adae40d378a34395f1090c5921d4be3c9cde283aaf76d91d|https://files.pythonhosted.org/packages/ce/48/32583066b155bb5d4507e7887dc88ee23118cc4de8e2a12870c49719e2a8/mcp_types-2.3.0-py3-none-any.whl
any|opentelemetry_api-1.45.2-py3-none-any.whl|2cbd737377e710ee740d261c94e93fa0f08e6d037c18f17513cc0a2d94479a34|https://files.pythonhosted.org/packages/a9/2d/610db864d7513158cebb8f36cc88e67e73bd6c7aa1905ef18d89e1281c81/opentelemetry_api-1.45.2-py3-none-any.whl
any|pycparser-3.12-py3-none-any.whl|a076f3f489b39b43ed13563a1dafe42447445bec2e294154ec5c57fcdda4c85e|https://files.pythonhosted.org/packages/b6/ae/315bbeee126a769cbde43cf4908acb4b40408d8bf8bbf334dd7368d8dadf/pycparser-3.12-py3-none-any.whl
any|pydantic-2.14.4-py3-none-any.whl|653a2ad9f6d8858529c77c72717d0ea991d6c6837fe683246b2f4b2bbfc3fadc|https://files.pythonhosted.org/packages/8a/8c/824a686c4ba815ddb0722f9e66272088bccd4e1ae1d2f7015375e4a4fc7f/pydantic-2.14.4-py3-none-any.whl
x86_64|pydantic_core-2.50.5-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl|cbfde3ad127786f1dea1a6cd89a5eb824a16203f24743ad2b4e07506f43bc844|https://files.pythonhosted.org/packages/13/c2/62015187d0e986dafc530ea4df390fce3d3379c744959148806668d40ab9/pydantic_core-2.50.5-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl
aarch64|pydantic_core-2.50.5-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl|8bbe282e79dc71b24ba7be284eacf27c8ddff8f26911e2030a0dd123c6aed326|https://files.pythonhosted.org/packages/e8/35/70928b77f724fa0f4824e0527891df02cf9b34101aab6e2ab348fd127f06/pydantic_core-2.50.5-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl
any|pyjwt-2.15.1-py3-none-any.whl|42d59d631f7768a1028a64c7ff581a9bf7519804daf91fc5b6c56e30eec5e193|https://files.pythonhosted.org/packages/50/ca/44de4e75f8aadc457f0634be3b542815078ded46dca30efb960edeecad6e/pyjwt-2.15.1-py3-none-any.whl
any|python_multipart-0.0.34-py3-none-any.whl|ebacd224bd686eee2f9aa1066a657affe07435a185834e05e5235e2e59173e91|https://files.pythonhosted.org/packages/f5/0e/090c52b122d8ec5fa37942c1410fea9cf04ce98bca0c84dde7f0aa11594d/python_multipart-0.0.34-py3-none-any.whl
any|referencing-0.37.0-py3-none-any.whl|381329a9f99628c9069361716891d34ad94af76e461dcb0335825aecc7692231|https://files.pythonhosted.org/packages/2c/58/ca301544e1fa93ed4f80d724bf5b194f6e4b945841c5bfd555878eea9fcb/referencing-0.37.0-py3-none-any.whl
x86_64|rpds_py-2026.9.1-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl|7868b85224291c6cb6759f9b5adb9745f486d226f62b16a614dd5a2a5ab2b35b|https://files.pythonhosted.org/packages/a0/36/76fab39973ee11e7f9f357c55138197bb01c86f6502cb76487e3b4f42db0/rpds_py-2026.9.1-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
aarch64|rpds_py-2026.9.1-cp313-cp313-manylinux_2_17_aarch64.manylinux2014_aarch64.whl|457866b85daf5034296666168b84a69e0b2e89dc4f1af102b46f6448a60b9063|https://files.pythonhosted.org/packages/bd/b7/497e85768bf4e0d8ddbaa096a4cac31d1509251dee2728a8490aa367e0b5/rpds_py-2026.9.1-cp313-cp313-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
any|sse_starlette-3.7.1-py3-none-any.whl|c1bb3af0508c6c24cd4ab6257047654bbec01456a424bed36b36e8020cd7a37f|https://files.pythonhosted.org/packages/78/4d/6b0380b7dbb965b84c3368c0bfd85aa6ba1b9b825e9b8f42b8643efbab11/sse_starlette-3.7.1-py3-none-any.whl
any|starlette-1.10.0-py3-none-any.whl|478c0ab3b4ced6e82719849c118fa406f0278a3499c1a898cd15cd31bdc38ce4|https://files.pythonhosted.org/packages/88/2e/947cfe02def9371c07cd5bf5b6b61c829e9aecb9904db02a66cfafbc1eec/starlette-1.10.0-py3-none-any.whl
any|truststore-0.10.5-py3-none-any.whl|9aaaedaefaf06d8b206278cf8b5012bc897f485a874503501e12d776df78951c|https://files.pythonhosted.org/packages/51/e9/3a7820be2bb0fe53b6bc9c3be26d3d1158004e4c3ab953aa6840b955b1e9/truststore-0.10.5-py3-none-any.whl
any|typing_extensions-4.16.0-py3-none-any.whl|481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8|https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl
any|typing_inspection-0.4.5-py3-none-any.whl|bc210535442b39e1bf2805e0c7a17dfd6a4ace760c84c7f7d16245d23a6b1c39|https://files.pythonhosted.org/packages/de/0c/ea2544850a7c135e15033a5c7a8e7211136184b7ae63e2239d557c2b3019/typing_inspection-0.4.5-py3-none-any.whl
any|uvicorn-0.54.0-py3-none-any.whl|505bdb0f318731d45f1f712071fc781a8981f6847a31c902c9f5e652d4f67faf|https://files.pythonhosted.org/packages/38/0c/b54a4fdd7f90a3af8b02ebc9ce6712c2c208b7926a2f7bad95c33ebbe943/uvicorn-0.54.0-py3-none-any.whl
WHEELS
)"
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
  say "building $version for linux-$arch: CPython $PY_VERSION, dirctl $DIR_VERSION, slimctl $SLIM_VERSION, slim-bindings $SLIM_BINDINGS, mcp 2.3.0 (28 wheels)"
  fetch "$py_url" "$py_asset" "$py_sha"
  fetch "$dir_url" "$dir_asset" "$dir_sha"
  fetch "$slim_url" "$slim_asset" "$slim_sha"
  fetch "$wheel_url" "$wheel_asset" "$wheel_sha"
  http_req="$work/requirements-http.txt"
  : >"$http_req"
  http_count=0
  while IFS='|' read -r w_arch w_file w_sha w_url; do
    [ -n "$w_file" ] || continue
    case "$w_arch" in any | "$march") ;; *) continue ;; esac
    fetch "$w_url" "$w_file" "$w_sha"
    printf '%s==%s --hash=sha256:%s\n' "${w_file%%-*}" "$(printf '%s' "$w_file" | cut -d- -f2)" "$w_sha" >>"$http_req"
    http_count=$((http_count + 1))
  done <<<"$HTTP_WHEELS"
  [ "$http_count" -ge 28 ] || die "the mcp wheel table gave only $http_count wheels for $arch"
  http_sha="$(sort "$http_req" | sha256sum | cut -d' ' -f1)"

  tar -xzf "$dl/$py_asset" -C "$tree" --no-same-owner
  [ -x "$tree/python/bin/python3" ] || die "no python/bin/python3 in $py_asset"
  install -m 0755 "$dl/$dir_asset" "$tree/bin/dirctl"
  mkdir -p "$work/slim"
  tar -xzf "$dl/$slim_asset" -C "$work/slim" --no-same-owner
  slimctl_file="$(find "$work/slim" -type f -name slimctl | head -n1)"
  [ -n "$slimctl_file" ] || die "no slimctl in $slim_asset"
  install -m 0755 "$slimctl_file" "$tree/bin/slimctl"

  # slim-bindings and the mcp wheels into lib/site-packages, by hash, with no index. The bundle's own interpreter installs it when
  # it runs here (a native build); otherwise (a cross build) the build host's python3 does, for the target's
  # platform tag. The wheel is pure Python plus one shared library, so both give the same files. -B: nothing
  # compiled into the interpreter's own tree at build time.
  printf 'slim-bindings==%s --hash=sha256:%s\n' "$SLIM_BINDINGS" "$wheel_sha" >"$work/requirements.txt"
  cat "$http_req" >>"$work/requirements.txt"
  pip_args=(install --quiet --disable-pip-version-check --no-index --no-deps --require-hashes --no-compile
    --find-links "$dl" --target "$tree/lib/site-packages" -r "$work/requirements.txt")
  if "$tree/python/bin/python3" -I -B -c "import sys" >/dev/null 2>&1; then
    "$tree/python/bin/python3" -I -B -m pip "${pip_args[@]}"
  else
    command -v python3 >/dev/null 2>&1 || die "a cross build ($arch on $(uname -m)) needs python3 with pip on the build host"
    say "cross build: slim-bindings and mcp installed by the build host's python3 for manylinux_2_28 (and the older 2_17 and 2014 tags mcp's wheels carry) $march"
    python3 -I -B -m pip "${pip_args[@]}" --platform "manylinux_2_28_$march" --platform "manylinux_2_17_$march" \
      --platform "manylinux2014_$march" --implementation cp --python-version "${PY_VERSION%.*}" --only-binary=:all:
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
  components="$(printf '    "python": {"version": "%s", "release": "%s", "url": "%s", "sha256": "%s"},\n    "dirctl": {"version": "%s", "url": "%s", "sha256": "%s"},\n    "slimctl": {"version": "%s", "url": "%s", "sha256": "%s"},\n    "slim-bindings": {"version": "%s", "url": "%s", "sha256": "%s"},\n    "mcp": {"version": "2.3.0", "wheels": %s, "requirements_sha256": "%s"}' \
    "$PY_VERSION" "$PY_RELEASE" "$py_url" "$py_sha" "$DIR_VERSION" "$dir_url" "$dir_sha" \
    "$SLIM_VERSION" "$slim_url" "$slim_sha" "$SLIM_BINDINGS" "$wheel_url" "$wheel_sha" "$http_count" "$http_sha")"
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
