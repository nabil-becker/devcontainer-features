"""The hub's issuer tiers (rulings K3, K4, K5; ADR-0078) with no network and no SLIM: mesh.yml's node.issuer.ssh_agent and
what refuses it, the built-in CA (a root and an issuing CA, DNS-constrained, no unseal), export-root (the root key leaves the
volume, nothing else changes), an ssh-agent holding the CA key (matched by fingerprint, ed25519 only, the key never a file,
issuing stops cleanly when the agent is gone), the order of the tiers, what `check` warns about, the roster backup, and the
commands a person alone may run. Every certificate is proved by `openssl verify`, which checks the same signature SLIM does."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import re  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402

from facilitator import cabuild, cli, identity, mesh as mesh_mod  # noqa: E402

HUB = """preset: team
role: hub
node:
  id: hub-1
  name: hub.corp.test
  listen:
    private: 0.0.0.0:46358
  join: 0.0.0.0:46359
  issuer:
    domain: corp.test
trust:
  corp.test: private
"""
FP = "SHA256:" + "A" * 43


def hub_text(issuer_extra: str = "") -> str:
    return HUB.replace("    domain: corp.test\n", "    domain: corp.test\n" + issuer_extra)


def m_(text):
    return mesh_mod.parse(text, Path("mesh.yml"))


class Agent:
    """A throwaway ssh-agent with the keys given as (name, type); never the person's own."""

    def __init__(self, tmp: Path, keys=(("ca", "ed25519"),)):
        self.tmp = tmp
        self.sock = str(tmp / "agent.sock")
        out = subprocess.run(["ssh-agent", "-a", self.sock, "-s"], capture_output=True, text=True, check=True).stdout
        self.pid = int(re.search(r"SSH_AGENT_PID=(\d+)", out).group(1))
        self.fp = {}
        for name, typ in keys:
            k = tmp / name
            subprocess.run(["ssh-keygen", "-q", "-t", typ, "-N", "", "-C", name, "-f", str(k)], check=True)
            subprocess.run(["ssh-add", str(k)], env={**os.environ, "SSH_AUTH_SOCK": self.sock}, check=True, capture_output=True)
            lines = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", str(k) + ".pub"], capture_output=True, text=True).stdout
            self.fp[name] = lines.split()[1]

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(50):
            if not Path(self.sock).exists():
                break
            time.sleep(0.05)


def leaf_for(iss, node="n1", dns=None, ttl=3600):
    dns = dns or f"{node}.corp.test"
    with tempfile.TemporaryDirectory() as t:
        k = Path(t) / "k"
        identity.new_key(k)
        return iss.sign(identity.csr(k, dns), node, dns, ttl)


def verifies(cert_pem: str, bundle_pem: str) -> bool:
    with tempfile.TemporaryDirectory() as t:
        b = Path(t) / "b.pem"
        b.write_text(bundle_pem)
        return identity.chain_ok(cert_pem, b)


def text_of(pem: str) -> str:
    return subprocess.run(["openssl", "x509", "-noout", "-text"], input=pem, capture_output=True, text=True).stdout


# ---------------------------------------------------------------- mesh.yml

def test_ssh_agent_in_mesh_yml_and_what_refuses_it():
    m = m_(hub_text(f"    ssh_agent:\n      socket: /run/ca/agent.sock\n      key: {FP}\n"))
    assert not m.findings, m.findings
    assert m.node["issuer"]["ssh_agent"]["key"] == FP
    assert not m_(hub_text(f"    ssh_agent:\n      socket: $SSH_AUTH_SOCK\n      key: {FP}\n")).findings
    bad = {
        "    ssh_agent:\n      socket: /s\n      key: SHA256:short\n": "bad-value",           # a fingerprint, not a prefix
        "    ssh_agent:\n      socket: /s\n": "bad-value",                                      # never 'the first key'
        f"    ssh_agent:\n      key: {FP}\n": "role-needs",                                     # a socket
        f"    ssh_agent:\n      socket: /s\n      key: {FP}\n      first: yes\n": "unknown-key",
        "    ssh_agent: /s\n": "bad-value",
    }
    for extra, rule in bad.items():
        f = m_(hub_text(extra)).findings
        assert any(x.rule == rule for x in f), (extra, rule, f)
    # a hub needs no OpenBao any more: the issuer's domain alone is the built-in CA
    assert not m_(HUB).findings


# ---------------------------------------------------------------- the built-in CA (file)

def test_the_built_in_ca_needs_no_unseal_and_issues_name_constrained_certificates():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t))
        iss = identity.make_issuer(m_(HUB), st, "corp.test")
        assert isinstance(iss, identity.BuiltinIssuer) and iss.tier == "file"
        bundle = iss.bundle()
        assert len(identity.pem_blocks(bundle)) == 2                     # the issuing CA, then the root
        for f in (iss.root_key, iss.ca_key):
            assert oct(f.stat().st_mode & 0o777) == "0o600", f
        got = leaf_for(iss, "spoke-a")
        assert verifies(got["cert"], bundle)
        info = identity.cert_info(got["cert"])
        assert info["uris"] == ["spiffe://corp.test/node/spoke-a"] and info["dns"] == ["spoke-a.corp.test"]
        assert 3500 < info["not_after"] - time.time() < 3700
        # what SLIM needs: DNS constraints only, ed25519, CA:false leaves; the root allows one CA below it
        for pem in identity.pem_blocks(bundle):
            nc = text_of(pem).split("Name Constraints")[1].split("X509v3")[0]
            assert "DNS:corp.test" in nc and "URI:" not in nc, nc
        assert "CA:FALSE" in text_of(got["cert"]) and "pathlen:1" in text_of(identity.pem_blocks(bundle)[1])
        # the domain's CA cannot vouch for a name outside it (name constraints), and the SPIFFE ID's domain is the issuer's
        other = leaf_for(iss, "evil", dns="evil.other.test")
        assert not verifies(other["cert"], bundle)
        assert identity.cert_info(leaf_for(iss, "x")["cert"])["uris"] == ["spiffe://corp.test/node/x"]
        # the same CA the second time (nothing remade), and a request not signed by its own key is refused
        assert iss.bundle() == bundle
        try:
            identity.make_issuer(m_(HUB), st, "corp.test").sign("not a request", "n", "n.corp.test", 60)
            assert False
        except identity.IdentityError:
            pass


def test_the_roster_is_backed_up_to_the_volume_and_restored():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t))
        iss = identity.make_issuer(m_(HUB), st, "corp.test")
        r = {"nodes": {"a": {"serial": "1", "revoked": False}}}
        iss.backup_roster(r)
        assert oct(iss.backup_file.stat().st_mode & 0o777) == "0o600"
        assert iss.restore_roster() == r


def test_export_root_takes_the_root_key_out_of_the_volume_and_nothing_else_changes():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t) / "vol")
        iss = identity.make_issuer(m_(HUB), st, "corp.test")
        before = leaf_for(iss, "a")["cert"]
        bundle = iss.bundle()
        out = Path(t) / "offline" / "root.pem"
        got = iss.export_root(out)
        assert oct(out.stat().st_mode & 0o777) == "0o600" and "PRIVATE KEY" in out.read_text() and "CERTIFICATE" in out.read_text()
        assert not iss.root_key.exists() and got["file"] == str(out)
        # the hub still issues, the bundle every spoke holds is unchanged, and what was issued before still verifies
        after = leaf_for(iss, "b")["cert"]
        assert iss.bundle() == bundle and verifies(after, bundle) and verifies(before, bundle)
        assert [identity.make_issuer(m_(HUB), st, "corp.test").status()[k] for k in ("root_offline", "two_level")] == [True, True]
        for again, why in ((out, "not in this volume"), (Path(t) / "other.pem", "not in this volume")):
            try:
                iss.export_root(again)
                assert False, why
            except identity.IdentityError as e:
                assert why in str(e), e
        # the exported root can sign a new issuing CA that the same bundle still trusts: openssl accepts root.key's signature
        assert identity.chain_ok(identity.pem_blocks(bundle)[0], _root_only(bundle))


def _root_only(bundle: str) -> Path:
    p = Path(tempfile.mkdtemp(prefix="fac-root-")) / "root.pem"
    p.write_text(identity.pem_blocks(bundle)[1] + "\n")
    return p


def test_a_hub_made_by_0_6_0_keeps_its_single_ca():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t))
        old = identity.LocalIssuer(st, "corp.test", ("hub.corp.test",))
        old.ensure()                                                      # ca.pem and ca.key only, as 0.6.0 made it
        iss = identity.make_issuer(m_(HUB), st, "corp.test")
        assert len(identity.pem_blocks(iss.bundle())) == 1
        assert verifies(leaf_for(iss)["cert"], iss.bundle())
        try:
            iss.export_root(Path(t) / "r.pem")
            assert False
        except identity.IdentityError as e:
            assert "0.6.0" in str(e)


# ---------------------------------------------------------------- the ssh-agent tier

def test_an_ssh_agent_signs_the_ca_and_every_leaf_and_the_key_is_never_a_file():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        ag = Agent(tmp, (("other", "ed25519"), ("ca", "ed25519")))      # the CA is NOT the first key
        try:
            cfg = f"    ssh_agent:\n      socket: {ag.sock}\n      key: {ag.fp['ca']}\n"
            m = m_(hub_text(cfg))
            assert not m.findings, m.findings
            st = identity.Store(tmp / "vol")
            iss = identity.make_issuer(m, st, "corp.test")
            assert isinstance(iss, identity.BuiltinIssuer) and iss.tier == "ssh-agent"
            bundle = iss.bundle()
            got = leaf_for(iss, "spoke-a")
            assert verifies(got["cert"], bundle) and len(identity.pem_blocks(bundle)) == 1
            # the CA certificate carries the agent key's public half, not the other key's
            pub = subprocess.run(["ssh-keygen", "-y", "-f", str(tmp / "ca")], capture_output=True, text=True).stdout.split()[1]
            assert identity.ssh_key(identity.cert_info(bundle)["raw_key"]).split()[1] == pub
            # no private key of the CA anywhere in the volume
            for f in (tmp / "vol").rglob("*"):
                if f.is_file():
                    assert "PRIVATE KEY" not in f.read_text(errors="replace") or f.name == "node.key", f
            assert not iss.ca_key.exists()
            nc = text_of(bundle).split("Name Constraints")[1].split("X509v3")[0]
            assert "DNS:corp.test" in nc and "URI:" not in nc
            assert not verifies(leaf_for(iss, "e", dns="e.other.test")["cert"], bundle)
            # the agent's own signature, checked a second way: a leaf signed by the OTHER key (same names) is refused
            other = identity.make_issuer(m_(hub_text(f"    ssh_agent:\n      socket: {ag.sock}\n      key: {ag.fp['other']}\n")),
                                         identity.Store(tmp / "vol2"), "corp.test")
            assert not verifies(leaf_for(other, "x")["cert"], bundle)
            st_ = iss.status()
            assert st_["agent"]["reachable"] and st_["agent"]["holds_key"] and st_["agent"]["other_keys"] == 1
            # the agent goes: issuing and renewing stop with a clear error, what was issued stays valid
            ag.kill()
            try:
                leaf_for(iss, "late")
                assert False
            except identity.IdentityError as e:
                assert "unreachable" in str(e), e
            assert verifies(got["cert"], bundle)
            assert iss.status()["agent"]["reachable"] is False
        finally:
            ag.kill()


def test_the_key_is_matched_by_fingerprint_ed25519_only():
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        ag = Agent(tmp, (("a", "ed25519"), ("r", "ecdsa")))
        try:
            def issuer(fp):
                return identity.make_issuer(m_(hub_text(f"    ssh_agent:\n      socket: {ag.sock}\n      key: {fp}\n")),
                                            identity.Store(tmp / ("v" + fp[-4:])), "corp.test")
            for fp, why in ((ag.fp["r"], "ssh-ed25519"), ("SHA256:" + "B" * 43, "does not hold")):
                try:
                    issuer(fp).bundle()
                    assert False, why
                except identity.IdentityError as e:
                    assert why in str(e), e
            # a CA made by one key is not accepted for another: changing the fingerprint is a new CA, said so
            first = issuer(ag.fp["a"])
            first.bundle()
            swapped = identity.BuiltinIssuer(first.store, "corp.test", (), agent={"socket": ag.sock, "key": ag.fp["r"]})
            try:
                swapped.bundle()
                assert False
            except identity.IdentityError:
                pass
            assert cabuild.fingerprint(cabuild.agent_key(ag.sock, ag.fp["a"])["blob"]) == ag.fp["a"]
        finally:
            ag.kill()


def test_the_socket_may_be_named_by_an_environment_variable():
    assert identity.agent_socket({"socket": "$SSH_AUTH_SOCK"}, {"SSH_AUTH_SOCK": "/x/a.sock"}) == "/x/a.sock"
    assert identity.agent_socket({"socket": "/y"}, {}) == "/y" and identity.agent_socket({"socket": "$NOPE"}, {}) == ""


def test_the_tiers_are_taken_in_order_openbao_then_ssh_agent_then_file():
    st = identity.Store(Path(tempfile.mkdtemp(prefix="fac-order-")))
    agent = f"    ssh_agent:\n      socket: /nonexistent\n      key: {FP}\n"
    assert type(identity.make_issuer(m_(hub_text("    openbao: http://bao:8200\n" + agent)), st, "corp.test")) is identity.Issuer
    assert identity.make_issuer(m_(hub_text(agent)), st, "corp.test").tier == "ssh-agent"
    assert identity.make_issuer(m_(HUB), st, "corp.test").tier == "file"
    # a peer keeps the single-level CA it had, unless it names an agent too (PP2)
    peer = "role: peer\nnode:\n  id: a\n  name: a.t\n  domain: a.t\n  join: 0.0.0.0:1\ntrust:\n  a.t: private\n"
    assert type(identity.make_issuer(m_(peer), st, "a.t")) is identity.LocalIssuer
    assert identity.make_issuer(m_(peer.replace("  join:", f"  issuer:\n    ssh_agent:\n      socket: /s\n      key: {FP}\n  join:")),
                                st, "a.t").tier == "ssh-agent"


# ---------------------------------------------------------------- migrate to OpenBao (needs the bao binary: a dev server)

def test_migrate_moves_the_same_ca_into_openbao_so_no_spoke_joins_again():
    import shutil
    import socket
    import urllib.request
    if not shutil.which("bao"):
        print("skip: bao is not installed (the migration is tested against a dev server)")
        return
    with socket.socket() as s_:
        s_.bind(("127.0.0.1", 0))
        port = s_.getsockname()[1]
    srv = subprocess.Popen(["bao", "server", "-dev", "-dev-root-token-id=t0", f"-dev-listen-address=127.0.0.1:{port}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/sys/health", timeout=1)
                break
            except Exception:           # noqa: BLE001
                time.sleep(0.1)
        with tempfile.TemporaryDirectory() as t:
            st = identity.Store(Path(t))
            iss = identity.make_issuer(m_(HUB), st, "corp.test")
            bundle = iss.bundle()
            before = leaf_for(iss, "a")["cert"]
            r = {"nodes": {"a": {"serial": "1", "revoked": False}}}
            identity.save_roster(st, r)
            bao = identity.Issuer({"domain": "corp.test", "openbao": f"http://127.0.0.1:{port}", "mount": "pki-corp"})
            got = iss.migrate_to_openbao(bao, "t0")
            assert got["nodes"] == 1 and not iss.ca_key.exists()
            # OpenBao signs now with the same CA: the old bundle (what every spoke holds) verifies the new leaf and the old one
            os.environ["FACILITATOR_OPENBAO_TOKEN"] = "t0"
            try:
                k = Path(t) / "k"
                identity.new_key(k)
                new = bao.sign(identity.csr(k, "b.corp.test"), "b", "b.corp.test", 3600)["cert"]
            finally:
                os.environ.pop("FACILITATOR_OPENBAO_TOKEN")
            assert verifies(new, bundle) and verifies(before, bundle)
            assert identity.cert_info(new)["uris"] == ["spiffe://corp.test/node/b"]
            assert bao.restore_roster() == r
            assert len(identity.pem_blocks(bao._call("GET", "pki-corp/cert/ca_chain", token=False, raw=False)["data"]["ca_chain"])) == 2
            # an agent's CA cannot be imported
            try:
                identity.BuiltinIssuer(identity.Store(Path(t) / "x"), "corp.test", (), agent={"socket": "/s", "key": FP}).migrate_to_openbao(bao, "t0")
                assert False
            except identity.IdentityError as e:
                assert "ssh-agent" in str(e)
    finally:
        srv.terminate()
        srv.wait(timeout=10)


# ---------------------------------------------------------------- check and the commands

def test_check_warns_when_the_ca_key_is_a_file_and_when_the_agent_holds_other_keys():
    e = helpers.Env()
    try:
        (e.root / ".devcontainer" / "mesh.yml").write_text(HUB)
        from facilitator import settings
        fac = cli.Facilitator(settings.load())
        rs = {r[0]: r for r in cli._issuer_rows(fac, identity.Store(fac.state.home), "corp.test")}
        assert rs["issuer"][1] and "built-in CA" in rs["issuer"][2] and "no unseal" in rs["issuer"][2]
        assert rs["issuer key"][1] and rs["issuer key"][2].startswith("warning:") and "last resort" in rs["issuer key"][2]
        assert rs["issuer key"][3] is False                       # a warning does not fail check
        with tempfile.TemporaryDirectory() as t:
            ag = Agent(Path(t), (("ca", "ed25519"), ("mine", "ed25519")))
            try:
                (e.root / ".devcontainer" / "mesh.yml").write_text(hub_text(f"    ssh_agent:\n      socket: {ag.sock}\n      key: {ag.fp['ca']}\n"))
                fac = cli.Facilitator(settings.load())
                rs = {r[0]: r for r in cli._issuer_rows(fac, identity.Store(fac.state.home), "corp.test")}
                assert rs["issuer"][1] and "never a file" in rs["issuer"][2] and "issuer key" not in rs
                assert rs["issuer agent"][2].startswith("warning:") and "1 other key" in rs["issuer agent"][2]
                ag.kill()
                rs = {r[0]: r for r in cli._issuer_rows(fac, identity.Store(fac.state.home), "corp.test")}
                assert not rs["issuer"][1] and "certificates already issued stay valid" in rs["issuer"][2]
            finally:
                ag.kill()
    finally:
        e.close()


def test_export_root_and_migrate_are_a_persons_act_refused_inside_an_agents_job():
    e = helpers.Env()
    try:
        (e.root / ".devcontainer" / "mesh.yml").write_text(HUB)
        for act in (["export-root", "--out", "/tmp/never-written.pem"], ["migrate"]):
            r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "issuer", *act],
                               capture_output=True, text=True, env={**os.environ, "CLAUDECODE": "1"})
            assert r.returncode == 1 and "agent's job" in r.stderr, (act, r.stderr)
        assert not Path("/tmp/never-written.pem").exists()
        # status is read only and says the tier
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "issuer", "status", "--json"],
                           capture_output=True, text=True, env={**os.environ, "CLAUDECODE": "1"})
        assert r.returncode == 0 and '"tier": "file"' in r.stdout, r.stderr
        # a person: export-root writes the file and the hub carries on
        out = e.root / "root-offline.pem"
        person = {k: v for k, v in os.environ.items() if k not in cli.AGENT_JOB_VARS and k != "CLAUDECODE"}
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "issuer", "export-root", "--out", str(out)],
                           capture_output=True, text=True, env=person)
        assert r.returncode == 0 and out.exists() and "no spoke changes anything" in r.stdout, (r.stdout, r.stderr)
    finally:
        e.close()


helpers.run_tests(globals())
