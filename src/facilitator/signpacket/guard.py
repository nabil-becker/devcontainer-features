"""Guards: an adopter's own checks on what goes into a packet and what comes out of one (SPEC.md,
"Guards").

A guard is a command, its first word an absolute path. It reads the packet's exact body bytes on
standard input and exits 0 to let the packet through; anything else refuses it (`guarded`): a
non-zero exit, a crash, a command that cannot run, or no answer within the timeout. It is given a
fixed PATH, the locale, the domain and the direction (`egress`: before a packet is signed;
`ingress`: after a received packet's signature is checked), and nothing else of the caller's
environment. The refusal names the exit and the first line of the guard's standard error; it never
repeats the packet. A chain runs its guards in order, and the first refusal decides.

A layer decides where it runs them, and what a refusal means there: agentic-register refuses to
write; packet-relay refuses to send on egress, and quarantines on ingress.
"""
from __future__ import annotations

import os
import shlex
import signal
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from .packet import Refused

TIMEOUT = 10.0              # seconds, unless a guard says otherwise
TIMEOUT_MAX = 300.0         # every writer waits for it
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ERR_MAX = 4096              # bytes of the guard's stderr read; the refusal shows one line of it
DIRECTIONS = ("egress", "ingress")


class GuardFailed(Refused):
    """The guard did not answer about the content: it could not run, gave no answer in time, or was
    killed. Still `guarded` (the packet does not pass), but a layer may tell it from a refusal: it
    says nothing about the packet (packet-relay holds the sender's order instead of quarantining)."""

    def __init__(self, detail: str):
        super().__init__("guarded", detail)


def env(domain: str, direction: str, extra: Iterable[tuple[str, str]] = ()) -> dict[str, str]:
    """All a guard is given: a fixed PATH, the locale, the domain and the direction, a layer's own
    names first (they never replace these), and Python's isolation (no user site, no script folder
    on the path) for a guard written in Python. Nothing else of the caller's environment."""
    out = dict(extra)
    out.update({"PATH": PATH, "SIGN_PACKET_GUARD_DOMAIN": domain, "SIGN_PACKET_GUARD_DIRECTION": direction,
                "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1"})
    for k in ("LANG", "LC_ALL", "LC_CTYPE"):
        if k in os.environ:
            out[k] = os.environ[k]
    return out


def _printable(text: str) -> str:
    return "".join(c if c.isprintable() else "?" for c in text)


def argv_of(value) -> tuple[str, ...]:
    """A guard's command, from a string (split as a shell would, without running one) or a list.
    Its first word MUST be an absolute path: never found on a writer's PATH or in its checkout."""
    argv = shlex.split(value) if isinstance(value, str) else value
    if not (isinstance(argv, (list, tuple)) and argv and all(isinstance(x, str) and x for x in argv)):
        raise ValueError(f"a guard is a command, a string or a list of strings: {value!r}")
    if not Path(argv[0]).is_absolute():
        raise ValueError(f"a guard's command is an absolute path, e.g. /usr/local/bin/phi-check: {argv[0]!r}")
    return tuple(argv)


@dataclass(frozen=True)
class Guard:
    """One command run on a packet's body. `extra`: more variables a layer gives it (agentic-register
    names the register in AGENTIC_REGISTER_GUARD_REGISTER)."""
    argv: tuple[str, ...]
    timeout: float = TIMEOUT
    extra: tuple[tuple[str, str], ...] = ()

    def __post_init__(self):
        argv_of(self.argv)
        if isinstance(self.timeout, bool) or not 0 < self.timeout <= TIMEOUT_MAX:
            raise ValueError(f"a guard's timeout is a number of seconds, 0 to {TIMEOUT_MAX:g}: {self.timeout!r}")

    def env(self, domain: str, direction: str) -> dict[str, str]:
        return env(domain, direction, self.extra)

    def check(self, body: bytes, domain: str, direction: str = "egress", noun: str = "packet") -> None:
        """Run the guard on the body. Returns when it lets the packet through; raises Refused("guarded").
        `noun`: what the refusal calls it (agentic-register says entry)."""
        if direction not in DIRECTIONS:
            raise ValueError(f"a guard's direction is egress or ingress: {direction!r}")
        with tempfile.TemporaryFile() as errf:
            try:
                p = subprocess.Popen(list(self.argv), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errf,
                                     env=self.env(domain, direction), cwd="/", start_new_session=True)
            except (OSError, ValueError) as e:
                raise GuardFailed(f"the guard could not run: {getattr(e, 'strerror', None) or e}") from None
            try:
                p.communicate(body, timeout=self.timeout)
                timed_out = False
            except subprocess.TimeoutExpired:
                timed_out = True
            try:
                os.killpg(p.pid, signal.SIGKILL)   # the guard and anything it started, whatever it answered
            except OSError:
                pass
            p.wait()
            if p.stdin:
                try:
                    p.stdin.close()
                except OSError:
                    pass
            if timed_out:
                raise GuardFailed(f"the guard gave no answer within {self.timeout:g}s") from None
            errf.seek(0)
            err = errf.read(ERR_MAX)
        if p.returncode < 0:                       # killed by a signal: no answer about the content
            raise GuardFailed(f"the guard was killed before it answered (exit {p.returncode}, signal {-p.returncode})")
        if p.returncode != 0:
            first = (err.decode("utf-8", errors="replace").strip().splitlines() or ["no reason given"])[0][:200]
            raise Refused("guarded", f"the guard refused the {noun} (exit {p.returncode}): {_printable(first)}")


@dataclass(frozen=True)
class Chain:
    """Guards run in order; the first refusal decides. An empty chain lets everything through."""
    guards: tuple[Guard, ...] = field(default_factory=tuple)

    @classmethod
    def of(cls, commands: Iterable, timeout: float = TIMEOUT) -> "Chain":
        return cls(tuple(Guard(argv_of(c), timeout) for c in commands))

    @classmethod
    def parse(cls, value: str, timeout: float = TIMEOUT) -> "Chain":
        """An option's value: commands separated by `;`, each split as a shell would. Empty: no guard.
        A value that is not empty yet names no command is refused, never read as no guard."""
        chain = cls.of([c for c in (x.strip() for x in (value or "").split(";")) if c], timeout)
        if (value or "").strip() and not chain.guards:
            raise ValueError(f"a guard option that names no command: {value!r}")
        return chain

    def __bool__(self) -> bool:
        return bool(self.guards)

    def check(self, body: bytes, domain: str, direction: str = "egress") -> None:
        for g in self.guards:
            g.check(body, domain, direction)
