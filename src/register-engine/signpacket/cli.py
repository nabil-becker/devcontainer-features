"""The sign-packet command (README.md, "Tasks"): version, check, verify."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__
from . import instance as inst
from .graph import collect
from .packet import VERSION


def _emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True) if a.json else text)


def _ssh_keygen() -> str | None:
    path = shutil.which("ssh-keygen")
    if not path:
        return None
    r = subprocess.run(["ssh", "-V"], capture_output=True, text=True) if shutil.which("ssh") else None
    return (r.stderr or r.stdout).strip() if r else path


def cmd_version(a) -> int:
    v = {"sign-packet": __version__, "format": VERSION, "python": sys.version.split()[0],
         "ssh-keygen": _ssh_keygen(), "library": str(Path(__file__).resolve().parent)}
    _emit(a, v, f"sign-packet {__version__} (format v{VERSION})\npython    : {v['python']}\n"
                f"ssh-keygen: {v['ssh-keygen'] or 'missing'}\nlibrary   : {v['library']}")
    return 0


def cmd_instance(a) -> int:
    """This running instance's id: resolved (the environment, OpenBao, or made here) and recorded once."""
    try:
        i, where = inst.resolve()
    except inst.InstanceError as e:
        print(f"sign-packet: {e}", file=sys.stderr)
        return 2
    _emit(a, {"instance": i, "source": where, "record": str(inst.home() / "instance-id")},
          f"{i}" if a.quiet else f"sign-packet: instance {i} ({where}; recorded in {inst.home() / 'instance-id'})")
    return 0


def cmd_check(a) -> int:
    try:
        rec = inst.recorded()
        env = inst.from_env()
        ok_inst = rec is not None and (env is None or env == rec)
        why = rec or "not settled: run sign-packet instance"
        if rec and env and env != rec:
            why = f"{rec}, but {inst.ENV} names {env}"
    except inst.InstanceError as e:
        ok_inst, why = False, str(e)
    parts = [("python", sys.version_info >= (3, 11), sys.version.split()[0]),
             ("ssh-keygen", shutil.which("ssh-keygen") is not None, shutil.which("ssh-keygen") or "missing: install openssh-client"),
             ("instance", ok_inst, why)]
    _emit(a, [{"part": p, "ready": ok, "detail": d} for p, ok, d in parts],
          "\n".join(f"sign-packet: {p:<10} {'ready' if ok else 'NOT READY'}  {d}" for p, ok, d in parts))
    return 0 if all(ok for _, ok, _ in parts) else 1


def cmd_verify(a) -> int:
    """Each packet file on its own: format, fields, domain and signature (checks 1 to 4). Each file
    is judged alone, so a bad copy is reported even when a good copy of the same packet is there.
    Not who may write: that is the layer on top's (agentic-register verify)."""
    files = [f for p in a.paths for f in (sorted(Path(p).glob("*.entry")) if Path(p).is_dir() else [Path(p)])]
    rows = []
    for f in files:
        found, refused = collect([f.read_bytes()], a.domain)
        if found:
            rows.append({"file": f.name, "id": next(iter(found)), "outcome": "valid"})
        else:
            (i, (code, detail)), = refused.items()
            rows.append({"file": f.name, "id": i, "outcome": code, "detail": detail})
    bad = [r for r in rows if r["outcome"] != "valid"]
    _emit(a, rows, "\n".join([f"sign-packet: {len(rows) - len(bad)} valid, {len(bad)} refused in {len(rows)} file(s) of {a.domain}"]
                             + [f"  refused {r['file']}: {r['outcome']}" + (f" ({r['detail']})" if r.get("detail") else "")
                                for r in bad]))
    return 0 if not bad else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="sign-packet", description="signed packets, named by their hash, chained per key (SPEC.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn, help_ in (("version", cmd_version, "what is installed"),
                            ("check", cmd_check, "what is ready (Python 3.11, ssh-keygen, the instance id); non-zero when not"),
                            ("instance", cmd_instance, "this running instance's id (AOF_INSTANCE_ID, OpenBao, or made here), recorded once"),
                            ("verify", cmd_verify, "check packet files alone: format, fields, domain, signature")):
        c = sub.add_parser(name, help=help_)
        c.add_argument("--json", action="store_true", help="output for machines")
        c.set_defaults(fn=fn)
        if name == "instance":
            c.add_argument("--quiet", action="store_true", help="print the id alone")
        if name == "verify":
            c.add_argument("--domain", required=True, help="the domain the packets belong to (a register's name)")
            c.add_argument("paths", nargs="+", help="packet files, or folders of <id>.entry files")
    a = ap.parse_args(argv)
    return a.fn(a)
