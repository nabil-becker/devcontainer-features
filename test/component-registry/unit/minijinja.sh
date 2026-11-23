# shellcheck shell=bash
# minijinja.sh: sourced by the Docker-free tests that render templates (component-registry 1.11.0,
# ADR-0077). need_minijinja <bin folder> puts minijinja-cli, at the version and sha256 the Feature's
# install.sh pins, into that folder: the one on PATH when it is that version (always so in CI, whose
# image installs the component-registry Feature, .devcontainer/ci), else, on a local run only, a
# cached copy, else one downloaded once (into a new, empty folder) and checked against the pinned
# sha256. In CI it never downloads: no pinned minijinja-cli on PATH is an error. Returns 1 and says
# why when it cannot (no network, an architecture without a static build).
need_minijinja() {
  local into="$1" inst ver sum arch cache asset dl
  inst="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/component-registry/install.sh"
  ver="$(sed -n 's/^MINIJINJA_VERSION=//p' "$inst")"
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 sum="$(sed -n 's/^MINIJINJA_SHA256_X86_64=//p' "$inst")" ;;
    aarch64 | arm64) arch=aarch64 sum="$(sed -n 's/^MINIJINJA_SHA256_AARCH64=//p' "$inst")" ;;
    *) echo "need_minijinja: no static minijinja-cli build for $(uname -m)" >&2; return 1 ;;
  esac
  mkdir -p "$into"
  if [ "$(minijinja-cli --version 2>/dev/null)" = "minijinja-cli $ver" ]; then
    cp "$(command -v minijinja-cli)" "$into/minijinja-cli"; return 0
  fi
  if [ -n "${CI:-}" ]; then
    echo "need_minijinja: CI has no minijinja-cli $ver on PATH (the CI image installs it with the component-registry Feature); not downloading" >&2
    return 1
  fi
  cache="${DCF_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dcf-test}/minijinja-cli-$ver-$arch"
  if [ ! -x "$cache" ]; then
    asset="minijinja-cli-$arch-unknown-linux-musl"
    dl="$(mktemp -d)"
    if ! curl -fsSL --retry 3 -o "$dl/$asset.tar.xz" "https://github.com/mitsuhiko/minijinja/releases/download/$ver/$asset.tar.xz"; then
      rm -rf "$dl"; echo "need_minijinja: could not download minijinja-cli $ver" >&2; return 1
    fi
    if ! echo "$sum  $dl/$asset.tar.xz" | sha256sum -c - >/dev/null; then
      rm -rf "$dl"; echo "need_minijinja: minijinja-cli $ver does not match its pinned sha256" >&2; return 1
    fi
    mkdir -p "$dl/x" "$(dirname "$cache")"
    tar -xJf "$dl/$asset.tar.xz" -C "$dl/x" && install -m 0755 "$dl/x/$asset/minijinja-cli" "$cache"
    rm -rf "$dl"
  fi
  cp "$cache" "$into/minijinja-cli"
}
