"""The small subset of YAML the participant list and facilitator.yml are written in (the participant
component's subset, components/participant/agents.sh): block maps and lists by indentation, plain,
single- and double-quoted scalars, flow lists `[a, b]`, comments. No anchors, no multi-line strings,
no flow maps. Keys are plain (letters, digits, `_ - . *`) or quoted. Errors name the file and line. Python's standard library has no YAML reader."""
from __future__ import annotations

import re


class YamlError(ValueError):
    def __init__(self, where: str, line: int, what: str):
        super().__init__(f"{where}:{line}: {what}")
        self.line = line


# A key: plain (letters, digits, _ - . *; mesh.yml's trust domains and the "*" default), or quoted (a full SPIFFE ID).
KEY_RE = re.compile(r"(\"[^\"]+\"|'[^']+'|[A-Za-z0-9_.*-]+):(?:\s+(.*))?$")


def _key(k: str) -> str:
    return k[1:-1] if k[:1] in "'\"" else k


def _strip_comment(s: str) -> str:
    out, q = [], None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            break
        out.append(c)
    return "".join(out).rstrip()


def scalar(v: str, where: str, line: int):
    v = v.strip()
    if v.startswith('"'):
        if len(v) < 2 or not v.endswith('"'):
            raise YamlError(where, line, f"an unclosed quote: {v}")
        return re.sub(r'\\(["\\])', r"\1", v[1:-1])
    if v.startswith("'"):
        if len(v) < 2 or not v.endswith("'"):
            raise YamlError(where, line, f"an unclosed quote: {v}")
        return v[1:-1].replace("''", "'")
    if v.startswith("["):
        if not v.endswith("]"):
            raise YamlError(where, line, f"a flow list must close on its line: {v}")
        inner = v[1:-1].strip()
        if not inner:
            return []
        items, cur, q = [], [], None
        for c in inner:
            if q:
                cur.append(c)
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
                cur.append(c)
            elif c == ",":
                items.append("".join(cur))
                cur = []
            else:
                cur.append(c)
        items.append("".join(cur))
        return [scalar(x, where, line) for x in items]
    if v.startswith("{"):
        raise YamlError(where, line, "write a map as key: value lines, not { }")
    if v in ("true", "True"):
        return True
    if v in ("false", "False"):
        return False
    if v in ("null", "~", ""):
        return None
    return v


def parse(text: str, where: str = "<yaml>"):
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise YamlError(where, n, "a tab in the indentation; indent with spaces")
        s = _strip_comment(raw)
        if not s.strip() or s.strip() == "---":
            continue
        lines.append((n, len(s) - len(s.lstrip(" ")), s.strip()))
    pos = 0

    def block(indent: int):
        nonlocal pos
        if pos >= len(lines):
            return None
        n, ind, t = lines[pos]
        if ind < indent:
            return None
        if t == "-" or t.startswith("- "):
            return seq(ind)
        return mapping(ind)

    def mapping(ind: int, first: tuple | None = None) -> dict:
        nonlocal pos
        out: dict = {}
        while pos < len(lines) or first:
            if first:
                n, i, t = first
                first = None
            else:
                n, i, t = lines[pos]
                if i < ind:
                    break
                if i > ind:
                    raise YamlError(where, n, "unexpected indentation")
                if t == "-" or t.startswith("- "):
                    raise YamlError(where, n, "a list item where a key was expected")
                pos += 1
            m = KEY_RE.match(t)
            if not m:
                raise YamlError(where, n, f"expected key: value, got {t!r}")
            k, v = _key(m.group(1)), m.group(2)
            if k in out:
                raise YamlError(where, n, f"'{k}' appears twice")
            if v is None or v == "":
                nxt = lines[pos] if pos < len(lines) else None
                if nxt and (nxt[1] > i or (nxt[1] == i and (nxt[2] == "-" or nxt[2].startswith("- ")) and i == ind)):
                    out[k] = block(nxt[1])
                else:
                    out[k] = None
            else:
                out[k] = scalar(v, where, n)
        return out

    def seq(ind: int) -> list:
        nonlocal pos
        out: list = []
        while pos < len(lines):
            n, i, t = lines[pos]
            if i < ind or not (t == "-" or t.startswith("- ")):
                if i > ind:
                    raise YamlError(where, n, "unexpected indentation")
                break
            if i > ind:
                raise YamlError(where, n, "a list item at the wrong indentation")
            pos += 1
            rest = t[1:].lstrip()
            if not rest:
                out.append(block(ind + 1))
            elif KEY_RE.match(rest) and not rest.startswith(("'", '"')):
                out.append(mapping(i + 2 + (len(t[1:]) - len(t[1:].lstrip()) - 1), (n, i + 2, rest)))
            else:
                out.append(scalar(rest, where, n))
        return out

    if not lines:
        return {}
    if lines[0][1] != 0:
        raise YamlError(where, lines[0][0], "the top level must not be indented")
    out = block(0)
    if pos < len(lines):
        raise YamlError(where, lines[pos][0], "unexpected indentation")
    return out
