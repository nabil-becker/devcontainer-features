#!/usr/bin/env python3
"""The packet-relay Feature, installed and used: install.sh into a throwaway root, the command, the
Taskfile. install.sh runs with DESTDIR into a throwaway root, as the current user."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FEATURE = HERE.parents[2] / "src" / "packet-relay"
FAILED: list[str] = []
PASSED = 0


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:700] if got is not None else ""))


def install(feature: Path, root: Path, **options) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(feature / "install.sh")], capture_output=True, text=True,
                          env={**os.environ, "DESTDIR": str(root), **options})


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        root = tmp / "root"
        if os.geteuid() != 0:
            r = subprocess.run(["bash", str(FEATURE / "install.sh")], capture_output=True, text=True,
                               env={k: v for k, v in os.environ.items() if k != "DESTDIR"})
            check("install: refuses to run as anyone but root", r.returncode != 0 and "root" in r.stderr, r.stderr)
        r = install(FEATURE, root, ROOT="/mnt/relay")
        check("install: installs under DESTDIR, with its own copy of sign-packet's library", r.returncode == 0
              and (root / "usr/local/lib/packet-relay/signpacket/packet.py").is_file()
              and not (root / "usr/local/lib/sign-packet").exists(), r.stderr or r.stdout)
        for p in ("usr/local/bin/packet-relay", "usr/local/bin/packet-relay-setup", "usr/local/libexec/packet-relay/dcf-persist",
                  "usr/local/lib/packet-relay/packetrelay/relay.py", "usr/local/lib/packet-relay/SPEC.md",
                  "usr/local/share/go-task/includes.d/packet-relay.yml"):
            check(f"install: {p}", (root / p).is_file())
        check("install: the root option is kept for the command",
              "ROOT=/mnt/relay" in (root / "usr/local/lib/packet-relay/options.env").read_text())
        version = json.loads((FEATURE / "devcontainer-feature.json").read_text())["version"]
        env = {**os.environ, "PACKET_RELAY_HOME": str(tmp / "home")}
        r = subprocess.run([str(root / "usr/local/bin/packet-relay"), "version", "--json"], capture_output=True, text=True, env=env)
        v = json.loads(r.stdout) if r.returncode == 0 else {}
        check("command: the installed command runs from the installed library, at the Feature's version",
              v.get("packet-relay") == version and v.get("library", "").startswith(str(root)), r.stdout or r.stderr)
        r = subprocess.run([str(root / "usr/local/bin/packet-relay"), "check"], capture_output=True, text=True, env=env)
        check("command: check is NOT READY while the shared folder is not mounted", r.returncode == 1 and "NOT READY" in r.stdout, r.stdout)
        check("install: a second install succeeds (idempotent)", install(FEATURE, root).returncode == 0)
        r = install(FEATURE, root, INSTALLTASKFILE="false")
        check("install: installTaskfile=false leaves no Taskfile",
              r.returncode == 0 and not (root / "usr/local/share/go-task/includes.d/packet-relay.yml").exists())
        alone = tmp / "published" / "packet-relay"                    # a published copy: no sign-packet beside it
        shutil.copytree(FEATURE, alone, ignore=shutil.ignore_patterns("__pycache__"))
        bare = tmp / "bare"
        r = install(alone, bare)
        check("alone: a published copy installs with nothing beside it", r.returncode == 0, r.stderr)
        r = subprocess.run([str(bare / "usr/local/bin/packet-relay"), "version"], capture_output=True, text=True, env=env)
        check("alone: the command runs on its own copy of sign-packet, no sign-packet Feature needed",
              r.returncode == 0 and "sign-packet" in r.stdout, r.stderr or r.stdout)

        # The guard options, installed: the command reads them, and an environment cannot drop them.
        phi = tmp / "bin" / "phi-check"
        phi.parent.mkdir()
        phi.write_text(f"#!{sys.executable}\nimport re, sys\nsys.exit(1 if re.search(r'\\d{{3}}-\\d{{2}}-\\d{{4}}', sys.stdin.read()) else 0)\n")
        phi.chmod(0o755)
        groot = tmp / "guarded"
        r = install(FEATURE, groot, GUARD=f"{phi} -", INGRESSGUARD=f"{phi} -", GUARDTIMEOUT="5")
        check("guards: the guard options install, and the install says which", r.returncode == 0
              and "guards: egress, ingress" in r.stdout, r.stdout + r.stderr)
        genv = {**os.environ, "PACKET_RELAY_HOME": str(tmp / "ghome"), "PACKET_RELAY_ROOT": str(tmp / "gshared")}
        (tmp / "gshared").mkdir()
        cmd = str(groot / "usr/local/bin/packet-relay")
        lines = [subprocess.run([cmd, "key", "new", p], capture_output=True, text=True, env=genv).stdout.strip() for p in ("alice", "bob")]
        (tmp / "ghome" / "members").mkdir(parents=True, exist_ok=True)
        (tmp / "ghome" / "members" / "talk").write_text("\n".join(lines) + "\n")
        r = subprocess.run([cmd, "send", "--domain", "talk", "--as", "alice", "--kind", "note", "--data",
                            '{"text": "ssn 123-45-6789"}'], capture_output=True, text=True, env=genv)
        check("guards: the installed command refuses what its egress guard refuses, in one line",
              r.returncode == 2 and "guarded" in r.stderr and "123-45-6789" not in r.stderr
              and len(r.stderr.strip().splitlines()) == 1, r.stderr)
        r = subprocess.run([cmd, "send", "--domain", "talk", "--as", "alice", "--kind", "note", "--data", '{"text": "fine"}'],
                           capture_output=True, text=True, env=genv)
        check("guards: and sends what it lets through", r.returncode == 0, r.stderr)
        r = install(FEATURE, tmp / "badguard", GUARD="phi-check -")
        check("guards: a guard that is not an absolute path fails the install, saying why",
              r.returncode != 0 and "absolute path" in r.stderr, r.stderr)
        r = subprocess.run(["task", "--list-all", "--json", "--taskfile", str(FEATURE / "taskfile.yml")],
                           capture_output=True, text=True, env={**os.environ, "NO_COLOR": "1"})
        tasks = json.loads(r.stdout)["tasks"] if r.returncode == 0 else []
        check("taskfile: version, setup, check, key, send, sync, status and skip, each with a desc",
              {x["name"] for x in tasks} >= {"version", "setup", "check", "key", "send", "sync", "status", "skip"}
              and all(x["desc"] for x in tasks), r.stdout or r.stderr)
    print(f"packet-relay feature: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
