"""The signed audit register (slice N5a, ruling HC3, backlog `http-audit-register`).

Slice N4 kept the enrolment of HTTP clients (token, approve, deny, revoke) as lines of `http/audit.jsonl`, each carrying the
hash of the one before it: a cut or an edit shows, a whole rewrite would not. This module keeps the same events, and the
cross-node ones of slice N5a (a public node's join request, a person's approval or denial of it, a revoked node, the mesh
secret's rotation), as a **register** of the type `audit` (types.d/facilitator.py, the same type mechanism as the
conversations): one register-engine register, `audit-enrolment`, in the state volume, every entry a sign-packet packet
signed by the node's facilitator key, which is an anchor. The register's chain (each key's `prev`, the heads it `saw`)
makes a cut, an edit or a rewrite show, and `verify` checks it. `replay` puts the lines of the N4 log into it, once each
(an entry names the SHA-256 of the line it replays, `line`), in order, so a node that ran slice N4 loses nothing; from then
on `Clients.audit` writes both (the JSON lines stay: they are the log a person can read with a pager).

    facilitator audit verify        the register's entries all valid and signed, no fork, and the jsonl log fully replayed
    facilitator audit replay        put the lines of http/audit.jsonl not yet in the register into it
    facilitator audit show          the events
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from registerengine import adapters, core

from .record import FACILITATOR, RecordError, audit_type

REGISTER = "audit-enrolment"


class AuditError(RuntimeError):
    pass


def line_hash(line: str) -> str:
    return hashlib.sha256(line.encode()).hexdigest()


class Audit:
    def __init__(self, fac):
        self.fac = fac
        self.dir = fac.state.home / "audit" / REGISTER
        self._type = None
        self.checked: set = set()

    @property
    def type(self):
        if self._type is None:
            self._type = audit_type()
        return self._type

    def store(self) -> adapters.DirStore:
        return adapters.DirStore(self.dir)

    def anchors(self) -> dict:
        return self.fac.record.anchors()

    # ------------------------------------------------------------ writing

    def append(self, event: str, subject: str, by: str, detail: str = "", claimed: str | None = None,
               line: str | None = None) -> str:
        """One signed entry. Never raises into the act it records: the caller treats a failure as 'not recorded here yet'
        (the jsonl log, or the command's own output, still holds it); `replay` and `verify` show the gap."""
        data = {"event": event, "subject": subject, "by": by}
        if detail:
            data["detail"] = detail[:500]
        if claimed:
            data["claimed"] = claimed
        if line:
            data["line"] = line
        self.fac.record.facilitator_key()
        self.dir.parent.mkdir(parents=True, exist_ok=True)
        try:
            return adapters.add(self.store(), self.fac.signer.signing_path(FACILITATOR), FACILITATOR, "enrolment", data,
                                self.anchors(), checked=self.checked, register=REGISTER, kinds=self.type.kinds)
        except core.Refused as e:
            raise AuditError(f"the audit register refused an entry: {e}") from None

    def on_line(self, line: str, rec: dict) -> None:
        """Called by Clients.audit after it wrote a line of http/audit.jsonl: the same event, signed, in the register."""
        try:
            self.append(_EVENTS.get(rec["event"], rec["event"]), rec["client"], rec["by"], rec.get("detail", ""),
                        rec.get("at"), line_hash(line))
        except (AuditError, RecordError, OSError, KeyError):
            pass            # the log has it; `facilitator audit replay` catches the register up

    # ------------------------------------------------------------ reading

    def read(self):
        led = core.read(adapters.raws(self.store()), self.anchors(), self.checked, REGISTER, self.type.kinds)
        proj, flags = self.type.project(led)
        return led, proj, flags

    def events(self) -> list[dict]:
        if not self.dir.is_dir():
            return []
        return self.read()[1]["events"]

    def log_lines(self) -> list[str]:
        try:
            return [x for x in self.fac.clients.audit_file.read_text().splitlines() if x.strip()]
        except OSError:
            return []

    def replay(self) -> int:
        """Puts the lines of http/audit.jsonl that the register does not hold into it, in the log's order. Idempotent: a line
        already replayed (its hash in an entry) is skipped. Returns how many entries were written."""
        have = set(self.read()[1]["lines"]) if self.dir.is_dir() else set()
        n = 0
        for line in self.log_lines():
            h = line_hash(line)
            if h in have:
                continue
            try:
                rec = json.loads(line)
                self.append(_EVENTS.get(rec["event"], rec["event"]), rec["client"], rec["by"], rec.get("detail", ""),
                            rec.get("at"), h)
            except (ValueError, KeyError) as e:
                raise AuditError(f"a line of http/audit.jsonl cannot be replayed ({e}): {line[:80]}") from None
            have.add(h)
            n += 1
        return n

    def verify(self) -> tuple[bool, str]:
        """(ok, detail): every entry of the register valid and its chain whole (no refused, held or forked entry, none by
        another key than the facilitator's), and every line of http/audit.jsonl present in it, in the log's order."""
        lines = self.log_lines()
        if not self.dir.is_dir():
            return (not lines, "no audit register yet" + (f"; {len(lines)} log line(s) not replayed (facilitator audit replay)" if lines else ""))
        led, proj, flags = self.read()
        problems = []
        for i, (code, detail) in led.refused.items():
            problems.append(f"entry {i[:12]} refused: {code} {detail}".strip())
        for i, waits in led.held.items():
            problems.append(f"entry {i[:12]} held, waiting for {', '.join(w[:12] for w in waits)} (a gap in the chain)")
        for f in led.unruled_forks:
            problems.append(f"a fork: {', '.join(x[:12] for x in f)}")
        for i, fs in flags.items():
            problems.append(f"entry {i[:12]}: {', '.join(fs)}")
        order = {e["entry"]: n for n, e in enumerate(proj["events"])}
        last = -1
        for line in lines:
            i = proj["lines"].get(line_hash(line))
            if i is None:
                problems.append(f"the log line {line_hash(line)[:12]} is not in the register (facilitator audit replay)")
            elif order[i] < last:
                problems.append(f"the log line {line_hash(line)[:12]} is in the register out of order")
            else:
                last = order[i]
        if problems:
            return False, "; ".join(problems[:4]) + (f" (+{len(problems) - 4} more)" if len(problems) > 4 else "")
        return True, (f"{len(proj['events'])} signed event(s), the chain holds, {len(lines)} log line(s) all replayed"
                      if lines else f"{len(proj['events'])} signed event(s), the chain holds")


_EVENTS = {"enrolled": "enrolled", "approved": "approved", "denied": "denied", "revoked": "revoked", "forget": "forget"}
