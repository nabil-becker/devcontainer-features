#!/usr/bin/env bash
# Pin a released facilitator node bundle: check each asset of the GitHub release facilitator-bundle-v<version>
# against its SHA256SUMS, the digest GitHub records for it and its build attestation, then add the lines to
# src/facilitator/digests.txt, rewrite the CHANGELOG line that says the bundle is unpinned, and re-render the
# README's "Changes" section. One implementation for `task bundle:pin` and the release-facilitator workflow.
#
#   pin-bundle.sh <version>                  checks the release on GitHub (needs gh, logged in)
#   pin-bundle.sh <version> --from-dir <dir> rehearsal: the assets and SHA256SUMS are in <dir>; only the
#                                            SHA256SUMS check runs (no release, no attestation yet). Never for a real pin.
# Nothing is committed; the caller does that. A digest already pinned for an asset must be the same one.
set -euo pipefail

usage() { echo "usage: pin-bundle.sh <bundle version> [--from-dir <dir>]" >&2; exit 2; }
[ $# -ge 1 ] || usage
v="$1"; shift
from=""
if [ "${1:-}" = "--from-dir" ]; then [ $# -eq 2 ] || usage; from="$2"; shift 2; fi
[ $# -eq 0 ] || usage
case "$v" in *[!0-9.]* | "") echo "pin-bundle: '$v' is not a version" >&2; exit 2 ;; esac

root="$(git rev-parse --show-toplevel)"
repo="${GITHUB_REPOSITORY:-nabil-becker/devcontainer-features}"
tag="facilitator-bundle-v$v"
digests="$root/src/facilitator/digests.txt"

work=""
if [ -n "$from" ]; then
  dir="$from"
else
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  dir="$work"
  gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --pattern "facilitator-$v-linux-*.tar.gz" --dir "$dir"
fi

[ "$(wc -l <"$dir/SHA256SUMS")" -eq 2 ] || { echo "pin-bundle: expected two lines in SHA256SUMS (amd64, arm64)" >&2; exit 1; }
(cd "$dir" && sha256sum -c SHA256SUMS)

while read -r sum name; do
  case "$name" in "facilitator-$v-linux-amd64.tar.gz" | "facilitator-$v-linux-arm64.tar.gz") ;; *)
    echo "pin-bundle: unexpected asset $name in SHA256SUMS" >&2; exit 1 ;;
  esac
  if [ -z "$from" ]; then
    api="$(gh api "repos/$repo/releases/tags/$tag" --jq ".assets[] | select(.name == \"$name\") | .digest")"
    [ "$api" = "sha256:$sum" ] || { echo "$name: SHA256SUMS says $sum, GitHub records $api" >&2; exit 1; }
    gh attestation verify "$dir/$name" --repo "$repo" >/dev/null
  fi
  have="$(awk -v n="$name" '$2 == n { print $1 }' "$digests")"
  if [ -z "$have" ]; then
    echo "$sum  $name" >>"$digests"
    echo "pinned $name $sum"
  elif [ "$have" = "$sum" ]; then
    echo "already pinned $name $sum"
  else
    echo "$name: digests.txt pins $have, this release has $sum; a pin is never replaced" >&2; exit 1
  fi
done <"$dir/SHA256SUMS"

# The CHANGELOG says the bundle is pinned, in the wording the earlier entries carry: a line that says it is
# unpinned is rewritten, and when there is none the line is added at the end of the Feature's current entry
# (the one for the version in devcontainer-feature.json). A line already in that form is left alone.
python3 -I - "$v" "$root/src/facilitator" <<'PY'
import json
import re
import sys

v, folder = sys.argv[1], sys.argv[2]
path = folder + "/CHANGELOG.md"
text = open(path, encoding="utf-8").read()
pinned = (f"- `bundleVersion` defaults to `{v}`: the Feature installs the published node bundle "
          f"`facilitator-bundle-v{v}`\n  (amd64 and arm64), pinned by SHA-256 in `digests.txt`.")
if f"`facilitator-bundle-v{v}`" in text and "pinned by SHA-256 in `digests.txt`" in text:
    print("CHANGELOG: already says the bundle is pinned")
    sys.exit(0)
unpinned = re.compile(r"^- `?bundleVersion`? defaults to `?" + re.escape(v) + r"`? \(unpinned[^\n]*\)\.?$", re.M)
new, n = unpinned.subn(lambda m: pinned, text, count=1)
if n == 0:
    fv = json.load(open(folder + "/devcontainer-feature.json", encoding="utf-8"))["version"]
    head = re.search(r"^## \[" + re.escape(fv) + r"\][^\n]*\n", text, re.M)
    if not head:
        print(f"CHANGELOG: no entry for Feature version {fv}; add the pinned line by hand", file=sys.stderr)
        sys.exit(1)
    nxt = re.search(r"^## \[", text[head.end():], re.M)
    end = head.end() + nxt.start() if nxt else len(text)
    new = text[:end].rstrip("\n") + "\n" + pinned + "\n" + ("\n" + text[end:] if nxt else "")
open(path, "w", encoding="utf-8").write(new)
print("CHANGELOG: now says the bundle is pinned")
PY

python3 -I "$root/.github/scripts/changelog.py" render
