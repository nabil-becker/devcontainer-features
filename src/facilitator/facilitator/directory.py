"""The directory part of the backend interface (proposal 4.8, E2): in `agntcy` mode, the Agent Directory,
through `dirctl` on loopback. A participant's OASF record (schema 1.1.0) is named
`facilitator.local/<handle>`; its identity is its CID (the content hash), so a changed record is a new
CID, and the newest record of a name is the participant's."""
from __future__ import annotations

import datetime as dt
import json
import subprocess

from .participants import Participant

PREFIX = "facilitator.local"
SCHEMA = "1.1.0"


class DirectoryError(RuntimeError):
    pass


def record(p: Participant, version: str) -> dict:
    """The OASF record of a participant, from its entry in the list (E4)."""
    return {
        "name": f"{PREFIX}/{p.name}",
        "version": f"v{version}",
        "schema_version": SCHEMA,
        "description": p.description or f"{p.name}: a {p.cli} participant of the facilitator",
        "authors": ["facilitator"],
        "created_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "locators": [{"type": "source_code", "urls": [f"https://{PREFIX}.invalid/{p.name}"]}],
        "skills": [{"name": s} for s in p.skills],
        "domains": [],
        "annotations": {"facilitator.cli": p.cli, "facilitator.kind": p.kind, "facilitator.attachment": p.attachment},
    }


class Directory:
    def __init__(self, dirctl: str | None, port: int):
        self.dirctl = dirctl
        self.addr = f"127.0.0.1:{port}"

    def _run(self, args: list[str], stdin: str | None = None, timeout: float = 30) -> str:
        if not self.dirctl:
            raise DirectoryError("dirctl is not installed")
        try:
            r = subprocess.run([self.dirctl, "--server-addr", self.addr, *args], input=stdin, capture_output=True,
                               text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise DirectoryError(f"dirctl {args[0]} did not answer in {timeout:.0f} s (is the Directory up? "
                                 "facilitator infra status)") from None
        if r.returncode != 0:
            why = (r.stderr.strip() or r.stdout.strip()).splitlines()[-1:] or ["no reason given"]
            raise DirectoryError(f"dirctl {args[0]}: {why[0]}")
        return r.stdout

    def push(self, rec: dict) -> str:
        cid = self._run(["push", "--stdin", "--output", "raw"], stdin=json.dumps(rec)).strip().strip('"')
        if not cid:
            raise DirectoryError("dirctl push gave no CID")
        return cid

    def records(self) -> dict[str, dict]:
        """handle -> the newest record of facilitator.local/<handle>."""
        out = json.loads(self._run(["search", "--name", f"{PREFIX}/*", "--format", "record", "--output", "json"]) or "[]")
        best: dict[str, dict] = {}
        for item in out or []:
            d = item.get("data", item)
            name = d.get("name", "")
            if not name.startswith(PREFIX + "/"):
                continue
            h = name.split("/", 1)[1]
            if h not in best or d.get("created_at", "") >= best[h].get("created_at", ""):
                best[h] = d
        return best
