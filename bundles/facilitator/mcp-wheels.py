#!/usr/bin/env python3
"""Regenerates the pinned `mcp` wheel table (HTTP_WHEELS) of bundles/facilitator/install.sh (ruling HC5).

    mcp-wheels.py <mcp version> [--check] [--script <install.sh>]

Resolves the dependency closure with `pip download` for CPython 3.13 on linux x86_64 (the names only), then asks
PyPI's JSON API (pypi.org/pypi/<name>/<version>/json) for each wheel's SHA-256 and URL: pure wheels once ("any"),
the wheels with native code once per architecture (x86_64, aarch64), taking the cp313 or abi3 manylinux wheel whose
glibc tag is 2_28 or older. Without --check it rewrites the table in the script; with --check it prints a
difference and exits 1 when the script's table is not the one PyPI gives. Needs network and pip."""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

ARCHES = ("x86_64", "aarch64")


def closure(version: str) -> list[tuple[str, str]]:
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, "-m", "pip", "download", f"mcp=={version}", "-d", d, "--no-input", "-q",
                        "--only-binary=:all:", "--python-version", "3.13", "--implementation", "cp",
                        "--platform", "manylinux2014_x86_64", "--platform", "manylinux_2_28_x86_64"], check=True)
        out = []
        for f in sorted(os.listdir(d)):
            p = f[:-4].split("-")
            out.append((p[0], p[1]))
        return out


def rows(version: str) -> list[str]:
    out = []
    for dist, ver in closure(version):
        j = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{dist.replace('_', '-')}/{ver}/json"))
        files = j["urls"]
        pure = [u for u in files if u["filename"].endswith("-none-any.whl")]
        if pure:
            u = pure[0]
            out.append("|".join(("any", u["filename"], u["digests"]["sha256"], u["url"])))
            continue
        for arch in ARCHES:
            best = None
            for u in files:
                n = u["filename"]
                if not n.endswith(".whl") or arch not in n or "musllinux" in n:
                    continue
                t = n[:-4].split("-")
                if not (t[-3] == "cp313" or t[-2] == "abi3"):
                    continue
                glibc = [(int(a), int(b)) for a, b in re.findall(r"manylinux_(\d+)_(\d+)", n)]
                if any(g <= (2, 28) for g in glibc) or re.search(r"manylinux(2014|2010|1)_", n):
                    best = best or u
            if best is None:
                sys.exit(f"mcp-wheels: no cp313 manylinux wheel of {dist} {ver} for {arch}")
            out.append("|".join((arch, best["filename"], best["digests"]["sha256"], best["url"])))
    return out


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    script = "bundles/facilitator/install.sh"
    if "--script" in argv:
        script = argv[argv.index("--script") + 1]
        args.remove(script)
    if len(args) != 1:
        print(__doc__)
        return 2
    new = "\n".join(rows(args[0]))
    text = open(script).read()
    m = re.search(r"(HTTP_WHEELS=\"\$\(cat <<'WHEELS'\n)(.*?)(\nWHEELS\n\)\")", text, re.S)
    if not m:
        sys.exit(f"mcp-wheels: no HTTP_WHEELS table in {script}")
    if "--check" in argv:
        if m.group(2) == new:
            print(f"mcp-wheels: the table of {script} is what PyPI gives for mcp {args[0]} ({new.count(chr(10)) + 1} wheels)")
            return 0
        old, nw = set(m.group(2).splitlines()), set(new.splitlines())
        print("mcp-wheels: the table differs:\n" + "\n".join(["- " + x for x in sorted(old - nw)] + ["+ " + x for x in sorted(nw - old)]))
        return 1
    open(script, "w").write(text[:m.start(2)] + new + text[m.end(2):])
    print(f"mcp-wheels: {script} now pins mcp {args[0]} ({new.count(chr(10)) + 1} wheels); run task bundle:sync, bump the Feature")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
