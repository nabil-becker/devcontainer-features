#!/usr/bin/env python3
"""The register-engine Feature, installed and used: install.sh into a throwaway root (with
sign-packet beside it, as in the source tree), the command, the Taskfile.

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
FEATURE = HERE.parents[2] / "src" / "register-engine"
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
        check("install: installs under DESTDIR, with its own copy of sign-packet's library", r.returncode == 0
              and (root / "usr/local/lib/register-engine/signpacket/packet.py").is_file()
              and not (root / "usr/local/lib/sign-packet").exists(), r.stderr or r.stdout)
        for p in ("usr/local/bin/register-engine", "usr/local/lib/register-engine/registerengine/core.py",
                  "usr/local/lib/register-engine/registerengine/adapters.py", "usr/local/lib/register-engine/registerengine/registertypes.py",
                  "usr/local/lib/register-engine/SPEC.md", "usr/local/share/go-task/includes.d/register-engine.yml"):
            check(f"install: {p}", (root / p).is_file())
        td = root / "usr/local/lib/register-engine/types.d"
        check("install: the types folder, writable by its owner alone", td.is_dir() and (td.stat().st_mode & 0o777) == 0o755,
              oct(td.stat().st_mode) if td.exists() else None)
        version = json.loads((FEATURE / "devcontainer-feature.json").read_text())["version"]
        cmd = str(root / "usr/local/bin/register-engine")
        r = subprocess.run([cmd, "version", "--json"], capture_output=True, text=True)
        v = json.loads(r.stdout) if r.returncode == 0 else {}
        check("command: the installed command runs from the installed library, at the Feature's version",
              v.get("register-engine") == version and v.get("library", "").startswith(str(root))
              and v.get("types") == str(td), r.stdout or r.stderr)
        r = subprocess.run([cmd, "types"], capture_output=True, text=True)
        check("command: a types folder in a root that is not root's all the way up is refused, saying why",
              r.returncode != 0 and ("not root" in r.stdout + r.stderr or "writable by its group or others" in r.stdout + r.stderr),
              r.stdout + r.stderr)
        r = subprocess.run([cmd, "check"], capture_output=True, text=True)
        check("command: check says the types folder is not ready there", r.returncode == 1 and "NOT READY" in r.stdout, r.stdout)
        # Isolated: a planted json.py and registerengine/ in the working folder and on PYTHONPATH never run.
        plant = Path(t) / "plant"
        (plant / "registerengine").mkdir(parents=True)
        marker = Path(t) / "planted-ran"
        for f in (plant / "json.py", plant / "registerengine" / "__init__.py", plant / "registerengine" / "cli.py"):
            f.write_text(f"open({str(marker)!r}, 'w').write('x')\n")
        r = subprocess.run([cmd, "version"], capture_output=True, text=True, cwd=plant,
                           env={**os.environ, "PYTHONPATH": str(plant)})
        check("command: modules planted in the working folder and on PYTHONPATH never run",
              r.returncode == 0 and not marker.exists(), r.stdout + r.stderr)
        (td / "kept.py").write_text("TYPES = []\n")
        os.chmod(td / "kept.py", 0o644)
        check("install: a second install succeeds, and keeps what the capability Features put in types.d",
              install(root).returncode == 0 and (td / "kept.py").is_file())
        r = install(root, INSTALLTASKFILE="false")
        check("install: installTaskfile=false leaves no Taskfile",
              r.returncode == 0 and not (root / "usr/local/share/go-task/includes.d/register-engine.yml").exists())
        r = subprocess.run(["task", "--list-all", "--json", "--taskfile", str(FEATURE / "taskfile.yml")],
                           capture_output=True, text=True, env={**os.environ, "NO_COLOR": "1"})
        names = {t["name"] for t in json.loads(r.stdout)["tasks"]} if r.returncode == 0 else set()
        check("taskfile: version, setup, check, types and verify are there, each with a desc",
              names >= {"version", "setup", "check", "types", "verify"}
              and all(t["desc"] for t in json.loads(r.stdout)["tasks"]), r.stdout or r.stderr)
    print(f"register-engine feature: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
