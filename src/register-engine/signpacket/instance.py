"""The running instance's id: one GUID per running stack (one dev container), the part after `@` in
its agents' principals (D93; AOF's design/federation.md, "Where the instance id comes from").

Resolved in this order, the first found wins:
  1. AOF_INSTANCE_ID in the environment (the machine-local .devcontainer/.env, through containerEnv);
  2. OpenBao, through the openbao Feature's `dcf-secret get instance --field id`, when it answers;
  3. neither: a new GUID, made once.
The id found is recorded in sign-packet's own volume ($SIGN_PACKET_HOME/instance-id), so every
Feature in the container reads the same one. Sources that disagree are refused before anything is
recorded; once recorded, a source that names another id is refused, never followed. What this does
not stop: a new instance given another instance's id at its creation (a copied .env, one OpenBao
secret shared by two instances). Nothing local can tell; packet-relay refuses a peer that claims
its own id, and the certificate authority a second key for one instance (the certificate work).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path

ENV = "AOF_INSTANCE_ID"
SECRET, FIELD = "instance", "id"
GUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
DEFAULT_HOME = "/var/lib/devcontainer-features/sign-packet"
DCF_SECRET = "/usr/local/bin/dcf-secret"     # where the openbao Feature installs it: asked first, before PATH


class InstanceError(Exception):
    """A refusal said in one line: a malformed id, or a source that names another instance."""


def home() -> Path:
    return Path(os.environ.get("SIGN_PACKET_HOME", DEFAULT_HOME))


def _check(value: str, where: str) -> str:
    v = value.strip()
    if not GUID_RE.fullmatch(v):          # never echoed: something else may have been put there by mistake
        raise InstanceError(f"{where} is not an instance id (a lowercase GUID, 8-4-4-4-12; it holds {len(v)} characters)")
    return v


def recorded(h: Path | None = None) -> str | None:
    f = (h or home()) / "instance-id"
    try:
        fd = os.open(f, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise InstanceError(f"{f} cannot be read as the instance record (a symlink or not a file): {e.strerror}") from None
    with os.fdopen(fd) as h_:
        return _check(h_.read(), str(f))


def from_env() -> str | None:
    v = os.environ.get(ENV, "").strip()
    return _check(v, ENV) if v else None


def from_openbao() -> tuple[str | None, str]:
    """(the id, or None; why). Asks only when the openbao Feature's dcf-secret is there."""
    cmd = DCF_SECRET if os.access(DCF_SECRET, os.X_OK) else shutil.which("dcf-secret")
    if not cmd:
        return None, "no dcf-secret (the openbao Feature is not installed)"
    try:
        r = subprocess.run([cmd, "get", SECRET, "--field", FIELD], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"dcf-secret did not answer: {e}"
    if r.returncode == 0:
        return _check(r.stdout, f"OpenBao's {SECRET} {FIELD}"), "OpenBao"
    why = {10: "unreachable", 11: "sealed", 12: "logged out", 13: "denied", 14: "not set"}.get(r.returncode, f"exit {r.returncode}")
    return None, f"OpenBao: {why}"


def _record(h: Path, value: str) -> str:
    """Write the record once, whole: a temporary file, then a hard link to the name (which never
    replaces). If another process recorded first, that one stands."""
    h.mkdir(parents=True, exist_ok=True)
    f = h / "instance-id"
    tmp = h / f".instance-id.{os.getpid()}.{uuid.uuid4().hex[:8]}"
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    try:
        with os.fdopen(fd, "w") as out:
            out.write(value + "\n")
        try:
            os.link(tmp, f)
        except FileExistsError:
            pass
    finally:
        tmp.unlink(missing_ok=True)
    got = recorded(h)
    if got is None:
        raise InstanceError(f"{f} could not be recorded")
    return got


def resolve(h: Path | None = None, ask_openbao: bool = True) -> tuple[str, str]:
    """(the instance id, where it came from). Records it the first time; refuses a source that names
    another id than the one recorded."""
    h = h or home()
    rec = recorded(h)
    sources = [("the environment", from_env())]
    if ask_openbao:
        sources.append(("OpenBao", from_openbao()[0]))
    found = [(where, value) for where, value in sources if value is not None]
    for where, value in found:
        if rec is not None and value != rec:
            raise InstanceError(f"{where} names instance {value}, but this instance is {rec} "
                                f"({h / 'instance-id'}); an id is never changed: remove the other value")
    if rec is None and len({v for _, v in found}) > 1:
        raise InstanceError("the sources disagree: " + ", ".join(f"{w} names {v}" for w, v in found)
                            + "; keep one, then run sign-packet instance again")
    if rec is not None:
        return rec, "recorded"
    if found:
        return _record(h, found[0][1]), found[0][0]
    return _record(h, str(uuid.uuid4())), "made here"


def get(h: Path | None = None) -> str:
    """The instance id for a writer: the recorded one, checked against the environment (cheap);
    resolved and recorded if there is none yet. OpenBao is asked at setup and by `sign-packet
    instance`, not on every write."""
    h = h or home()
    rec = recorded(h)
    env = from_env()
    if rec is not None:
        if env is not None and env != rec:
            raise InstanceError(f"{ENV} names instance {env}, but this instance is {rec}; an id is never changed")
        return rec
    return resolve(h)[0]
