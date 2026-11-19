#!/usr/bin/env python3
"""The sign-packet Feature, installed and used: install.sh into a throwaway root, the command, the Taskfile.

install.sh runs with DESTDIR into a throwaway root, as the current user; nothing is installed in
the system.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FEATURE = HERE.parents[2] / "src" / "sign-packet"
FAILED: list[str] = []
PASSED = 0


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:700] if got is not None else ""))


def install(root: Path, **options) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(FEATURE / "install.sh")], capture_output=True, text=True,
                          env={**os.environ, "DESTDIR": str(root), **options})


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        root = Path(t) / "root"
        if os.geteuid() != 0:
            r = subprocess.run(["bash", str(FEATURE / "install.sh")], capture_output=True, text=True,
                               env={k: v for k, v in os.environ.items() if k != "DESTDIR"})
            check("install: refuses to run as anyone but root", r.returncode != 0 and "root" in r.stderr, r.stderr)
        r = install(root)
        check("install: installs under DESTDIR", r.returncode == 0, r.stderr or r.stdout)
        for p in ("usr/local/bin/sign-packet", "usr/local/bin/sign-packet-setup", "usr/local/libexec/sign-packet/dcf-persist",
                  "usr/local/lib/sign-packet/signpacket/instance.py", "usr/local/lib/sign-packet/signpacket/packet.py",
                  "usr/local/lib/sign-packet/signpacket/graph.py", "usr/local/lib/sign-packet/SPEC.md",
                  "usr/local/share/go-task/includes.d/sign-packet.yml"):
            check(f"install: {p}", (root / p).is_file())
        version = json.loads((FEATURE / "devcontainer-feature.json").read_text())["version"]
        r = subprocess.run([str(root / "usr/local/bin/sign-packet"), "version", "--json"], capture_output=True, text=True)
        v = json.loads(r.stdout) if r.returncode == 0 else {}
        check("command: the installed command runs from the installed library, at the Feature's version",
              v.get("sign-packet") == version and v.get("library", "").startswith(str(root)), r.stdout or r.stderr)
        state = Path(t) / "state"
        clean_path = ":".join(d for d in os.environ["PATH"].split(":") if d and not (Path(d) / "dcf-secret").exists())
        r = subprocess.run([str(root / "usr/local/bin/sign-packet-setup")], capture_output=True, text=True,
                           env={**{k: v for k, v in os.environ.items() if k != "AOF_INSTANCE_ID"},
                                "SIGN_PACKET_HOME": str(state), "PATH": f"{root / 'usr/local/bin'}:{clean_path}"})
        rec = (state / "instance-id").read_text().strip() if (state / "instance-id").exists() else ""
        check("setup: the post-create hook resolves this instance's id and records it, never failing",
              r.returncode == 0 and len(rec) == 36 and rec in r.stdout, r.stdout + r.stderr)
        check("install: a second install succeeds (idempotent)", install(root).returncode == 0)
        r = install(root, INSTALLTASKFILE="false")
        check("install: installTaskfile=false leaves no Taskfile",
              r.returncode == 0 and not (root / "usr/local/share/go-task/includes.d/sign-packet.yml").exists())
        r = subprocess.run(["task", "--list-all", "--json", "--taskfile", str(FEATURE / "taskfile.yml")],
                           capture_output=True, text=True, env={**os.environ, "NO_COLOR": "1"})
        names = {t["name"] for t in json.loads(r.stdout)["tasks"]} if r.returncode == 0 else set()
        check("taskfile: version, setup, check, instance and verify are there, each with a desc",
              names >= {"version", "setup", "check", "instance", "verify"}
              and all(t["desc"] for t in json.loads(r.stdout)["tasks"]), r.stdout or r.stderr)
    print(f"sign-packet feature: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
