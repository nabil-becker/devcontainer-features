"""install.sh into a throwaway root (DESTDIR), without the downloads: what it installs, the options baked,
the Taskfile switch, idempotence, the refusals (lean, identity, a checksum that does not match), and the
conversation type put into register-engine's types folder when that Feature is there."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

INSTALL = helpers.SRC / "install.sh"


def install(root, **env):
    e = {k: v for k, v in os.environ.items() if not k.startswith("FACILITATOR_")}
    e.update({"DESTDIR": str(root), **{k: str(v) for k, v in env.items()}})
    e.setdefault("FACILITATOR_SKIP_DOWNLOADS", "1")
    if e["FACILITATOR_SKIP_DOWNLOADS"] == "":
        del e["FACILITATOR_SKIP_DOWNLOADS"]
    return subprocess.run(["bash", str(INSTALL)], env=e, capture_output=True, text=True)


def test_installs_the_tree_and_options():
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(f"{t}/usr/local/lib/register-engine/types.d")
        r = install(t, HOPLIMIT=4, AUTOSTART="false")
        assert r.returncode == 0, r.stderr
        lib = f"{t}/usr/local/lib/facilitator"
        for p in ("facilitator/cli.py", "registerengine/core.py", "signpacket/packet.py", "types.d/facilitator.py",
                  "agntcy/dir-daemon.config.yaml.in", "agntcy/slim-config.yaml.in", "options.env"):
            assert os.path.isfile(f"{lib}/{p}"), p
        for b in ("facilitator", "facilitator-setup", "facilitator-start"):
            assert os.access(f"{t}/usr/local/bin/{b}", os.X_OK), b
        assert os.access(f"{t}/usr/local/libexec/facilitator/dcf-persist", os.X_OK)
        assert os.path.isfile(f"{t}/usr/local/share/go-task/includes.d/facilitator.yml")
        assert os.path.isfile(f"{t}/usr/local/lib/register-engine/types.d/facilitator.py")
        opts = open(f"{lib}/options.env").read()
        assert "FACILITATOR_HOP_LIMIT=4" in opts and "FACILITATOR_AUTOSTART=false" in opts
        assert "FACILITATOR_BACKEND=agntcy" in opts
        v = subprocess.run([f"{t}/usr/local/bin/facilitator", "version", "--json"], capture_output=True, text=True,
                           env={**os.environ, "FACILITATOR_HOME": f"{t}/state"}, cwd=t)
        assert v.returncode == 0 and '"facilitator": "0.1.0"' in v.stdout, v.stderr
        assert '"backend": "agntcy"' in v.stdout
        again = install(t, HOPLIMIT=4)
        assert again.returncode == 0, again.stderr                   # idempotent


def test_taskfile_switch():
    with tempfile.TemporaryDirectory() as t:
        assert install(t).returncode == 0
        r = install(t, INSTALLTASKFILE="false")
        assert r.returncode == 0 and not os.path.exists(f"{t}/usr/local/share/go-task/includes.d/facilitator.yml")


def test_refusals():
    with tempfile.TemporaryDirectory() as t:
        r = install(t, BACKEND="lean")
        assert r.returncode == 1 and "not yet: slice 5" in r.stderr, r.stderr
        r = install(t, IDENTITY="true")
        assert r.returncode == 1 and "not yet: slice 7" in r.stderr
        r = install(t, HOPLIMIT="six")
        assert r.returncode == 1 and "hopLimit" in r.stderr
        r = install(t, DIRVERSION="1.0.0")
        assert r.returncode == 1 and "no pinned checksum for dirctl 1.0.0" in r.stderr
        assert not os.path.exists(f"{t}/usr/local/bin/facilitator")


def test_a_download_that_does_not_match_is_refused():
    with tempfile.TemporaryDirectory() as t:
        assets = f"{t}/assets"
        os.makedirs(assets)
        for name in ("dirctl-linux-amd64", "dirctl-linux-arm64"):
            open(f"{assets}/{name}", "w").write("not the binary\n")
        r = install(f"{t}/root", FACILITATOR_SKIP_DOWNLOADS="", FACILITATOR_ASSETS=assets)
        assert r.returncode == 1 and "does not match the one pinned" in r.stderr, r.stderr
        assert not os.path.exists(f"{t}/root/usr/local/bin/dirctl")


def test_latest_resolves_to_the_pin():
    with tempfile.TemporaryDirectory() as t:
        r = install(t, DIRVERSION="latest", SLIMVERSION="v3.4.6")
        assert r.returncode == 0 and "dirVersion latest resolves to 1.9.1" in r.stdout, r.stdout


if __name__ == "__main__":
    helpers.run_tests(globals())
