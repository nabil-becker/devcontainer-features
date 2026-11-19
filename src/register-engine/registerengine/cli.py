"""The register-engine command (README.md, "Tasks"): what is installed, what is ready, the types the
capability Features gave, and a check of one store. The capability Features have the commands that
write; this one only reads."""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from . import __version__, adapters, core
from . import registertypes as types

LIB = Path(__file__).resolve().parents[1]


def _emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str) if getattr(a, "json", False) else text)


def cmd_version(a) -> int:
    v = {"register-engine": __version__, "format": core.VERSION, "sign-packet": core.sp.__version__,
         "python": sys.version.split()[0], "library": str(LIB), "types": str(types.TYPES_DIR)}
    _emit(a, v, f"register-engine {__version__} (format v{core.VERSION}, sign-packet {core.sp.__version__})\n"
                f"python : {v['python']}\nlibrary: {v['library']}\ntypes  : {v['types']}")
    return 0


def cmd_check(a) -> int:
    try:
        n = len(types.load())
        tok, tdetail = True, f"{n} type(s) from {types.TYPES_DIR}"
    except types.TypesError as e:
        tok, tdetail = False, str(e)
    parts = [("python", sys.version_info >= (3, 11), sys.version.split()[0]),
             ("ssh-keygen", shutil.which("ssh-keygen") is not None, shutil.which("ssh-keygen") or "missing"),
             ("sign-packet", tuple(int(x) for x in core.sp.__version__.split(".")[:3]) >= core.SIGN_PACKET_MIN,
              core.sp.__version__),
             ("types", tok, tdetail)]
    _emit(a, [{"part": p, "ready": ok, "detail": d} for p, ok, d in parts],
          "\n".join(f"register-engine: {p:<11} {'ready' if ok else 'NOT READY'}  {d}" for p, ok, d in parts))
    return 0 if all(ok for _, ok, _ in parts) else 1


def cmd_setup(a) -> int:
    """Nothing to prepare: the engine keeps no state of its own; each capability Feature keeps its own."""
    print("register-engine: nothing to set up (each capability Feature keeps its own state)")
    return 0


def cmd_types(a) -> int:
    try:
        ts = types.load()
    except types.TypesError as e:
        raise SystemExit(f"register-engine: {e}")
    rows = [{"name": t.name, "feature": t.feature, "kinds": sorted(t.kinds), "description": t.description,
             "outside_git": t.outside_git} for t in sorted(ts.values(), key=lambda t: t.name)]
    _emit(a, rows, "\n".join(f"register-engine: {r['name']:<10} from {r['feature']:<22} {r['description']}" for r in rows))
    return 0


def cmd_verify(a) -> int:
    """Read one store as one register: every entry checked (format, register, kind, signature,
    roster, anchors); exit 1 on a refusal, a held entry or a fork no operator ruled on."""
    try:
        t = types.get(a.type)
    except (types.TypesError, ValueError) as e:
        raise SystemExit(f"register-engine: {e}")
    store = Path(a.store)
    if not store.is_dir():
        raise SystemExit(f"register-engine: no store folder {store}")
    anchors = adapters.load_anchors(Path(a.anchors)) if a.anchors else {}
    led = core.read(adapters.raws(adapters.DirStore(store)), anchors, None, a.register, t.kinds, a.format)
    if t.project is not None:
        _, more = t.project(led)
        for i, fs in more.items():
            led.flags.setdefault(i, []).extend(f for f in fs if f not in led.flags.get(i, []))
    r = {"register": a.register, "type": t.name, "format": a.format, "valid": len(led.valid), "held": led.held,
         "refused": {i: list(c) for i, c in led.refused.items()}, "unruled_forks": led.unruled_forks,
         "pruned": sorted(led.pruned), "flags": led.flags}
    bad = bool(led.refused or led.held or led.unruled_forks)
    _emit(a, r, f"register-engine: {a.register} ({t.name}): {len(led.valid)} valid, {len(led.held)} held, "
                f"{len(led.refused)} refused, {len(led.unruled_forks)} unruled fork(s)"
                + "".join(f"\n  refused {i[:16]}: {c[0]} {c[1]}" for i, c in led.refused.items()))
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="register-engine", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def command(name, fn, help_):
        c = sub.add_parser(name, help=help_)
        c.add_argument("--json", action="store_true", help="output for machines")
        c.set_defaults(fn=fn)
        return c

    command("version", cmd_version, "what is installed")
    command("check", cmd_check, "what is ready; non-zero when not")
    command("setup", cmd_setup, "nothing to prepare (idempotent, never fatal)")
    command("types", cmd_types, "the register types installed, and which Feature gave each")
    c = command("verify", cmd_verify, "check every entry of one store as one register")
    c.add_argument("store", help="the store folder (one <id>.entry file per entry)")
    c.add_argument("--register", required=True, help="the register's name: every entry must name it")
    c.add_argument("--type", default="log", help="its type (default: log)")
    c.add_argument("--anchors", help="the anchors file (operator keys this reader trusts)")
    c.add_argument("--format", type=int, choices=core.FORMATS, default=2,
                   help="the register's format: 2 (a roster) or 3 (identity and permission); default 2")
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except ValueError as e:
        print(f"register-engine: {e}", file=sys.stderr)
        return 1
