#!/usr/bin/env bash
# registry-source-git: the component registry's `git` source. A layer is a git repository read
# at a branch, a tag or a commit; review and release are the repository owner's, the registry only
# pins what to read. Installed on PATH by the component-registry Feature; dcf-registry calls it.
#
#   registry-source-git fetch <layer> <dest> url=<url> (branch=|tag=|commit=)<ref> [path=<folder>] [auth.*=...]
#                                         the files at that ref into <dest> (no .git); with path=, only
#                                         that folder of the repository (1.12.0: a monorepo), its
#                                         contents as the layer root
#   registry-source-git version <layer> url=<url> (branch=|tag=|commit=)<ref> [auth.*=...]
#                                         the commit the ref names now (git ls-remote)
#   registry-source-git supports          the verbs it implements
#
# path=<folder> (optional): a folder of the repository, relative, no .. and not absolute. Only that
# folder is fetched (a blob-less partial fetch where the server allows it, else a full shallow
# fetch; either way only that folder is checked out) and its contents are copied to <dest>, so
# *.layer and @file are read as in a root layer. A folder missing at the ref is an error naming
# layer, ref and path. The version stays the commit: a change elsewhere in the repository is a new
# version too (the folder's tree hash would need the objects, i.e. a fetch, on every check).
#
# Log-in (optional): auth.secret=<name> is read with dcf-secret (the openbao Feature) and handed
# to git through the environment, never an argument: auth.type=basic (the default; auth.user,
# default git) or auth.type=bearer (an Authorization header). Without dcf-secret on PATH the
# source says so and goes on without a secret. git never prompts (GIT_TERMINAL_PROMPT=0).
#
# Exit: 0 done, 1 failed (unreachable, unknown ref, no git), 2 bad use, 3 not supported.
set -uo pipefail

die() { local rc="$1"; shift; printf 'registry-source-git: %s\n' "$*" >&2; exit "$rc"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  supports) printf 'fetch\nversion\nsupports\n'; exit 0 ;;
  fetch) [ $# -ge 2 ] || die 2 "usage: fetch <layer> <dest> url=<url> branch=|tag=|commit=<ref>"; layer="$1" dest="$2"; shift 2 ;;
  version) [ $# -ge 1 ] || die 2 "usage: version <layer> url=<url> branch=|tag=|commit=<ref>"; layer="$1"; shift ;;
  '') die 2 "usage: registry-source-git fetch|version|supports ..." ;;
  *) die 3 "verb '$verb' is not supported (fetch, version, supports)" ;;
esac

url='' reftype='' ref='' atype=basic auser=git asecret='' fpath=''
for kv in "$@"; do
  case "$kv" in
    url=*) url="${kv#url=}" ;;
    branch=* | tag=* | commit=*)
      [ -z "$reftype" ] || die 2 "layer $layer: give exactly one of branch, tag, commit"
      reftype="${kv%%=*}" ref="${kv#*=}" ;;
    path=*) fpath="${kv#path=}" ;;
    auth.type=*) atype="${kv#auth.type=}" ;;
    auth.user=*) auser="${kv#auth.user=}" ;;
    auth.secret=*) asecret="${kv#auth.secret=}" ;;
    *) die 2 "layer $layer: unknown setting '${kv%%=*}' (url, branch, tag, commit, path, auth.type, auth.user, auth.secret)" ;;
  esac
done
[ -n "$url" ] || die 2 "layer $layer: a git source needs url"
[ -n "$reftype" ] && [ -n "$ref" ] || die 2 "layer $layer: a git source needs one of branch, tag, commit"
case "$atype" in basic | bearer) ;; *) die 2 "layer $layer: auth.type is basic or bearer" ;; esac
[ "$reftype" != commit ] || [[ "$ref" =~ ^[0-9a-f]{7,64}$ ]] || die 2 "layer $layer: commit '$ref' is not a commit id"
if [ -n "$fpath" ]; then
  fpath="${fpath#./}"; fpath="${fpath%/}"
  case "/$fpath/" in
    //* | */../* | *\\* | */./*) die 2 "layer $layer: path '$fpath' must be a relative folder without .. (a folder of the repository)" ;;
  esac
  [ -n "$fpath" ] && [ "${fpath:0:1}" != / ] || die 2 "layer $layer: path must be a relative folder of the repository"
fi
command -v git >/dev/null 2>&1 || die 1 "layer $layer: git is not installed (add the git Feature or a base image with git)"

export GIT_TERMINAL_PROMPT=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The secret goes to git through the environment only: GIT_ASKPASS reads it for basic, the
# GIT_CONFIG_* variables carry the header for bearer.
if [ -n "$asecret" ]; then
  if ! command -v dcf-secret >/dev/null 2>&1; then
    echo "registry-source-git: layer $layer: auth.secret is set but dcf-secret (the openbao Feature) is not installed; reading without a secret" >&2
  else
    token="$(dcf-secret get "$asecret")" || die 1 "layer $layer: dcf-secret could not read $asecret (exit $?)"
    export REGISTRY_SOURCE_GIT_TOKEN="$token" REGISTRY_SOURCE_GIT_USER="$auser"
    if [ "$atype" = basic ]; then
      # shellcheck disable=SC2016  # the askpass script expands them when git runs it
      printf '#!/bin/sh\ncase "$1" in Username*) printf "%%s\\n" "$REGISTRY_SOURCE_GIT_USER" ;; *) printf "%%s\\n" "$REGISTRY_SOURCE_GIT_TOKEN" ;; esac\n' > "$tmp/askpass"
      chmod 700 "$tmp/askpass"
      export GIT_ASKPASS="$tmp/askpass"
    else
      export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Bearer $token"
    fi
    unset token
  fi
fi

# remote_commit: the commit the pinned ref names at the remote
remote_commit() {
  local out sha
  case "$reftype" in
    commit) printf '%s\n' "$ref"; return 0 ;;
    branch) out="$(git ls-remote "$url" "refs/heads/$ref" 2>"$tmp/err")" || return 1 ;;
    tag) out="$(git ls-remote "$url" "refs/tags/$ref" "refs/tags/$ref^{}" 2>"$tmp/err")" || return 1 ;;
  esac
  # An annotated tag lists its object and, with ^{}, the commit; the commit is the one to keep.
  sha="$(printf '%s\n' "$out" | awk '$2 ~ /\^\{\}$/ { p = $1 } { if (f == "") f = $1 } END { print (p != "" ? p : f) }')"
  [ -n "$sha" ] || { echo "no $reftype $ref at $url" > "$tmp/err"; return 1; }
  printf '%s\n' "$sha"
}

case "$verb" in
  version)
    remote_commit || die 1 "layer $layer: cannot read $reftype $ref: $(grep -m 1 . "$tmp/err")" ;;
  fetch)
    [ -d "$dest" ] || die 2 "layer $layer: the destination $dest is not a folder"
    git init -q "$tmp/repo" || die 1 "layer $layer: git init failed"
    case "$reftype" in
      branch) want="refs/heads/$ref" ;;
      tag) want="refs/tags/$ref" ;;
      commit) want="$ref" ;;
    esac
    filt=()
    [ -z "$fpath" ] || filt=(--filter=blob:none)
    if ! git -C "$tmp/repo" fetch -q --depth 1 "${filt[@]}" "$url" "$want" 2>"$tmp/err" &&
      ! { [ -n "$fpath" ] && git -C "$tmp/repo" fetch -q --depth 1 "$url" "$want" 2>"$tmp/err"; }; then
      # A server that refuses a commit by id in a shallow fetch: fetch everything, then pick it.
      if [ "$reftype" != commit ] || ! git -C "$tmp/repo" fetch -q "$url" '+refs/heads/*:refs/remotes/r/*' '+refs/tags/*:refs/tags/*' 2>>"$tmp/err"; then
        die 1 "layer $layer: cannot fetch $reftype $ref from $url: $(grep -m 1 . "$tmp/err")"
      fi
      want="$ref"
    else
      want=FETCH_HEAD
    fi
    if [ -n "$fpath" ]; then
      [ "$(git -C "$tmp/repo" cat-file -t "$want:$fpath" 2>/dev/null)" = tree ] ||
        die 1 "layer $layer: $reftype $ref of $url has no folder '$fpath'"
      git -C "$tmp/repo" -c advice.detachedHead=false checkout -q "$want" -- "$fpath" 2>"$tmp/err" ||
        die 1 "layer $layer: cannot check out $fpath at $reftype $ref: $(grep -m 1 . "$tmp/err")"
      src="$tmp/repo/$fpath"
    else
      git -C "$tmp/repo" -c advice.detachedHead=false checkout -q "$want" 2>"$tmp/err" ||
        die 1 "layer $layer: cannot check out $reftype $ref: $(grep -m 1 . "$tmp/err")"
      src="$tmp/repo"
    fi
    rm -rf "$tmp/repo/.git"
    cp -R "$src/." "$dest/" || die 1 "layer $layer: could not copy the files into $dest" ;;
esac
exit 0
