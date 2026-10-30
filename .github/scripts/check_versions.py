#!/usr/bin/env python3
"""Fail when a container test compares a Feature's version with a literal that is not the current one.

A Feature's install script bakes its version (/usr/local/share/<id>-feature/version) and its Taskfile
prints it (`task <id>:version`). A container test that greps for the literal breaks in CI, and only
there (container tests need Docker), when the version is bumped. This finds every line of
test/<id>/*.sh that names `/usr/local/share/<id>-feature/version` or `<id>:version` together with a
semver literal, and reports file:line when the literal differs from the version in
src/<id>/devcontainer-feature.json (or local-features/<id>/). Usage: check_versions.py [ROOT].
Stdlib only.
"""
import json
import re
import sys
from pathlib import Path

BAKED = re.compile(r"/usr/local/share/([a-z0-9][\w-]*)-feature/version")
OUTPUT = re.compile(r"(?<![\w/-])([a-z0-9][\w-]*):version\b")
SEMVER = re.compile(r"(?<![\w.])(\d+\.\d+\.\d+)(?![\w.])")


def feature_version(root, ident):
    for base in ("src", "local-features"):
        path = root / base / ident / "devcontainer-feature.json"
        if path.is_file():
            return json.loads(path.read_text()).get("version")
    return None


def check(root):
    findings = []
    for script in sorted(root.glob("test/*/*.sh")):
        for number, line in enumerate(script.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            ids = set(BAKED.findall(line)) | set(OUTPUT.findall(line))
            for ident in sorted(ids):
                want = feature_version(root, ident)
                if want is None:
                    continue
                for literal in SEMVER.findall(line):
                    if literal != want:
                        findings.append(f"{script.relative_to(root)}:{number}: expects {ident} {literal}, "
                                        f"but src/{ident}/devcontainer-feature.json says {want}")
    return findings


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    findings = check(root)
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        print("Update the version in the container test (or bump the Feature to match).", file=sys.stderr)
        return 1
    print("container tests: every Feature version literal matches its devcontainer-feature.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
