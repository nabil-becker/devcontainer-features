#!/usr/bin/env python3
"""phi-check: refuse files that hold protected health information.

A linter-style command: it checks the paths it is given and knows nothing of
git, staged changes or hooks. Never prints the matched text, only the path,
the line and the rule. Exit 0 clean, 1 findings, 2 usage or internal error.
Python 3 standard library only; the patterns are in phi_patterns.py.
"""
import argparse
import datetime
import json
import os
import sys

_HERE = os.path.dirname(os.path.realpath(__file__))
_SHARE = "/usr/local/share/phi-check"
for _dir in (_SHARE, _HERE):  # the module beside the command wins in a checkout
    if os.path.isfile(os.path.join(_dir, "phi_patterns.py")):
        sys.path.insert(0, _dir)
import phi_patterns  # noqa: E402

PROG = "phi-check"
DEFAULT_EXCEPTIONS = ".phi-exceptions.txt"
NOT_TEXT = "not text; cannot be checked"
NOT_FOUND = "not found; cannot be checked"
NOT_READABLE = "not readable; cannot be checked"
MALFORMED = "malformed exception line (expected: <path> <YYYY-MM-DD> <why>)"
SKIP_DIRS = {".git"}


class Usage(Exception):
    pass


def default_exceptions_name():
    name = os.environ.get("PHI_CHECK_EXCEPTIONS")
    if name:
        return name
    try:
        with open(os.path.join(_SHARE, "exceptions-default"), encoding="utf-8") as fh:
            name = fh.read().strip()
    except OSError:
        name = ""
    return name or DEFAULT_EXCEPTIONS


def norm(path):
    return os.path.normpath(os.path.abspath(path))


def load_exceptions(path, findings):
    """Return {normalised path: date} and add a finding per malformed line."""
    listed = {}
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    for n, line in enumerate(raw.splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        parts = text.split(None, 2)
        ok = len(parts) == 3
        if ok:
            try:
                datetime.date.fromisoformat(parts[1])
                ok = len(parts[1]) == 10
            except ValueError:
                ok = False
        if not ok:
            findings.append((path, n, MALFORMED))
            continue
        listed[norm(parts[0])] = parts[1]
    return listed


def expand(paths):
    """Yield (display name, path or None for stdin) for every file to check."""
    for p in paths:
        if p == "-":
            yield "-", None
        elif os.path.isdir(p):
            found = []
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
                found.extend(os.path.join(root, f) for f in files)
            for f in sorted(found):
                yield f, f
        else:
            yield p, p


def read_text(data):
    """Return the text, or None when the bytes are not UTF-8 text."""
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def check(paths, stdin_name, listed):
    findings, skipped, count = [], [], 0
    for shown, path in expand(paths):
        name = (stdin_name or "<stdin>") if path is None else shown
        key = norm(name)
        if listed is not None and key in listed:
            skipped.append((name, listed[key]))
            continue
        count += 1
        try:
            if path is None:
                data = sys.stdin.buffer.read()
            else:
                if not os.path.exists(path):
                    findings.append((name, None, NOT_FOUND))
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
        except OSError:
            findings.append((name, None, NOT_READABLE))
            continue
        text = read_text(data)
        if text is None:
            findings.append((name, None, NOT_TEXT))
            continue
        for line, rule in phi_patterns.scan(text):
            findings.append((name, line, rule))
    return findings, skipped, count


def gh_escape(value, prop=False):
    value = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    if prop:
        value = value.replace(":", "%3A").replace(",", "%2C")
    return value


def render(fmt, findings, skipped, count, exc_name):
    out = []
    if fmt == "json":
        out.append(json.dumps({
            "tool": PROG,
            "version": phi_patterns.VERSION,
            "clean": not findings,
            "files": count,
            "findings": [{"path": p, "line": l, "rule": r} for p, l, r in findings],
            "skipped": [{"path": p, "exception_date": d, "listed_in": exc_name}
                        for p, d in skipped],
        }, indent=2))
        return out
    for p, l, r in findings:
        if fmt == "github":
            loc = "file=%s" % gh_escape(p, True) + (",line=%d" % l if l else "")
            out.append("::error %s::%s" % (loc, gh_escape(r)))
        elif l is None:
            out.append("%s: %s" % (p, r))
        else:
            out.append("%s:%s: %s" % (p, l, r))
    for p, d in skipped:
        note = "skipped %s (listed in %s, %s)" % (p, exc_name, d)
        out.append("::notice::" + gh_escape(note) if fmt == "github" else "%s: %s" % (PROG, note))
    if findings:
        out.append("%s: refused, %d finding(s) in %d file(s)" % (PROG, len(findings), count))
    else:
        out.append("%s: clean, %d file(s)" % (PROG, count))
    return out


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def main(argv):
    ap = Parser(prog=PROG, add_help=True,
                description="Refuse files that hold protected health information. "
                            "Never prints the matched text.")
    ap.add_argument("paths", nargs="*", metavar="path",
                    help="file or folder to check; - reads standard input")
    ap.add_argument("--format", choices=("text", "json", "github"), default="text")
    ap.add_argument("--exceptions", metavar="FILE",
                    help="exceptions file (default: the exceptions option, .phi-exceptions.txt)")
    ap.add_argument("--no-exceptions", action="store_true",
                    help="ignore the exceptions file (for exports)")
    ap.add_argument("--stdin-filename", metavar="NAME", help="the name shown for -")
    ap.add_argument("--cwd", metavar="DIR", help="resolve paths and the exceptions file here")
    ap.add_argument("--version", action="store_true")
    args = ap.parse_args(argv)
    if args.version:
        print("%s %s" % (PROG, phi_patterns.VERSION))
        return 0
    if not args.paths:
        raise Usage("no path given")
    if args.paths.count("-") > 1:
        raise Usage("- (standard input) can be given once")
    if args.stdin_filename and "-" not in args.paths:
        raise Usage("--stdin-filename needs - among the paths")
    if args.exceptions and args.no_exceptions:
        raise Usage("--exceptions and --no-exceptions exclude each other")
    if args.cwd:
        if not os.path.isdir(args.cwd):
            raise Usage("--cwd is not a folder")
        os.chdir(args.cwd)

    findings, listed, exc_name = [], None, None
    if not args.no_exceptions:
        exc_name = args.exceptions or default_exceptions_name()
        if os.path.isfile(exc_name):
            try:
                listed = load_exceptions(exc_name, findings)
            except (OSError, UnicodeDecodeError):
                findings.append((exc_name, None, NOT_READABLE))
        elif args.exceptions:
            raise Usage("the exceptions file does not exist")
    more, skipped, count = check(args.paths, args.stdin_filename, listed)
    findings.extend(more)
    for line in render(args.format, findings, skipped, count, exc_name):
        print(line)
    return 1 if findings else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as err:
        print("%s: usage error: %s" % (PROG, err), file=sys.stderr)
        sys.exit(2)
    except SystemExit:
        raise
    except BaseException as err:  # fail closed, and never echo data
        print("%s: internal error (%s); nothing was checked as clean" % (PROG, type(err).__name__),
              file=sys.stderr)
        sys.exit(2)
