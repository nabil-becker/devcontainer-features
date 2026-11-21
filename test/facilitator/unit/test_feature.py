"""The bundle script and the Feature's install.sh into a throwaway root (DESTDIR), without the downloads: the
bundle script builds a skeleton bundle (FACILITATOR_SKIP_DOWNLOADS: the application and its libraries, no
interpreter, binaries or wheel) with its SHA256SUMS; install.sh installs it (FACILITATOR_BUNDLE). What it
installs, the options baked, mode leaf, the deprecated dirVersion and slimVersion, bundleVersion, the Taskfile
switch, idempotence, the refusals (lean, identity, a bundle that does not match its SHA256SUMS or the pin), the
vendored copy of the bundle script, and the conversation type put into register-engine's types folder."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import atexit  # noqa: E402
import json
import re  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tarfile  # noqa: E402
import tempfile  # noqa: E402

# The tests install skeleton bundles they build themselves, so they run the Feature from a copy whose
# digests.txt holds no pins: the real pins (for the published bundle) would refuse every skeleton.
_UNPINNED = Path(tempfile.mkdtemp(prefix="fac-feature-"))
atexit.register(shutil.rmtree, _UNPINNED, True)
shutil.copytree(helpers.SRC, _UNPINNED, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "bundle"))
(_UNPINNED / "digests.txt").write_text(
    "".join(line for line in (helpers.SRC / "digests.txt").read_text().splitlines(True) if line.startswith("#")))
INSTALL = _UNPINNED / "install.sh"
BUILDER = helpers.ROOT / "bundles" / "facilitator" / "install.sh"
ARCH = "arm64" if os.uname().machine in ("aarch64", "arm64") else "amd64"
# The bundle follows the application's version, not the Feature's (ruling CE): Feature 0.3.1 installs bundle 0.3.0.
VERSION = re.search(r'^__version__ = "([^"]+)"', (helpers.SRC / "facilitator" / "__init__.py").read_text(), re.M).group(1)
ASSET = f"facilitator-{VERSION}-linux-{ARCH}.tar.gz"


def clean_env(**env):
    e = {k: v for k, v in os.environ.items() if not k.startswith("FACILITATOR_")}
    e.update({k: str(v) for k, v in env.items()})
    return e


def build(out, builder=BUILDER, source=None):
    argv = ["bash", str(builder), "--arch", ARCH, "--out", str(out)] + (["--source", str(source)] if source else [])
    return subprocess.run(argv, env=clean_env(FACILITATOR_SKIP_DOWNLOADS="1"), capture_output=True, text=True)


_BUNDLE = {}


def bundle():
    """One skeleton bundle for the whole module: (folder, tarball)."""
    if not _BUNDLE:
        d = tempfile.mkdtemp(prefix="fac-bundle-")
        r = build(d)
        assert r.returncode == 0, r.stderr
        _BUNDLE["dir"] = d
    return Path(_BUNDLE["dir"]), Path(_BUNDLE["dir"]) / ASSET


def install(root, bundle_file=None, **env):
    e = clean_env(DESTDIR=str(root), **env)
    e.setdefault("FACILITATOR_BUNDLE", str(bundle_file or bundle()[1]))
    if e["FACILITATOR_BUNDLE"] == "":
        del e["FACILITATOR_BUNDLE"]
    return subprocess.run(["bash", str(INSTALL)], env=e, capture_output=True, text=True)


def facilitator(root, *args, **env):
    return subprocess.run([f"{root}/usr/local/bin/facilitator", *args], capture_output=True, text=True, cwd=root,
                          env={**clean_env(**env), "FACILITATOR_HOME": f"{root}/state"})


def test_the_bundle_and_its_sums():
    d, tarball = bundle()
    assert tarball.is_file()
    line = (d / "SHA256SUMS").read_text().split()
    assert line[1] == ASSET and len(line[0]) == 64
    with tarfile.open(tarball) as t:
        names = t.getnames()
        assert all(n == "facilitator" or n.startswith("facilitator/") for n in names)
        for p in ("bin/facilitator", "lib/facilitator/cli.py", "lib/registerengine/core.py", "lib/signpacket/packet.py",
                  "lib/types.d/facilitator.py", "lib/agntcy/dir-daemon.config.yaml.in", "MANIFEST.json"):
            assert f"facilitator/{p}" in names, p
        assert all(m.uid == 0 and m.gid == 0 for m in t.getmembers())
        manifest = json.load(t.extractfile("facilitator/MANIFEST.json"))
    assert manifest["version"] == VERSION and manifest["arch"] == ARCH and manifest["prefix"] == "/opt/facilitator"
    again = Path(tempfile.mkdtemp(prefix="fac-bundle-"))
    try:
        assert build(again).returncode == 0
        assert (again / "SHA256SUMS").read_text() == (d / "SHA256SUMS").read_text()   # the same bytes again
    finally:
        shutil.rmtree(again)


def test_the_libraries_come_from_the_source():
    d, tarball = bundle()
    with tarfile.open(tarball) as t:
        for lib in ("registerengine", "signpacket"):
            for f in sorted((helpers.SRC / lib).glob("*.py")):
                assert t.extractfile(f"facilitator/lib/{lib}/{f.name}").read() == f.read_bytes(), f


def test_the_vendored_builder_is_the_same_file():
    assert (helpers.SRC / "bundle-build.sh").read_bytes() == BUILDER.read_bytes(), "task bundle:sync"
    with tempfile.TemporaryDirectory() as t:                     # and builds the same bundle from the Feature's folder
        r = build(t, builder=helpers.SRC / "bundle-build.sh")
        assert r.returncode == 0, r.stderr
        assert (Path(t) / "SHA256SUMS").read_text() == (bundle()[0] / "SHA256SUMS").read_text()


def test_installs_the_tree_and_options():
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(f"{t}/usr/local/lib/register-engine/types.d")
        r = install(t, HOPLIMIT=4, AUTOSTART="false")
        assert r.returncode == 0, r.stderr
        assert "unpinned local bundle" in r.stdout
        opt = f"{t}/opt/facilitator"
        for p in ("lib/facilitator/cli.py", "lib/registerengine/core.py", "lib/signpacket/packet.py",
                  "lib/types.d/facilitator.py", "lib/agntcy/slim-config.yaml.in", "lib/options.env", "MANIFEST.json"):
            assert os.path.isfile(f"{opt}/{p}"), p
        for b in ("facilitator", "facilitator-setup", "facilitator-start"):
            assert os.access(f"{t}/usr/local/bin/{b}", os.X_OK), b
        assert os.readlink(f"{t}/usr/local/bin/facilitator") == "../../../opt/facilitator/bin/facilitator"
        assert os.access(f"{t}/usr/local/libexec/facilitator/dcf-persist", os.X_OK)
        assert os.path.isfile(f"{t}/usr/local/share/go-task/includes.d/facilitator.yml")
        assert os.path.isfile(f"{t}/usr/local/lib/register-engine/types.d/facilitator.py")
        opts = open(f"{opt}/lib/options.env").read()
        assert "FACILITATOR_HOP_LIMIT=4" in opts and "FACILITATOR_AUTOSTART=false" in opts
        assert "FACILITATOR_BACKEND=agntcy" in opts and "FACILITATOR_MODE=node" in opts
        assert "FACILITATOR_DEPRECATED=\n" in opts
        v = facilitator(t, "version", "--json")
        assert v.returncode == 0 and f'"facilitator": "{VERSION}"' in v.stdout, v.stderr
        assert '"backend": "agntcy"' in v.stdout and '"mode": "node"' in v.stdout
        assert f'"bundle": "{VERSION} linux-{ARCH}"' in v.stdout and "deprecated" not in v.stderr
        open(f"{opt}/stale-file", "w").write("x")
        again = install(t, HOPLIMIT=4)
        assert again.returncode == 0, again.stderr                   # idempotent: the tree is replaced whole
        assert not os.path.exists(f"{opt}/stale-file")


def test_mode_leaf():
    with tempfile.TemporaryDirectory() as t:
        r = install(t, MODE="leaf")
        assert r.returncode == 0, r.stderr
        assert "FACILITATOR_MODE=leaf" in open(f"{t}/opt/facilitator/lib/options.env").read()
        assert not os.path.lexists(f"{t}/usr/local/bin/slimctl")
        up = facilitator(t, "infra", "up")
        assert up.returncode == 1 and "mode leaf" in up.stderr, up.stderr
        run = facilitator(t, "node", "run")
        assert run.returncode == 1 and "mode leaf runs no node" in run.stderr, run.stderr
        start = subprocess.run([f"{t}/usr/local/bin/facilitator", "start"], capture_output=True, text=True, cwd=t,
                               env={**clean_env(), "FACILITATOR_HOME": f"{t}/state", "FACILITATOR_KEYS": "file"})
        assert start.returncode == 0 and "mode leaf: no daemon is started" in start.stdout, start.stdout + start.stderr
        c = facilitator(t, "check", "--json", FACILITATOR_KEYS="file")
        parts = {p["part"]: p for p in json.loads(c.stdout)}
        assert parts["mode"]["detail"].startswith("leaf") and not parts["slimctl"]["needed"]
        assert not any(k in parts for k in ("agent", "dir", "slim"))
        assert install(t, MODE="hub").returncode == 1


def test_deprecated_dir_and_slim_versions():
    with tempfile.TemporaryDirectory() as t:
        r = install(t, DIRVERSION="1.9.1", SLIMVERSION="latest")
        assert r.returncode == 0, r.stderr
        assert "dirVersion is deprecated: use bundleVersion" in r.stderr and "slimVersion is deprecated" in r.stderr
        assert "FACILITATOR_DEPRECATED=dirVersion slimVersion" in open(f"{t}/opt/facilitator/lib/options.env").read()
        v = facilitator(t, "version")
        assert v.returncode == 0 and "dirVersion is deprecated: use bundleVersion" in v.stderr, v.stderr
        r = install(t, DIRVERSION="1.0.0")
        assert r.returncode == 1 and "dirVersion 1.0.0: the bundle carries 1.9.1" in r.stderr, r.stderr


def test_bundle_version():
    with tempfile.TemporaryDirectory() as t:
        r = install(t, BUNDLEVERSION="latest")
        assert r.returncode == 0 and f"bundleVersion latest resolves to {VERSION}" in r.stdout, r.stdout
        r = install(t, BUNDLEVERSION="0.0.1", FACILITATOR_BUNDLE="")
        assert r.returncode == 1 and "no digest for facilitator-0.0.1" in r.stderr, r.stderr
        r = install(t, BUNDLEVERSION="next")
        assert r.returncode == 1 and "bundleVersion 'next'" in r.stderr


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
        assert not os.path.exists(f"{t}/usr/local/bin/facilitator")


def test_a_bundle_that_does_not_match_is_refused():
    with tempfile.TemporaryDirectory() as t:
        d, tarball = bundle()
        bad = Path(t) / "bad"
        bad.mkdir()
        shutil.copy(tarball, bad / ASSET)
        shutil.copy(d / "SHA256SUMS", bad / "SHA256SUMS")
        with open(bad / ASSET, "ab") as f:
            f.write(b"tampered")
        r = install(f"{t}/root", bundle_file=bad / ASSET)
        assert r.returncode == 1 and "does not match its SHA256SUMS" in r.stderr, r.stderr
        (bad / "SHA256SUMS").write_text("")
        r = install(f"{t}/root", bundle_file=bad / ASSET)
        assert r.returncode == 1 and "no line for it" in r.stderr, r.stderr
        assert not os.path.exists(f"{t}/root/opt/facilitator")


def test_a_pinned_digest_wins_over_the_sums():
    """With a pin in digests.txt, a bundle whose SHA256SUMS agrees with it but whose digest differs from the pin
    is refused: the pin is what the Feature trusts."""
    with tempfile.TemporaryDirectory() as t:
        feature = Path(t) / "feature"
        shutil.copytree(helpers.SRC, feature, ignore=shutil.ignore_patterns("__pycache__", "bundle"))
        with open(feature / "digests.txt", "a") as f:
            f.write(f"{'0' * 64}  {ASSET}\n")
        e = clean_env(DESTDIR=f"{t}/root", FACILITATOR_BUNDLE=str(bundle()[1]))
        r = subprocess.run(["bash", str(feature / "install.sh")], env=e, capture_output=True, text=True)
        assert r.returncode == 1 and "does not match the one pinned in digests.txt" in r.stderr, r.stderr


if __name__ == "__main__":
    try:
        helpers.run_tests(globals())
    finally:
        if _BUNDLE:
            shutil.rmtree(_BUNDLE["dir"], ignore_errors=True)
