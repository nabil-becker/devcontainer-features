"""The node's own HTTP clients (slice N4, ADR-0070, ADR-0068): the table behind the MCP endpoint over HTTP.

A person creates a static bearer token for a client (`facilitator http token <client>`); the token is printed once
and kept only as a SHA-256 hash in `http/clients.json` (mode 600, in the state volume). A client has a state:

    enrolled   the token exists and works; the client's first message is held until a person approves (level public)
    approved   a person approved it (`facilitator http approve`, or the approve tool of a person's session)
    denied     a person refused it: its token no longer works
    revoked    a person revoked it: its token no longer works, at once

The node signs for the client with a key it holds (ADR-0068): the roster entry is kind `http`, and every packet
the client's messages and task states make carries `data.via` = {transport: http, auth: bearer, client}. The
client's SPIFFE ID is `spiffe://http.<home domain>/node/<node id>/http/<client>` (the domain is the mapping key of
mesh.yml's trust: public unless mapped private).

Every enrolment, approval, denial and revocation is also a line in `http/audit.jsonl`, each carrying the hash of the
one before it, so a cut or an edit shows (`facilitator http audit`). That log is not a register: see the NOTES.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
from pathlib import Path

from .state import State

HANDLE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
STATES = ("enrolled", "approved", "denied", "revoked")
LIVE = ("enrolled", "approved")
MAX_PENDING = 20           # enrolled and not yet approved (the flood cap of proposal 11.3, here per node)
SCOPE = "facilitator:participate"


class ClientError(RuntimeError):
    pass


def now_iso(t: float | None = None) -> str:
    return dt.datetime.fromtimestamp(t if t is not None else dt.datetime.now(dt.timezone.utc).timestamp(),
                                     dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> float:
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def hash_secret(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


def split_token(token: str | None) -> tuple[str, str] | None:
    """(client, secret) of `<client>.<secret>`, or None: the client name is in the token, so a lookup is one entry
    and the secret is compared in constant time."""
    if not token or len(token) > 200 or "." not in token:
        return None
    name, _, secret = token.partition(".")
    if not HANDLE_RE.fullmatch(name) or not secret:
        return None
    return name, secret


class Clients:
    def __init__(self, state: State):
        self.state = state
        self.dir = state.home / "http"
        self.file = self.dir / "clients.json"
        self.audit_file = self.dir / "audit.jsonl"

    # ------------------------------------------------------------ the table

    def _ensure(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)

    def all(self) -> dict:
        try:
            d = json.loads(self.file.read_text())
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def get(self, name: str) -> dict | None:
        return self.all().get(name)

    def _put(self, table: dict) -> None:
        self._ensure()
        self.state.write_private(self.file, json.dumps(table, indent=2, sort_keys=True) + "\n")

    def stamp(self) -> int:
        try:
            return self.file.stat().st_mtime_ns
        except OSError:
            return 0

    # ------------------------------------------------------------ the person's acts

    def create(self, name: str, by: str, label: str = "") -> str:
        """Enrol a client and make its token (returned once, never stored): a person's act."""
        if not HANDLE_RE.fullmatch(name or ""):
            raise ClientError(f"{name!r}: a client name is a lowercase handle (letters, digits, - and _)")
        with self.state.lock("http-clients"):
            t = self.all()
            if name in t and t[name]["status"] in LIVE:
                raise ClientError(f"the client {name} exists ({t[name]['status']}); revoke it first to make a new token")
            if sum(1 for c in t.values() if c["status"] == "enrolled") >= MAX_PENDING:
                raise ClientError(f"{MAX_PENDING} clients are enrolled and not yet approved: approve or deny some first "
                                  "(the cap on pending enrolments)")
            secret = secrets.token_urlsafe(32)
            at = now_iso()
            t[name] = {"status": "enrolled", "token_hash": hash_secret(secret), "created": at, "created_by": by,
                       "label": label, "approved_at": None, "approved_by": None, "last_seen": None}
            self._put(t)
            self.audit("enrolled", name, by)
        return f"{name}.{secret}"

    def set_status(self, name: str, status: str, by: str, event: str, **extra) -> dict:
        if status not in STATES:
            raise ClientError(f"no state {status}")
        with self.state.lock("http-clients"):
            t = self.all()
            if name not in t:
                raise ClientError(f"no HTTP client {name} (facilitator http list)")
            c = t[name]
            if c["status"] in ("denied", "revoked"):
                raise ClientError(f"the client {name} is {c['status']}; make a new token (facilitator http token {name})")
            c["status"] = status
            c.update(extra)
            if status in ("denied", "revoked"):
                c["token_hash"] = ""                  # the pending token is discarded: no call can use it again
            self._put(t)
            self.audit(event, name, by)
            return c

    def approve(self, name: str, by: str) -> dict:
        return self.set_status(name, "approved", by, "approved", approved_at=now_iso(), approved_by=by)

    def deny(self, name: str, by: str) -> dict:
        return self.set_status(name, "denied", by, "denied")

    def revoke(self, name: str, by: str) -> dict:
        return self.set_status(name, "revoked", by, "revoked")

    def seen(self, name: str) -> None:
        try:
            with self.state.lock("http-clients"):
                t = self.all()
                if name in t:
                    t[name]["last_seen"] = now_iso()
                    self._put(t)
        except OSError:
            pass

    # ------------------------------------------------------------ the endpoint's check

    def check_token(self, token: str | None) -> tuple[str, dict] | None:
        """(client, its entry) for a valid token of an enrolled or approved client; else None. Constant time in the
        secret; an unknown client costs the same compare."""
        sp = split_token(token)
        if sp is None:
            return None
        name, secret = sp
        c = self.get(name)
        want = (c or {}).get("token_hash") or "0" * 64
        ok = hmac.compare_digest(want.encode(), hash_secret(secret).encode())
        if not ok or c is None or c["status"] not in LIVE:
            return None
        return name, c

    def approved(self, name: str, ttl_seconds: int, now: float) -> bool:
        """Whether a person's approval stands: approved, and (ttl > 0) not older than the level's approval_ttl."""
        c = self.get(name)
        if not c or c["status"] != "approved" or not c.get("approved_at"):
            return False
        return ttl_seconds <= 0 or now - parse_iso(c["approved_at"]) < ttl_seconds

    # ------------------------------------------------------------ audit

    def audit(self, event: str, client: str, by: str, detail: str = "") -> None:
        self._ensure()
        prev = "0" * 64
        try:
            lines = self.audit_file.read_text().splitlines()
            if lines:
                prev = hashlib.sha256(lines[-1].encode()).hexdigest()
        except OSError:
            pass
        rec = {"at": now_iso(), "event": event, "client": client, "by": by, "prev": prev}
        if detail:
            rec["detail"] = detail
        line = json.dumps(rec, sort_keys=True, separators=(",", ":"))
        fd = os.open(self.audit_file, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(line + "\n")

    def audit_log(self) -> list[dict]:
        try:
            return [json.loads(x) for x in self.audit_file.read_text().splitlines() if x.strip()]
        except (OSError, ValueError):
            return []

    def audit_ok(self) -> tuple[bool, str]:
        """The chain checked: each line names the hash of the one before it."""
        try:
            lines = [x for x in self.audit_file.read_text().splitlines() if x.strip()]
        except OSError:
            return True, "no audit log yet"
        prev = "0" * 64
        for n, line in enumerate(lines, 1):
            try:
                rec = json.loads(line)
            except ValueError:
                return False, f"line {n}: not JSON"
            if rec.get("prev") != prev:
                return False, f"line {n}: the chain is cut or edited (it does not follow line {n - 1})"
            prev = hashlib.sha256(line.encode()).hexdigest()
        return True, f"{len(lines)} line(s), the chain holds"

    # ------------------------------------------------------------ names

    @staticmethod
    def spiffe_id(mesh, name: str) -> str:
        return f"spiffe://{mesh.http_domain}/node/{mesh.node_id}/http/{name}"


def public_view(name: str, c: dict) -> dict:
    """What a listing shows: never the hash."""
    return {"client": name, "status": c["status"], "created": c["created"], "approved_at": c.get("approved_at"),
            "approved_by": c.get("approved_by"), "last_seen": c.get("last_seen"), "label": c.get("label", "")}


def default_path(home: Path) -> Path:
    return home / "http" / "clients.json"
