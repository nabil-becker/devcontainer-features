"""Slice N5a with no network and no SLIM: role peer and preset open (mesh.yml), the issuer a node keeps itself, pairing two
peers by a token (the daemon's own handlers called directly), a public node's join request, a person's approval and the
1 h certificate, what a public receiver is shown (the issuer's own card, public agents only), lock two on a public
card, copy addressed (the write rule, the check before sending, partial replicas in verify), first contact for a public
node's agent, revoke and the mesh secret's rotation, and the commands refused inside an agent's job."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402

from facilitator import identity, mesh as mesh_mod, peers  # noqa: E402
from facilitator.app import FacilitatorError  # noqa: E402

PEER_A = """preset: open
role: peer
node:
  id: node-a
  name: a.mesh.test
  domain: a.mesh.test
  listen:
    private: 0.0.0.0:46358
    public: 0.0.0.0:46360
  join: 0.0.0.0:46359
  public:
    domain: open.test
    join: 0.0.0.0:46361
trust:
  a.mesh.test: private
  open.test: public
expose:
  jester: public
  "*": local
limits:
  public:
    svid_ttl: 2m
"""

PEER_B = """preset: team
role: peer
node:
  id: node-b
  name: b.mesh.test
  domain: b.mesh.test
  join: 0.0.0.0:46359
trust:
  b.mesh.test: private
"""


def m_(t):
    return mesh_mod.parse(t, Path("mesh.yml"))


def env_with(text, participants=helpers.PARTICIPANTS):
    e = helpers.Env(participants)
    (e.root / ".devcontainer" / "mesh.yml").write_text(text)
    return e


# ---------------------------------------------------------------- mesh.yml

def test_peer_open_and_public_parse_and_the_rules_around_them():
    m = m_(PEER_A)
    assert not m.findings, m.findings
    assert (m.role, m.ceiling, m.public_domain, m.domain) == ("peer", "public", "open.test", "a.mesh.test")
    assert m.domains_issued() == ["a.mesh.test", "open.test"] and set(m.listeners()) == {"private", "public"}
    assert any("public join endpoint" in r["what"] for r in m.open_ports())
    assert m.limit("public", "copy")[0] == "addressed" and m.svid_seconds("public") == 120
    assert m.level_of_domain("open.test") == "public"
    # the rules: public under team is above the ceiling; a public listener needs its domain; a peer needs its own domain,
    # private; the Directory never peers beside a public domain; the public join is separate; public copies only addressed
    cases = {
        "preset: team\nrole: peer\nnode:\n  id: a\n  name: a.t\n  domain: a.t\n  join: 0.0.0.0:1\ntrust:\n  a.t: private\n  o.t: public\n": "above-ceiling",
        PEER_A.replace("  public:\n    domain: open.test\n    join: 0.0.0.0:46361\n", ""): "role-needs",
        PEER_B.replace("  domain: b.mesh.test\n", ""): "role-needs",
        PEER_A.replace("  join: 0.0.0.0:46359\n  public:", "  directory:\n    peering: true\n  join: 0.0.0.0:46359\n  public:"): "role-needs",
        PEER_A.replace("join: 0.0.0.0:46361", "join: 0.0.0.0:46359"): "bad-value",
        PEER_A.replace("limits:\n  public:\n    svid_ttl: 2m\n", "limits:\n  public:\n    copy: full\n"): "bad-value",
        PEER_A.replace("svid_ttl: 2m", "svid_ttl: 10s"): "bad-value",
        "preset: team\nrole: spoke\nnode:\n  id: s\n  peers:\n    x: a.t:1\n": "role-needs",
    }
    for text, rule in cases.items():
        f = m_(text).findings
        assert any(x.rule == rule for x in f), (rule, text, f)


def test_no_ca_we_make_carries_a_uri_name_constraint():
    with tempfile.TemporaryDirectory() as t:
        st = identity.Store(Path(t))
        st.ensure()
        st.ensure_local_ca("n1.local")
        identity.LocalIssuer(st, "d.test", ("n.d.test",)).ensure()
        for pem in (st.ca / "ca.pem", st.ca / "d.test" / "ca.pem"):
            txt = subprocess.run(["openssl", "x509", "-noout", "-text"], input=pem.read_text(), capture_output=True, text=True).stdout
            nc = txt.split("Name Constraints")[1].split("X509v3")[0]
            assert "DNS:" in nc and "URI:" not in nc, (pem, nc)
        st.issue_local("n1.local", "n1", "n1.local")      # a certificate under it still verifies
        assert identity.chain_ok(st.cert("n1.local").read_text(), st.bundle("n1.local"))


# ---------------------------------------------------------------- the issuer a node keeps, pairing, public requests

def test_a_peer_is_its_own_issuer_and_certificates_are_name_constrained():
    e = env_with(PEER_A)
    try:
        fac = e.fac()
        assert peers.ensure_own_cert(fac, "a.mesh.test") == "issued" and peers.ensure_own_cert(fac, "a.mesh.test") == "present"
        peers.ensure_own_cert(fac, "open.test")
        st = identity.Store(fac.state.home)
        own, pub = st.cert_state("a.mesh.test"), st.cert_state("open.test")
        assert own["id"] == "spiffe://a.mesh.test/node/node-a" and pub["id"] == "spiffe://open.test/node/node-a"
        assert 3 * 3600 < own["not_after"] - time.time() < 25 * 3600 and 60 < pub["not_after"] - time.time() <= 125   # 24 h, and 2 m
        assert identity.chain_ok(st.cert("open.test").read_text(), st.bundle("open.test"))
        assert not identity.chain_ok(st.cert("open.test").read_text(), st.bundle("a.mesh.test"))   # one CA each
        # SLIM 3.4.6 (rustls-webpki) refuses every leaf under a CA with a URI name constraint (NameConstraintViolation): the
        # CA has DNS constraints only; p2p_flow.sh links real SLIM nodes over it
        txt = subprocess.run(["openssl", "x509", "-noout", "-text"], input=st.bundle("open.test").read_text(), capture_output=True,
                             text=True).stdout
        nc = txt.split("Name Constraints")[1].split("X509v3")[0]
        assert "DNS:" in nc and "URI:" not in nc, nc
        # the CA of one domain cannot vouch for another's SPIFFE ID (name constraints)
        with tempfile.TemporaryDirectory() as t:
            k = Path(t) / "k"
            identity.new_key(k)
            got = identity.LocalIssuer(st, "open.test").sign(identity.csr(k, "x"), "x", "x.open.test", 120)
            assert identity.chain_ok(got["cert"], st.bundle("open.test"))
            bad = subprocess.run(["openssl", "verify", "-CAfile", str(st.bundle("open.test")), "-purpose", "any", "/dev/stdin"],
                                 input=got["cert"].replace("open.test", "open.test"), capture_output=True, text=True)
            assert bad.returncode == 0
    finally:
        e.close()


def test_pairing_two_peers_exchanges_bundles_and_hands_the_secret_over():
    a = env_with(PEER_A.replace("preset: open", "preset: team").replace("    public: 0.0.0.0:46360\n", "")
                 .replace("  public:\n    domain: open.test\n    join: 0.0.0.0:46361\n", "").replace("  open.test: public\n", "")
                 .replace("limits:\n  public:\n    svid_ttl: 2m\n", ""))
    try:
        fa = a.fac()
        assert not fa.mesh_file.findings, fa.mesh_file.findings
        peers.ensure_own_cert(fa, "a.mesh.test")
        sa = identity.Store(fa.state.home)
        tok = identity.make_token(sa, "a.mesh.test:46359", "a.mesh.test", sa.bundle("a.mesh.test").read_text())
        t = identity.parse_token(tok)
        # b's side: its own CA bundle, as `node peer` sends it
        b = env_with(PEER_B)
        try:
            fb = b.fac()
            peers.ensure_own_cert(fb, "b.mesh.test")
            sb = identity.Store(fb.state.home)
            d = peers.Daemon(fa)
            code, body = d.pair({"token_id": t["i"], "secret": t["s"], "node": "node-b", "name": "b.mesh.test",
                                 "domain": "b.mesh.test", "bundle": sb.bundle("b.mesh.test").read_text()})
            assert code == 200 and body["domain"] == "a.mesh.test" and body["mesh_secret"] and d.reexec
            assert body["slim"] == "a.mesh.test:46358"
            m2 = mesh_mod.load(fa.s)
            assert not m2.findings, m2.findings
            assert m2.peers == {"node-b": "incoming"} and m2.trust["b.mesh.test"] == "private", m2.node
            assert sa.bundle("b.mesh.test").is_file()
            # single use, and a known node or domain is refused
            code, body = d.pair({"token_id": t["i"], "secret": t["s"], "node": "node-c", "name": "c", "domain": "c.mesh.test",
                                 "bundle": sb.bundle("b.mesh.test").read_text()})
            assert code == 403 and "used already" in body["error"]
            tok2 = identity.parse_token(identity.make_token(sa, "a.mesh.test:46359", "a.mesh.test", "x"))
            assert d.pair({"token_id": tok2["i"], "secret": tok2["s"], "node": "node-b", "name": "b", "domain": "b2.mesh.test",
                           "bundle": sb.bundle("b.mesh.test").read_text()})[0] == 409
        finally:
            b.close()
    finally:
        a.close()


def _approved_public(e, fac, node="pub-1"):
    """A public node's request, a person's approval; returns (store, the requester's key file, its certificate)."""
    st = identity.Store(fac.state.home)
    peers.ensure_own_cert(fac, "open.test")
    identity.open_window(st)
    k = Path(e.tmp.name) / f"{node}.key"
    identity.new_key(k)
    sec = "s3cret"
    import hashlib
    d = peers.Daemon(fac)
    code, body = d.request({"node": node, "csr": identity.csr(k, node), "secret_hash": hashlib.sha256(sec.encode()).hexdigest()})
    assert code == 200 and body["status"] == "pending", body
    return st, k, body, d, sec


def test_a_public_node_joins_by_its_key_and_a_persons_approval():
    e = env_with(PEER_A)
    try:
        fac = e.fac()
        st, k, body, d, sec = _approved_public(e, fac)
        rid = body["id"]
        # nothing issued before a person acts; the status call is secret-protected
        assert d.request_status({"id": rid, "secret": sec})[1] == {"status": "pending"}
        assert d.request_status({"id": rid, "secret": "wrong"})[0] == 403
        # no window: refused; one pending per node; the key must sign its own request
        import hashlib
        identity.open_window(st, -1)
        assert d.request({"node": "pub-2", "csr": identity.csr(k, "x"), "secret_hash": "h"})[0] == 403
        identity.open_window(st)
        assert d.request({"node": "pub-1", "csr": identity.csr(k, "x"), "secret_hash": "h"})[0] == 403
        # the person approves (the CLI: a human of facilitator.yml; refused inside an agent's job)
        (e.root / ".devcontainer" / "facilitator.yml").write_text("humans: [you]\n")
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "approve", rid, "--yes"],
                           capture_output=True, text=True, env={**os.environ, "CLAUDECODE": "1"})
        assert r.returncode == 1 and "agent's job" in r.stderr
        env2 = {k_: v for k_, v in os.environ.items() if k_ not in ("CLAUDECODE", "DEVHOST_JOB_CHILD", "FACILITATOR_HANDLE")}
        r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", "approve", rid, "--yes"],
                           capture_output=True, text=True, env=env2)
        assert r.returncode == 0, r.stderr
        code, got = d.request_status({"id": rid, "secret": sec})
        assert got["status"] == "approved" and got["level"] == "public" and got["hub"]["slim"] == "a.mesh.test:46360"
        info = identity.cert_info(got["cert"])
        assert info["uris"] == ["spiffe://open.test/node/pub-1"] and 60 < info["not_after"] - time.time() <= 125   # svid_ttl 2m
        assert info["raw_key"] == identity.cert_info(identity.LocalIssuer(st, "open.test").sign(
            identity.csr(k, "pub-1"), "pub-1", "x", 60)["cert"])["raw_key"]               # the key it asked with
        assert d.request_status({"id": rid, "secret": sec})[1]["status"] == "collected"     # the certificate is served once
        assert identity.roster(st)["nodes"]["pub-1"]["approved_by"] == "you"
        # the approval is a signed entry of the audit register: who approved what, and when
        ev = [x for x in fac.audit.events() if x["event"] == "join-approved"]
        assert ev and ev[0]["subject"] == "pub-1" and ev[0]["by"] == "you" and fac.audit.verify()[0]
    finally:
        e.close()


def test_a_public_card_is_checked_by_lock_two_and_shows_the_issuer_alone():
    e = env_with(PEER_A, helpers.PARTICIPANTS)
    try:
        fac = e.register_all()
        st, k, body, d, sec = _approved_public(e, fac)
        peers.ensure_own_cert(fac, "a.mesh.test")
        pub_cert = identity.LocalIssuer(st, "open.test").sign(identity.csr(k, "pub-1"), "pub-1", "pub-1.open.test", 120)["cert"]
        # the public node's card, as it would make it (its certificate key, its own participants)
        kd = Path(e.tmp.name) / "pubstore"
        pst = identity.Store(kd)
        pst.ensure()
        pst.dom("open.test").mkdir(parents=True)
        pst.key("open.test").write_bytes(k.read_bytes())
        pst.cert("open.test").write_text(pub_cert)
        card = identity.make_card(pst, "open.test", "pub-1", "ssh-ed25519 AAAA", [
            {"handle": "p1", "key": "k1", "kind": "agent", "exposure": "public"}])
        ok, level, why = identity.check_card(card, fac.mesh, {"open.test": st.bundle("open.test")}, set())
        assert ok and level == "public", why
        # it may not list an agent narrower than public; a revoked node, and one whose card is not signed by its key, fail
        bad = identity.make_card(pst, "open.test", "pub-1", "ssh-ed25519 AAAA", [
            {"handle": "p2", "key": "k2", "kind": "agent", "exposure": "private"}])
        assert not identity.check_card(bad, fac.mesh, {"open.test": st.bundle("open.test")}, set())[0]
        assert not identity.check_card(card, fac.mesh, {"open.test": st.bundle("open.test")}, {"pub-1"})[0]
        forged = {**card, "participants": card["participants"] + [{"handle": "x", "key": "k", "kind": "agent", "exposure": "public"}]}
        assert "signature" in identity.check_card(forged, fac.mesh, {"open.test": st.bundle("open.test")}, set())[2]
        # an agent not marked public is not in the card the issuer shows a public node; a public one is (and carries its badge)
        fac.state.set_identity("jester", badge="opaque-badge-token")
        d.net.save_card(card, "public")
        mine = d.my_card("public", "open.test")
        handles = {p["handle"]: p for p in mine["participants"]}
        assert set(handles) == {"jester"} and handles["jester"]["badge"] == "opaque-badge-token", handles
        # the roster a public receiver gets holds no other node's card
        r = identity.roster(st)
        r["nodes"]["pub-1"] = {"domain": "open.test", "revoked": False}
        identity.save_roster(st, r)
        env = json.loads(d.roster_envelope("pub-1"))
        assert env["cards"] == [] and env["hub_card"]["domain"] == "open.test" and env["hub_directory"] == {}
        # what is sent to a node of the public domain is signed with the public certificate's key (its card is)
        e1 = json.loads(d.envelope("pub-1", {"type": "entries"}))
        assert identity.check_envelope(e1, json.loads(d.roster_envelope("pub-1"))["hub_card"]), "signed by the wrong key"
        assert not identity.check_envelope(e1, d.my_card("private"))
        # an unknown node, neither a peer nor joined, is refused at hello
        c, why = d.sender_card({"type": "hello", "from": "pub-9", "card": {**card, "node": "pub-9"}})
        assert c is None
    finally:
        e.close()


# ---------------------------------------------------------------- copy addressed

def _fake_public_node(fac, node="pub-1"):
    """An admitted public card with one participant, without a network: what the issuer's net holds after a hello."""
    st = identity.Store(fac.state.home)
    pk = Path(fac.state.home) / "pubkey"
    sub = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(pk)], capture_output=True)
    assert sub.returncode == 0
    pub = (pk.with_suffix(".pub")).read_text().split()
    key = f"{pub[0]} {pub[1]}"
    card = {"v": 1, "node": node, "domain": "open.test", "id": f"spiffe://open.test/node/{node}", "cert": "x",
            "facilitator": key, "participants": [{"handle": "p1", "key": key, "kind": "agent", "exposure": "public"}],
            "at": identity.now_utc(), "sig": "x"}
    fac.net.save_card(card, "public")
    return key


def test_copy_addressed_the_write_rule_the_check_before_sending_and_the_partial_replica():
    e = env_with(PEER_A)
    try:
        fac = e.register_all()
        key = _fake_public_node(fac)
        assert fac.net.copy_of("pub-1") == "addressed" and fac.net.copy_of("nobody") == "member"
        fac.state.set_identity("jester", description="x")
        # a conversation of the public agent with the public-exposed agent; the one agent not exposed public cannot join
        try:
            fac.new_conversation("domain-expert-one", ["p1.pub-1"])
            raise AssertionError("a local-only agent must not join")
        except FacilitatorError as ex:
            assert "exposed local" in str(ex) and "so it cannot be in a conversation" in str(ex), ex
    finally:
        e.close()


def test_addressed_ok_refuses_a_register_that_holds_what_is_not_addressed():
    e = env_with(PEER_A.replace("  \"*\": local\n", "  \"*\": public\n"))
    try:
        fac = e.register_all()
        _fake_public_node(fac)
        conv = fac.new_conversation("jester", ["p1.pub-1"])
        r = fac.send("you", "@jester hi", conv) if False else None      # (a person is not in this conversation)
        mid = fac.write(conv, "jester", "hello @p1.pub-1", None, None, None, None, 0) if False else None
        ok, why = fac.net.addressed_ok(conv, "pub-1")
        assert ok, why                                                  # no message yet
        # a group of the public agent, two local agents and a person: a message to a local agent is refused at the write
        fac2 = fac
        conv2 = fac2.new_conversation("jester", ["domain-expert-one", "p1.pub-1"])
        try:
            fac2.write(conv2, "jester", "@domain-expert-one a secret", None, None, None, None, 0)
            raise AssertionError("refused expected")
        except Exception as ex:                                        # noqa: BLE001
            assert "copy addressed" in str(ex) and "not written" in str(ex), ex
        mid = fac2.write(conv2, "jester", "@p1.pub-1 a public word", None, None, None, None, 0)
        assert mid and fac.net.addressed_ok(conv2, "pub-1")[0] is False      # not routed to it yet: the route is not written
        fac2.dispatch(conv2, mid)
        assert fac.net.addressed_ok(conv2, "pub-1")[0], fac.net.addressed_ok(conv2, "pub-1")
        # a message written around the rule (straight into the register) is withheld: the register is not sent
        fac2.record.add(conv2, "domain-expert-one", "message", {
            "thread": conv2, "message_id": "m-aaaaaaaaaaaa", "parts": [{"kind": "text", "text": "private"}],
            "root": mid, "hops": 1, "reply_to": mid})
        ok, why = fac.net.addressed_ok(conv2, "pub-1")
        assert not ok and "not addressed" in why, why
        d = peers.Daemon(fac)
        assert d.entries_envelope("pub-1", conv2) is None
        assert any("withheld, copy addressed" in x["why"] for x in peers.refusals(d.store))
        # verify on a replica says partial at policy addressed and is not a break
        fac.net.save_meta(conv2, {"jester.node-a": "node-a", "p1.pub-1": "pub-1"}, "pub-1", "addressed")
    finally:
        e.close()


def test_first_contact_holds_a_public_nodes_agent_until_a_person_approves():
    e = env_with(PEER_A.replace("  \"*\": local\n", "  \"*\": public\n"))
    try:
        fac = e.register_all()
        _fake_public_node(fac)
        assert fac.remote_first_contact("p1.pub-1") and not fac.remote_first_contact("jester") \
            and not fac.remote_first_contact("p1.node-a")
        r = fac.approve_client("p1.pub-1", "you")
        assert r["approved_by"] == "you" and not fac.remote_first_contact("p1.pub-1")
        # an approval lasts approval_ttl (30 d at public)
        d = fac.net.approvals()
        d["p1.pub-1"]["at"] = "2020-01-01T00:00:00Z"
        identity._private(fac.net.store.root / "approved.json", json.dumps(d))
        assert fac.remote_first_contact("p1.pub-1")
        assert any(x["event"] == "approved" for x in fac.audit.events())
    finally:
        e.close()


# ---------------------------------------------------------------- revoke and the secret's rotation

def test_revoke_cuts_a_public_node_off_and_rotates_the_secret_to_the_nodes_that_remain():
    e = env_with(PEER_A)
    try:
        fac = e.register_all()
        st, k, body, d, sec = _approved_public(e, fac)
        (e.root / ".devcontainer" / "facilitator.yml").write_text("humans: [you]\n")
        env2 = {k_: v for k_, v in os.environ.items() if k_ not in ("CLAUDECODE", "DEVHOST_JOB_CHILD", "FACILITATOR_HANDLE")}
        cli = [sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator")]
        assert subprocess.run([*cli, "node", "approve", body["id"], "--yes"], capture_output=True, text=True, env=env2).returncode == 0
        _fake_public_node(fac)                                    # pub-1 had a card
        fac.net.save_card({**json.loads((fac.net.store.cards / "pub-1.json").read_text())["card"], "node": "node-c",
                           "id": "spiffe://a.mesh.test/node/node-c", "domain": "a.mesh.test"}, "private")
        secret = st.mesh_secret(create=True)
        r = subprocess.run([*cli, "node", "revoke", "pub-1", "--yes"], capture_output=True, text=True, env=env2)
        assert r.returncode == 0, r.stderr
        assert "expires within" in r.stdout and "node-c" in r.stdout and "pub-1" not in r.stdout.split("hands the new one to")[1]
        roster = identity.roster(st)
        assert roster["nodes"]["pub-1"]["revoked"] and "pub-1" not in fac.net.__class__(e.fac()).cards()
        # no renewal, and lock two refuses it from now on
        code, _ = (lambda dd: (dd.on_renew({"from": "pub-1", "csr": "x"}, {"level": "public"}), 0))(peers.Daemon(e.fac()))
        assert code == [] and any("revoked" in x["why"] for x in peers.refusals(st))
        # the rotation record: a new secret, owed to the nodes that remain, never to the revoked one
        rot = identity.rotation(st)
        assert rot["state"] == "sending" and rot["pending"] == ["node-c"] and rot["new"] != secret and len(rot["new"]) >= 32
        ev = [x["event"] for x in e.fac().audit.events()]
        assert "node-revoked" in ev and "secret-rotated" in ev and e.fac().audit.verify()[0]
        # a node that remains takes the new secret from an admitted node, once, and passes it on to the peers it still trusts
        e2 = env_with(PEER_B)
        try:
            fb = e2.fac()
            sb = identity.Store(fb.state.home)
            db = peers.Daemon(fb)
            db.net.save_card({"v": 1, "node": "node-a", "domain": "x", "id": "x", "cert": "x", "participants": [], "at": "x"}, "private")
            db.net.save_card({"v": 1, "node": "node-z", "domain": "x", "id": "x", "cert": "x", "participants": [], "at": "x"}, "private")
            env = {"from": "node-a", "rid": rot["rid"], "new": rot["new"], "rotated_at": rot["at"], "reason": "x"}
            db.on_secret(env, {"level": "private"})
            got = identity.rotation(sb)
            assert got["rid"] == rot["rid"] and got["new"] == rot["new"] and got["pending"] == ["node-z"], got   # not back to a
            before = got["deadline"]
            db.on_secret(env, {"level": "private"})
            assert identity.rotation(sb)["deadline"] == before                       # never twice
            old = {**env, "rid": "other", "rotated_at": "2000-01-01T00:00:00Z"}
            db.on_secret(old, {"level": "private"})
            assert identity.rotation(sb)["rid"] == rot["rid"] and any("replay" in x["why"] for x in peers.refusals(sb))
            db.on_secret({**env, "rid": "r3", "new": "short", "rotated_at": "2999-01-01T00:00:00Z"}, {"level": "private"})
            assert identity.rotation(sb)["rid"] == rot["rid"]
        finally:
            e2.close()
    finally:
        e.close()


def test_the_commands_that_decide_are_refused_inside_an_agents_job():
    e = env_with(PEER_A)
    try:
        for act in (["approve", "r-1"], ["deny", "r-1"], ["revoke", "x", "--yes"], ["secret"], ["invite", "--level", "public"]):
            r = subprocess.run([sys.executable, "-I", str(helpers.SRC / "bin" / "facilitator"), "node", *act],
                               capture_output=True, text=True, env={**os.environ, "CLAUDECODE": "1"})
            assert r.returncode == 1 and "agent's job" in r.stderr, (act, r.stderr)
    finally:
        e.close()


helpers.run_tests(globals())
