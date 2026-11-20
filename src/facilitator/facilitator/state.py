"""The state folder ($FACILITATOR_HOME, the volume facilitator-state-${devcontainerId}):

    keys/<handle>.pub        each identity's public key (the private half is in OpenBao,
                             facilitator/keys/<handle>, or, as the 0.1.0 fallback, keys/<handle>, mode 600)
    tokens/<handle>          each participant's token (mode 600), made again at every container start
    roster.json              who is registered: key, kind, where the key is, the directory record's CID
    anchors                  the facilitator's own key: the anchor of every conversation's roster
    conversations/<id>/      one register-engine store per conversation (<entry id>.entry files)
    attach/<handle>          when each participant last called receive (its mtime)
    mail/<handle>.json       what a person has read: per conversation, the message ids the mail tool handed over
    mail/<handle>.notice     the turn hook's last answer and the fingerprint it was computed for
    secrets/                 the SLIM secrets when OpenBao is not there (mode 600)
    dir/  slim/  run/  logs/ the infrastructure: the Directory's data, SLIM's config, pidfiles, logs
"""
from __future__ import annotations

import fcntl
import hmac
import json
import os
import secrets
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


class State:
    def __init__(self, home: Path):
        self.home = Path(home)
        self.keys = self.home / "keys"
        self.tokens = self.home / "tokens"
        self.conversations = self.home / "conversations"
        self.attach = self.home / "attach"
        self.mail = self.home / "mail"
        self.secrets = self.home / "secrets"
        self.run = self.home / "run"
        self.logs = self.home / "logs"
        self.dir = self.home / "dir"
        self.slim = self.home / "slim"
        self.roster_file = self.home / "roster.json"
        self.anchors_file = self.home / "anchors"

    def ensure(self) -> None:
        self.home.mkdir(parents=True, exist_ok=True)
        for d, mode in ((self.keys, 0o700), (self.tokens, 0o700), (self.secrets, 0o700), (self.conversations, 0o755),
                        (self.attach, 0o755), (self.mail, 0o700), (self.run, 0o700), (self.logs, 0o755), (self.dir, 0o700), (self.slim, 0o700)):
            d.mkdir(parents=True, exist_ok=True)
            os.chmod(d, mode)

    def writable(self) -> tuple[bool, str]:
        try:
            self.ensure()
            with tempfile.NamedTemporaryFile(dir=self.home, prefix=".probe-"):
                pass
            return True, str(self.home)
        except OSError as e:
            return False, f"{self.home}: {e.strerror or e}"

    # ------------------------------------------------------------ files written whole, mode 600

    @staticmethod
    def write_private(path: Path, text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".w-")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    @contextmanager
    def lock(self, name: str):
        self.run.mkdir(parents=True, exist_ok=True)
        with open(self.run / f".lock-{name}", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    # ------------------------------------------------------------ the roster of identities

    def roster(self) -> dict:
        try:
            return json.loads(self.roster_file.read_text())
        except (OSError, ValueError):
            return {}

    def set_identity(self, handle: str, **fields) -> dict:
        with self.lock("roster"):
            r = self.roster()
            r[handle] = {**r.get(handle, {}), **fields}
            tmp = self.roster_file.with_suffix(".tmp")
            tmp.write_text(json.dumps(r, indent=2, sort_keys=True) + "\n")
            os.replace(tmp, self.roster_file)
            return r[handle]

    # ------------------------------------------------------------ participant tokens

    def make_token(self, handle: str) -> str:
        tok = secrets.token_hex(32)
        self.write_private(self.tokens / handle, tok + "\n")
        return tok

    def token_ok(self, handle: str, token: str | None) -> bool:
        if not token:
            return False
        try:
            want = (self.tokens / handle).read_text().strip()
        except OSError:
            return False
        return bool(want) and hmac.compare_digest(want.encode(), token.strip().encode())

    # ------------------------------------------------------------ attachment (receive heartbeats)

    def seen(self, handle: str) -> None:
        p = self.attach / handle
        try:
            p.write_text(f"{os.getpid()}\n")
        except OSError:
            pass

    def last_seen(self, handle: str) -> float | None:
        try:
            return (self.attach / handle).stat().st_mtime
        except OSError:
            return None

    def attached(self, handle: str, stale_seconds: int, now: float | None = None) -> bool:
        t = self.last_seen(handle)
        return t is not None and ((now or time.time()) - t) <= stale_seconds

    # ------------------------------------------------------------ a person's mail (what the mail tool handed over)

    def read_marks(self, handle: str) -> dict[str, list[str]]:
        try:
            d = json.loads((self.mail / f"{handle}.json").read_text())
            return {k: list(v) for k, v in d.items()} if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def mark_read(self, handle: str, read: dict[str, list[str]]) -> None:
        """Adds message ids, per conversation, to what `handle` has read."""
        if not read:
            return
        with self.lock(f"mail-{handle}"):
            cur = self.read_marks(handle)
            for conv, mids in read.items():
                have = cur.setdefault(conv, [])
                have += [m for m in mids if m not in have]
            self.write_private(self.mail / f"{handle}.json", json.dumps(cur, sort_keys=True) + "\n")

    def marks_stamp(self, handle: str) -> int:
        try:
            return (self.mail / f"{handle}.json").stat().st_mtime_ns
        except OSError:
            return 0

    def conversations_stamp(self) -> list:
        """A cheap fingerprint of every conversation: its id and how many entries it holds (no signature read)."""
        out = []
        try:
            with os.scandir(self.conversations) as it:
                for d in it:
                    if d.is_dir():
                        with os.scandir(d.path) as es:
                            out.append([d.name, sum(1 for e in es if e.name.endswith(".entry"))])
        except OSError:
            pass
        return sorted(out)
