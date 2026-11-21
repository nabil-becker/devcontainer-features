"""The facilitator command (the Feature's NOTES, "Commands"; its Taskfile calls it). Exit 0 done, 1 failed
or not ready, 2 bad usage."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time

from . import __version__, identity, mcp, mesh as mesh_mod, peers, settings as settings_mod
from .app import Facilitator, FacilitatorError, Session, _ago
from .directory import DirectoryError
from .identity import IdentityError
from .infra import MESH_COMPONENTS, InfraError
from .participants import ListError
from .record import FACILITATOR, RecordError
from .settings import SettingsError
from .signer import SignerError, openbao_status
from .transcript import TranscriptError

ERRORS = (FacilitatorError, InfraError, ListError, RecordError, SettingsError, SignerError, DirectoryError,
          TranscriptError, IdentityError, peers.PeersError, mesh_mod.MeshError)
AGENT_JOB_VARS = ("DEVHOST_JOB_CHILD", "CLAUDECODE", "FACILITATOR_HANDLE")


def agent_job() -> str | None:
    """The variable that makes this an agent's job (the rule of ADR-0048 decision 4 that every OpenBao share and
    token task follows; FACILITATOR_HANDLE marks a participant's own process), or None."""
    names = list(AGENT_JOB_VARS) + os.environ.get("FACILITATOR_AGENT_JOB_VARS", "").split() \
        + os.environ.get("OPENBAO_AGENT_JOB_VARS", "").split()
    return next((v for v in names if os.environ.get(v)), None)


def refuse_in_agent_job(what: str) -> None:
    v = agent_job()
    if v:
        raise FacilitatorError(f"{what} refuses to run inside an agent's job ({v} is set): it is a person's act "
                               "(a join token is a secret, a revoke cuts a node off). Run it yourself in a plain terminal")


def _emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str) if getattr(a, "json", False) else text)


def _fac(a) -> Facilitator:
    return Facilitator(settings_mod.load())


def _bundle() -> dict | None:
    """The node bundle's MANIFEST.json (beside lib/ in /opt/facilitator), or None from a source tree."""
    try:
        return json.loads((settings_mod.LIB.parent / "MANIFEST.json").read_text())
    except (OSError, ValueError):
        return None


def _deprecations(fac) -> None:
    """CONTRIBUTING's deprecation notice: one line on stderr from version and check."""
    for name in fac.s.deprecated():
        print(f"facilitator: {name} is deprecated: use bundleVersion (removed in 1.0.0)", file=sys.stderr)


def _versions(fac) -> dict:
    out = {"facilitator": __version__, "python": sys.version.split()[0], "library": str(settings_mod.LIB),
           "mode": fac.s["FACILITATOR_MODE"]}
    b = _bundle()
    out["bundle"] = f"{b.get('version')} linux-{b.get('arch')}" if b else "none (a source tree)"
    try:
        from registerengine import __version__ as rv, core
        out["register-engine"] = rv
        out["sign-packet"] = core.sp.__version__
    except Exception:                          # noqa: BLE001
        pass
    inf = fac.infra()
    for c, flag in (("dir", "version"), ("slim", "version")):
        b = inf.binary(c)
        name = "dirctl" if c == "dir" else "slimctl"
        if not b:
            out[name] = "missing"
            continue
        r = subprocess.run([b, flag], capture_output=True, text=True, timeout=30)
        txt = (r.stdout + r.stderr).strip()
        out[name] = next((w.lstrip("v") for line in txt.splitlines() for w in line.replace("\t", " ").split()
                          if w[:1].isdigit() or (w[:1] == "v" and w[1:2].isdigit())), txt[:40])
    try:
        import slim_bindings
        out["slim-bindings"] = slim_bindings.get_version()
    except Exception:                          # noqa: BLE001
        out["slim-bindings"] = "missing"
    return out


def cmd_version(a) -> int:
    fac = _fac(a)
    v = _versions(fac)
    v["backend"] = fac.s["FACILITATOR_BACKEND"]
    _deprecations(fac)
    _emit(a, v, f"facilitator {v['facilitator']} (backend {v['backend']}; mode {v['mode']}; register-engine "
                f"{v.get('register-engine')}, sign-packet {v.get('sign-packet')})\n"
                f"bundle       : {v['bundle']}\n"
                f"dirctl       : {v['dirctl']}\nslimctl      : {v['slimctl']}\nslim-bindings: {v['slim-bindings']} "
                f"(the node version it speaks)\npython       : {v['python']}\nlibrary      : {v['library']}")
    return 0


TLS_REFUSALS = (("UnknownIssuer", "a certificate from a CA the other side does not trust (lock one)"),
                ("CertificateRequired", "a dialer with no client certificate"),
                ("NotValidForName", "the certificate's DNS name is not the server_name dialled"),
                ("not valid for name", "the certificate's DNS name is not the server_name dialled"),
                ("BadSignature", "a certificate whose signature does not check"),
                ("Expired", "an expired certificate"))


def tls_refusals(fac, lines: int = 400) -> dict[str, int]:
    """TLS refusals in the SLIM node's log: a refused peer sees only a timeout, the reason is in the log of the
    side that refused, the dialer's (spike 2). Counted by kind from the last `lines` lines."""
    try:
        tail = (fac.state.logs / "slim.log").read_bytes().decode(errors="replace").splitlines()[-lines:]
    except OSError:
        return {}
    out: dict[str, int] = {}
    for line in tail:
        for word, _ in TLS_REFUSALS:
            if word in line:
                out[word] = out.get(word, 0) + 1
    return out


def mesh_parts(fac) -> list[tuple]:
    """check's lines for the mesh (slice N3): the file and its findings, the role, the certificate, what is open
    beyond loopback (ADR-0071), the hub, TLS refusals from the SLIM log and lock two's refusals."""
    out = []
    mf, m = fac.mesh_file, fac.mesh
    where = f"{mf.path}" + ("" if mf.exists else " (none: solo, standalone)")
    if mf.findings:
        out.append(("mesh", False, f"{where}: {len(mf.findings)} finding(s), so the node runs standalone (fail narrow): "
                    + "; ".join(f"{f.line}: {f.rule}: {f.message}" for f in mf.findings[:3])))
        return out
    out.append(("mesh", True, f"{where}: preset {m.preset}, role {m.role}, node {m.node_id}"))
    if m.role == "standalone":
        out.append(("open ports", True, "none beyond loopback (role standalone)", False))
        return out
    store = identity.Store(fac.state.home)
    dom = m.domain
    st = store.cert_state(dom) if dom else {"present": False}
    if st.get("present"):
        left = st["not_after"] - time.time()
        out.append(("certificate", not st["expired"], f"{st['id']} DNS {','.join(st['dns'])}, "
                    + ("EXPIRED" if st["expired"] else f"{left / 3600:.1f} h left, renewed at half life")))
    else:
        out.append(("certificate", False, f"none in {dom}: " + ("facilitator node join <hub> --token <token>"
                                                                if m.role == "spoke" else "the issuer (OpenBao) must be unsealed, then facilitator infra up")))
    rows = m.open_ports()
    out.append(("open ports", True, "; ".join(f"{r['what']} {r['address']} ({r['when']})" for r in rows)
                or "none beyond loopback (a spoke dials out)", False))
    try:
        status = json.loads(store.status_file.read_text())
    except (OSError, ValueError):
        status = {}
    if m.role == "spoke":
        seen = status.get("hub_seen")
        out.append(("hub", bool(seen), f"{m.node.get('hub_node')} at {m.node.get('hub')} (server_name {m.node.get('hub_name')}): "
                    + (f"its roster last received {seen}" if seen else "no roster received yet (peers part down, or the hub unreachable)")))
    else:
        r = identity.roster(store)
        nodes = r.get("nodes", {})
        out.append(("roster", True, f"{sum(1 for n in nodes.values() if not n.get('revoked'))} node(s) joined, "
                    f"{sum(1 for n in nodes.values() if n.get('revoked'))} revoked; join tokens live: "
                    f"{identity.live_tokens(store)}", False))
    cards = fac.net.cards()
    out.append(("peers", True, ", ".join(f"{n} ({c['level']})" for n, c in sorted(cards.items())) or "no card admitted yet",
                False))
    clash = fac.net.clashes()
    if clash:
        out.append(("handles", True, f"announced by two nodes, reachable on neither: {', '.join(sorted(clash))}", False))
    tls = tls_refusals(fac)
    out.append(("tls refusals", True, "; ".join(f"{k} x{v}: {dict(TLS_REFUSALS)[k]}" for k, v in tls.items())
                or "none in the SLIM log", False))
    ref = peers.refusals(store, 5)
    out.append(("lock two", True, "; ".join(f"{x['at']} {x['what']}: {x['why']}" for x in ref) or "nothing refused", False))
    return out


def cmd_check(a) -> int:
    if a.paths:
        return lint(a)
    fac = _fac(a)
    parts = []

    def part(name, ok, detail, needed=True):
        parts.append({"part": name, "ready": bool(ok), "detail": detail, "needed": needed})

    _deprecations(fac)
    leaf = fac.s.mode() == "leaf"
    part("mode", True, "leaf: the thin client only; no Directory, SLIM or ssh-agent runs here" if leaf
         else "node: the Directory, SLIM and the ssh-agent run here")
    part("python", sys.version_info >= (3, 11), sys.version.split()[0])
    for tool in ("ssh-keygen", "ssh-agent", "ssh-add"):
        part(tool, shutil.which(tool), shutil.which(tool) or "missing (openssh-client)")
    part("backend", True, f"{fac.s['FACILITATOR_BACKEND']} (from {fac.s.sources['FACILITATOR_BACKEND']})")
    ok, detail = fac.state.writable()
    part("state", ok, detail)
    try:
        fac.record
        part("record", True, "the conversation type loads (register-engine, sign-packet)")
    except RecordError as e:
        part("record", False, str(e))
    v = _versions(fac)
    part("dirctl", v["dirctl"] != "missing", v["dirctl"])
    part("slimctl", v["slimctl"] != "missing" or leaf, v["slimctl"] if not leaf else "not installed (mode leaf)",
         needed=not leaf)
    transport = fac.s["FACILITATOR_TRANSPORT"]
    part("slim-bindings", v["slim-bindings"] != "missing" or transport == "poll",
         v["slim-bindings"] if transport == "slim" else f"{v['slim-bindings']} (transport poll: tests only, no SLIM)")
    st = openbao_status()
    fb = (fac.state.keys / "FALLBACK").exists()
    part("keys", True, f"OpenBao {st}" + ("; some keys are in the 0.1.0 fallback file (keys/FALLBACK)" if fb else ""))
    for p_ in mesh_parts(fac):
        part(*p_)
    inf = fac.infra()
    for row in ([] if leaf else inf.status()):
        why = "healthy" if row["healthy"] else "not running: facilitator infra up"
        if row.get("port_owners"):
            why += "; port in use by " + ", ".join(f"{o} ({k})" for k, o in row["port_owners"].items())
        part(row["component"], row["healthy"], f"{why} {' '.join(row.get('ports', {}).values())}".strip())
    try:
        plist, cfg, warnings, path = fac.participants()
        part("participants", True, f"{len(plist)} in {path}" + ("" if path.exists() else " (none yet)"), needed=False)
        roster = fac.state.roster()
        for p in plist:
            reg = p.name in roster
            tok = (fac.state.tokens / p.name).exists()
            seen = fac.state.last_seen(p.name)
            part(f"  {p.name}", reg and tok, f"{'registered' if reg else 'not registered (facilitator register ' + p.name + ')'}"
                 f", token {'made' if tok else 'missing'}, attachment {p.attachment} last seen {_ago(seen)}", needed=False)
        for w in warnings:
            part("  note", True, w, needed=False)
    except ListError as e:
        part("participants", False, str(e))
    _emit(a, parts, "\n".join(f"facilitator: {p['part']:<14} {'ready' if p['ready'] else 'NOT READY'}  {p['detail']}"
                              for p in parts))
    return 0 if all(p["ready"] for p in parts if p["needed"]) else 1


def lint(a) -> int:
    """`check <paths>`: mesh.yml by NFR-11's contract: paths ('-' for standard input), findings as
    `path:line: rule: message` (or --format json), exit 0 clean, 1 findings, 2 usage. Names only, no secrets."""
    out = []
    for p in a.paths:
        if p == "-":
            text, name = sys.stdin.read(), "-"
        else:
            try:
                text, name = open(p).read(), p
            except OSError as e:
                print(f"facilitator: {p}: {e.strerror or e}", file=sys.stderr)
                return 2
        m = mesh_mod.parse(text)
        out += [{"path": name, "line": f.line, "rule": f.rule, "message": f.message} for f in m.findings]
    if a.format == "json" or a.json:
        print(json.dumps(out, indent=2))
    else:
        for f in out:
            print(f"{f['path']}:{f['line']}: {f['rule']}: {f['message']}")
    return 1 if out else 0


def cmd_explain(a) -> int:
    """What level a SPIFFE ID or a handle gets here, and what it may see (read only)."""
    fac = _fac(a)
    m = fac.mesh
    x = a.what
    out: dict = {"what": x}
    sid = mesh_mod.parse_id(x)
    if sid:
        lv = m.level_of_domain(sid.domain)
        out.update({"id": str(sid), "domain": sid.domain, "level": lv or "refused (not in trust)"})
        if lv:
            out["reaches"] = sorted(h for h in set(fac.state.roster()) - {"facilitator"}
                                    if mesh_mod.reach_ok(lv, m.exposure(h)))
    else:
        r = fac.remote().get(x)
        if r:
            out.update({"handle": x, "node": r["node"], "level": r["level"], "exposure": r["exposure"],
                        "id": f"spiffe://{r['domain']}/node/{r['node']}/agent/{x}"})
        else:
            out.update({"handle": x, "node": m.node_id, "exposure": m.exposure(x),
                        "id": f"spiffe://{m.domain or m.home_domain}/node/{m.node_id}/agent/{x}"})
    for lv in ("local", "private"):
        out.setdefault("limits", {})[lv] = {k: f"{v} ({src})" for k in mesh_mod.LIMIT_KEYS
                                            for v, src in [m.limit(lv, k, fac.s)]}
    _emit(a, out, "\n".join(f"{k}: {v}" for k, v in out.items() if k != "limits") + "\nlimits:\n" + "\n".join(
        f"  {lv}: " + ", ".join(f"{k} {v}" for k, v in d.items()) for lv, d in out["limits"].items()))
    return 0


def cmd_setup(a) -> int:
    """Never fatal: each problem is one line."""
    try:
        fac = _fac(a)
        fac.state.ensure()
        fac.record.facilitator_key()
        n = 0
        if a.rotate_tokens:
            for h, ident in fac.state.roster().items():
                if ident.get("kind") in ("agent", "human"):
                    fac.state.make_token(h)
                    n += 1
        if not a.quiet:
            print(f"facilitator: state ready in {fac.state.home}" + (f"; {n} participant token(s) made again" if a.rotate_tokens else ""))
    except Exception as e:                     # noqa: BLE001
        print(f"facilitator: setup: {e}", file=sys.stderr)
    return 0


def cmd_start(a) -> int:
    """postStartCommand: setup (tokens made again: they are valid for this container start), then the
    infrastructure when autostart is on. Never fatal; participants are never started."""
    a.rotate_tokens, a.quiet = True, False
    cmd_setup(a)
    try:
        fac = _fac(a)
        if fac.s.mode() == "leaf":
            print("facilitator: mode leaf: no daemon is started here (the thin client only)")
            return 0
        if not fac.s.bool("FACILITATOR_AUTOSTART"):
            print("facilitator: autostart is off; facilitator infra up starts the Directory and SLIM")
            return 0
        for c, word in fac.infra().up():
            print(f"facilitator: {c} {word}")
    except Exception as e:                     # noqa: BLE001
        print(f"facilitator: autostart did not complete: {e} (facilitator check; facilitator infra up)", file=sys.stderr)
    return 0


def cmd_infra(a) -> int:
    fac = _fac(a)
    inf = fac.infra()
    which = [a.component] if a.component else None
    if a.action == "up" and fac.s.mode() == "leaf":
        raise FacilitatorError("infra up: mode leaf runs no Directory, SLIM or ssh-agent here (the Feature's option "
                               "mode: node installs a node)")
    if a.action == "up":
        for c, word in inf.up(which):
            print(f"facilitator: {c} {word}")
        return 0
    if a.action == "down":
        for c, word in inf.down(which):
            print(f"facilitator: {c} {word}")
        return 0
    if a.action == "logs":
        if a.component == "agent":
            print("facilitator: the ssh-agent keeps no log")
            return 0
        print(inf.logs(a.component, a.lines))
        return 0
    rows = [r for r in inf.status() if not a.component or r["component"] == a.component]
    _emit(a, rows, "\n".join(
        f"facilitator: {r['component']:<6} {'healthy' if r['healthy'] else 'running' if r['running'] else 'stopped'}"
        f"{'  pid ' + str(r['pid']) if r['pid'] and r['running'] else ''}  {' '.join(r.get('ports', {}).values())}"
        + (f"  ({r['note']})" if r.get("note") else "") for r in rows))
    return 0 if all(r["healthy"] for r in rows) else 1


def node_run(a) -> int:
    """node run: the node in the foreground, for a container whose only process tree is the node (the server
    image, under tini). It makes the state folder and the facilitator's key, starts the ssh-agent, the Directory
    and the SLIM node, then waits: a signal (TERM, INT) stops all three and exits 0; one of them dying stops the
    others and exits 1, so the container's restart policy is the supervisor. The role is mesh.yml's: a hub also
    runs the peers part and its listeners (FACILITATOR_MESH_FILE, /etc/facilitator/mesh.yml in the image)."""
    fac = _fac(a)
    if fac.s.mode() == "leaf":
        raise FacilitatorError("node run: mode leaf runs no node (the Feature's option mode: node installs one)")
    fac.state.ensure()
    fac.record.facilitator_key()
    inf = fac.infra()
    stop: list[int] = []

    def on_signal(signum, _frame):
        stop.append(signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, on_signal)
    try:
        for c, word in inf.up():
            print(f"facilitator: {c} {word}", flush=True)
    except InfraError:
        inf.down()
        raise
    b = _bundle()
    opened = ", ".join(f"{r['what']} {r['address']}" for r in fac.mesh.open_ports()) or "every port on loopback"
    print(f"facilitator: node running (role {fac.mesh.role}, node {fac.mesh.node_id}; {opened}; facilitator {__version__}"
          + (f", bundle {b.get('version')} linux-{b.get('arch')}" if b else "") + f"; state {fac.state.home})",
          flush=True)
    rc = 0
    while not stop:
        try:                                   # reap what the node started and that has exited
            while os.waitpid(-1, os.WNOHANG)[0] > 0:
                pass
        except ChildProcessError:
            pass
        dead = [c for c in inf.components() if not inf.running(c)]
        if dead:
            time.sleep(0.5)                    # look twice before stopping the node
            dead = [c for c in dead if not inf.running(c)]
        if dead:
            print(f"facilitator: {', '.join(dead)} stopped; stopping the node (facilitator infra logs)",
                  file=sys.stderr, flush=True)
            rc = 1
            break
        time.sleep(1)
    for c, word in inf.down():
        print(f"facilitator: {c} {word}", flush=True)
    return rc


def cmd_node(a) -> int:
    return {"run": node_run, "peers": node_peers, "invite": node_invite, "join": node_join, "revoke": node_revoke,
            "approve": node_approve, "status": node_status, "restore-roster": node_restore, "bundle": node_bundle,
            "renew": node_renew}[a.action](a)


def node_bundle(a) -> int:
    """A federated domain's trust bundle (its CA certificates), placed by a person: lock one admits its nodes on the
    listener of the level mesh.yml maps the domain to, lock two checks that each one claims only that domain."""
    refuse_in_agent_job("facilitator node bundle")
    fac = _fac(a)
    if not a.target or not a.file:
        raise SettingsError("node bundle <domain> --file <PEM file with the domain's CA certificates>")
    if fac.mesh.level_of_domain(a.target) is None:
        raise FacilitatorError(f"node bundle: {a.target} is not in mesh.yml's trust; map it to a level first")
    pem = open(a.file).read()
    if not identity.pem_blocks(pem):
        raise FacilitatorError(f"node bundle: {a.file} holds no certificate")
    store = identity.Store(fac.state.home)
    store.ensure()
    store.write_bundle(a.target, pem)
    print(f"facilitator: the trust bundle of {a.target} ({len(identity.pem_blocks(pem))} certificate(s)) is in place; "
          "SLIM reads bundles at start: restart the node (facilitator infra down slim, then up; or the container)")
    return 0


def node_renew(a) -> int:
    """Asks the peers part to renew this spoke's certificate now (it does at half life on its own)."""
    fac = _fac(a)
    if fac.mesh.role != "spoke":
        raise FacilitatorError("node renew: a spoke's certificate (a hub renews its own at half life)")
    store = identity.Store(fac.state.home)
    store.ensure()
    (store.root / "renew-now").write_text(identity.now_utc() + "\n")
    print("facilitator: the peers part asks the hub for a new certificate within a few seconds (facilitator node status)")
    return 0


def node_peers(a) -> int:
    """The peers part, in the foreground (infra up starts it in the background)."""
    import asyncio
    fac = _fac(a)
    if fac.mesh.role == "standalone":
        raise FacilitatorError("node peers: the role is standalone (mesh.yml role spoke or hub runs it)")
    return asyncio.run(peers.Daemon(fac).main())


def node_invite(a) -> int:
    refuse_in_agent_job("facilitator node invite")
    fac = _fac(a)
    m = fac.mesh
    if m.role != "hub":
        raise FacilitatorError(f"node invite: only a hub invites (this node's role is {m.role})")
    if not m.node.get("join"):
        raise FacilitatorError("node invite: mesh.yml has no node.join (the join endpoint's address)")
    store = identity.Store(fac.state.home)
    if not store.bundle(m.domain).is_file():
        raise FacilitatorError("node invite: the hub has no certificate yet (unseal its OpenBao, then facilitator infra up)")
    _, port = mesh_mod.parse_addr(m.node["join"])
    tok = identity.make_token(store, f"{m.node['name']}:{port}", m.node["name"], store.bundle(m.domain).read_text())
    print(tok)
    print(f"facilitator: a join token for {m.domain} (level {m.level_of_domain(m.domain)}), single use, valid 15 minutes; "
          f"the join endpoint {m.node['name']}:{port} is open while it is live. On the new spoke: "
          "facilitator node join --token <token>", file=sys.stderr)
    return 0


def node_join(a) -> int:
    fac = _fac(a)
    tok = a.token
    if tok and os.path.isfile(tok):
        tok = open(tok).read().strip()
    if not tok:
        raise SettingsError("node join [<hub join address>] --token <token or a file holding it>")
    if fac.mesh.role == "hub":
        raise FacilitatorError("node join: this node is a hub")
    r = peers.join(fac, a.target, tok)
    _emit(a, r, f"facilitator: joined {r['domain']} (level {r['level']}) as {r['id']}; hub {r['hub']['node']} at "
                f"{r['hub']['slim']}; mesh.yml written ({r['mesh_file']}). Next: facilitator infra up (or restart the "
                "container): the SLIM node links to the hub and the peers part says hello")
    return 0


def node_revoke(a) -> int:
    refuse_in_agent_job("facilitator node revoke")
    fac = _fac(a)
    m = fac.mesh
    if m.role != "hub":
        raise FacilitatorError("node revoke: only the hub that issued a node's certificate revokes it")
    store = identity.Store(fac.state.home)
    r = identity.roster(store)
    n = r.get("nodes", {}).get(a.target)
    if n is None:
        raise FacilitatorError(f"node revoke: {a.target} has not joined this hub")
    if not a.yes:
        if not sys.stdin.isatty():
            raise FacilitatorError("node revoke asks to confirm: run it in a terminal, or pass --yes")
        if input(f"revoke {a.target}? its certificate is not renewed, and it is refused from now on [y/N] ").strip().lower() != "y":
            print("facilitator: not revoked")
            return 1
    n["revoked"] = True
    n["revoked_at"] = identity.now_utc()
    identity.save_roster(store, r)
    fac.net.revoke_card(a.target)
    note = ""
    try:
        iss = identity.Issuer(m.node["issuer"])
        if n.get("serial"):
            iss.revoke(n["serial"])
        iss.backup_roster(r)
    except (IdentityError, KeyError) as e:
        note = f" (OpenBao: {e})"
    print(f"facilitator: {a.target} revoked: its certificate is not renewed and expires within "
          f"{m.limit(m.level_of_domain(m.domain), 'svid_ttl')[0]}; lock two refuses it on this hub now and on every spoke "
          f"at its next roster. What it already holds is not recalled.{note}")
    return 0


def node_approve(a) -> int:
    raise FacilitatorError("node approve: not yet: slice N5 (a public node joins by its key and a person's approval; "
                           "a private node joins with a join token: facilitator node invite)")


def node_status(a) -> int:
    fac = _fac(a)
    store = identity.Store(fac.state.home)
    try:
        st = json.loads(store.status_file.read_text())
    except (OSError, ValueError):
        st = {}
    out = {"role": fac.mesh.role, "node": fac.mesh.node_id, "domain": fac.mesh.domain, "peers": st,
           "cards": {n: c["level"] for n, c in fac.net.cards().items()},
           "roster": identity.roster(store) if fac.mesh.role == "hub" else None,
           "refused": peers.refusals(store, 10)}
    _emit(a, out, json.dumps(out, indent=2, sort_keys=True, default=str))
    return 0


def node_restore(a) -> int:
    refuse_in_agent_job("facilitator node restore-roster")
    fac = _fac(a)
    if fac.mesh.role != "hub":
        raise FacilitatorError("node restore-roster: a hub's roster only")
    r = identity.Issuer(fac.mesh.node["issuer"]).restore_roster()
    identity.save_roster(identity.Store(fac.state.home), r)
    print(f"facilitator: the roster restored from OpenBao: {len(r.get('nodes', {}))} node(s)")
    return 0


def cmd_register(a) -> int:
    fac = _fac(a)
    plist, cfg, _, _ = fac.participants()
    handles = [p.name for p in plist] + list(cfg.humans) if a.all else a.handles
    if not handles:
        raise FacilitatorError("register <handle>... or --all")
    rows = []
    for h in handles:
        rows.append(fac.register(h, new_key=a.new_key, push=not a.no_directory))
    _emit(a, rows, "\n".join(
        f"facilitator: {r['handle']} registered ({r['kind']}, key in {r['keystore']}"
        + (f", token {r['token']}" if r.get("token") else "") + (f", record {r['cid']}" if r.get("cid") else "") + ")"
        for r in rows))
    return 0


def cmd_participants(a) -> int:
    fac = _fac(a)
    plist, cfg, warnings, path = fac.participants()
    roster = fac.state.roster()
    rows = [{**p.json(), "registered": p.name in roster, "cid": roster.get(p.name, {}).get("cid"),
             "keystore": roster.get(p.name, {}).get("keystore")} for p in plist]
    rows += [{"name": h, "kind": "human", "registered": h in roster} for h in cfg.humans]
    text = [f"facilitator: {path}"] + [
        f"  {r['name']:<20} {r.get('cli', '-'):<18} {r['kind']:<10} {'registered' if r['registered'] else 'not registered'}"
        + (f"  {r['description']}" if r.get("description") else "") for r in rows] + [f"  note: {w}" for w in warnings]
    _emit(a, {"file": str(path), "participants": rows, "warnings": warnings}, "\n".join(text))
    return 0


def cmd_status(a) -> int:
    from . import guard
    fac = _fac(a)
    w = fac.who()
    convs = []
    for c in fac.record.conversations():
        _, proj, _ = fac.record.read(c)
        if proj["thread"] is None:
            continue
        last = proj["messages"][proj["order"][-1]] if proj["order"] else None
        convs.append({"conversation": c, "kind": proj["thread"]["kind"], "members": proj["thread"]["members"],
                      "messages": len(proj["order"]), "last_hops": last["hops"] if last else 0,
                      "paused": guard.paused(proj) or "", "budget_used": guard.since_continue(proj),
                      "waiting": sum(1 for t in proj["tasks"].values() if t["state"] == "submitted")})
    out = {"participants": w["participants"], "conversations": convs}
    lines = ["participants:"] + [
        f"  @{p['handle']:<20} " + (f"{'attached' if p.get('attached') else 'not attached'}, last receive {p.get('last_seen')}"
                                    if p["kind"] == "agent" else "human") for p in w["participants"]]
    lines += ["conversations:"] + [
        f"  {c['conversation']} {c['kind']:<6} {', '.join(c['members'])}: {c['messages']} message(s), last hops "
        f"{c['last_hops']}, budget {c['budget_used']}/{fac.limits.message_budget}, {c['waiting']} waiting"
        + (f", PAUSED ({c['paused']}: a person's continue)" if c["paused"] else "") for c in convs]
    _emit(a, out, "\n".join(lines))
    return 0


def _handle(a, required: bool = True) -> str | None:
    """--as, else FACILITATOR_HANDLE (one MCP entry serves every agent whose harness sets it)."""
    h = getattr(a, "as_", None) or os.environ.get("FACILITATOR_HANDLE", "").strip() or None
    if h is None and required:
        raise SettingsError("no handle: set FACILITATOR_HANDLE (with FACILITATOR_TOKEN) in the CLI's environment, "
                            "or pass --as <handle>")
    return h


def cmd_mail(a) -> int:
    """Read only (the mail tool of a person's MCP session marks messages read; this never does)."""
    if a.notice or a.hook:
        # the turn hook: one line or nothing, never a failure, never a wait
        try:
            fac = _fac(a)
            h = _handle(a, required=False)
            line = fac.mail_notice(h) if h else ""
        except Exception:                      # noqa: BLE001 - a hook must never fail a turn
            line = ""
        if line and a.hook:
            print(json.dumps({"systemMessage": line, "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": line + " (the facilitator's mail tool reads them)"}}))
        elif line:
            print(line)
        return 0
    from .mcp import mail_text
    fac = _fac(a)
    h = _handle(a)
    if h not in fac.humans():
        raise FacilitatorError(f"{h} is not a human of facilitator.yml (humans: {', '.join(fac.humans())})")
    r = fac.mail(h, a.limit, mark=False)
    _emit(a, r, mail_text(r))
    return 0


def cmd_transcript(a) -> int:
    from .transcript import lines, transcript
    fac = _fac(a)
    if a.json:
        print(json.dumps(transcript(fac, a.conv, a.limit), indent=2, sort_keys=True))
        return 0
    print("\n".join(lines(fac, a.conv, a.limit)))
    return 0


def cmd_verify(a) -> int:
    from .verify import verify
    fac = _fac(a)
    r = verify(fac, a.conv, a.message)
    if a.format == "json":
        print(json.dumps(r, indent=2, sort_keys=True))
    else:
        for mid, lines in r["chains"].items():
            if a.message or mid == list(r["chains"])[-1]:
                print("\n".join(lines))
        for p in r["problems"]:
            print(f"{a.conv}: {p}")
        print(f"facilitator: {a.conv}: {r['entries']} entries, {r['messages']} message chain(s) walked: "
              f"{'every chain verifies back to a human' if r['ok'] else str(len(r['problems'])) + ' problem(s)'}")
    return 0 if r["ok"] else 1


def cmd_snippet(a) -> int:
    fac = _fac(a)
    plist, cfg, _, _ = fac.participants()
    p = next((x for x in plist if x.name == a.handle), None)
    human = a.handle in cfg.humans
    if p is None and not human:
        raise FacilitatorError(f"{a.handle} is neither in the participant list nor a human of facilitator.yml")
    tokens = fac.state.tokens / a.handle
    cfg_ = {"mcpServers": {"facilitator": {"type": "stdio", "command": "facilitator", "args": ["mcp"]}}}
    env = [f"FACILITATOR_HANDLE={a.handle}", f'FACILITATOR_TOKEN="$(cat {tokens})"']
    shared = "claude mcp add --scope user facilitator -- facilitator mcp"
    if human:
        hook = f"facilitator mail --as {a.handle} --hook 2>/dev/null || true"
        settings = {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]}}
        out = {"handle": a.handle, "kind": "human", "mcp_config": cfg_, "add": shared, "env": env,
               "token_file": str(tokens), "hook": settings, "notice": f"facilitator mail --as {a.handle} --notice",
               "instructions": mcp.persona(a.handle, True)}
        lines = [f"# {a.handle}: talk to the agents from your own Claude Code session, over the facilitator's MCP server",
                 "# (the Feature never edits a CLI's settings, NFR-13: run or paste these yourself).",
                 "# 1. The one shared MCP entry (the same for every agent and person; it names no handle):",
                 shared,
                 "# 2. Start your session with your handle and token in its environment (tokens are made again at",
                 "#    each container start, so never put the token in the entry):",
                 f"{' '.join(env)} claude",
                 "# 3. Optional, the turn hook: a line 'Facilitator: N new messages in c-...' at each prompt, or",
                 "#    nothing. Add this to ~/.claude/settings.json (or .claude/settings.local.json); it never",
                 "#    fails a turn:",
                 json.dumps(settings, indent=2),
                 "# Copilot CLI: the same MCP entry (copilot mcp add facilitator -- facilitator mcp) and environment;",
                 "#    it has no hook that can show a line at each turn, so ask it to call mail. In any shell:",
                 f"#    facilitator mail --as {a.handle} --notice",
                 "# Then: 'ask @jester for a joke'; 'any mail?'; 'continue c-...' when a conversation pauses."]
        _emit(a, out, "\n".join(lines))
        return 0
    out = {"handle": a.handle, "kind": "agent", "cli": p.cli, "persona": mcp.persona(a.handle), "mcp_config": cfg_,
           "add": shared, "env": env, "token_file": str(tokens)}
    lines = [f"# {a.handle}: attach its {p.cli} CLI to the facilitator (the Feature never edits a CLI's config, NFR-13)."]
    if p.cli == "claude":
        lines += ["# 1. The one shared MCP entry (once for every agent; it names no handle), through Claude Code's own command:",
                  shared,
                  "#    or, for one run: claude -p --mcp-config '" + json.dumps(cfg_) + "' ..."]
    elif p.cli == "openai-compatible":
        lines += ["# 1. A local model needs no MCP: its harness runs the model wrapper:",
                  f"facilitator model --as {a.handle} --endpoint http://localhost:11434/v1 --model <name> "
                  f"--definition {p.definition or '<persona file>'}"]
    else:
        lines += [f"# 1. The one shared stdio MCP entry (it names no handle), through {p.cli}'s own MCP command:",
                  json.dumps(cfg_)]
    lines += ["# 2. The harness starts the CLI with these two in its environment, never in the MCP entry of step 1",
              "#    (tokens are made again at each container start, so an entry would go stale):",
              *env,
              "# 3. Add this sentence to its definition (system prompt, profile or first message):",
              mcp.persona(a.handle)]
    _emit(a, out, "\n".join(lines))
    return 0


def cmd_mcp(a) -> int:
    proto = mcp.private_stdout()
    fac = _fac(a)
    wait = fac.s.int("FACILITATOR_RECEIVE_WAIT_SECONDS")

    handle = _handle(a)
    human = fac.state.roster().get(handle, {}).get("kind") == "human"

    def make():
        s = Session(fac, handle, os.environ.get("FACILITATOR_TOKEN"))
        try:
            s.tr = fac.transport_for(handle)
        except Exception as e:                 # noqa: BLE001
            raise FacilitatorError(f"SLIM is not reachable ({e}): facilitator infra up") from None
        return s

    server = mcp.Server(handle, make, wait, out=proto, inp=sys.stdin, human=human)
    try:
        return server.serve()
    finally:
        if server.session is not None and server.session.tr is not None:
            server.session.tr.close()


def cmd_model(a) -> int:
    from . import model
    fac = _fac(a)
    s = Session(fac, a.as_, os.environ.get("FACILITATOR_TOKEN"))
    s.tr = fac.transport_for(a.as_)
    definition = ""
    if a.definition:
        with open(a.definition) as f:
            definition = f.read()
    try:
        return model.run(s, a.endpoint, a.model, definition, a.wait or fac.s.int("FACILITATOR_RECEIVE_WAIT_SECONDS"),
                         once=a.once, api_key=os.environ.get("FACILITATOR_MODEL_API_KEY"))
    finally:
        s.tr.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="facilitator", description="The facilitator: conversations between agents of "
                                                                  "any vendor, on AGNTCY (the Feature's NOTES).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def command(name, fn, help_, json_=True):
        c = sub.add_parser(name, help=help_)
        if json_:
            c.add_argument("--json", action="store_true", help="output for machines")
        c.set_defaults(fn=fn)
        return c

    command("version", cmd_version, "what is installed")
    c = command("check", cmd_check, "what is ready, one line a part; non-zero when not. With paths: check mesh.yml "
                                    "files (path:line: rule: message; '-' reads standard input)")
    c.add_argument("paths", nargs="*")
    c.add_argument("--format", choices=["text", "json"], default="text")
    c = command("explain", cmd_explain, "the level a SPIFFE ID or a handle gets here, and the limits of each level")
    c.add_argument("what")
    c = command("setup", cmd_setup, "the state folder and the facilitator's key (idempotent, never fatal)", False)
    c.add_argument("--rotate-tokens", action="store_true", help="make every participant's token again")
    c.add_argument("--quiet", action="store_true")
    command("start", cmd_start, "postStartCommand: setup, tokens made again, infra up when autostart (never fatal)", False)
    c = command("infra", cmd_infra, "the Directory, SLIM and the ssh-agent: up, down, status, logs")
    c.add_argument("action", choices=["up", "down", "status", "logs"])
    c.add_argument("component", nargs="?", choices=MESH_COMPONENTS)
    c.add_argument("--lines", type=int, default=40)
    c = command("register", cmd_register, "a participant's key, token and OASF record (a person's key and token)")
    c.add_argument("handles", nargs="*")
    c.add_argument("--all", action="store_true", help="every participant of the list and every human")
    c.add_argument("--new-key", action="store_true", help="make a new key (the old one stays valid for what it signed)")
    c.add_argument("--no-directory", action="store_true", help="do not push the OASF record")
    c = command("node", cmd_node, "run (the node in the foreground: the server image's command), peers, invite, "
                                  "join, revoke, approve (slice N5), status, restore-roster")
    c.add_argument("action", choices=["run", "peers", "invite", "join", "revoke", "approve", "status", "restore-roster",
                                      "bundle", "renew"])
    c.add_argument("target", nargs="?", help="join: the hub's join address (default: the token's); revoke: the node; "
                                             "bundle: the trust domain")
    c.add_argument("--file", help="bundle: a PEM file with the domain's CA certificates")
    c.add_argument("--token", help="join: the join token, or a file holding it")
    c.add_argument("--yes", action="store_true", help="revoke: do not ask to confirm")
    command("participants", cmd_participants, "the participant list and who is registered")
    command("status", cmd_status, "who is attached, and each conversation's hops, budget and pause")
    c = command("mail", cmd_mail, "a person's unread messages, read only (the MCP tool mail marks them read); "
                                  "--notice: one line or nothing, for a turn hook, never failing")
    c.add_argument("--as", dest="as_")
    c.add_argument("--limit", type=int, default=20)
    c.add_argument("--notice", action="store_true", help="one line 'Facilitator: N new messages in ...', or nothing")
    c.add_argument("--hook", action="store_true", help="the same line as Claude Code hook JSON (UserPromptSubmit)")
    c = command("transcript", cmd_transcript, "a conversation, as text or --json (read only)")
    c.add_argument("--conv", required=True)
    c.add_argument("--limit", type=int, help="its last this many messages")
    c = command("verify", cmd_verify, "walk every message back to a human-signed root; exit 0 good, 1 a break", False)
    c.add_argument("--conv", required=True)
    c.add_argument("--message")
    c.add_argument("--format", choices=["text", "json"], default="text")
    c = command("snippet", cmd_snippet, "how to attach a participant's or a person's CLI: the shared MCP entry, the "
                                        "environment, the persona; for a person, the turn hook")
    c.add_argument("handle")
    c = command("mcp", cmd_mcp, "the MCP server (stdio) a participant's or a person's CLI starts; the handle from "
                                "FACILITATOR_HANDLE, or --as", False)
    c.add_argument("--as", dest="as_")
    c = command("model", cmd_model, "the local-model wrapper: receive, /v1/chat/completions, reply", False)
    c.add_argument("--as", dest="as_", required=True)
    c.add_argument("--endpoint", required=True)
    c.add_argument("--model", required=True)
    c.add_argument("--definition")
    c.add_argument("--wait", type=int)
    c.add_argument("--once", action="store_true", help="one turn (or one wait), then exit")
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except ERRORS as e:
        print(f"facilitator: {e}", file=sys.stderr)
        return 2 if isinstance(e, SettingsError) and "not yet" not in str(e) else 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
