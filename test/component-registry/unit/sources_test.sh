#!/usr/bin/env bash
# Docker-free, network-free tests of release 2.2.0: a folder of a git repository as a layer (git
# source `path`: good, nested, missing, a file, `..`, absolute) and an http source that is an
# archive (archive tar.gz | tgz | zip; sha256 pin match and mismatch, path inside the archive, the
# unsafe entries refused (absolute, .., symlink, hardlink, device), the size cap, plain http
# unchanged), and the layer list's checks for both. Fixtures: a local git repository, a local
# http server on 127.0.0.1 serving a folder of generated archives. Part of
# `task test:component-registry-unit`.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v git >/dev/null; then echo "skip - python3, curl and git are needed"; exit 0; fi

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
srv_pid=''
trap '[ -z "$srv_pid" ] || kill "$srv_pid" 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

export CLAUDE_CONFIG_DIR="$T/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email test@example.invalid; git config --global user.name test
git config --global init.defaultBranch main
bin="$T/bin"; mkdir -p "$bin" "$T/share"
for f in dcf-registry registry-source-http registry-source-path registry-source-git; do cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"; done
cp "$src/dcf-curl.sh" "$T/share/dcf-curl.sh"
export PATH="$bin:$PATH" COMPONENT_REGISTRY_SHARE_DIR="$T/share" REGISTRY_SOURCE_HTTP_MAX_TIME=10

# ------------------------------------------------------------------ git path ----
G="$T/mono"; mkdir -p "$G/registry/corp/skills-files" "$G/registry/other" "$G/elsewhere"
printf '[skills/mono]\nbody:text = @file skills-files/m.md\n' > "$G/registry/corp/corp.layer"
printf 'from the monorepo folder\n' > "$G/registry/corp/skills-files/m.md"
printf '[skills/other]\nbody:text = other\n' > "$G/registry/other/other.layer"
printf 'noise\n' > "$G/elsewhere/n.txt"; printf 'top\n' > "$G/top.txt"
git -C "$G" init -q && git -C "$G" add -A && git -C "$G" commit -qm one
sg=registry-source-git
lsd() { find "$T/d" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort; }
gf() { rm -rf "$T/d"; mkdir "$T/d"; $sg fetch mono "$T/d" "url=$G" "$@" >"$T/out" 2>"$T/err"; }
gf branch=main path=registry/corp; check "git path: fetched (exit 0)" 0 $?
check "git path: the folder's contents are the layer root" "corp.layer skills-files" "$(lsd | tr '\n' ' ' | sed 's/ $//')"
check "git path: @file siblings come with it" "from the monorepo folder" "$(head -n 1 "$T/d/skills-files/m.md")"
check "git path: nothing from outside the folder" "" "$(lsd | grep -E 'top|elsewhere|other')"
gf branch=main path=registry/corp/; check "git path: a trailing slash is fine" 0 $?
gf branch=main path=./registry/other; check "git path: a leading ./ is fine" 0 $?
check "git path: the other folder" "other.layer" "$(lsd)"
gf branch=main path=registry/nosuch; check "git path: a missing folder: exit 1" 1 $?
contains "git path: the error names layer, ref and path" "$(cat "$T/err")" "layer mono: branch main of $G has no folder 'registry/nosuch'"
gf branch=main path=top.txt; check "git path: a file is not a folder: exit 1" 1 $?
gf branch=main path=../x; check "git path: .. refused: exit 2" 2 $?
gf branch=main path=registry/../..; check "git path: .. inside refused: exit 2" 2 $?
gf branch=main path=/etc; check "git path: absolute refused: exit 2" 2 $?
gf branch=main 'path=a\b'; check "git path: a backslash refused: exit 2" 2 $?
git -C "$G" tag v1
gf tag=v1 path=registry/corp; check "git path: at a tag" 0 $?
c1="$(git -C "$G" rev-parse HEAD)"
gf commit="$c1" path=registry/corp; check "git path: at a commit" 0 $?
check "git path: version is the commit" "$c1" "$($sg version mono "url=$G" branch=main path=registry/corp)"
gf branch=main; check "git without path: the whole repository, as before" "elsewhere registry top.txt" "$(lsd | tr '\n' ' ' | sed 's/ $//')"

# ------------------------------------------------------------------ archives ----
W="$T/www"; mkdir -p "$W"
python3 -I - "$W" <<'PY'
import io, os, sys, tarfile, zipfile
w = sys.argv[1]
LAYER = b"[skills/rel]\nbody:text = @file s/body.md\n"
def tar(name, entries):
    with tarfile.open(os.path.join(w, name), "w:gz") as t:
        for e in entries:
            kind, n = e[0], e[1]
            ti = tarfile.TarInfo(n)
            if kind == "f":
                ti.size = len(e[2]); t.addfile(ti, io.BytesIO(e[2]))
            elif kind == "d":
                ti.type = tarfile.DIRTYPE; t.addfile(ti)
            elif kind == "l":
                ti.type = tarfile.SYMTYPE; ti.linkname = e[2]; t.addfile(ti)
            elif kind == "h":
                ti.type = tarfile.LNKTYPE; ti.linkname = e[2]; t.addfile(ti)
            elif kind == "dev":
                ti.type = tarfile.CHRTYPE; ti.devmajor = 1; ti.devminor = 3; t.addfile(ti)
good = [("d", "pkg"), ("f", "pkg/registry.layer", LAYER), ("d", "pkg/s"), ("f", "pkg/s/body.md", b"from the archive\n"),
        ("f", "pkg/other.txt", b"x")]
tar("good.tar.gz", good)
tar("good.tgz", good)
tar("flat.tar.gz", [("f", "registry.layer", LAYER), ("d", "s"), ("f", "s/body.md", b"flat\n")])
tar("inside-link.tar.gz", [("f", "a.layer", LAYER), ("d", "s"), ("f", "s/body.md", b"x"), ("l", "s/alias.md", "body.md")])
tar("abs.tar.gz", [("f", "/etc/evil.layer", b"x")])
tar("dotdot.tar.gz", [("f", "a/../../evil.layer", b"x")])
tar("symlink-abs.tar.gz", [("l", "link", "/etc/passwd")])
tar("symlink-up.tar.gz", [("l", "link", "../../etc")])
tar("hardlink.tar.gz", [("f", "a", b"x"), ("h", "b", "/etc/passwd")])
tar("device.tar.gz", [("dev", "null")])
tar("big.tar.gz", [("f", "big.layer", b"0" * 3000)])
with zipfile.ZipFile(os.path.join(w, "good.zip"), "w") as z:
    z.writestr("pkg/registry.layer", LAYER); z.writestr("pkg/s/body.md", "from the zip\n")
with zipfile.ZipFile(os.path.join(w, "dotdot.zip"), "w") as z:
    z.writestr("a/../../evil.layer", "x")
with zipfile.ZipFile(os.path.join(w, "abs.zip"), "w") as z:
    z.writestr("/evil.layer", "x")
with zipfile.ZipFile(os.path.join(w, "symlink.zip"), "w") as z:
    zi = zipfile.ZipInfo("link"); zi.create_system = 3; zi.external_attr = (0o120777 << 16)
    z.writestr(zi, "body.md")
open(os.path.join(w, "plain.layer"), "w").write("[skills/plain]\nbody:text = plain http\n")
PY
cat > "$T/server.py" <<'PY'
import http.server, os, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def __init__(self, *a, **k): super().__init__(*a, directory=sys.argv[1], **k)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 -I "$T/server.py" "$W" > "$T/port" 2>/dev/null &
srv_pid=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(cat "$T/port")"
sh=registry-source-http
hf() { rm -rf "$T/d"; mkdir "$T/d"; $sh fetch rel "$T/d" "$@" >"$T/out" 2>"$T/err"; }
sum() { sha256sum "$W/$1" | cut -d' ' -f1; }

hf "url=$base/plain.layer"; check "plain http unchanged: one .layer file saved by its name" "plain.layer" "$(lsd)"
hf "url=$base/good.tar.gz"; check "an archive URL without archive: still refused (exit 1)" 1 $?
contains "an archive URL without archive: says to set archive" "$(cat "$T/err")" "set archive: tar.gz"
hf "url=$base/good.tar.gz" archive=tar.gz; check "tar.gz: fetched" 0 $?
check "tar.gz: the archive's top level is the root" "pkg" "$(lsd)"
hf "url=$base/good.tar.gz" archive=tar.gz path=pkg; check "tar.gz path: fetched" 0 $?
check "tar.gz path: the folder's contents are the root" "other.txt registry.layer s" "$(lsd | tr '\n' ' ' | sed 's/ $//')"
check "tar.gz path: @file siblings come with it" "from the archive" "$(head -n 1 "$T/d/s/body.md")"
hf "url=$base/good.tgz" archive=tgz path=pkg/; check "tgz is accepted" 0 $?
hf "url=$base/flat.tar.gz" archive=tar.gz; check "tar.gz without path: a flat archive" "registry.layer s" "$(lsd | tr '\n' ' ' | sed 's/ $//')"
hf "url=$base/inside-link.tar.gz" archive=tar.gz; check "a symlink that stays inside is accepted" 0 $?
hf "url=$base/good.tar.gz" archive=tar.gz path=nosuch; check "path missing in the archive: exit 1" 1 $?
contains "path missing: named" "$(cat "$T/err")" "layer rel: $base/good.tar.gz has no folder 'nosuch' inside the archive"
check "path missing: nothing written" "" "$(lsd)"
hf "url=$base/good.tar.gz" archive=tar.gz path=../x; check "archive path ..: exit 2" 2 $?
hf "url=$base/good.tar.gz" archive=tar.gz path=/etc; check "archive path absolute: exit 2" 2 $?
hf "url=$base/good.tar.gz" archive=tar.gz path=pkg/registry.layer; check "archive path a file: exit 1" 1 $?
# sha256
good_sum="$(sum good.tar.gz)"
hf "url=$base/good.tar.gz" archive=tar.gz "sha256=$good_sum" path=pkg; check "sha256 match: fetched" 0 $?
hf "url=$base/good.tar.gz" archive=tar.gz "sha256=$(printf '%064d' 0)" path=pkg; check "sha256 mismatch: exit 1" 1 $?
contains "sha256 mismatch: says so and that nothing was replaced" "$(cat "$T/err")" "does not match its sha256"
check "sha256 mismatch: nothing written" "" "$(lsd)"
hf "url=$base/good.tar.gz" archive=tar.gz sha256=abc; check "sha256 not 64 hex: exit 2" 2 $?
check "version with sha256: that hash, no request" "sha256:$good_sum" "$($sh version rel "url=http://127.0.0.1:1/none.tar.gz" archive=tar.gz "sha256=$good_sum")"
case "$($sh version rel "url=$base/good.tar.gz" archive=tar.gz)" in modified:* | sha256:* | etag:*) v=ok ;; *) v=bad ;; esac
check "version without sha256: a validator or the archive's hash" ok "$v"
hf "url=$base/plain.layer" sha256="$good_sum"; check "sha256 on a plain http source: exit 2" 2 $?
hf "url=$base/plain.layer" path=x; check "path on a plain http source: exit 2" 2 $?
hf "url=$base/good.tar.gz" archive=rar; check "an unknown archive kind: exit 2" 2 $?
# zip
if command -v unzip >/dev/null 2>&1; then
  hf "url=$base/good.zip" archive=zip path=pkg; check "zip: fetched" 0 $?
  check "zip: the folder's contents are the root" "registry.layer s" "$(lsd | tr '\n' ' ' | sed 's/ $//')"
  hf "url=$base/symlink.zip" archive=zip; check "zip with a symlink: refused" 1 $?
  hf "url=$base/dotdot.zip" archive=zip; check "zip with ..: refused" 1 $?
  hf "url=$base/abs.zip" archive=zip; check "zip with an absolute name: refused" 1 $?
else
  echo "skip - unzip is not installed"
fi
# without unzip the zip is refused saying so
nz="$T/nounzip"; mkdir "$nz"; for t in bash env cat sed grep awk tar gzip curl sha256sum cut mktemp rm mkdir wc tr sort head tail find du readlink cp ls dirname basename date id python3 git; do p="$(command -v "$t")" && ln -s "$p" "$nz/$t"; done
rm -rf "$T/d"; mkdir "$T/d"
PATH="$nz" "$bin/registry-source-http" fetch rel "$T/d" "url=$base/good.zip" archive=zip >"$T/out" 2>"$T/err"; check "zip without unzip: exit 1" 1 $?
contains "zip without unzip: says so" "$(cat "$T/err")" "unzip is not installed"
# unsafe entries
for f in abs dotdot; do
  hf "url=$base/$f.tar.gz" archive=tar.gz; check "tar.gz $f entry: refused (exit 1)" 1 $?
  contains "tar.gz $f entry: named" "$(cat "$T/err")" "unsafe entry name"
  check "tar.gz $f entry: nothing written" "" "$(lsd)"
done
hf "url=$base/symlink-abs.tar.gz" archive=tar.gz; check "tar.gz absolute symlink: refused" 1 $?
contains "absolute symlink: said" "$(cat "$T/err")" "link pointing outside"
hf "url=$base/symlink-up.tar.gz" archive=tar.gz; check "tar.gz symlink with ..: refused" 1 $?
hf "url=$base/hardlink.tar.gz" archive=tar.gz; check "tar.gz hardlink to outside: refused" 1 $?
hf "url=$base/device.tar.gz" archive=tar.gz; check "tar.gz device file: refused" 1 $?
contains "device file: said" "$(cat "$T/err")" "device, fifo or other special file"
check "an evil entry wrote nothing outside the layer folder" "no" "$([ -e /etc/evil.layer ] && echo yes || echo no)"
# size cap
hf "url=$base/big.tar.gz" archive=tar.gz max-size=1000; check "size cap (max-size): refused (exit 1)" 1 $?
contains "size cap: names the cap and how to raise it" "$(cat "$T/err")" "over the 1000 (max-size) cap; raise it with max-size: on the source or COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE"
check "size cap: nothing written" "" "$(lsd)"
hf "url=$base/big.tar.gz" archive=tar.gz; check "under the default cap: fetched" 0 $?
hf "url=$base/big.tar.gz" archive=tar.gz max-size=4K; check "max-size 4K raises it over the 3000 bytes: fetched" 0 $?
hf "url=$base/big.tar.gz" archive=tar.gz max-size=2K; check "max-size 2K (binary units) refuses 3000 bytes" 1 $?
COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE=1000 hf "url=$base/big.tar.gz" archive=tar.gz; check "env default 1000: refused" 1 $?
contains "env default: named" "$(cat "$T/err")" "over the 1000 (COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE) cap"
COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE=1000 hf "url=$base/big.tar.gz" archive=tar.gz max-size=1M; check "the source's key beats the env default" 0 $?
COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE=1M hf "url=$base/big.tar.gz" archive=tar.gz max-size=1000; check "the key beats the env default (lowering)" 1 $?
COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE=1000 hf "url=$base/plain.layer"; check "the env default does not touch a plain file" 0 $?
hf "url=$base/plain.layer" max-size=10; check "max-size on a plain file caps its download (exit 1)" 1 $?
hf "url=$base/plain.layer" max-size=1K; check "max-size on a plain file: fetched under it" 0 $?
for bad in 0 -5 abc 1.5M 10X 010 ''; do
  [ -n "$bad" ] || continue
  hf "url=$base/good.tar.gz" archive=tar.gz "max-size=$bad"; check "max-size '$bad' refused (exit 2)" 2 $?
done
COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE=lots hf "url=$base/good.tar.gz" archive=tar.gz; check "a bad env default is refused (exit 2)" 2 $?

# ------------------------------------------------------- through the layer list ----
C="$T/case"; mkdir -p "$C/repo/.devcontainer"; cd "$C/repo" || exit 1
export COMPONENT_REGISTRY_STATE_DIR="$C/state"
printf 'layers:\n  - id: mono\n    at: /Corp\n    sources:\n      - { kind: git, url: "%s", branch: main, path: registry/corp }\n  - id: rel\n    at: /Corp/rel\n    sources:\n      - { kind: http, url: "%s/good.tar.gz", archive: tar.gz, sha256: "%s", path: pkg }\n' "$G" "$base" "$good_sum" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp/rel/me 2>&1)"; rc=$?
echo "$out" >> "$T/resolve.log"
check "layer list: a git path layer and an archive layer resolve (exit 0)" 0 "$rc"
contains "layer list: the monorepo folder's skill resolved with its @file" "$(cat "$C/state/view/skills/mono/SKILL.md")" "from the monorepo folder"
contains "layer list: the archive's skill resolved with its @file" "$(cat "$C/state/view/skills/rel/SKILL.md")" "from the archive"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: http, url: "%s/plain.layer", sha256: "%s" }\n' "$base" "$good_sum" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp/me 2>&1)"; rc=$?
check "layer list: sha256 without archive refused (exit 2)" 2 "$rc"
contains "layer list: and says why" "$out" "sha256 and path belong to an archive source"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: http, url: "%s/good.tar.gz", archive: tar.gz, max-size: 0 }\n' "$base" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp/me 2>&1)"; rc=$?
check "layer list: max-size 0 refused (exit 2)" 2 "$rc"
contains "layer list: and says why" "$out" "max-size is a number of bytes or a number with K, M or G"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: git, url: "%s", branch: main, max-size: 1M }\n' "$G" > .devcontainer/registry.yml
check "layer list: max-size on a git source refused (exit 2)" 2 "$(dcf-registry resolve --as /Corp/me >/dev/null 2>&1; echo $?)"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: git, url: "%s", branch: main, archive: zip }\n' "$G" > .devcontainer/registry.yml
check "layer list: archive on a git source refused (exit 2)" 2 "$(dcf-registry resolve --as /Corp/me >/dev/null 2>&1; echo $?)"
mkdir -p "$T/plainfolder"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: "%s", max-size: 1M }\n' "$T/plainfolder" > .devcontainer/registry.yml
check "layer list: max-size on a path source refused (exit 2)" 2 "$(dcf-registry resolve --as /Corp/me >/dev/null 2>&1; echo $?)"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: "%s", archive: tar.gz }\n' "$T/plainfolder" > .devcontainer/registry.yml
check "layer list: archive on a path source refused (exit 2)" 2 "$(dcf-registry resolve --as /Corp/me >/dev/null 2>&1; echo $?)"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: db, driver: sqlite, path: "%s/x.db", table: t, sha256: "%s" }\n' "$T" "$good_sum" > .devcontainer/registry.yml
check "layer list: sha256 on a db source refused (exit 2)" 2 "$(dcf-registry resolve --as /Corp/me >/dev/null 2>&1; echo $?)"

echo "component-registry sources: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
