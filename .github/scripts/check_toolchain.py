#!/usr/bin/env python3
"""Fail when the CI devcontainer config drifts from the main one.

The Lint workflow builds .devcontainer/ci/devcontainer.json; people work in
.devcontainer/devcontainer.json. The toolchain must be one definition, so this
compares what the two share: the base image, and every Feature entry of the CI
config against the same entry (same reference, same options) in the main one.
Local Features ("./features/x" in the main file, "../features/x" in the CI one)
match by name. The tools lint runs with must also carry an explicit version.
Stdlib only; both files are JSONC (comments).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / ".devcontainer" / "devcontainer.json"
CI = ROOT / ".devcontainer" / "ci" / "devcontainer.json"
# Features whose version option must be set (not "latest", not absent).
PINNED = (
    "ghcr.io/devcontainers/features/powershell",
    "ghcr.io/devcontainers-extra/features/shellcheck",
    "ghcr.io/devcontainers-extra/features/yamllint",
)
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)


def load(path):
    text = TOKEN.sub(lambda m: m.group(0) if m.group(0).startswith('"') else "", path.read_text())
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))


def key(ref):
    """The comparison key: a registry ref as is (tag included), a local Feature by its path under features/."""
    return ref[len("../"):] if ref.startswith("../features/") else ref[len("./"):] if ref.startswith("./features/") else ref


def main():
    a, b = load(MAIN), load(CI)
    errors = []
    if a.get("image") != b.get("image"):
        errors.append(f"image differs: {a.get('image')} (main) vs {b.get('image')} (ci)")
    fa = {key(k): v for k, v in a.get("features", {}).items()}
    fb = {key(k): v for k, v in b.get("features", {}).items()}
    for name, opts in fb.items():
        if name not in fa:
            errors.append(f"feature {name} is in the CI config only")
        elif fa[name] != opts:
            errors.append(f"feature {name} differs: {fa[name]} (main) vs {opts} (ci)")
    for name in PINNED:
        for label, feats in (("main", fa), ("ci", fb)):
            ref = next((k for k in feats if k.rsplit(":", 1)[0] == name), None)
            if ref is None:
                errors.append(f"{name} is missing from the {label} config")
            elif not feats[ref].get("version") or feats[ref]["version"] == "latest":
                errors.append(f"{ref} has no pinned version in the {label} config")
    for e in errors:
        print(f"toolchain drift: {e}")
    if errors:
        print("Fix: make .devcontainer/ci/devcontainer.json match .devcontainer/devcontainer.json for these entries.")
        return 1
    print("toolchain: the CI devcontainer and the main one agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
