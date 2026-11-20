"""Shared by the facilitator's unit tests: a throwaway repository and state folder, the library on the
path from the source tree, keys in files (no OpenBao), the poll transport (no SLIM)."""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "src" / "facilitator"
sys.path[:0] = [str(SRC)]

PARTICIPANTS = """participants:
  - name: jester
    cli: openai-compatible
    kind: resident
    description: tells jokes
    skills: [humour]
  - name: domain-expert-one
    cli: claude
    kind: resident
    attachment: mcp
  - name: third
    cli: fakeb
    kind: on-demand
"""


class Env:
    """A repository with .devcontainer/participants.yml and a state folder; the environment set for both
    in-process use and subprocesses (`run`)."""

    def __init__(self, participants: str = PARTICIPANTS, facilitator_yml: str | None = None, **extra):
        self.tmp = tempfile.TemporaryDirectory(prefix="fac-test-")
        self.root = Path(self.tmp.name) / "repo"
        (self.root / ".devcontainer").mkdir(parents=True)
        (self.root / ".devcontainer" / "participants.yml").write_text(participants)
        if facilitator_yml is not None:
            (self.root / ".devcontainer" / "facilitator.yml").write_text(facilitator_yml)
        self.home = Path(self.tmp.name) / "home"
        self.env = {"FACILITATOR_HOME": str(self.home), "FACILITATOR_KEYS": "file", "FACILITATOR_TRANSPORT": "poll",
                    "FACILITATOR_DIRCTL": "/nonexistent/dirctl", "FACILITATOR_SLIMCTL": "/nonexistent/slimctl",
                    **{k: str(v) for k, v in extra.items()}}
        self.old_env = {k: os.environ.get(k) for k in self.env}
        self.old_cwd = os.getcwd()
        os.environ.update(self.env)
        os.chdir(self.root)

    def close(self) -> None:
        os.chdir(self.old_cwd)
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def fac(self):
        from facilitator import settings
        from facilitator.app import Facilitator
        return Facilitator(settings.load())

    def register_all(self, fac=None):
        fac = fac or self.fac()
        for h in ("you", "jester", "domain-expert-one", "third"):
            fac.register(h, push=False)
        return fac

    def session(self, fac, handle):
        from facilitator.app import Session
        tok = (self.home / "tokens" / handle).read_text().strip()
        return Session(fac, handle, tok)


def run_tests(g: dict) -> None:
    """Every test_* function of the module, one line each; exit 1 on a failure."""
    import traceback
    names = [n for n in g if n.startswith("test_") and callable(g[n])]
    bad = 0
    for n in names:
        try:
            g[n]()
            print(f"ok   {n}")
        except Exception:                      # noqa: BLE001
            bad += 1
            print(f"FAIL {n}")
            traceback.print_exc()
    print(f"{len(names) - bad}/{len(names)} passed")
    sys.exit(1 if bad else 0)
