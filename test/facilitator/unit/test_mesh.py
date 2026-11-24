"""Slice N3's policy, with no network: mesh.yml's parsing, presets and findings (and check's linter contract), the
limits' order (the preset's, the Feature option, mesh.yml), the reach rule, lock two's decisions on a table of
cases and on real certificates (the right ID, an untrusted CA, a level above the preset, a revoked node, a
tampered card, and the spike's impostor: a certificate from another domain's CA that claims this domain), join
tokens (15 minutes, single use), invite and revoke refused inside an agent's job, and the ports each role opens,
with the SLIM configuration each role renders (a listener per level with that level's bundle on a hub, one peer
link on a spoke, loopback only when standalone)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402

from facilitator import identity, mesh  # noqa: E402

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
    openbao: http://openbao:8200
    mount: pki-corp
trust:
  corp.test: private
  partner.test: private
expose:
  "*": local
  triage: private
  "spiffe://corp.test/node/hub-1/agent/scribe": private
limits:
  private:
    hops: 4
"""


def m_(text):
    return mesh.parse(text, Path("mesh.yml"))


# ---------------------------------------------------------------- mesh.yml

def test_defaults_solo_standalone():
    m = mesh.Mesh(None)
    assert (m.preset, m.role, m.ceiling) == ("solo", "standalone", "local")
    assert m.open_ports() == [] and m.listeners() == {}
    assert m.exposure("anyone") == "local"


def test_hub_file_parses():
    m = m_(HUB)
    assert not m.findings, m.findings
    assert (m.preset, m.role, m.node_id, m.domain, m.home_domain) == ("team", "hub", "hub-1", "corp.test", "hub-1.local")
    assert m.trust == {"corp.test": "private", "partner.test": "private"}
    assert m.exposure("triage") == "private" and m.exposure("scribe") == "private" and m.exposure("other") == "local"
    assert m.level_of_domain("hub-1.local") == "local" and m.level_of_domain("nowhere.test") is None


def test_findings_name_line_and_rule():
    text = ("preset: wide\nrole: mesh\nnode:\n  id: Bad_Id\n  colour: blue\ntrust:\n  corp.test: public\n"
            "  hub.local: private\nexpose:\n  jester: public\n  \"*\": nowhere\nlimits:\n  private:\n    hops: 0\n"
            "    copy: member\n  public:\n    copy: full\nextra: 1\n")
    m = m_(text)
    got = {(f.rule, f.line) for f in m.findings}
    msgs = " | ".join(f.message for f in m.findings)
    assert ("bad-value", 1) in got and "solo, team or open" in msgs, got        # preset
    assert ("bad-value", 2) in got and "hub or peer" in msgs                    # role
    assert ("bad-value", 4) in got                                   # node.id
    assert ("unknown-key", 5) in got                                 # node.colour
    assert ("above-ceiling", 7) in got                               # public trust under the default solo
    assert ("unknown-key", 18) in got                                # extra
    assert ("bad-value", 14) in got and ("bad-value", 17) in got     # hops 0, public copy full
    assert any(f.rule == "bad-value" and "nowhere" in f.message for f in m.findings)


def test_above_ceiling_and_home_domain():
    m = m_("preset: solo\ntrust:\n  corp.test: private\nnode:\n  id: n1\n")
    assert [f.rule for f in m.findings] == ["above-ceiling"], m.findings
    m = m_("preset: team\nnode:\n  id: n1\ntrust:\n  n1.local: private\n")
    assert [f.rule for f in m.findings] == ["home-domain"], m.findings


def test_roles_need_what_they_need():
    m = m_("preset: team\nrole: hub\ntrust:\n  corp.test: private\n")
    assert {f.rule for f in m.findings} == {"role-needs"} and len(m.findings) == 3, m.findings
    m = m_("preset: team\nrole: spoke\nnode:\n  listen:\n    private: 0.0.0.0:1\n")
    assert any("opens nothing" in f.message for f in m.findings)
    m = m_("preset: solo\nrole: spoke\n")
    assert any(f.rule == "above-ceiling" for f in m.findings)


def test_invalid_file_runs_standalone():
    m = m_("preset: team\nrole: hub\n")
    e = mesh.effective(m)
    assert e.role == "standalone" and e.preset == "solo" and e.listeners() == {} and e.findings


def test_write_node_round_trip():
    with tempfile.TemporaryDirectory() as t:
        p = Path(t) / "mesh.yml"
        p.write_text("expose:\n  \"*\": local\n  a1: private\n")
        mesh.write_node(p, {"id": "spoke-a", "hub": "hub.corp.test:46358", "hub_name": "hub.corp.test", "hub_node": "hub-1",
                            "domain": "corp.test"}, role="spoke", trust={"corp.test": "private"})
        m = mesh.parse(p.read_text(), p)
        assert not m.findings, (p.read_text(), m.findings)
        assert m.role == "spoke" and m.preset == "team" and m.domain == "corp.test" and m.exposure("a1") == "private"


# ---------------------------------------------------------------- limits and the reach rule

def test_limits_order():
    e = helpers.Env(FACILITATOR_HOP_LIMIT="5")
    try:
        from facilitator import settings
        s = settings.load()
        m = m_(HUB)
        assert m.limit("local", "hops", s)[0] == 5 and "FACILITATOR_HOP_LIMIT" in m.limit("local", "hops", s)[1]
        assert m.limit("private", "hops", s) == (4, "mesh.yml limits.private.hops")
        assert m.limit("private", "budget", s)[0] == 40
        assert m.limit("private", "copy", s)[0] == "member" and m.limit("local", "copy", s)[0] == "full"
        assert m.limit("public", "hops", s)[0] == 2           # no option applies to public
        assert m.svid_seconds("private") == 86400
    finally:
        e.close()


def test_reach_rule_table():
    table = {("local", "local"): True, ("local", "private"): True, ("local", "public"): True,
             ("private", "local"): False, ("private", "private"): True, ("private", "public"): True,
             ("public", "local"): False, ("public", "private"): False, ("public", "public"): True}
    for (caller, exposure), want in table.items():
        assert mesh.reach_ok(caller, exposure) is want, (caller, exposure)


# ---------------------------------------------------------------- lock two, as decisions

def test_lock_two_decisions():
    m = m_(HUB)
    cases = [
        ("spiffe://corp.test/node/spoke-a", "corp.test", set(), True, "private"),          # the right ID
        ("spiffe://corp.test/node/spoke-a/agent/a1", "corp.test", set(), True, "private"),
        ("spiffe://corp.test/node/spoke-a", "partner.test", set(), False, "impostor"),     # the impostor
        ("spiffe://corp.test/node/spoke-a", None, set(), False, "chains to no trust bundle"),
        ("spiffe://other.test/node/x", "other.test", set(), False, "not in mesh.yml's trust"),  # wrong domain
        ("spiffe://corp.test/workload/x", "corp.test", set(), False, "not a node or agent"),
        ("spiffe://corp.test/node/spoke-a", "corp.test", {"spoke-a"}, False, "revoked"),
    ]
    for claimed, ca, rev, ok, want in cases:
        got_ok, level, why = m.admit(claimed, ca, rev)
        assert got_ok is ok, (claimed, ca, why)
        assert (level == want) if ok else (want in why), (claimed, why)
    # the wrong level: a domain mapped to a level above the preset's ceiling never admits
    solo = mesh.Mesh(None, preset="solo", trust={"corp.test": "private"})
    ok, _, why = solo.admit("spiffe://corp.test/node/x", "corp.test")
    assert not ok and "ceiling" in why, why


# ---------------------------------------------------------------- lock two, on real certificates

def _ca(d: Path, name: str, domain: str) -> tuple[Path, Path]:
    key, pem = d / f"{name}.key", d / f"{name}.pem"
    identity.new_key(key)
    r = subprocess.run(["openssl", "req", "-x509", "-new", "-key", str(key), "-subj", f"/CN={domain} CA", "-days", "2",
                        "-addext", "basicConstraints=critical,CA:true", "-addext", "keyUsage=critical,keyCertSign"],
                       capture_output=True, check=True)
    pem.write_bytes(r.stdout)
    return key, pem


def _leaf(d: Path, ca: tuple[Path, Path], name: str, uri: str, dns: str) -> tuple[Path, str]:
    key = d / f"{name}.key"
    identity.new_key(key)
    (d / f"{name}.csr").write_text(identity.csr(key, dns))
    (d / f"{name}.ext").write_text(f"basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                                   f"extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:{dns},URI:{uri}\n")
    r = subprocess.run(["openssl", "x509", "-req", "-in", str(d / f"{name}.csr"), "-CA", str(ca[1]), "-CAkey", str(ca[0]),
                        "-days", "1", "-extfile", str(d / f"{name}.ext"), "-set_serial", "0x1234"], capture_output=True,
                       check=True)
    return key, r.stdout.decode()


def _card(store_home: Path, d: Path, ca, node: str, domain: str, uri: str | None = None) -> dict:
    st = identity.Store(store_home)
    st.ensure()
    key, pem = _leaf(d, ca, node, uri or f"spiffe://{domain}/node/{node}", f"{node}.{domain}")
    st.dom(domain).mkdir(parents=True, exist_ok=True)
    os.replace(key, st.key(domain))
    st.cert(domain).write_text(pem)
    parts = [{"handle": "a1", "key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPwI58rTvWzqSQWDprqGYWqaO0+u6fBuHMKkxtN2ibyd",
              "kind": "agent", "exposure": "private"}]
    return identity.make_card(st, domain, node, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA" + "B" * 42 + "=", parts)


def test_lock_two_on_certificates_and_the_impostor():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        corp, partner = _ca(d, "corp", "corp.test"), _ca(d, "partner", "partner.test")
        lonely = _ca(d, "lonely", "lonely.test")
        bundles = {"corp.test": corp[1], "partner.test": partner[1]}
        m = m_(HUB)
        good = _card(d / "a", d, corp, "spoke-a", "corp.test")
        ok, level, why = identity.check_card(good, m, bundles)
        assert ok and level == "private", why
        # the spike's impostor: a certificate from partner.test's CA (trusted, the same level, so lock one lets it
        # through the private listener) that claims to be a node of corp.test
        imp = _card(d / "i", d, partner, "spoke-a", "corp.test")
        ok, _, why = identity.check_card(imp, m, bundles)
        assert not ok and "impostor" in why and "partner.test" in why, why
        # a certificate from a CA no domain in trust has
        stranger = _card(d / "s", d, lonely, "spoke-s", "lonely.test")
        ok, _, why = identity.check_card(stranger, m, bundles)
        assert not ok and "chains to no trust bundle" in why, why
        # a revoked node
        ok, _, why = identity.check_card(good, m, bundles, {"spoke-a"})
        assert not ok and "revoked" in why
        # a tampered card: another participant key slipped in after signing
        bad = json.loads(json.dumps(good))
        bad["participants"][0]["key"] = bad["facilitator"]
        ok, _, why = identity.check_card(bad, m, bundles)
        assert not ok and "signature" in why, why
        # an envelope is checked against its sender's card
        st = identity.Store(d / "a")
        env = identity.sign_envelope(st, "corp.test", {"v": 1, "from": "spoke-a", "to": "hub-1", "type": "entries"})
        assert identity.check_envelope(env, good)
        env["to"] = "spoke-b"
        assert not identity.check_envelope(env, good)
        # the SSH form of a certificate's key (how sign-packet names keys) is the key ssh-keygen derives
        info = identity.cert_info(st.cert("corp.test").read_text())
        derived = subprocess.run(["ssh-keygen", "-y", "-f", str(st.key("corp.test"))], capture_output=True, text=True).stdout
        assert identity.ssh_key(info["raw_key"]) == " ".join(derived.split()[:2])


# ---------------------------------------------------------------- join tokens

def test_join_token_lifetime_and_single_use():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t))
        tok = identity.make_token(st, "hub.corp.test:46359", "hub.corp.test", "BUNDLE", now=1000.0)
        d = identity.parse_token(tok)
        assert d["j"] == "hub.corp.test:46359" and d["n"] == "hub.corp.test" and len(d["b"]) == 64
        assert identity.live_tokens(st, now=1000.0 + 14 * 60) == 1
        assert identity.live_tokens(st, now=1000.0 + 15 * 60 + 1) == 0
        ok, why = identity.consume_token(st, d["i"], d["s"], now=1000.0 + 15 * 60 + 1)
        assert not ok and "expired" in why, why
        tok2 = identity.make_token(st, "hub.corp.test:46359", "hub.corp.test", "BUNDLE", now=5000.0)
        d2 = identity.parse_token(tok2)
        assert identity.consume_token(st, d2["i"], "not-the-secret", now=5001.0)[0] is False
        assert identity.consume_token(st, d2["i"], d2["s"], now=5001.0) == (True, "ok")
        ok, why = identity.consume_token(st, d2["i"], d2["s"], now=5002.0)
        assert not ok and "single use" in why, why
        assert "hash" in json.loads(st.invites.read_text())[0] and d2["s"] not in st.invites.read_text()
        for bad in ("nope", "fj1.@@@"):
            try:
                identity.parse_token(bad)
                raise AssertionError(bad)
            except identity.IdentityError:
                pass


# ---------------------------------------------------------------- refused inside an agent's job

def _cli(env_extra: dict, *args) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "DEVHOST_JOB_CHILD", "FACILITATOR_HANDLE")}
    env.update(env_extra)
    return subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), *args], capture_output=True,
                          text=True, env=env)


def test_invite_and_revoke_refused_in_an_agents_job():
    e = helpers.Env()
    try:
        (e.root / ".devcontainer" / "mesh.yml").write_text(HUB)
        for var in ("CLAUDECODE", "DEVHOST_JOB_CHILD", "FACILITATOR_HANDLE"):
            r = _cli({var: "1"}, "node", "invite")
            assert r.returncode == 1 and "inside an agent's job" in r.stderr and var in r.stderr, (var, r.stderr)
        r = _cli({"FACILITATOR_AGENT_JOB_VARS": "MY_JOB", "MY_JOB": "x"}, "node", "revoke", "spoke-a", "--yes")
        assert r.returncode == 1 and "MY_JOB" in r.stderr, r.stderr
        # outside a job it goes on (and here stops at the missing certificate, never at the job rule)
        r = _cli({}, "node", "invite")
        assert r.returncode == 1 and "agent's job" not in r.stderr and "no certificate" in r.stderr, r.stderr
        r = _cli({"CLAUDECODE": "1"}, "node", "approve", "r-1")
        assert r.returncode == 1 and "inside an agent's job" in r.stderr, r.stderr
    finally:
        e.close()


def test_check_lint_contract():
    with tempfile.TemporaryDirectory() as t:
        good, bad = Path(t) / "good.yml", Path(t) / "bad.yml"
        good.write_text(HUB)
        bad.write_text("preset: wide\nrole: hub\n")
        r = _cli({}, "check", str(good))
        assert r.returncode == 0 and r.stdout == "", (r.returncode, r.stdout, r.stderr)
        r = _cli({}, "check", str(bad))
        assert r.returncode == 1 and r.stdout.startswith(f"{bad}:1: bad-value: preset"), r.stdout
        r = _cli({}, "check", "--format", "json", str(bad))
        assert r.returncode == 1 and json.loads(r.stdout)[0]["rule"] == "bad-value"
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "check", "-"],
                           input="trust:\n  x.test: public\n  y.test: nowhere\n", capture_output=True, text=True)
        assert r.returncode == 1 and r.stdout.startswith("-:2: above-ceiling"), r.stdout
        r = _cli({}, "check", str(Path(t) / "missing.yml"))
        assert r.returncode == 2


# ---------------------------------------------------------------- ports and the SLIM configuration each role renders

def test_ports_per_role():
    assert m_("preset: team\nrole: standalone\n").open_ports() == []
    spoke = m_("preset: team\nrole: spoke\nnode:\n  id: s1\n  hub: hub.corp.test:46358\n  hub_name: hub.corp.test\n"
               "  hub_node: hub-1\n  domain: corp.test\ntrust:\n  corp.test: private\n")
    assert not spoke.findings and spoke.open_ports() == [] and spoke.listeners() == {}
    hub = m_(HUB)
    rows = hub.open_ports()
    assert [r["address"] for r in rows] == ["0.0.0.0:46358", "0.0.0.0:46359"], rows
    assert "only while a join token is live" in rows[1]["when"]
    peering = m_(HUB.replace("  issuer:", "  directory:\n    peering: true\n  issuer:"))
    assert any("Directory OCI" in r["what"] for r in peering.open_ports())


def _render(text: str, certs: list[str]):
    e = helpers.Env()
    (e.root / ".devcontainer" / "mesh.yml").write_text(text)
    fac = e.fac()
    st = identity.Store(fac.state.home)
    for dom in certs:
        st.dom(dom).mkdir(parents=True, exist_ok=True)
        for f in (st.key(dom), st.cert(dom), st.bundle(dom)):
            f.write_text("x\n")
    return e, fac


def test_slim_config_per_role():
    e, fac = _render(HUB, ["corp.test", "partner.test"])
    try:
        text = Path(fac.infra().render("slim")).read_text()
        assert '"127.0.0.1:' in text and '"0.0.0.0:46358"' in text and "client_ca" in text, text
        lv = fac.state.home / "mesh" / "certs" / "level-private.pem"
        assert lv.read_text() == "x\nx\n"                       # both private domains' bundles, nothing else
        assert "connection_type" not in text
    finally:
        e.close()
    spoke = ("preset: team\nrole: spoke\nnode:\n  id: s1\n  hub: hub.corp.test:46358\n  hub_name: hub.corp.test\n"
             "  hub_node: hub-1\n  domain: corp.test\ntrust:\n  corp.test: private\n")
    e, fac = _render(spoke, ["corp.test"])
    try:
        text = Path(fac.infra().render("slim")).read_text()
        assert 'endpoint: "https://hub.corp.test:46358"' in text and "connection_type: peer" in text, text
        assert 'server_name: "hub.corp.test"' in text and "ca_source" in text
        assert '0.0.0.0' not in text                             # a spoke opens nothing
        assert fac.infra().components()[-1] == "peers"
    finally:
        e.close()
    e, fac = _render(spoke, [])
    try:
        try:
            fac.infra().render("slim")
            raise AssertionError("rendered with no certificate")
        except Exception as ex:                                 # noqa: BLE001
            assert "has not joined" in str(ex), ex
    finally:
        e.close()
    e = helpers.Env()
    try:
        text = Path(e.fac().infra().render("slim")).read_text()
        assert "0.0.0.0" not in text and "clients: []" in text and e.fac().infra().components()[-1] == "slim"
    finally:
        e.close()


def test_directory_per_role():
    """Routable addresses only where the role needs them (SP5, ruling BI): a peering hub's OCI registry and libp2p on
    its name, its API on loopback; a spoke's libp2p on loopback with the hub as bootstrap peer; 10 s publication;
    standalone as before. mDNS has no switch: peering needs firewall auto (root, NET_ADMIN) or external."""
    peering_hub = HUB.replace("  issuer:", "  directory:\n    peering: true\n    firewall: external\n  issuer:")
    e, fac = _render(peering_hub, ["corp.test"])
    try:
        text = Path(fac.infra().render("dir")).read_text()
        assert 'registry_address: "hub.corp.test:' in text and 'listen_address: "/ip4/0.0.0.0/tcp/' in text, text
        assert 'directory_api_address: "127.0.0.1:' in text and 'directory_oci_address: "hub.corp.test:' in text
        assert 'scheduler_interval: 10s' in text and 'listen_address: "127.0.0.1:' in text     # the API itself
        pid = fac.infra().dir_peer_id()
        assert pid.startswith("12D3KooW") and pid == fac.infra().dir_peer_id()                # stable, from its key
    finally:
        e.close()
    spoke = ("preset: team\nrole: spoke\nnode:\n  id: s1\n  hub: hub.corp.test:46358\n  hub_name: hub.corp.test\n"
             "  hub_node: hub-1\n  domain: corp.test\n  directory:\n    peering: true\ntrust:\n  corp.test: private\n")
    e, fac = _render(spoke, ["corp.test"])
    try:
        (fac.state.home / "mesh" / "hub-directory.json").write_text(json.dumps(
            {"peer_id": "12D3KooWTEST", "p2p": "hub.corp.test:8999", "oci": "hub.corp.test:5555"}))
        text = Path(fac.infra().render("dir")).read_text()
        assert 'listen_address: "/ip4/127.0.0.1/tcp/' in text and "/dns4/hub.corp.test/tcp/8999/p2p/12D3KooWTEST" in text, text
        assert 'registry_address: "127.0.0.1:' in text and "0.0.0.0" not in text
        try:
            fac.infra().firewall_up()
            assert os.geteuid() == 0                            # only root with iptables may set the rule
        except Exception as ex:                                 # noqa: BLE001
            assert "mDNS" in str(ex) and "external" in str(ex), ex
    finally:
        e.close()
    e = helpers.Env()
    try:
        text = Path(e.fac().infra().render("dir")).read_text()
        assert "0.0.0.0" not in text and "bootstrap_peers" not in text and "scheduler_interval: 5m" in text
    finally:
        e.close()


helpers.run_tests(globals())
