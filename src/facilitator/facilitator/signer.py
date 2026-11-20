"""The signer module (proposal 4.7): every packet is signed with the key of the identity it is from.

Keys are made here (`ssh-keygen -t ed25519`). The private half goes to OpenBao
(`dcf-secret put facilitator/keys/<handle>`, ADR-0048) and is loaded, through a pipe, into the
facilitator's own ssh-agent for the sitting (run/agent.sock, started by `facilitator infra up`); the
packet is then signed through the agent with the public key file, so the private key is never in a
file. When OpenBao is not ready (not installed, sealed, logged out, the policy denies the name), the
**0.1.0 fallback** keeps the private key in `keys/<handle>`, mode 600, in the volume: a written
exception to ADR-0048 (the NOTES, "Keys"), marked by `keys/FALLBACK`. FACILITATOR_KEYS=openbao|file
forces one; auto (the default) uses OpenBao when `dcf-secret status` says ready.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from .state import State

FALLBACK_NOTE = """The private keys in this folder are the facilitator 0.1.0 fallback: OpenBao was not ready when
they were made (ADR-0048 exception, written in the facilitator Feature's NOTES, "Keys"). They are
mode 600 in the Feature's volume. Re-register a participant once OpenBao is ready to move its key there:
  facilitator register <handle> --new-key
"""


class SignerError(RuntimeError):
    pass


def _dcf_secret() -> str | None:
    p = "/usr/local/bin/dcf-secret"
    return p if os.access(p, os.X_OK) else shutil.which("dcf-secret")


def openbao_status() -> str:
    cmd = _dcf_secret()
    if not cmd:
        return "absent"
    try:
        r = subprocess.run([cmd, "status"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return "unreachable"
    return (r.stdout.strip().split() or ["unknown"])[0]


class Signer:
    def __init__(self, state: State, mode: str = "auto"):
        if mode not in ("auto", "openbao", "file"):
            raise SignerError(f"FACILITATOR_KEYS={mode!r}: auto, openbao or file")
        self.state = state
        self.mode = mode
        self.sock = state.run / "agent.sock"
        if len(str(self.sock)) > 100:        # a Unix socket path holds 107 bytes: a deep FACILITATOR_HOME (tests)
            import hashlib
            short = Path("/tmp") / f"facilitator-{os.getuid()}"
            short.mkdir(mode=0o700, exist_ok=True)
            os.chmod(short, 0o700)
            self.sock = short / f"agent-{hashlib.sha256(str(state.home).encode()).hexdigest()[:12]}.sock"

    def secret_name(self, handle: str) -> str:
        return f"facilitator/keys/{handle}"

    def public(self, handle: str) -> str | None:
        try:
            t = (self.state.keys / f"{handle}.pub").read_text().split()
            return f"{t[0]} {t[1]}"
        except (OSError, IndexError):
            return None

    def where(self, handle: str) -> str | None:
        if (self.state.keys / handle).is_file():
            return "file"
        if self.public(handle):
            return "openbao"
        return None

    def ensure_key(self, handle: str, new: bool = False) -> tuple[str, str]:
        """(public key, where the private half is: openbao | file). Makes one when there is none."""
        if not new and self.public(handle) and self.where(handle):
            return self.public(handle), self.where(handle)
        self.state.ensure()
        with tempfile.TemporaryDirectory(dir=self.state.keys, prefix=".new-") as tmp:
            k = Path(tmp) / "k"
            r = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(k)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise SignerError(f"ssh-keygen could not make a key: {r.stderr.strip()}")
            pub = k.with_suffix(".pub").read_text().split()
            pub = f"{pub[0]} {pub[1]}"
            where, why = "file", ""
            if self.mode in ("auto", "openbao"):
                st = openbao_status()
                if st == "ready":
                    cmd = _dcf_secret()
                    r = subprocess.run([cmd, "put", self.secret_name(handle), "--field", "private", "--replace"],
                                       input=k.read_text(), capture_output=True, text=True, timeout=30)
                    if r.returncode == 0:
                        where = "openbao"
                    else:
                        why = f"dcf-secret put failed (exit {r.returncode})"
                else:
                    why = f"OpenBao is {st}"
                if where != "openbao" and self.mode == "openbao":
                    raise SignerError(f"FACILITATOR_KEYS=openbao and {why}")
            if where == "file":
                self.state.write_private(self.state.keys / handle, k.read_text())
                self.state.write_private(self.state.keys / "FALLBACK", FALLBACK_NOTE)
            else:
                try:
                    (self.state.keys / handle).unlink()
                except FileNotFoundError:
                    pass
            (self.state.keys / f"{handle}.pub").write_text(pub + "\n")
        return pub, where

    # ------------------------------------------------------------ signing

    def agent_env(self) -> dict:
        return {**os.environ, "SSH_AUTH_SOCK": str(self.sock)}

    def agent_alive(self) -> bool:
        if not self.sock.exists():
            return False
        r = subprocess.run(["ssh-add", "-l"], env=self.agent_env(), capture_output=True, text=True)
        return r.returncode in (0, 1)      # 1: the agent answers and holds no key

    def start_agent(self) -> None:
        """The facilitator's own ssh-agent, for the sitting (infra up starts it; signing starts it when
        it is not there). Its socket is in run/, mode 700."""
        if self.agent_alive():
            return
        self.state.ensure()
        try:
            self.sock.unlink()
        except FileNotFoundError:
            pass
        r = subprocess.run(["ssh-agent", "-a", str(self.sock)], capture_output=True, text=True)
        if r.returncode != 0:
            raise SignerError(f"ssh-agent did not start: {r.stderr.strip()}")
        for part in r.stdout.replace(";", "\n").splitlines():
            part = part.strip()
            if part.startswith("SSH_AGENT_PID="):
                (self.state.run / "agent.pid").write_text(part.split("=", 1)[1] + "\n")

    def _loaded(self, pub: str) -> bool:
        r = subprocess.run(["ssh-add", "-L"], env=self.agent_env(), capture_output=True, text=True)
        return any(line.split()[:2] == pub.split() for line in r.stdout.splitlines() if line.strip())

    def load(self, handle: str) -> None:
        """Put an OpenBao-held key into the agent, through a pipe (never a file)."""
        pub = self.public(handle)
        if not pub:
            raise SignerError(f"no key for {handle}: facilitator register {handle}")
        self.start_agent()
        if self._loaded(pub):
            return
        cmd = _dcf_secret()
        if not cmd:
            raise SignerError(f"the key of {handle} is in OpenBao and dcf-secret is not installed")
        g = subprocess.run([cmd, "get", self.secret_name(handle), "--field", "private"], capture_output=True,
                           text=True, timeout=30)
        if g.returncode != 0:
            raise SignerError(f"could not read the key of {handle} from OpenBao (dcf-secret exit {g.returncode}): "
                              f"{g.stderr.strip().splitlines()[-1:] or ''}")
        a = subprocess.run(["ssh-add", "-q", "-"], input=g.stdout, env=self.agent_env(), capture_output=True, text=True)
        if a.returncode != 0:
            raise SignerError(f"ssh-add refused the key of {handle}: {a.stderr.strip()}")

    def signing_path(self, handle: str) -> Path:
        """What register-engine's add() signs with: the private key file (fallback), or the public key
        file with the private half in the facilitator's agent (SSH_AUTH_SOCK is set for this process)."""
        where = self.where(handle)
        if where == "file":
            return self.state.keys / handle
        if where == "openbao":
            self.load(handle)
            os.environ["SSH_AUTH_SOCK"] = str(self.sock)
            return self.state.keys / f"{handle}.pub"
        raise SignerError(f"no key for {handle}: facilitator register {handle}")
