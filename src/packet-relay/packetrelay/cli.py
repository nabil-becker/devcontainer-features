"""The packet-relay command (README.md, "Tasks")."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__
from .relay import Relay, RelayError, load_keys, sp

LIB = Path(__file__).resolve().parents[1]


def home() -> Path:
    return Path(os.environ.get("PACKET_RELAY_HOME", "/var/lib/devcontainer-features/packet-relay"))


def options() -> dict[str, str]:
    """The Feature's options, written by install.sh (options.env beside the library)."""
    f = LIB / "options.env"
    out = {}
    if f.is_file():
        for line in f.read_text().splitlines():
            k, sep, v = line.partition("=")
            if sep:
                out[k.strip()] = v.strip()
    return out


def _emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str) if getattr(a, "json", False) else text)


def _root(a) -> Path:
    r = a.root or os.environ.get("PACKET_RELAY_ROOT") or options().get("ROOT", "")
    if not r:
        raise RelayError("no shared folder: give --root, set PACKET_RELAY_ROOT, or the Feature's root option")
    if not Path(r).is_dir():
        raise RelayError(f"the shared folder {r} is not there (is it mounted?)")
    return Path(r)


def _who(a) -> str:
    who = a.as_ or os.environ.get("PACKET_RELAY_AS", "")
    if not sp.PRINCIPAL_RE.fullmatch(who):
        raise RelayError("who is writing: give --as <party> or set PACKET_RELAY_AS")
    return who


def relay(a) -> Relay:
    who = _who(a)
    members_file = Path(a.members) if a.members else home() / "members" / a.domain
    if not members_file.is_file():
        raise RelayError(f"no members file for {a.domain} at {members_file}: one '<party> ssh-ed25519 <base64>' "
                         "line per party (README.md, \"Parties\")")
    anchors_file = Path(a.anchors) if a.anchors else home() / "anchors"
    anchors = load_keys(anchors_file) if anchors_file.is_file() else {}
    key = Path(a.key) if a.key else home() / "keys" / who
    if not key.is_file():
        raise RelayError(f"no key for {who} at {key}: packet-relay key new {who}, or --key <file>")
    return Relay(_root(a), a.domain, who, key, load_keys(members_file), home(), anchors, *guards())


def guards():
    """The egress and ingress guards: the installed options only (root-owned), never the environment
    (SPEC.md, "Guards"). The command runs isolated (python3 -I), so no PYTHONPATH or user site can
    stand in for the library that runs them."""
    o = options()
    try:
        timeout = float(o.get("GUARD_TIMEOUT") or sp.guard.TIMEOUT)
        return sp.guard.Chain.parse(o.get("GUARD", ""), timeout), sp.guard.Chain.parse(o.get("INGRESS_GUARD", ""), timeout)
    except ValueError as e:
        raise RelayError(f"the installed guard options cannot be used: {e}") from None


def cmd_version(a) -> int:
    o = options()
    v = {"packet-relay": __version__, "sign-packet": sp.__version__, "python": sys.version.split()[0],
         "library": str(LIB), "home": str(home()),
         "guards": {"egress": o.get("GUARD", ""), "ingress": o.get("INGRESS_GUARD", "")}}
    _emit(a, v, f"packet-relay {__version__} (sign-packet {sp.__version__})\npython : {v['python']}\n"
                f"library: {v['library']}\nhome   : {v['home']}")
    return 0


def cmd_check(a) -> int:
    root = a.root or os.environ.get("PACKET_RELAY_ROOT") or options().get("ROOT", "")
    parts = [("python", sys.version_info >= (3, 11), sys.version.split()[0]),
             ("ssh-keygen", shutil.which("ssh-keygen") is not None, shutil.which("ssh-keygen") or "missing"),
             ("home", home().is_dir() and os.access(home(), os.W_OK), str(home())),
             ("folder", bool(root) and Path(root).is_dir(), root or "not set: --root, PACKET_RELAY_ROOT or the root option")]
    _emit(a, [{"part": p, "ready": ok, "detail": d} for p, ok, d in parts],
          "\n".join(f"packet-relay: {p:<10} {'ready' if ok else 'NOT READY'}  {d}" for p, ok, d in parts))
    return 0 if all(ok for _, ok, _ in parts) else 1


def cmd_setup(a) -> int:
    """The home's folders; never fatal (the post-create hook runs it)."""
    try:
        for d in (home() / "keys", home() / "members"):
            d.mkdir(parents=True, exist_ok=True)
        os.chmod(home() / "keys", 0o700)
        print(f"packet-relay: home {home()} ready")
    except OSError as e:
        print(f"packet-relay: setup could not make the home ({e}); run packet-relay check")
    return 0


def cmd_key(a) -> int:
    if not sp.PRINCIPAL_RE.fullmatch(a.principal):
        raise RelayError(f"{a.principal!r} is not a plain name")
    kp = home() / "keys" / a.principal
    if a.action == "new":
        if kp.exists():
            raise RelayError(f"{kp} exists; a key is never replaced (README.md, \"State\")")
        kp.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(kp.parent, 0o700)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(kp)], check=True)
    if not kp.is_file():
        raise RelayError(f"no key for {a.principal} at {kp}")
    print(f"{a.principal} {sp.public_key(kp)}")
    return 0


def cmd_send(a) -> int:
    if a.file == "-":                   # standard input: the data never touches a shared temp folder
        data = json.loads(sys.stdin.read())
    else:
        data = json.loads(Path(a.file).read_text()) if a.file else json.loads(a.data or "{}")
    if not isinstance(data, dict):
        raise RelayError("the data is a JSON object")
    i = relay(a).send(a.kind, data)
    _emit(a, {"id": i}, i)
    return 0


def cmd_sync(a) -> int:
    rep = relay(a).sync()
    lines = [f"packet-relay: {len(rep.delivered)} taken, {rep.kept} of mine kept, {rep.removed} removed, "
             f"{rep.resent} written again" + (", acknowledged" if rep.ack_written else "")]
    lines += [f"  taken {d['from']} #{d['seq']} {d['kind']} {d['id'][:12]}" + (" (again, after a crash)" if d["again"] else "")
              for d in rep.delivered]
    lines += [f"  waiting for {s} #{w['next']}" + (f" (id {w['missing_id'][:12]})" if w["missing_id"] else "")
              + f", have #{w['have'][0]} and on" for s, w in rep.waiting.items()]
    lines += [f"  FORK {s} at #{f['seq']}: {f['why']} ({', '.join(i[:12] for i in f['ids'])}); nothing more is taken "
              "from it until an operator gives it a new key" for s, f in rep.forks.items()]
    lines += [f"  skipped {k['from']} #{k['first']} through #{k['through']}, vouched by {k['by']}" for k in rep.skipped]
    lines += [f"  {p}'s acknowledgement names no packet of mine (#{a['seq']}): nothing removed for it" for p, a in rep.stale_acks.items()]
    lines += [f"  QUARANTINED {q['from']} #{q['seq']} {q['id'][:12]}: {q['reason']}" for q in rep.quarantined]
    lines += [f"  GUARD FAILED on {s} #{g['seq']}: {g['reason']}; nothing more taken from {s} until it answers"
              for s, g in rep.guard_failed.items()]
    lines += [f"  refused {r['file']}: {r['code']} {r['detail']}" for r in rep.refused]
    _emit(a, rep.as_dict(), "\n".join(lines))
    return 1 if rep.forks or rep.refused or rep.quarantined or rep.guard_failed else 0


def cmd_status(a) -> int:
    s = relay(a).status()
    _emit(a, s, "\n".join([f"packet-relay: {s['me']} in {s['domain']}: sent {s['sent']}, {s['outbox']} not yet taken by all"]
                          + [f"  {p} has taken mine through #{n}" for p, n in sorted(s["acked_by"].items())]
                          + [f"  taken from {p} through #{t['seq']}" for p, t in sorted(s["taken"].items())]))
    return 0


def cmd_skip(a) -> int:
    i = relay(a).skip(a.party, a.first, a.through, a.id)
    _emit(a, {"id": i}, i)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="packet-relay",
                                 description="sign-packet packets between parties through a shared folder (SPEC.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def command(name, fn, help_, relay_args=False):
        c = sub.add_parser(name, help=help_)
        c.add_argument("--json", action="store_true", help="output for machines")
        c.set_defaults(fn=fn)
        if relay_args:
            c.add_argument("--domain", required=True, help="the domain: one conversation between the parties")
            c.add_argument("--root", help="the shared folder (default: $PACKET_RELAY_ROOT, else the root option)")
            c.add_argument("--as", dest="as_", help="this party (default: $PACKET_RELAY_AS)")
            c.add_argument("--key", help="its signing key (default: $PACKET_RELAY_HOME/keys/<party>)")
            c.add_argument("--members", help="the parties (default: $PACKET_RELAY_HOME/members/<domain>)")
            c.add_argument("--anchors", help="the operators who may skip a gap (default: $PACKET_RELAY_HOME/anchors)")
        return c

    command("version", cmd_version, "what is installed")
    c = command("check", cmd_check, "what is ready; non-zero when not")
    c.add_argument("--root")
    command("setup", cmd_setup, "the home's folders (idempotent, never fatal)")
    c = command("key", cmd_key, "make or show a party's key: new <party> | show <party>")
    c.add_argument("action", choices=["new", "show"])
    c.add_argument("principal")
    c = command("send", cmd_send, "send a packet: --kind <kind> --data <json object> (or --file)", True)
    c.add_argument("--kind", required=True)
    c.add_argument("--data")
    c.add_argument("--file", help="a file holding the data, or - for standard input")
    command("sync", cmd_sync, "one round: take what others sent, acknowledge it, remove or write again mine", True)
    command("status", cmd_status, "what this party sent, took and had acknowledged", True)
    c = command("skip", cmd_skip, "an operator vouches a lost gap: --party <p> --from <seq> --through <seq> --id <the next packet's prev>", True)
    c.add_argument("--party", required=True)
    c.add_argument("--from", dest="first", type=int, required=True)
    c.add_argument("--through", type=int, required=True)
    c.add_argument("--id", required=True)
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except (RelayError, sp.NoPublicKey) as e:
        print(f"packet-relay: {e}", file=sys.stderr)
        return 2
    except sp.Refused as e:
        print(f"packet-relay: refused, {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"packet-relay: {e}", file=sys.stderr)
        return 2
