#!/usr/bin/env python3
"""Fail when a reference architecture's devcontainer.json fragment has drifted from the Features.

docs/reference-architectures/*.md each carry a complete `devcontainer.json` fragment in a ```jsonc block.
This parses every such block (comments and trailing commas allowed) and, for each entry of its
"features" object, checks it against the tree:

  - ghcr.io/nabil-becker/devcontainer-features/<id>:<major>  the id is a folder of src/ (a Feature in
    local-features/ is not published, so it is refused here and named as ./features/<id>), the tag is
    the current major of src/<id>/devcontainer-feature.json (a bare id, or a minor such as 1.4, is
    refused), and every option is in that file's "options" with the right type (and in its enum);
  - ./features/<id>  the id is in src/ or local-features/, options checked the same way, no major;
  - any other reference (an official or third-party Feature) is not checked.

A block fenced ```jsonc planned is a design not built yet: it must parse, and it must still fail the
checks above (an option that does not exist yet); when it starts to pass, the check says so, so the
snippet moves into the checked fragment. Also checks each architecture file's shape: a features
fragment, a ```text diagram, "## Best practices", "## Anti-patterns" whose entries have Don't, Why,
Instead and Caught by, and a link from the README.md index.

Usage: check_architectures.py [ROOT]. Docker-free, stdlib only.
"""
import json
import re
import sys
from pathlib import Path

PREFIX = "ghcr.io/nabil-becker/devcontainer-features/"
FENCE = re.compile(r"^```(\w+)?[ \t]*(\w+)?[ \t]*$")
ANTI_LABELS = ("Don't", "Why", "Instead", "Caught by")


def strip_jsonc(text):
    """The JSON in a jsonc text: // and /* */ comments and trailing commas removed, strings kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def blocks(text):
    """[(info, planned, first line number of the body, body)] for every fenced block."""
    found, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m and m.group(1):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            found.append((m.group(1), m.group(2) == "planned", i + 2, "\n".join(lines[i + 1:j])))
            i = j
        i += 1
    return found


def feature_json(root, ident, bases):
    for base in bases:
        path = root / base / ident / "devcontainer-feature.json"
        if path.is_file():
            return json.loads(path.read_text())
    return None


def check_options(ident, spec, given):
    problems = []
    options = spec.get("options", {})
    for name, value in given.items():
        if name not in options:
            problems.append(f"{ident}: option {name!r} is not in its devcontainer-feature.json "
                            f"(options: {', '.join(sorted(options)) or 'none'})")
            continue
        want = options[name]
        kind = want.get("type")
        if kind == "boolean" and not isinstance(value, bool):
            problems.append(f"{ident}: option {name!r} is a boolean, given {value!r}")
        elif kind == "string" and not isinstance(value, str):
            problems.append(f"{ident}: option {name!r} is a string, given {value!r}")
        elif "enum" in want and value not in want["enum"]:
            problems.append(f"{ident}: option {name!r} is {value!r}, one of {want['enum']}")
    return problems


def check_features(root, features):
    problems = []
    for key, given in features.items():
        given = given if isinstance(given, dict) else {}
        if key.startswith(PREFIX):
            ident, _, tag = key[len(PREFIX):].partition(":")
            spec = feature_json(root, ident, ("src",))
            if spec is None:
                local = feature_json(root, ident, ("local-features",))
                problems.append(f"{key}: no Feature {ident!r} in src/" + (
                    f"; it is local and unpublished, reference it as ./features/{ident}" if local else ""))
                continue
            major = spec["version"].split(".")[0]
            if not tag:
                problems.append(f"{key}: name the major, {PREFIX}{ident}:{major}")
            elif tag != major:
                problems.append(f"{key}: src/{ident} is at version {spec['version']}, so the major is "
                                f"{major}: {PREFIX}{ident}:{major}")
            problems += check_options(ident, spec, given)
        elif key.startswith("./features/"):
            ident = key[len("./features/"):]
            spec = feature_json(root, ident, ("src", "local-features"))
            if spec is None:
                problems.append(f"{key}: no Feature {ident!r} in src/ or local-features/")
                continue
            problems += check_options(ident, spec, given)
    return problems


def check_shape(path, text, index_text):
    problems = []
    body = blocks(text)
    if not any(info == "jsonc" for info, _, _, _ in body):
        problems.append(f"{path.name}: no ```jsonc block with the devcontainer.json fragment")
    if not any(info == "text" for info, _, _, _ in body):
        problems.append(f"{path.name}: no ```text block (the diagram)")
    if "\n## Best practices\n" not in text:
        problems.append(f"{path.name}: no '## Best practices' section")
    anti = re.search(r"\n## Anti-patterns\n(.*?)(?=\n## |\Z)", text, re.S)
    if not anti:
        problems.append(f"{path.name}: no '## Anti-patterns' section")
    else:
        entries = re.split(r"\n### ", "\n" + anti.group(1))[1:]
        if not entries:
            problems.append(f"{path.name}: '## Anti-patterns' has no '### ' entry")
        for entry in entries:
            title = entry.split("\n", 1)[0]
            for label in ANTI_LABELS:
                if f"- **{label}:**" not in entry:
                    problems.append(f"{path.name}: anti-pattern {title!r} has no '- **{label}:**' line")
    if f"]({path.name})" not in index_text:
        problems.append(f"{path.name}: not linked from README.md")
    return problems


def check(root):
    folder = root / "docs" / "reference-architectures"
    index = folder / "README.md"
    if not index.is_file():
        return ["docs/reference-architectures/README.md is missing"], 0
    index_text = index.read_text()
    problems, fragments = [], 0
    for path in sorted(folder.glob("*.md")):
        text = path.read_text()
        rel = path.relative_to(root)
        has_features = False
        for info, planned, line, body in blocks(text):
            if info != "jsonc":
                continue
            try:
                doc = json.loads(strip_jsonc(body))
            except ValueError as err:
                problems.append(f"{rel}:{line}: the jsonc block does not parse: {err}")
                continue
            if not isinstance(doc, dict) or not isinstance(doc.get("features"), dict):
                continue
            found = check_features(root, doc["features"])
            if planned:
                if not found:
                    problems.append(f"{rel}:{line}: this 'jsonc planned' fragment passes now; move it into the "
                                    f"checked fragment and drop 'planned'")
                continue
            has_features = True
            fragments += 1
            problems += [f"{rel}:{line}: {p}" for p in found]
        if path != index:
            if not has_features:
                problems.append(f"{rel}: no checked ```jsonc fragment with a \"features\" object")
            problems += [f"{rel}: {p}" for p in check_shape(path, text, index_text)]
    return problems, fragments


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    problems, fragments = check(root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print("Fix the fragment (or bump it with the Feature): docs/reference-architectures must match src/.",
              file=sys.stderr)
        return 1
    print(f"reference architectures: {fragments} fragment(s) match src/ (ids, majors, options)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
