"""The infrastructure the Feature starts and owns (proposal 4.8): the facilitator's ssh-agent, the Agent
Directory daemon and the SLIM node, as background processes with a pidfile (run/), a log (logs/) and a
health check, every port on loopback. Never a participant. `up` is idempotent; nothing is restarted on a
crash (`status` says so)."""
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

from .signer import Signer, _dcf_secret, openbao_status
from .state import State

LIB = Path(__file__).resolve().parents[1]
AGNTCY = LIB / "agntcy"
ONLINE_POLICY = ('[{"provider": "oasf", "op": ["push", "autosync", "index"], "name": "schema", '
                 '"schema_url": "https://schema.oasf.outshift.com"}]')
COMPONENTS = ("agent", "dir", "slim")


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
    def __init__(self, settings, state: State, signer: Signer):
        self.s = settings
        self.state = state
        self.signer = signer
        self.ports = {
            "dir": {"api": settings.int("FACILITATOR_DIR_PORT", 1), "oci": settings.int("FACILITATOR_DIR_OCI_PORT", 1),
                    "p2p": settings.int("FACILITATOR_DIR_P2P_PORT", 1), "gateway": settings.int("FACILITATOR_DIR_GATEWAY_PORT", 1)},
            "slim": {"dataplane": settings.int("FACILITATOR_SLIM_PORT", 1)},
        }

    # ------------------------------------------------------------ binaries

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
        else:
            text = (AGNTCY / "slim-config.yaml.in").read_text()
            subs = {"@SLIM_PORT@": self.ports["slim"]["dataplane"]}
            out = self.state.slim / "config.yaml"
        for k, v in subs.items():
            text = text.replace(k, str(v))
        self.state.write_private(out, text)
        return out

    # ------------------------------------------------------------ one component

    def pidfile(self, c: str) -> Path:
        return self.state.run / f"{c}.pid"

    def pid(self, c: str) -> int | None:
        try:
            return int(self.pidfile(c).read_text().strip())
        except (OSError, ValueError):
            return None

    def needle(self, c: str) -> str:
        return {"agent": "ssh-agent", "dir": "daemon start", "slim": "slim start"}[c]

    def running(self, c: str) -> bool:
        if c == "agent":
            return self.signer.agent_alive()
        p = self.pid(c)
        return p is not None and pid_alive(p, self.needle(c))

    def healthy(self, c: str) -> bool:
        if c == "agent":
            return self.signer.agent_alive()
        main = self.ports[c]["api" if c == "dir" else "dataplane"]
        return self.running(c) and port_open(main)

    def status(self) -> list[dict]:
        rows = []
        for c in COMPONENTS:
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
        cfg = self.render(c)
        env = {k: v for k, v in os.environ.items() if not k.startswith("DIRECTORY_")}
        if c == "dir":
            argv = [binary, "daemon", "start", "--data-dir", str(self.state.dir), "--config", str(cfg)]
        else:
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
                raise InfraError(f"{c}: exited at start; see {self.state.logs / (c + '.log')} (facilitator infra logs {c})")
            time.sleep(0.1)
        raise InfraError(f"{c}: not answering on its port after {seconds:.0f} s; see facilitator infra logs {c}")

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
        return [(c, self.up_one(c)) for c in (which or COMPONENTS)]

    def down(self, which: list[str] | None = None) -> list[tuple[str, str]]:
        return [(c, self.down_one(c)) for c in reversed(which or COMPONENTS)]

    def logs(self, c: str | None, lines: int = 40) -> str:
        out = []
        for name in ([c] if c else ["dir", "slim"]):
            f = self.state.logs / f"{name}.log"
            try:
                tail = f.read_bytes().decode(errors="replace").splitlines()[-lines:]
            except OSError:
                tail = ["(no log yet)"]
            out.append(f"== {f}\n" + "\n".join(tail))
        return "\n".join(out)
