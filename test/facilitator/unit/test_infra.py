"""The infrastructure, with fake dirctl and slimctl that only listen on their port: up starts them and is
idempotent, status sees a crash and says so, down stops them by pid, a port in use is refused naming its
owner, the configs are rendered with every port on loopback and the online schema check off unless asked; a
stale Directory daemon.pid is removed before a start; `node run` keeps the node in the foreground, stops it on a
signal (exit 0) and stops it all when one part dies (exit 1)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

from facilitator.infra import InfraError, pid_alive, port_owner  # noqa: E402

LISTEN = ("import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); "
          "s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(); time.sleep(3600)")


def fakes(folder: Path) -> dict:
    folder.mkdir(parents=True, exist_ok=True)
    py = sys.executable
    (folder / "dirctl").write_text(
        "#!/bin/sh\n# dirctl daemon start --data-dir D --config C\n"
        "port=$(sed -n 's/^  listen_address: \"127.0.0.1:\\([0-9]*\\)\"/\\1/p' \"$6\")\n"
        f"exec {py} -c \"{LISTEN}\" \"$port\" daemon start\n")
    (folder / "slimctl").write_text(
        "#!/bin/sh\n# slimctl slim start --config C\n"
        "port=$(sed -n 's/.*endpoint: \"127.0.0.1:\\([0-9]*\\)\"/\\1/p' \"$4\")\n"
        f"exec {py} -c \"{LISTEN}\" \"$port\" slim start\n")
    for f in ("dirctl", "slimctl"):
        (folder / f).chmod(0o755)
    return {"FACILITATOR_DIRCTL": str(folder / "dirctl"), "FACILITATOR_SLIMCTL": str(folder / "slimctl")}


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def env_ports():
    return {"FACILITATOR_DIR_PORT": free_port(), "FACILITATOR_DIR_OCI_PORT": free_port(),
            "FACILITATOR_DIR_P2P_PORT": free_port(), "FACILITATOR_DIR_GATEWAY_PORT": free_port(),
            "FACILITATOR_SLIM_PORT": free_port()}


def test_up_idempotent_status_down():
    tmp = Path(__import__("tempfile").mkdtemp(prefix="fac-infra-"))
    e = helpers.Env(**fakes(tmp / "bin"), **env_ports())
    inf = None
    try:
        fac = e.fac()
        inf = fac.infra()
        assert dict(inf.up()) == {"agent": "started", "dir": "started", "slim": "started"}
        pids = {c: inf.pid(c) for c in ("dir", "slim")}
        assert dict(inf.up()) == {"agent": "running", "dir": "running", "slim": "running"}
        assert {c: inf.pid(c) for c in ("dir", "slim")} == pids          # one copy each, never two
        assert all(r["healthy"] for r in inf.status())
        cfg = (e.home / "dir" / "daemon.config.yaml").read_text()
        assert "0.0.0.0" not in cfg and "localhost:" not in cfg and "operations: []" in cfg
        assert ":@" not in cfg and "@POLICY" not in cfg
        slim_cfg = (e.home / "slim" / "config.yaml").read_text()
        assert f'endpoint: "127.0.0.1:{os.environ["FACILITATOR_SLIM_PORT"]}"' in slim_cfg
        assert oct(os.stat(e.home / "secrets" / "slim.json").st_mode & 0o777) == "0o600"
        os.kill(pids["slim"], signal.SIGKILL)                            # a crash: not restarted, said
        time.sleep(0.3)
        row = {r["component"]: r for r in inf.status()}["slim"]
        assert not row["running"] and "does not restart" in row["note"]
        assert dict(inf.up(["slim"])) == {"slim": "started"}
        downs = dict(inf.down())
        assert downs == {"slim": "stopped now", "dir": "stopped now", "agent": "stopped now"}, downs
        assert not any(pid_alive(p, "start") for p in pids.values() if p)     # (a zombie child of this test has no command line)
        assert not any(r["running"] for r in inf.status())
        assert dict(inf.down()) == {"slim": "stopped", "dir": "stopped", "agent": "stopped"}
    finally:
        if inf:
            inf.down()
        e.close()
        __import__("shutil").rmtree(tmp, ignore_errors=True)


def test_port_in_use_names_its_owner():
    tmp = Path(__import__("tempfile").mkdtemp(prefix="fac-infra-"))
    ports = env_ports()
    e = helpers.Env(**fakes(tmp / "bin"), **ports)
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", ports["FACILITATOR_SLIM_PORT"]))
    s.listen()
    try:
        owner = port_owner(ports["FACILITATOR_SLIM_PORT"])
        assert owner and f"pid {os.getpid()}" in owner, owner
        inf = e.fac().infra()
        try:
            inf.up_one("slim")
            raise AssertionError("started on a port in use")
        except InfraError as x:
            assert f"pid {os.getpid()}" in str(x) and "FACILITATOR_SLIM_PORT" in str(x), str(x)
        row = {r["component"]: r for r in inf.status()}["slim"]
        assert row["port_owners"]["dataplane"] == owner
    finally:
        s.close()
        e.close()
        __import__("shutil").rmtree(tmp, ignore_errors=True)


def test_online_schema_check_when_asked():
    e = helpers.Env(FACILITATOR_DIR_ONLINE_CHECK="true")
    try:
        cfg = e.fac().infra().render("dir").read_text()
        assert "schema.oasf.outshift.com" in cfg.split("operations:", 1)[1].splitlines()[0]
    finally:
        e.close()


def test_a_stale_daemon_pid_is_removed():
    tmp = Path(__import__("tempfile").mkdtemp(prefix="fac-infra-"))
    e = helpers.Env(**fakes(tmp / "bin"), **env_ports())
    inf = None
    try:
        inf = e.fac().infra()
        (e.home / "dir").mkdir(parents=True)
        (e.home / "dir" / "daemon.pid").write_text("1\n")             # left by a removed container
        assert inf.up_one("dir") == "started"
        assert not (e.home / "dir" / "daemon.pid").exists()
    finally:
        if inf:
            inf.down()
        e.close()
        __import__("shutil").rmtree(tmp, ignore_errors=True)


def _node_run(e):
    argv = [sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "run"]
    return subprocess.Popen(argv, cwd=e.root, env=dict(os.environ), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)


def _wait_running(p, e, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        pids = [(e.home / "run" / f"{c}.pid") for c in ("dir", "slim")]
        if p.poll() is not None:
            break
        if all(f.exists() for f in pids):
            time.sleep(1.5)
            return {f.stem: int(f.read_text()) for f in pids}
        time.sleep(0.1)
    if p.poll() is not None:
        raise AssertionError(f"node run exited {p.returncode}: {p.communicate()}")
    raise AssertionError("node run did not start its parts")


def test_node_run_stops_on_a_signal():
    tmp = Path(__import__("tempfile").mkdtemp(prefix="fac-infra-"))
    e = helpers.Env(**fakes(tmp / "bin"), **env_ports())
    p = _node_run(e)
    try:
        pids = _wait_running(p, e)
        p.send_signal(signal.SIGTERM)
        out, err = p.communicate(timeout=30)
        assert p.returncode == 0, err
        assert "node running (role standalone" in out and "slim stopped now" in out, out
        assert not any(pid_alive(x, "start") for x in pids.values())
    finally:
        if p.poll() is None:
            p.kill()
        e.fac().infra().down()
        e.close()
        __import__("shutil").rmtree(tmp, ignore_errors=True)


def test_node_run_stops_all_when_one_dies():
    tmp = Path(__import__("tempfile").mkdtemp(prefix="fac-infra-"))
    e = helpers.Env(**fakes(tmp / "bin"), **env_ports())
    p = _node_run(e)
    try:
        pids = _wait_running(p, e)
        os.kill(pids["slim"], signal.SIGKILL)
        out, err = p.communicate(timeout=30)
        assert p.returncode == 1, (out, err)
        assert "slim stopped; stopping the node" in err, err
        assert not pid_alive(pids["dir"], "start")
    finally:
        if p.poll() is None:
            p.kill()
        e.fac().infra().down()
        e.close()
        __import__("shutil").rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    helpers.run_tests(globals())
