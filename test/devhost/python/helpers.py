"""Fakes for the devhost Python tests: a temporary git repository with a committed ledger on a
base branch, an environment that points every DEVHOST_* variable at it, and transcripts with
the record shapes of Claude Code's own (usage, model, ids, timestamps; never content).
Standard library only; runs on Windows (`python`) and Linux (`python3`)."""
from __future__ import annotations

import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

HERE = Path(__file__).resolve().parent
PYTHON_DIR = HERE.parents[2] / "src" / "devhost" / "share" / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

LEDGER_MONTH = "2026-10"
# A made-up person, seeded where a real name would come from (the git identity); no output may carry it.
PERSON = "Guinevere Pendragon"
ENV_VARS = ("DEVHOST_ROOT", "DEVHOST_STATE", "DEVHOST_LEDGER_DIR", "DEVHOST_BACKLOG", "DEVHOST_LEXICON",
            "DEVHOST_ADR_DIR", "DEVHOST_NIGHT_SHIFT_DIR", "DEVHOST_ENGINEER", "DEVHOST_REDACT_FILE",
            "DEVHOST_REDACT_WITH", "DEVHOST_FORBIDDEN_WORDS", "DEVHOST_BASE_REF", "CLAUDE_CONFIG_DIR",
            "CLAUDE_PROJECT_DIR", "DEVHOST_SHARE")


def load(name: str):
    """The devhost module, fresh (its functions read the environment at call time anyway)."""
    return importlib.import_module(name)


def script(name: str) -> Path:
    return PYTHON_DIR / f"{name}.py"


def run(args: list[str], cwd: Path, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run a devhost script as its entrypoint would, with this interpreter."""
    return subprocess.run([sys.executable, str(script(args[0])), *args[1:]], cwd=str(cwd), env=env or os.environ.copy(),
                          capture_output=True, text=True, encoding="utf-8")


def git(root: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, encoding="utf-8")
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {done.stderr}")
    return done.stdout


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def entry(date: str, title: str, friction: str = "none") -> str:
    return "\n".join([
        f"### {date} {title}",
        "",
        "- **Session:** scribe (00000000-0000-0000-0000-000000000000)",
        "- **Engineer:** tester",
        "- **Branch:** work",
        f"- **Asked:** {title}",
        "- **Skill:** none",
        "- **Came out:** a change",
        f"- **Friction:** {friction}",
        "- **Learned:** none",
        "- **Decisions:** none",
        "- **For the repository:** none",
        "- **Decisions needed:** none",
        "- **Measures:** $0.01 (test); list-price estimate",
        "",
    ])


def ledger_text(entries: list[str]) -> str:
    return f"# Ledger, {LEDGER_MONTH}\n\n" + "\n".join(entries)


def make_repo(base: Path) -> Path:
    """A git repository with a ledger of two entries committed on `main`, checked out on `work`."""
    root = (base / "repo").resolve()
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.name", PERSON)
    git(root, "config", "user.email", "test@example.invalid")
    git(root, "config", "core.autocrlf", "false")
    git(root, "config", "commit.gpgsign", "false")
    write(root / ".claude" / "settings.json", "{}\n")
    write(root / "docs" / "ledger" / f"{LEDGER_MONTH}.md",
          ledger_text([entry("2026-10-01", "First thing"), entry("2026-10-02", "Second thing", "[tooling] a missing task")]))
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "ledger")
    git(root, "switch", "-q", "-c", "work")
    return root


def track(root: Path) -> None:
    git(root, "add", "-A")


@contextmanager
def devhost_env(root: Path, **extra: str):
    """Every DEVHOST_* and CLAUDE_* variable set for `root` (and cleared afterwards)."""
    saved = {k: os.environ.get(k) for k in ENV_VARS}
    for k in ENV_VARS:
        os.environ.pop(k, None)
    os.environ["DEVHOST_ROOT"] = str(root)
    os.environ["DEVHOST_STATE"] = str(root.parent / "state")
    os.environ["CLAUDE_CONFIG_DIR"] = str(root.parent / "claude")
    os.environ["DEVHOST_ENGINEER"] = "tester"
    for k, v in extra.items():
        os.environ[k] = v
    try:
        yield dict(os.environ)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# Transcripts: only the fields the scripts read, with made-up values.


def usage(input_tokens=1000, output_tokens=100, cache_read=0, cache_write=0, split=None) -> dict:
    u = {"input_tokens": input_tokens, "output_tokens": output_tokens,
         "cache_read_input_tokens": cache_read, "cache_creation_input_tokens": cache_write,
         "service_tier": "standard"}
    if split is not None:
        u["cache_creation"] = {"ephemeral_5m_input_tokens": split[0], "ephemeral_1h_input_tokens": split[1]}
    return u


def assistant(msg_id: str, model: str, ts: str, use: dict, uuid: str = "u-1", parent: str | None = "u-0") -> dict:
    return {"type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": ts,
            "message": {"id": msg_id, "model": model, "role": "assistant", "type": "message", "usage": use}}


def user(uuid: str = "u-0", ts: str = "2026-10-05T10:00:00.000Z") -> dict:
    return {"type": "user", "uuid": uuid, "parentUuid": None, "timestamp": ts, "message": {"role": "user", "content": "x"}}


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write('{"type": "permission-mode", "permissionMode": "default", "sessionId": "s"}\n')
        for r in records:
            handle.write(json.dumps(r) + "\n")


def project_folder(root: Path) -> Path:
    """Where Claude Code keeps the transcripts of `root` under CLAUDE_CONFIG_DIR."""
    import re
    return Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(root))


class RepoCase(unittest.TestCase):
    """A fresh repository and environment per test."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name).resolve()
        self.root = make_repo(self.base)
        self._env = devhost_env(self.root)
        self.env = self._env.__enter__()

    def tearDown(self) -> None:
        self._env.__exit__(None, None, None)
        try:
            self._tmp.cleanup()
        except (PermissionError, OSError):
            pass
