"""The facilitator command (the Feature's NOTES, "Commands"; its Taskfile calls it). Exit 0 done, 1 failed
or not ready, 2 bad usage."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import __version__, clients as clients_mod, identity, mcp, mesh as mesh_mod, peers, settings as settings_mod
from .app import Facilitator, FacilitatorError, Session, _ago
from .directory import DirectoryError
from .identity import IdentityError
from .infra import ALL_COMPONENTS, InfraError
from .participants import ListError
from .record import FACILITATOR, RecordError
from .settings import SettingsError
from .signer import SignerError, openbao_status
from .transcript import TranscriptError

ERRORS = (FacilitatorError, InfraError, ListError, RecordError, SettingsError, SignerError, DirectoryError,
          TranscriptError, IdentityError, peers.PeersError, mesh_mod.MeshError, clients_mod.ClientError)
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
    try:
        from importlib import metadata
        out["mcp"] = metadata.version("mcp")
    except Exception:                          # noqa: BLE001
        out["mcp"] = "missing"
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
                f"(the node version it speaks)\nmcp          : {v['mcp']} (the http module's library)\npython       : {v['python']}\nlibrary      : {v['library']}")
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
        try:
            last = (json.loads(store.status_file.read_text()).get("errors") or [""])[-1]
        except (OSError, ValueError):
            last = ""
        out.append(("certificate", False, f"none in {dom}: " + (
            "facilitator node join --token <token>" if m.role == "spoke" else
            "its issuer must answer (the built-in one needs nothing; OpenBao unsealed by hand with the PKI and the AppRole file "
            "written; an ssh-agent holding the CA key; the peers part keeps asking, then opens the listeners)"
            + (f"; last: {last.split(' ', 1)[-1]}" if last else ""))))
    if m.role in mesh_mod.ISSUING_ROLES and dom:
        out.extend(_issuer_rows(fac, store, dom))
    if m.public_domain:
        pst = store.cert_state(m.public_domain)
        out.append(("public cert", bool(pst.get("present")) and not pst.get("expired"),
                    f"{pst['id']}, {(pst['not_after'] - time.time()) / 60:.0f} min left" if pst.get("present")
                    else f"none in {m.public_domain} yet (facilitator infra up)", False))
        out.append(("join requests", True, f"{sum(1 for r in identity.requests(store) if r['status'] == 'pending')} wait for a person "
                    "(facilitator node requests, node approve)", False))
    if m.role == "peer":
        out.append(("peers", True, ", ".join(f"{n} ({'dials it' if a_ != 'incoming' else 'dials us'})" for n, a_ in sorted(m.peers.items()))
                    or "none yet (facilitator node invite, node peer --token)", False))
    rot = identity.rotation(store)
    if rot:
        out.append(("secret rotation", rot.get("state") == "done", f"{rot['rid']} {rot.get('state')}"
                    + (f", still owed to {', '.join(rot['pending'])}" if rot.get("pending") else ""), False))
    rows = m.open_ports()
    out.append(("open ports", True, "; ".join(f"{r['what']} {r['address']} ({r['when']})" for r in rows)
                or "none beyond loopback (a spoke dials out)", False))
    try:
        status = json.loads(store.status_file.read_text())
    except (OSError, ValueError):
        status = {}
    if m.role == "peer":
        pass
    elif m.role == "spoke":
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
    shared = fac.net.shared_handles()
    if shared:
        out.append(("handles", True, "shared, so named with their node: " + "; ".join(
            f"{h}: {', '.join(v)}" for h, v in sorted(shared.items())), False))
    tls = tls_refusals(fac)
    out.append(("tls refusals", True, "; ".join(f"{k} x{v}: {dict(TLS_REFUSALS)[k]}" for k, v in tls.items())
                or "none in the SLIM log", False))
    ref = peers.refusals(store, 5)
    out.append(("lock two", True, "; ".join(f"{x['at']} {x['what']}: {x['why']}" for x in ref) or "nothing refused", False))
    return out


def http_parts(fac) -> list[tuple]:
    """check's lines for the MCP endpoint over HTTP (slice N4): off unless facilitator.http.listen is set; what refuses
    it (the preset solo, TLS, no approver); the level HTTP clients get; the clients and the audit chain."""
    out = []
    try:
        fcfg = fac.participants()[1]
    except ListError:
        return out
    cfg = fcfg.http
    from . import endpoint
    if cfg.issuers and not fcfg.http_errors:
        b = endpoint.base_url(cfg)
        out.append(("http oauth", True, "resource server for " + ", ".join(f"{i.name} ({i.issuer})" for i in cfg.issuers)
                    + f"; resource {b}{endpoint.PATH}, metadata {b}{endpoint.METADATA_PATHS[1]}; a client is an (issuer, subject), "
                    "enrolled on its first token and approved by a person (facilitator http issuers reads their keys)", False))
    ok, why = fac.http_ready()
    if not cfg.configured and not fcfg.http_errors:
        out.append(("http endpoint", True, "off (facilitator.http.listen is not set: nothing is open)", False))
    else:
        detail = (f"{cfg.listen}" + (" (disabled: http.enabled false)" if not cfg.enabled else "")
                  + (" TLS" if cfg.tls_cert else " behind a proxy" if cfg.behind_proxy else " plain (http.insecure)" if cfg.insecure else " plain, loopback")) if ok \
            else f"refused: {why}"
        out.append(("http endpoint", ok, detail, cfg.active or bool(fcfg.http_errors)))
    if cfg.insecure and not fcfg.http_errors:
        out.append(("http insecure", True, "warning: " + endpoint.INSECURE_WARNING, False))
    if cfg.configured or fac.clients.all():
        lv = fac.mesh.http_level()
        ap = fac.mesh.limit(lv, "approval")[0]
        out.append(("http level", True, f"level {lv} (mesh.yml trust {fac.mesh.http_domain}; public unless mapped private), "
                    f"approval {ap}", False))
        table = fac.clients.all()
        counts = {k: sum(1 for c in table.values() if c["status"] == k) for k in clients_mod.STATES}
        okc, detail = fac.clients.audit_ok()
        out.append(("http clients", okc, (", ".join(f"{n} {k}" for k, n in counts.items() if n) or "none yet")
                    + f"; audit: {detail}", False))
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
    part("approval", True, "; ".join(f"{lv} {fac.mesh.limit(lv, 'approval')[0]}"
                                     + ("" if fac.mesh.limit(lv, 'approval')[1].startswith("the default") else " (mesh.yml)")
                                     for lv in ("local", "private", "public")) + " (what a person must approve before a message "
         "that crosses from another node, or from an HTTP client, is delivered)", needed=False)
    for p_ in http_parts(fac):
        part(*p_)
    try:
        want_http = fac.participants()[1].http.active
    except ListError:
        want_http = False
    part("mcp", v["mcp"] != "missing" or not want_http, v["mcp"] if v["mcp"] != "missing" else
         "not installed (the node bundle carries it; needed only when facilitator.http.listen is set)", needed=want_http)
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
        if fac.net.active:
            got = fac.net.resolve(x)
            if len(got) > 1:
                raise FacilitatorError(f"@{x} names {len(got)} participants: "
                                       + ", ".join("@" + (g if "." in g else f"{g}.{m.node_id}") for g in got) + "; name one")
            x = got[0] if got else x
            out["what"] = x
        r = fac.remote().get(x)
        if r:
            out.update({"handle": r["handle"], "node": r["node"], "level": r["level"], "exposure": r["exposure"],
                        "id": f"spiffe://{r['domain']}/node/{r['node']}/agent/{r['handle']}"})
        else:
            out.update({"handle": x, "node": m.node_id, "exposure": m.exposure(x),
                        "id": f"spiffe://{m.domain or m.home_domain}/node/{m.node_id}/agent/{x}"})
    if out.get("level") in mesh_mod.LEVELS:
        mode, src = m.limit(out["level"], "approval")
        out["approval"] = f"{mode} ({src}): " + APPROVAL_TEXT[mode]
    for lv in ("local", "private", "public"):
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
            "renew": node_renew, "peer": node_peer, "request": node_request, "collect": node_collect,
            "requests": node_requests, "deny": node_deny, "secret": node_secret, "issuer": node_issuer}[a.action](a)


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


def _issuer_rows(fac, store, dom: str) -> list:
    """The issuer's tier (ruling K5, ADR-0078): who holds the CA key, and what to warn about. Warnings are rows that do not fail check."""
    iss = identity.make_issuer(fac.mesh, store, dom)
    if isinstance(iss, identity.Issuer):
        sealed = iss.sealed()
        return [("issuer", sealed is False, f"OpenBao {iss.addr}, mount {iss.mount}: "
                 + {True: "SEALED (unseal it by hand; nothing is issued or renewed until then)", False: "unsealed",
                    None: "not reachable"}[sealed])]
    if not isinstance(iss, identity.BuiltinIssuer):
        return [("issuer", True, f"a CA this node keeps for {dom}, its key a file in the volume (mode 600)", False)]
    st = iss.status()
    rows = []
    if st["tier"] == "ssh-agent":
        ag = st.get("agent", {})
        if not ag.get("reachable"):
            rows.append(("issuer", False, f"ssh-agent: {ag.get('error', 'unreachable')}; nothing is issued or renewed "
                         "until it answers, and certificates already issued stay valid until they expire"))
        elif not ag.get("holds_key"):
            rows.append(("issuer", False, f"ssh-agent at {ag['socket']} does not hold {ag['key']}"))
        else:
            rows.append(("issuer", ag.get("key_type") == "ssh-ed25519", f"ssh-agent at {ag['socket']}, CA key {ag['key']} "
                         f"({ag.get('key_type')}); the key is never a file" + ("" if ag.get("key_type") == "ssh-ed25519"
                                                                              else ": only ed25519 signs a certificate's bytes as they are")))
            if ag.get("other_keys"):
                rows.append(("issuer agent", True, f"warning: the agent also holds {ag['other_keys']} other key(s); it signs anything for any key it "
                             "holds, so a CA key belongs in an agent of its own", False))
    else:
        rows.append(("issuer", True, f"built-in CA for {dom}, no unseal: its key is a file in the volume (mode 600)"
                     + ("; the root is offline (export-root done)" if st.get("root_offline") else ""), False))
        rows.append(("issuer key", True, "warning: the CA key is a file in the volume (the last resort): anyone who reads the volume can "
                     "issue certificates for this domain; node.issuer.ssh_agent keeps it out of any file"
                     + ("" if st.get("root_offline") or not st.get("two_level") else
                        "; facilitator node issuer export-root takes the root key out of the volume"), False))
    return rows


def node_invite(a) -> int:
    refuse_in_agent_job("facilitator node invite")
    fac = _fac(a)
    m = fac.mesh
    store = identity.Store(fac.state.home)
    level = getattr(a, "level", None) or "private"
    if m.role not in mesh_mod.ISSUING_ROLES:
        raise FacilitatorError(f"node invite: only a hub or a peer invites (this node's role is {m.role})")
    if level == "public":
        pj = (m.node.get("public") or {}).get("join")
        dom = m.public_domain
        if not dom or not pj:
            raise FacilitatorError("node invite --level public: mesh.yml needs node.public.domain and node.public.join (preset open)")
        iss = identity.make_issuer(m, store, dom)
        ensure_cert = peers.ensure_own_cert
        try:
            ensure_cert(fac, dom)
        except identity.IdentityError as e:
            raise FacilitatorError(f"node invite: {e}") from None
        until = identity.open_window(store)
        _, port = mesh_mod.parse_addr(pj)
        _, lport = mesh_mod.parse_addr(m.node["listen"]["public"])
        bundle = iss.bundle()
        info = {"v": 1, "domain": dom, "join": f"{m.node['name']}:{port}", "name": m.node["name"], "node": m.node_id,
                "slim": f"{m.node['name']}:{lport}", "bundle": bundle}
        print(json.dumps(info, indent=2, sort_keys=True))
        print(f"facilitator: a request window for {dom} is open for 15 minutes (the public join endpoint {m.node['name']}:{port}). "
              f"Give the info above to the person who runs the other node (a channel of your own: its bundle is what they trust; "
              f"SHA-256 {hashlib.sha256(bundle.encode()).hexdigest()}). Nothing is issued until a person runs "
              "facilitator node approve <request> here.", file=sys.stderr)
        return 0
    if not m.node.get("join"):
        raise FacilitatorError("node invite: mesh.yml has no node.join (the join endpoint's address)")
    if not store.bundle(m.domain).is_file():
        raise FacilitatorError("node invite: this node has no certificate yet (infra up; a hub with OpenBao needs it unsealed, one with an ssh-agent needs the agent)")
    _, port = mesh_mod.parse_addr(m.node["join"])
    tok = identity.make_token(store, f"{m.node['name']}:{port}", m.node["name"], store.bundle(m.domain).read_text())
    print(tok)
    how = ("facilitator node peer --token <token>" if m.role == "peer" else "facilitator node join --token <token>")
    print(f"facilitator: a {'pairing' if m.role == 'peer' else 'join'} token for {m.domain} (level {m.level_of_domain(m.domain)}), "
          f"single use, valid 15 minutes; the join endpoint {m.node['name']}:{port} is open while it is live. On the other node: "
          + how, file=sys.stderr)
    return 0


def node_peer(a) -> int:
    fac = _fac(a)
    tok = a.token
    if tok and os.path.isfile(tok):
        tok = open(tok).read().strip()
    if not tok:
        raise SettingsError("node peer [<peer's join address>] --token <token or a file holding it>")
    try:
        r = peers.pair_with(fac, a.target, tok)
    except (peers.PeersError, identity.IdentityError) as e:
        raise FacilitatorError(str(e)) from None
    _emit(a, r, f"facilitator: paired with {r['node']} ({r['domain']}) at {r['slim']}; mesh.yml updated ({r['mesh_file']}). "
                "Restart the node's SLIM link: facilitator infra down slim, then up (or the container)")
    return 0


def node_request(a) -> int:
    fac = _fac(a)
    src = a.file or a.target
    if not src:
        raise SettingsError("node request <info file>  (the output of `node invite --level public` on the issuing node; - for stdin)")
    info = json.loads(sys.stdin.read() if src == "-" else open(src).read())
    try:
        r = peers.request_public(fac, info)
    except (peers.PeersError, identity.IdentityError) as e:
        raise FacilitatorError(str(e)) from None
    _emit(a, r, f"facilitator: request {r['id']} sent for {r['node']} (key {r['fp'][:16]}; CA bundle SHA-256 {r['bundle_sha256']}). "
                "A person on the other node approves it; then: facilitator node collect")
    return 0


def node_collect(a) -> int:
    fac = _fac(a)
    try:
        r = peers.collect_public(fac)
    except (peers.PeersError, identity.IdentityError) as e:
        raise FacilitatorError(str(e)) from None
    if r["status"] != "approved":
        _emit(a, r, f"facilitator: request {r['id']} is {r['status']}")
        return 1
    _emit(a, r, f"facilitator: approved: {r['id']} (public, 1 h certificates, renewed at half life while the issuer allows it); "
                f"hub {r['hub']['node']} at {r['hub']['slim']}; mesh.yml written. Next: facilitator infra up")
    return 0


def node_requests(a) -> int:
    fac = _fac(a)
    rows = [identity.request_view(r) for r in identity.requests(identity.Store(fac.state.home))]
    _emit(a, rows, "\n".join(f"facilitator: {r['id']}  {r['status']:<9} node {r['node']}  key {r['fp'][:16]}  asked {r['at']}"
                             + (f"  by {r['approved_by']}" if r.get("approved_by") else "") for r in rows)
          or "facilitator: no join requests")
    return 0


def _issuing(fac, what: str):
    if fac.mesh.role not in mesh_mod.ISSUING_ROLES or not fac.mesh.public_domain:
        raise FacilitatorError(f"node {what}: this node issues no public domain (mesh.yml node.public.domain, preset open)")
    return identity.Store(fac.state.home)


def node_approve(a) -> int:
    """A person's act: the request's key is approved for the public domain, a certificate (1 h) is issued to it, and the
    node joins the roster. The approval is a signed entry of the audit register, so the record shows who approved what and
    when (proposal 8.3)."""
    refuse_in_agent_job("facilitator node approve")
    fac = _fac(a)
    m = fac.mesh
    store = _issuing(fac, "approve")
    rid = a.target
    row = identity.get_request(store, rid or "")
    if row is None:
        raise FacilitatorError(f"node approve: no join request {rid!r} (facilitator node requests)")
    if row["status"] != "pending":
        raise FacilitatorError(f"node approve: {rid} is {row['status']}")
    r = identity.roster(store)
    if row["node"] in r.get("nodes", {}):
        raise FacilitatorError(f"node approve: the node {row['node']} is in the roster already")
    by = _by(fac, a)
    if not a.yes:
        if not sys.stdin.isatty():
            raise FacilitatorError("node approve asks to confirm: run it in a terminal, or pass --yes")
        if input(f"approve key {row['fp'][:16]} as node {row['node']} in {row['domain']}? [y/N] ").strip().lower() != "y":
            print("facilitator: not approved")
            return 1
    dom = m.public_domain
    ttl = m.svid_seconds("public")
    got = identity.make_issuer(m, store, dom).sign(row["csr"], row["node"], f"{row['node']}.{dom}", ttl)
    identity.update_request(store, rid, status="approved", cert=got["cert"], approved_by=by, approved_at=identity.now_utc())
    r.setdefault("nodes", {})[row["node"]] = {"serial": got["serial"], "joined": identity.now_utc(), "revoked": False,
                                              "domain": dom, "key": row["fp"], "approved_by": by}
    identity.save_roster(store, r)
    note = ""
    try:
        fac.audit.append("join-approved", row["node"], by, f"key {row['fp'][:16]} for {dom}")
    except Exception as e:                  # noqa: BLE001
        note = f" (the audit register: {e})"
    _emit(a, {"request": rid, "node": row["node"], "domain": dom, "by": by, "certificate_seconds": ttl},
          f"facilitator: {row['node']} approved by {by} for {dom}: a certificate of {ttl} s is issued; it collects it with "
          f"facilitator node collect, and renews it at half life until you revoke it{note}")
    return 0


def node_deny(a) -> int:
    refuse_in_agent_job("facilitator node deny")
    fac = _fac(a)
    store = _issuing(fac, "deny")
    row = identity.get_request(store, a.target or "")
    if row is None or row["status"] != "pending":
        raise FacilitatorError(f"node deny: no pending request {a.target!r}")
    by = _by(fac, a)
    identity.update_request(store, row["id"], status="denied", approved_by=by, approved_at=identity.now_utc())
    try:
        fac.audit.append("join-denied", row["node"], by, f"key {row['fp'][:16]}")
    except Exception:                       # noqa: BLE001
        pass
    print(f"facilitator: the request of {row['node']} denied by {by}")
    return 0


def node_secret(a) -> int:
    """The mesh's SLIM app secret, for a node that missed a rotation (a person carries it over a channel of their own)."""
    refuse_in_agent_job("facilitator node secret")
    fac = _fac(a)
    store = identity.Store(fac.state.home)
    if a.file:
        sec = open(a.file).read().strip()
        if len(sec) < 32:
            raise FacilitatorError("node secret --file: a mesh secret is at least 32 characters")
        store.set_mesh_secret(sec)
        print("facilitator: the mesh secret is set; restart the node's peers part (facilitator infra down, then up)")
        return 0
    sec = store.mesh_secret()
    if not sec:
        raise FacilitatorError("node secret: this node holds no mesh secret")
    print(sec)
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
    """Cuts a node off (proposal 12.2): its certificate is not renewed and expires within the level's svid_ttl (public: 1 h),
    lock two refuses it from now on, its card is dropped, and the mesh's SLIM app secret rotates (ruling H4): the nodes that
    remain are handed the new one, so the revoked node's link, which a certificate alone would keep until it expires, can
    no longer form. What it already holds is not recalled."""
    refuse_in_agent_job("facilitator node revoke")
    fac = _fac(a)
    m = fac.mesh
    if m.role not in mesh_mod.ISSUING_ROLES:
        raise FacilitatorError("node revoke: a hub or a peer revokes (the node that issued a certificate, or that trusts the peer)")
    store = identity.Store(fac.state.home)
    r = identity.roster(store)
    n = r.get("nodes", {}).get(a.target)
    if n is None and a.target not in m.peers:
        raise FacilitatorError(f"node revoke: {a.target} has not joined this node and is not in node.peers")
    if not a.yes:
        if not sys.stdin.isatty():
            raise FacilitatorError("node revoke asks to confirm: run it in a terminal, or pass --yes")
        if input(f"revoke {a.target}? its certificate is not renewed, and it is refused from now on [y/N] ").strip().lower() != "y":
            print("facilitator: not revoked")
            return 1
    if n is not None:
        n["revoked"] = True
        n["revoked_at"] = identity.now_utc()
        identity.save_roster(store, r)
    rv = peers.Daemon.revoked_names(store)
    rv.add(a.target)
    (store.root / "revoked.json").write_text(json.dumps(sorted(rv)))
    fac.net.revoke_card(a.target)
    note = ""
    level = m.level_of_domain((n or {}).get("domain") or m.domain) or "private"
    try:
        iss = identity.make_issuer(m, store, (n or {}).get("domain") or m.domain)
        if n and n.get("serial"):
            iss.revoke(n["serial"])
        iss.backup_roster(r)
    except (identity.IdentityError, KeyError) as e:
        note = f" (OpenBao: {e})"
    owed = sorted(x for x in {*fac.net.cards(), *[k for k, v in r.get("nodes", {}).items() if not v.get("revoked")]}
                  if x != a.target and x not in rv)
    rot = identity.begin_rotation(store, None, None, None, m.node_id, owed, f"{a.target} revoked")
    try:
        fac.audit.append("node-revoked", a.target, _by(fac, a), f"level {level}")
        fac.audit.append("secret-rotated", m.node_id, _by(fac, a), f"rotation {rot['rid']}, owed to {', '.join(owed) or 'nobody'}")
    except Exception:                       # noqa: BLE001
        pass
    print(f"facilitator: {a.target} revoked: its certificate is not renewed and expires within "
          f"{m.limit(level, 'svid_ttl')[0]}; lock two refuses it on this node now"
          + (" and on every spoke at its next roster" if m.role == "hub" else "")
          + f". The mesh secret rotates: the peers part hands the new one to {', '.join(owed) or 'no other node'} within "
          f"{identity.ROTATION_WAIT_SECONDS} s. What it already holds is not recalled.{note}")
    return 0


def _builtin(fac, what: str):
    m = fac.mesh
    if m.role not in mesh_mod.ISSUING_ROLES:
        raise FacilitatorError(f"node issuer {what}: only a hub or a peer is an issuer (this node's role is {m.role})")
    iss = identity.make_issuer(m, identity.Store(fac.state.home), m.domain)
    return iss


def node_issuer(a) -> int:
    """`node issuer status | export-root --out <file> | migrate`: the built-in issuer of a hub (rulings K3, K4, K5; ADR-0078)."""
    what = a.target or "status"
    if what not in ("status", "export-root", "migrate"):
        raise FacilitatorError("node issuer: status, export-root --out <file> or migrate")
    if what != "status":
        refuse_in_agent_job(f"facilitator node issuer {what}")
    fac = _fac(a)
    iss = _builtin(fac, what)
    if what == "status":
        if isinstance(iss, identity.Issuer):
            out = {"tier": "openbao", "openbao": iss.addr, "mount": iss.mount, "role": iss.role, "sealed": iss.sealed()}
        elif isinstance(iss, identity.BuiltinIssuer) or isinstance(iss, identity.LocalIssuer):
            out = iss.status() if isinstance(iss, identity.BuiltinIssuer) else {
                "tier": "file", "domain": iss.domain, "ca_present": iss.ca_pem.is_file(), "key_file": str(iss.ca_key)}
        _emit(a, out, json.dumps(out, indent=2, sort_keys=True, default=str))
        return 0
    if what == "export-root":
        if not isinstance(iss, identity.BuiltinIssuer):
            raise FacilitatorError("node issuer export-root: this node's CA is OpenBao's (take its root out there) or not a hub's built-in one")
        if not a.out:
            raise FacilitatorError("node issuer export-root: --out <a new file> (the root CA's key and certificate, mode 600)")
        try:
            got = iss.export_root(Path(a.out))
        except identity.IdentityError as e:
            raise FacilitatorError(str(e)) from None
        print(f"facilitator: the root CA's key and certificate are in {got['file']} (mode 600) and no longer in this node's volume. "
              "Take the file offline now (a password manager's attachment, a safe): it is what signs a new issuing CA, and "
              "whoever holds it can make certificates the spokes trust. This hub keeps issuing, and no spoke changes anything.")
        return 0
    if not isinstance(iss, identity.BuiltinIssuer):
        raise FacilitatorError("node issuer migrate: this hub's CA is already OpenBao's")
    cfg = dict(fac.mesh.node.get("issuer") or {})
    addr = a.openbao or cfg.get("openbao") or os.environ.get("BAO_ADDR")
    if not addr:
        raise FacilitatorError("node issuer migrate: the OpenBao address (--openbao, node.issuer.openbao, or BAO_ADDR)")
    tok = os.environ.get("FACILITATOR_OPENBAO_TOKEN") or ""
    if a.token_file:
        try:
            tok = Path(a.token_file).read_text().strip()
        except OSError as e:
            raise FacilitatorError(f"node issuer migrate: {a.token_file}: {e.strerror or e}") from None
    if not tok:
        raise FacilitatorError("node issuer migrate: a token that may configure the PKI mount (--token-file, or "
                               "FACILITATOR_OPENBAO_TOKEN): yours, not the hub's AppRole")
    bao = identity.Issuer({**cfg, "domain": fac.mesh.domain, "openbao": addr, "mount": a.mount or cfg.get("mount") or "pki"})
    try:
        got = iss.migrate_to_openbao(bao, tok)
    except identity.IdentityError as e:
        raise FacilitatorError(str(e)) from None
    print(f"facilitator: the hub's CA now lives in OpenBao ({addr}, mount {got['mount']}, role {got['role']}); the issuing CA's key is "
          f"no longer in this volume, and the roster ({got['nodes']} node(s)) is in OpenBao's KV. Spokes keep the same CA and bundle: "
          "none joins again. Now add to mesh.yml, then restart the hub:\n"
          f"  node.issuer.openbao: {addr}\n  node.issuer.mount: {got['mount']}\n  node.issuer.approle: <a file with role_id= and secret_id= "
          "of an AppRole that may sign with the role above>\n"
          "(until then the hub, with no key, cannot issue; certificates already out stay valid).")
    return 0


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
    store = identity.Store(fac.state.home)
    iss = identity.make_issuer(fac.mesh, store, fac.mesh.domain)
    try:
        r = iss.restore_roster()
    except identity.IdentityError as e:
        raise FacilitatorError(f"node restore-roster: {e}") from None
    identity.save_roster(store, r)
    print(f"facilitator: the roster restored from {'OpenBao' if isinstance(iss, identity.Issuer) else 'the volume'}: "
          f"{len(r.get('nodes', {}))} node(s)")
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


def _by(fac, a) -> str:
    """The person acting: --as (a human of facilitator.yml), else the first of facilitator.yml's humans. On a node with
    no person attached this is the hub's own humans list (ADR-0070 decision 6)."""
    h = getattr(a, "as_", None)
    humans = fac.humans()
    if h:
        if h not in humans:
            raise FacilitatorError(f"{h} is not a human of facilitator.yml (humans: {', '.join(humans)})")
        return h
    if not humans:
        raise FacilitatorError("facilitator.yml names no human to act for the node")
    return humans[0]


APPROVAL_TEXT = {"none": "nothing a person must approve",
                 "first-contact": "a person approves each new sender once (for approval_ttl)",
                 "every-message": "a person approves every message that arrives from another node",
                 "per-conversation": "a person approves the first message of each new conversation from another node"}


def cmd_answer(a) -> int:
    """facilitator approve | deny <message | conversation | client>: a person's answer to what waits (mail lists it)."""
    approve = a.cmd == "approve"
    refuse_in_agent_job(f"facilitator {a.cmd}")
    fac = _fac(a)
    by = _by(fac, a)
    if a.target[:2] in ("m-", "c-"):
        r = fac.answer_message(a.target, by, approve)
        _emit(a, r, "\n".join(f"facilitator: {x['conversation']}/{x['message_id']} from {x['from']} {x['answer']} by {by}"
                              + (", delivered" if x["delivered"] else ", not delivered") for x in r["answered"]))
        return 0
    if not approve:
        raise FacilitatorError(f"deny: {a.target!r} is not a held message or conversation id (facilitator mail lists them); "
                               "a client is denied with facilitator http deny <client>")
    r = fac.approve_client(a.target, by)
    _emit(a, r, f"facilitator: {a.target} approved by {by}: " + (", ".join(
        f"{x['conversation']}/{x['message_id']} {'delivered' if x['delivered'] else 'not delivered'}" for x in r["released"])
        or "no held message"))
    return 0


def cmd_http(a) -> int:
    """facilitator http serve | token | list | approve | deny | revoke | forget | audit (slice N4)."""
    fac = _fac(a)
    act = a.action
    if act == "serve":
        from .endpoint import Daemon, EndpointError
        try:
            return Daemon(fac).run()
        except EndpointError as e:
            raise FacilitatorError(f"http serve: {e}") from None
        except ImportError as e:
            raise FacilitatorError(f"http serve: the mcp library is not installed here ({e}); the node bundle carries it "
                                   "(slice N4)") from None
    if act == "list":
        rows = [clients_mod.public_view(n, c) | {"id": fac.clients.spiffe_id(fac.mesh, n)}
                for n, c in sorted(fac.clients.all().items())]
        pend = {p["client"]: p["held"] for p in fac.pending_approvals()}
        for r in rows:
            r["held"] = pend.get(r["client"], 0)
        _emit(a, rows, "\n".join(
            f"facilitator: {r['client']:<20} {r['status']:<9} level {fac.mesh.http_level()}, "
            + (f"OAuth, subject {r['subject']} of {r['issuer']}, " if r["auth"] == "oauth" else "") + f"created {r['created']}"
            + (f", approved {r['approved_at']} by {r['approved_by']}" if r["approved_at"] else "")
            + (f", {r['held']} message(s) wait for approval" if r["held"] else "") for r in rows) or "facilitator: no HTTP clients yet "
            "(facilitator http token <client>)")
        return 0
    if act == "issuers":
        return _http_issuers(a, fac)
    if act == "audit":
        ok, detail = fac.clients.audit_ok()
        log = fac.clients.audit_log()
        _emit(a, {"ok": ok, "detail": detail, "events": log},
              "\n".join(f"{e['at']} {e['event']:<9} {e['client']} by {e['by']}" for e in log) + f"\nfacilitator: audit: {detail}")
        return 0 if ok else 1
    refuse_in_agent_job(f"facilitator http {act}")
    if not a.client:
        raise SettingsError(f"http {act} <client>")
    by = _by(fac, a)
    if act == "token":
        r = fac.enrol_http(a.client, by, a.label or "")
        if getattr(a, "json", False):
            print(json.dumps(r, indent=2, sort_keys=True))
            return 0
        print(r["token"])
        cfg = fac.participants()[1].http
        url = (cfg.url.rstrip("/") if cfg.url else f"{'https' if cfg.tls_cert else 'http'}://{cfg.listen or '<http.listen>'}") + "/mcp"
        print(f"facilitator: the token of the HTTP client {r['client']} (shown once; only its hash is kept): level {r['level']}, "
              f"approval {r['approval']}, {r['id']}. Claude Code: claude mcp add --transport http {r['client']} {url} --header "
              f"\"Authorization: Bearer <token>\"; Copilot CLI: copilot mcp add --transport http ... with the same header "
              f"(NOTES, 'MCP over HTTP'). {'Its first message waits for facilitator http approve ' + r['client'] + '.' if r['approval'] == 'first-contact' else ''}",
              file=sys.stderr)
        return 0
    if act == "approve":
        r = fac.approve_client(a.client, by)
        _emit(a, r, f"facilitator: {a.client} approved by {by}: " + (", ".join(
            f"{x['conversation']}/{x['message_id']} {'delivered' if x['delivered'] else 'not delivered'}" for x in r["released"])
            or "no held message"))
        return 0
    if act in ("deny", "revoke"):
        r = (fac.deny_client if act == "deny" else fac.revoke_client)(a.client, by)
        _emit(a, r, f"facilitator: {a.client} {r['status']} by {by}: its token no longer works" + (
            f"; {r['dropped']} held message(s) not delivered" if r["dropped"] else ""))
        return 0
    if act == "forget":
        r = fac.forget_client(a.client, by)
        _emit(a, r, f"facilitator: {a.client} forgotten by {by} (it was {r['was']}): " + (
            "its next valid OAuth token enrols it anew, held for a person's approval" if r["auth"] == "oauth" else
            f"a new token can be made (facilitator http token {a.client})") + "; the record keeps naming it")
        return 0
    raise SettingsError(f"http {act}")


def _http_issuers(a, fac) -> int:
    """facilitator http issuers: the authorization servers of facilitator.http.issuers and, asked for here only, whether
    each one's keys can be read now (the one place the node fetches an issuer's JWKS on request; `check` fetches nothing)."""
    from . import endpoint, oauth
    cfg = fac.participants()[1].http
    if not cfg.issuers:
        _emit(a, [], "facilitator: no OAuth issuers (facilitator.http.issuers is empty): only bearer tokens are accepted")
        return 0
    base = endpoint.base_url(cfg)
    ver = oauth.Verifier(cfg.issuers, f"{base}{endpoint.PATH}", insecure=cfg.insecure)
    rows, bad = [], 0
    for i in cfg.issuers:
        ok, detail = ver.check_reachable(i)
        bad += not ok
        rows.append(i.json() | {"reachable": ok, "detail": detail})
    _emit(a, {"resource": f"{base}{endpoint.PATH}", "metadata": f"{base}{endpoint.METADATA_PATHS[1]}", "issuers": rows},
          f"facilitator: resource {base}{endpoint.PATH}; protected-resource metadata {base}{endpoint.METADATA_PATHS[1]}\n"
          + "\n".join(f"  {r['name']:<16} {r['issuer']}  {'ok' if r['reachable'] else 'NOT READABLE'}: {r['detail']}" for r in rows))
    return 1 if bad else 0


def cmd_audit(a) -> int:
    """facilitator audit verify | replay | show: the signed register of enrolments (slice N5a, ruling HC3)."""
    fac = _fac(a)
    if a.action == "replay":
        n = fac.audit.replay()
        ok, detail = fac.audit.verify()
        _emit(a, {"replayed": n, "ok": ok, "detail": detail}, f"facilitator: {n} line(s) of http/audit.jsonl put in the audit register; {detail}")
        return 0 if ok else 1
    if a.action == "show":
        ev = fac.audit.events()
        _emit(a, ev, "\n".join(f"{e['at']} {e['event']:<15} {e['subject']} by {e['by']}" + (f" ({e['detail']})" if e.get('detail') else "")
                               for e in ev) or "facilitator: the audit register is empty")
        return 0
    ok, detail = fac.audit.verify()
    _emit(a, {"ok": ok, "detail": detail}, f"facilitator: audit register: {'verifies' if ok else 'DOES NOT VERIFY'}: {detail}")
    return 0 if ok else 1


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
        for p in r.get("partial", []):
            print(f"{a.conv}: partial: {p}")
        if r.get("replica"):
            print(f"{a.conv}: a replica copied at policy {r['replica']}: what it holds verifies; what policy keeps off this node "
                  "is not a break (exit 0), and a break in what is here is (exit 1)")
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
    c.add_argument("component", nargs="?", choices=ALL_COMPONENTS)
    c.add_argument("--lines", type=int, default=40)
    c = command("register", cmd_register, "a participant's key, token and OASF record (a person's key and token)")
    c.add_argument("handles", nargs="*")
    c.add_argument("--all", action="store_true", help="every participant of the list and every human")
    c.add_argument("--new-key", action="store_true", help="make a new key (the old one stays valid for what it signed)")
    c.add_argument("--no-directory", action="store_true", help="do not push the OASF record")
    c = command("audit", cmd_audit, "the signed audit register of enrolments: verify (the chain, and the http log fully replayed), "
                                    "replay (put the lines of http/audit.jsonl in it), show")
    c.add_argument("action", choices=["verify", "replay", "show"])
    c = command("node", cmd_node, "run (the node in the foreground: the server image's command), peers, invite, "
                                  "join, peer, request, collect, requests, approve, deny, revoke, secret, status, restore-roster, issuer "
                                  "(status | export-root --out <file> | migrate)")
    c.add_argument("action", choices=["run", "peers", "invite", "join", "revoke", "approve", "status", "restore-roster",
                                      "bundle", "renew", "peer", "request", "collect", "requests", "deny", "secret", "issuer"])
    c.add_argument("--level", choices=["private", "public"], help="invite: a join or pairing token (private), or a request window for "
                                                                  "the public domain (public)")
    c.add_argument("--as", dest="as_", help="approve, deny: the person acting (a human of facilitator.yml)")
    c.add_argument("target", nargs="?", help="join: the hub's join address (default: the token's); revoke: the node; "
                                             "bundle: the trust domain")
    c.add_argument("--file", help="bundle: a PEM file with the domain's CA certificates")
    c.add_argument("--token", help="join: the join token, or a file holding it")
    c.add_argument("--yes", action="store_true", help="revoke: do not ask to confirm")
    c.add_argument("--out", help="issuer export-root: a new file for the root CA's key and certificate (mode 600)")
    c.add_argument("--openbao", help="issuer migrate: the OpenBao address (default node.issuer.openbao, else BAO_ADDR)")
    c.add_argument("--mount", help="issuer migrate: the PKI mount (default node.issuer.mount, else pki)")
    c.add_argument("--token-file", help="issuer migrate: a file holding an OpenBao token that may configure the mount "
                                        "(the Operator's own, not the hub's AppRole)")
    c = command("http", cmd_http, "the MCP endpoint over HTTP (slice N4): serve (the infra part runs it), token <client> (a "
                                  "person's act: a bearer token, shown once), list, approve <client>, deny <client>, "
                                  "revoke <client>, forget <client> (a revoked or denied client back as new), audit, issuers (the OAuth authorization servers, and whether their keys can be read)")
    c.add_argument("action", choices=["serve", "token", "list", "approve", "deny", "revoke", "forget", "audit", "issuers"])
    c.add_argument("client", nargs="?")
    c.add_argument("--label", help="token: a note for the list")
    c.add_argument("--as", dest="as_", help="the person acting (a human of facilitator.yml; default the first)")
    for verb, what in (("approve", "approves"), ("deny", "denies")):
        c = command(verb, cmd_answer, f"a person {what} what waits: a held message (m-...) or conversation (c-...) from "
                                      "facilitator mail" + ("; or an HTTP client, or another node's agent (first contact)"
                                                            if verb == "approve" else "; the sender gets a signed notice"))
        c.add_argument("target")
        c.add_argument("--as", dest="as_", help="the person acting (a human of facilitator.yml; default the first)")
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
