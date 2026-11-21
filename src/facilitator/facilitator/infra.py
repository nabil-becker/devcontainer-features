"""The infrastructure the Feature starts and owns (proposal 4.8): the facilitator's ssh-agent, the Agent
Directory daemon and the SLIM node, as background processes with a pidfile (run/), a log (logs/) and a
health check, every port on loopback. Never a participant. `up` is idempotent; nothing is restarted on a
crash (`status` says so).

In a mesh (slice N3, mesh.yml role spoke or hub) a fourth part runs, `peers` (peers.Daemon), and the SLIM
node's configuration follows the role (ADR-0071: nothing opens beyond loopback unless the role and mesh.yml
say so): a hub adds one listener per trust level, each with that level's CA bundle and its own certificate
(lock one, ADR-0069); a spoke adds one static link to its hub, of type peer (SP3), and opens nothing."""
from __future__ import annotations

import json
import os
import secrets as pysecrets
import shutil
import signal
import socket
import subprocess
import time
from pathlib import Path

from . import mesh as mesh_mod
from .signer import Signer, _dcf_secret, openbao_status
from .state import State

LIB = Path(__file__).resolve().parents[1]
AGNTCY = LIB / "agntcy"
ONLINE_POLICY = ('[{"provider": "oasf", "op": ["push", "autosync", "index"], "name": "schema", '
                 '"schema_url": "https://schema.oasf.outshift.com"}]')
COMPONENTS = ("agent", "dir", "slim")
MESH_COMPONENTS = COMPONENTS + ("peers",)


class InfraError(RuntimeError):
    pass


# ---------------------------------------------------------------- ports and their owners

def port_open(port: int, timeout: float = 0.3) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def _listening_inodes(port: int) -> set[str]:
    out = set()
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(f).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            p = line.split()
            if len(p) > 9 and p[3] == "0A" and int(p[1].rsplit(":", 1)[1], 16) == port:
                out.add(p[9])
    return out


def port_owner(port: int) -> str | None:
    """'<command> (pid N)' of the process listening on the port, 'another user's process' when it cannot be
    seen, or None when nobody listens."""
    inodes = _listening_inodes(port)
    if not inodes:
        return None
    for pid in (p for p in os.listdir("/proc") if p.isdigit()):
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                link = os.readlink(f"/proc/{pid}/fd/{fd}")
                if link.startswith("socket:[") and link[8:-1] in inodes:
                    comm = Path(f"/proc/{pid}/comm").read_text().strip()
                    return f"{comm} (pid {pid})"
        except OSError:
            continue
    return "a process this user cannot see"


def pid_alive(pid: int, needle: str | None = None) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    if needle:
        try:
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            return False
        return needle in cmd
    return True


class Infra:
    def __init__(self, settings, state: State, signer: Signer, mesh=None, fac=None):
        self.s = settings
        self.state = state
        self.signer = signer
        self.mesh = mesh
        self.fac = fac
        self.ports = {
            "dir": {"api": settings.int("FACILITATOR_DIR_PORT", 1), "oci": settings.int("FACILITATOR_DIR_OCI_PORT", 1),
                    "p2p": settings.int("FACILITATOR_DIR_P2P_PORT", 1), "gateway": settings.int("FACILITATOR_DIR_GATEWAY_PORT", 1)},
            "slim": {"dataplane": settings.int("FACILITATOR_SLIM_PORT", 1)},
        }

    # ------------------------------------------------------------ binaries

    def meshed(self) -> bool:
        """A hub, or a spoke that has joined its hub (node.hub set by node join): the peers part runs."""
        m = self.mesh
        return m is not None and (m.role == "hub" or (m.role == "spoke" and bool(m.node.get("hub"))))

    def components(self) -> tuple:
        return MESH_COMPONENTS if self.meshed() else COMPONENTS

    def binary(self, c: str) -> str | None:
        name = self.s["FACILITATOR_DIRCTL"] if c == "dir" else self.s["FACILITATOR_SLIMCTL"]
        return name if os.path.isabs(name) and os.access(name, os.X_OK) else shutil.which(name)

    # ------------------------------------------------------------ SLIM's secrets

    def slim_secrets(self, create: bool = False) -> dict | None:
        """{password, secret, where}: SLIM's basic-auth password and the apps' shared secret, from OpenBao
        (facilitator/slim) or, as the 0.1.0 fallback, secrets/slim.json (mode 600)."""
        marker = self.state.slim / "secrets-in"
        where = marker.read_text().strip() if marker.exists() else ""
        cmd = _dcf_secret()
        if where == "openbao" and cmd:
            vals = {}
            for f in ("password", "secret"):
                r = subprocess.run([cmd, "get", "facilitator/slim", "--field", f], capture_output=True, text=True, timeout=30)
                if r.returncode != 0:
                    vals = {}
                    break
                vals[f] = r.stdout.strip()
            if vals:
                return {**vals, "where": "openbao"}
        f = self.state.secrets / "slim.json"
        if where == "file" and f.exists():
            try:
                d = json.loads(f.read_text())
                return {"password": d["password"], "secret": d["secret"], "where": "file"}
            except (ValueError, KeyError):
                pass
        if not create:
            return None
        vals = {"password": pysecrets.token_urlsafe(24), "secret": pysecrets.token_urlsafe(36)}
        mode = self.s["FACILITATOR_KEYS"]
        if mode != "file" and cmd and openbao_status() == "ready":
            ok = True
            for i, (k, v) in enumerate(vals.items()):
                r = subprocess.run([cmd, "put", "facilitator/slim", "--field", k] + (["--replace"] if i == 0 else []),
                                   input=v, capture_output=True, text=True, timeout=30)
                ok = ok and r.returncode == 0
            if ok:
                self.state.ensure()
                marker.write_text("openbao\n")
                return {**vals, "where": "openbao"}
        if mode == "openbao":
            raise InfraError("FACILITATOR_KEYS=openbao and OpenBao could not keep SLIM's secrets")
        self.state.ensure()
        self.state.write_private(f, json.dumps(vals))
        marker.write_text("file\n")
        return {**vals, "where": "file"}

    # ------------------------------------------------------------ configs

    def render(self, c: str) -> Path:
        if c == "dir":
            p = self.ports["dir"]
            text = (AGNTCY / "dir-daemon.config.yaml.in").read_text()
            subs = {"@API_PORT@": p["api"], "@OCI_PORT@": p["oci"], "@P2P_PORT@": p["p2p"], "@GATEWAY_PORT@": p["gateway"],
                    "@POLICY_OPERATIONS@": ONLINE_POLICY if self.s.bool("FACILITATOR_DIR_ONLINE_CHECK") else "[]"}
            out = self.state.dir / "daemon.config.yaml"
        elif self.meshed() and (text := self.slim_mesh_config()) is not None:
            out = self.state.slim / "config.yaml"
            self.state.write_private(out, text)
            return out
        else:
            text = (AGNTCY / "slim-config.yaml.in").read_text()
            subs = {"@SLIM_PORT@": self.ports["slim"]["dataplane"]}
            out = self.state.slim / "config.yaml"
        for k, v in subs.items():
            text = text.replace(k, str(v))
        self.state.write_private(out, text)
        return out

    def slim_mesh_config(self) -> str:
        """The SLIM node of a hub or a spoke (ADR-0069 lock one, ADR-0071, SP3). The loopback server for this
        node's own participants is as when standalone (basic auth with the generated secret). A hub adds a server
        per level in node.listen: mTLS, its certificate in the issuer's domain, client_ca the bundles of that
        level's domains only. A spoke adds a client link to its hub, of type peer (the default edge carries no
        routes), mTLS with its certificate, the domain's bundle, and server_name the hub's DNS name, which is
        in the hub's certificate (spike 2: a URI SAN alone fails the dialer's name check)."""
        from . import identity
        m = self.mesh
        store = identity.Store(self.state.home)
        dom = m.domain
        if not dom or not store.cert(dom).is_file() or not store.bundle(dom).is_file():
            if m.role == "hub":
                # the hub's OpenBao is sealed or not set up yet (it is unsealed by hand, ADR-0069): the node runs on
                # loopback, and the peers part asks for the certificate again and restarts SLIM with the listeners
                return None
            raise InfraError(f"slim: no certificate in {dom or 'a trust domain'}: this spoke has not joined a hub "
                             "(facilitator node join <hub> --token <token>)")
        q = json.dumps
        lines = ["# The facilitator's SLIM node, role " + m.role + " (rendered by facilitator infra up; do not edit).",
                 "tracing:", "  log_level: info", "runtime:", "  n_cores: 2", '  thread_name: "slim-data-plane"',
                 "  drain_timeout: 10s", "services:", "  slim/0:", f"    node_id: {q(m.node_id)}", "    dataplane:",
                 "      servers:", f'        - endpoint: "127.0.0.1:{self.ports["slim"]["dataplane"]}"',
                 "          tls:", "            insecure: true", "          auth:", "            type: basic",
                 "            username: facilitator", "            password: ${env:SLIM_PASSWORD}"]
        for lv, (host, port) in sorted(m.listeners().items()):
            bundles = store.bundles(m.trust, lv)
            if not bundles:
                raise InfraError(f"slim: the {lv} listener has no CA bundle (no domain of level {lv} has a trust bundle "
                                 "on disk)")
            level_bundle = store.certs / f"level-{lv}.pem"
            level_bundle.write_text("".join(b.read_text() for _, b in sorted(bundles.items())))
            lines += [f"        - endpoint: {q(f'{host}:{port}')}", "          tls:",
                      f"            source: {{type: file, cert: {q(str(store.cert(dom)))}, key: {q(str(store.key(dom)))}}}",
                      f"            client_ca: {{type: file, path: {q(str(level_bundle))}}}"]
        if m.role == "spoke":
            lines += ["      clients:", f"        - endpoint: {q('https://' + m.node['hub'])}",
                      f"          server_name: {q(m.node['hub_name'])}", "          connection_type: peer", "          tls:",
                      f"            source: {{type: file, cert: {q(str(store.cert(dom)))}, key: {q(str(store.key(dom)))}}}",
                      f"            ca_source: {{type: file, path: {q(str(store.bundle(dom)))}}}"]
        else:
            lines += ["      clients: []"]
        return "\n".join(lines) + "\n"

    def bind_check(self) -> None:
        """ADR-0071 decision 2: a bind beyond loopback only with a mesh.yml whose preset allows a level above local,
        and never without mutual TLS (every listener the mesh config renders is mTLS)."""
        m = self.mesh
        if m is None:
            return
        for lv, (host, port) in m.listeners().items():
            if mesh_mod.is_loopback(host):
                continue
            if not m.exists or mesh_mod.ORDER[m.ceiling] < mesh_mod.ORDER["private"]:
                raise InfraError(f"slim: refusing to listen on {host}:{port}: only a mesh.yml whose preset allows a level "
                                 "above local opens a port beyond loopback (ADR-0071)")

    # ------------------------------------------------------------ one component

    def pidfile(self, c: str) -> Path:
        return self.state.run / f"{c}.pid"

    def pid(self, c: str) -> int | None:
        try:
            return int(self.pidfile(c).read_text().strip())
        except (OSError, ValueError):
            return None

    def needle(self, c: str) -> str:
        return {"agent": "ssh-agent", "dir": "daemon start", "slim": "slim start", "peers": "node peers"}[c]

    def running(self, c: str) -> bool:
        if c == "agent":
            return self.signer.agent_alive()
        p = self.pid(c)
        return p is not None and pid_alive(p, self.needle(c))

    def healthy(self, c: str) -> bool:
        if c == "agent":
            return self.signer.agent_alive()
        if c == "peers":
            if not self.running(c):
                return False
            try:
                st = json.loads((self.state.home / "mesh" / "status.json").read_text())
            except (OSError, ValueError):
                return False
            return bool(st.get("connected")) and st.get("pid") == self.pid(c)
        main = self.ports[c]["api" if c == "dir" else "dataplane"]
        return self.running(c) and port_open(main)

    def status(self) -> list[dict]:
        rows = []
        for c in self.components():
            r = {"component": c, "running": self.running(c), "healthy": self.healthy(c), "pid": self.pid(c),
                 "log": str(self.state.logs / f"{c}.log")}
            if c in self.ports:
                r["ports"] = {k: f"127.0.0.1:{v}" for k, v in self.ports[c].items()}
                if not r["running"]:
                    r["port_owners"] = {k: o for k, v in self.ports[c].items() if (o := port_owner(v))}
            if self.pidfile(c).exists() and not r["running"]:
                r["note"] = "stopped since it was started (the Feature does not restart it): facilitator infra up"
            rows.append(r)
        return rows

    def up_one(self, c: str) -> str:
        if c == "agent":
            was = self.signer.agent_alive()
            self.signer.start_agent()
            return "running" if was else "started"
        if self.healthy(c):
            return "running"
        if c == "peers":
            return self.up_peers()
        binary = self.binary(c)
        if not binary:
            raise InfraError(f"{c}: {'dirctl' if c == 'dir' else 'slimctl'} is not installed (the Feature's install put it "
                             "in /usr/local/bin; FACILITATOR_DIRCTL / FACILITATOR_SLIMCTL name another)")
        if self.running(c):          # alive but not answering yet: give it the health check's time
            return self._wait(c, "running")
        for name, port in self.ports[c].items():
            owner = port_owner(port)
            if owner:
                raise InfraError(f"{c}: port 127.0.0.1:{port} ({name}) is in use by {owner}; stop it, or set "
                                 f"{self._port_var(c, name)} to a free port")
        self.state.ensure()
        if c == "slim" and self.mesh is not None and self.mesh.role == "hub" and self.fac is not None:
            from .identity import IdentityError
            from .peers import ensure_hub_cert
            try:
                ensure_hub_cert(self.fac)
            except IdentityError as e:
                print(f"facilitator: slim: no certificate for the hub yet ({e}); its listeners open once the issuer "
                      "answers (the peers part keeps asking)", file=__import__("sys").stderr, flush=True)
        cfg = self.render(c)
        env = {k: v for k, v in os.environ.items() if not k.startswith("DIRECTORY_")}
        if c == "dir":
            # A removed container leaves the Directory's own pidfile behind, and the daemon then refuses to
            # start ("daemon already running", the pid matching any process of a new container; spike 2). It
            # is not running here (checked above), so the file is stale.
            stale = self.state.dir / "daemon.pid"
            if stale.exists():
                stale.unlink()
            argv = [binary, "daemon", "start", "--data-dir", str(self.state.dir), "--config", str(cfg)]
        else:
            self.bind_check()
            sec = self.slim_secrets(create=True)
            env["SLIM_PASSWORD"] = sec["password"]
            argv = [binary, "slim", "start", "--config", str(cfg)]
        log = open(self.state.logs / f"{c}.log", "ab")
        try:
            p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env,
                                 cwd=str(self.state.dir if c == "dir" else self.state.slim), start_new_session=True)
        finally:
            log.close()
        self.pidfile(c).write_text(f"{p.pid}\n")
        return self._wait(c, "started")

    def _wait(self, c: str, word: str, seconds: float = 20) -> str:
        end = time.time() + seconds
        while time.time() < end:
            if self.healthy(c):
                return word
            if not self.running(c):
                time.sleep(0.2)              # a command line read in the middle of an exec is empty: look again
                if self.running(c):
                    continue
                raise InfraError(f"{c}: exited at start; see {self.state.logs / (c + '.log')} (facilitator infra logs {c})")
            time.sleep(0.1)
        raise InfraError(f"{c}: not answering on its port after {seconds:.0f} s; see facilitator infra logs {c}")

    def up_peers(self) -> str:
        """The peers daemon (`facilitator node peers`): a background process like the others."""
        import sys
        lib_bin = LIB / "bin" / "facilitator"
        cmd = lib_bin if lib_bin.is_file() else LIB.parent / "bin" / "facilitator"
        log = open(self.state.logs / "peers.log", "ab")
        try:
            p = subprocess.Popen([sys.executable, "-I", str(cmd), "node", "peers"], stdin=subprocess.DEVNULL, stdout=log,
                                 stderr=subprocess.STDOUT, cwd=str(self.state.home), start_new_session=True,
                                 env={k: v for k, v in os.environ.items() if not k.startswith("DIRECTORY_")})
        finally:
            log.close()
        self.pidfile("peers").write_text(f"{p.pid}\n")
        return self._wait("peers", "started", 30)

    @staticmethod
    def _port_var(c: str, name: str) -> str:
        return {"api": "FACILITATOR_DIR_PORT", "oci": "FACILITATOR_DIR_OCI_PORT", "p2p": "FACILITATOR_DIR_P2P_PORT",
                "gateway": "FACILITATOR_DIR_GATEWAY_PORT", "dataplane": "FACILITATOR_SLIM_PORT"}[name]

    def down_one(self, c: str) -> str:
        pid = self.pid(c) if c != "agent" else self._agent_pid()
        if pid is None or not pid_alive(pid, self.needle(c)):
            self._clear(c)
            return "stopped"
        os.kill(pid, signal.SIGTERM)
        end = time.time() + 10
        while time.time() < end and pid_alive(pid, self.needle(c)):
            time.sleep(0.1)
        if pid_alive(pid, self.needle(c)):
            os.kill(pid, signal.SIGKILL)
        self._clear(c)
        return "stopped now"

    def _agent_pid(self) -> int | None:
        return self.pid("agent")

    def _clear(self, c: str) -> None:
        for p in (self.pidfile(c), self.signer.sock if c == "agent" else None):
            if p is not None:
                try:
                    p.unlink()
                except FileNotFoundError:
                    pass

    def up(self, which: list[str] | None = None) -> list[tuple[str, str]]:
        return [(c, self.up_one(c)) for c in (which or self.components())]

    def down(self, which: list[str] | None = None) -> list[tuple[str, str]]:
        return [(c, self.down_one(c)) for c in reversed(which or self.components())]

    def logs(self, c: str | None, lines: int = 40) -> str:
        out = []
        for name in ([c] if c else ["dir", "slim"] + (["peers"] if "peers" in self.components() else [])):
            f = self.state.logs / f"{name}.log"
            try:
                tail = f.read_bytes().decode(errors="replace").splitlines()[-lines:]
            except OSError:
                tail = ["(no log yet)"]
            out.append(f"== {f}\n" + "\n".join(tail))
        return "\n".join(out)
