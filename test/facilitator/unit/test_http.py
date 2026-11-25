"""MCP over HTTP for CLIs, the node's side (slice N4, facilitator 0.5.0; ADR-0070, ADR-0071, ADR-0068), with no network
and no `mcp` library: the http settings of facilitator.yml and what refuses them (the preset solo, no TLS beyond
loopback, no approver, issuers for slice N5), the client table (a token shown once and kept as a hash, revoked at
once, a cap on pending clients, an audit chain that shows an edit), the level an HTTP client is mapped to
(`http.<home domain>`, public unless mesh.yml says private), mesh.yml's new keys (approval, approval_ttl,
http_receive_wait; public in expose under team), the reach rule (a public client sees only public-exposed agents, and
one it cannot reach reads as one that does not exist), first-contact approval (held, shown in a person's mail,
released by approve, ruling BG's 7 days, denied, a ttl), the public limits (rate, hops, size), `via` in every packet the
node signs for a client and shown by transcript and verify, a client never a person (no continue, no approve), a private
client with no approval, and the person-only commands refused inside an agent's job. The endpoint itself is in
test_http_endpoint.py."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

from facilitator import app as app_mod, clients as clients_mod, mesh as mesh_mod  # noqa: E402
from facilitator.app import FacilitatorError, HttpSession  # noqa: E402
from fake_mcp import facilitator_argv  # noqa: E402

MESH = """preset: team
expose:
  jester: public
  "*": local
"""
FAC = """facilitator:
  humans: [you]
  http:
    listen: 127.0.0.1:18765
"""


def env(mesh=MESH, fac_yml=FAC, **kw):
    e = helpers.Env(facilitator_yml=fac_yml, **kw)
    if mesh is not None:
        (e.root / ".devcontainer" / "mesh.yml").write_text(mesh)
    return e


def enrol(fac, name="cli-one", by="you"):
    r = fac.enrol_http(name, by)
    return r, HttpSession(fac, name)


def cli(e, *args, extra=None):
    envv = {k: v for k, v in os.environ.items() if k not in app_mod_agent_vars()}
    return subprocess.run(facilitator_argv() + list(args), cwd=e.root, env={**envv, **(extra or {})},
                          capture_output=True, text=True, timeout=60)


def app_mod_agent_vars():
    from facilitator import cli as c
    return c.AGENT_JOB_VARS


# ---------------------------------------------------------------- settings and refusals

def test_http_is_off_by_default_and_refused_under_solo():
    e = env(mesh=None, fac_yml="facilitator:\n  humans: [you]\n")
    try:
        fac = e.fac()
        assert not fac.participants()[1].http.active
        assert fac.http_ready()[0] is True           # nothing set: nothing refused, nothing open
    finally:
        e.close()
    e = env(mesh="preset: solo\n")
    try:
        ok, why = e.fac().http_ready()
        assert not ok and "preset solo" in why, why
        try:
            e.fac().enrol_http("x", "you")
            raise AssertionError("a token under solo")
        except FacilitatorError as err:
            assert "solo" in str(err)
    finally:
        e.close()
    e = env(mesh=None)                                # no mesh.yml at all is solo
    try:
        assert "preset solo" in e.fac().http_ready()[1]
    finally:
        e.close()


def test_beyond_loopback_needs_tls_or_a_proxy_and_a_host_name():
    cases = [
        ("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n", "TLS is required"),
        ("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    behind_proxy: true\n", "http.url"),
        ("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    tls_cert: /c.pem\n", "go together"),
        ("facilitator:\n  http:\n    listen: nonsense\n", "host:port"),
        ("facilitator:\n  http:\n    listen: 127.0.0.1:8443\n    bogus: 1\n", "unknown"),
        ("facilitator:\n  humans: []\n  http:\n    listen: 127.0.0.1:8443\n", "names nobody"),
    ]
    for text, want in cases:
        e = env(fac_yml=text)
        try:
            ok, why = e.fac().http_ready()
            assert not ok and want in why, (text, why)
        finally:
            e.close()
    good = ["facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    behind_proxy: true\n    url: https://node.example\n",
            "facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    tls_cert: /c.pem\n    tls_key: /k.pem\n    url: https://node.example\n",
            "facilitator:\n  http:\n    listen: 127.0.0.1:8443\n"]
    for text in good:
        e = env(fac_yml=text)
        try:
            assert e.fac().http_ready()[0], e.fac().http_ready()
        finally:
            e.close()


ISS = "    url: https://node.example\n    issuers:\n"


def test_the_issuers_setting_is_linted_option_by_option():
    """facilitator.http.issuers (slice N5b): each option, accepted and refused; nothing is fetched to lint it."""
    base = "facilitator:\n  http:\n    listen: 127.0.0.1:8443\n"
    good = base + ISS + ("      - name: corp\n        issuer: https://login.example.org\n        jwks_uri: https://login.example.org/keys\n"
                         "        algorithms: [RS256, ES256, PS384, EdDSA]\n        scope: node.use\n        audience: api://node\n"
                         "      - name: two\n        issuer: https://b.example\n")
    e = env(fac_yml=good)
    try:
        fac = e.fac()
        assert fac.http_ready()[0], fac.http_ready()
        iss = fac.participants()[1].http.issuers
        assert [i.name for i in iss] == ["corp", "two"] and iss[0].algorithms == ["RS256", "ES256", "PS384", "EdDSA"]
        assert iss[0].jwks_uri == "https://login.example.org/keys" and iss[0].scope == "node.use" and iss[0].audience == "api://node"
        assert iss[1].algorithms == ["RS256", "ES256"] and iss[1].jwks_uri is None and iss[1].scope is None
    finally:
        e.close()
    bad = [
        (base + "    issuers: [https://idp.example]\n", "a bare URL has no name"),
        (base + "    issuers:\n      - name: corp\n        issuer: https://idp.example\n", "needs http.url"),
        (base + "    url: http://node.example\n    issuers:\n      - name: corp\n        issuer: https://idp.example\n", "must be https"),
        (base + ISS + "      - name: Corp\n        issuer: https://idp.example\n", "a lowercase handle"),
        (base + ISS + "      - name: corp\n", "an https:// URL"),
        (base + ISS + "      - name: corp\n        issuer: http://idp.example\n", "an https:// URL"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        jwks_uri: http://idp.example/k\n", "jwks_uri"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        algorithms: [none]\n", "is refused"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        algorithms: [HS256]\n", "shared-secret"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        algorithms: [RS999]\n", "is not one of"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        scope: a b\n", "one scope name"),
        (base + ISS + "      - name: corp\n        issuer: https://idp.example\n        colour: red\n", "unknown colour"),
        (base + ISS + "      - name: corp\n        issuer: https://a.example\n      - name: corp\n        issuer: https://b.example\n", "used twice"),
        (base + ISS + "      - name: a\n        issuer: https://a.example\n      - name: b\n        issuer: https://a.example\n", "listed twice"),
    ]
    for text, want in bad:
        e = env(fac_yml=text)
        try:
            ok, why = e.fac().http_ready()
            assert not ok and want in why, (text, why)
        finally:
            e.close()
    # http.insecure admits a plain-http jwks_uri on any host (the issuer's in-cluster service); without it the entry is refused
    insec = ("facilitator:\n  http:\n    listen: 0.0.0.0:8765\n    url: http://localhost:8765\n    insecure: true\n    issuers:\n"
             "      - name: kc\n        issuer: http://localhost:8080/realms/t\n"
             "        jwks_uri: http://keycloak:8080/realms/t/protocol/openid-connect/certs\n")
    e = env(fac_yml=insec)
    try:
        ok, why = e.fac().http_ready()
        assert ok, why
        assert e.fac().participants()[1].http.issuers[0].jwks_uri.startswith("http://keycloak:8080/")
    finally:
        e.close()
    e = env(fac_yml=insec.replace("    insecure: true\n", ""))
    try:
        ok, why = e.fac().http_ready()
        assert not ok and "jwks_uri" in why, why
    finally:
        e.close()
    e = env(fac_yml=base + "    url: http://127.0.0.1:8443\n    issuers:\n      - name: corp\n        issuer: http://127.0.0.1:9000\n")
    try:
        assert e.fac().http_ready()[0]                    # http only on a loopback host, for tests
    finally:
        e.close()


def test_an_oauth_client_entry_is_the_issuer_and_subject_and_has_no_token():
    e = env()
    try:
        fac = e.fac()
        name, c = fac.oauth_client("corp", "https://idp.example", "alice", "claude-web")
        assert name == "corp-alice" and c["status"] == "enrolled" and c["token_hash"] == "" and c["auth"] == "oauth"
        assert fac.is_http(name) and fac.caller_level(name) == "public"
        again, c2 = fac.oauth_client("corp", "https://idp.example", "alice", "claude-web")
        assert again == name and c2["created"] == c["created"]
        assert fac.clients.via(name) == {"transport": "http", "auth": "oauth", "client": name, "issuer": "https://idp.example",
                                         "subject": "alice"}
        assert fac.clients.via("cli-one") == {"transport": "http", "auth": "bearer", "client": "cli-one"}
        assert fac.record.via(name)["auth"] == "oauth"
        view = clients_mod.public_view(name, fac.clients.get(name))
        assert view["auth"] == "oauth" and view["subject"] == "alice" and "token_hash" not in view
        try:                                              # the same handle for another (issuer, subject) is refused
            fac.clients.ensure_oauth(name, "corp", "https://evil.example", "alice", "")
            raise AssertionError("taken")
        except clients_mod.ClientError as err:
            assert "taken" in str(err)
        try:                                              # a name of a participant is never an OAuth client's
            fac.oauth_client("domain", "https://idp.example", "expert-one", "")
            raise AssertionError("participant")
        except FacilitatorError:
            pass
        fac.revoke_client(name, "you")
        _, c3 = fac.oauth_client("corp", "https://idp.example", "alice", "claude-web")
        assert c3["status"] == "revoked"                  # a person's revoke stands; a new token does not undo it
        out = cli(e, "http", "list").stdout
        assert "OAuth, subject alice of https://idp.example" in out and "revoked" in out, out
    finally:
        e.close()


def test_check_names_the_issuers_without_fetching_and_http_issuers_says_when_there_are_none():
    e = env()
    try:
        out = cli(e, "http", "issuers")
        assert out.returncode == 0 and "no OAuth issuers" in out.stdout, out.stdout + out.stderr
    finally:
        e.close()
    text = ("facilitator:\n  humans: [you]\n  http:\n    listen: 127.0.0.1:18765\n    url: https://node.example\n    issuers:\n"
            "      - name: corp\n        issuer: https://127.0.0.1:9\n")           # nothing listens there: a fetch would fail loudly
    e = env(fac_yml=text)
    try:
        t0 = time.time()
        chk = cli(e, "check", "--json")
        parts = {p["part"]: p for p in json.loads(chk.stdout)}
        d = parts["http oauth"]["detail"]
        assert "corp (https://127.0.0.1:9)" in d and "https://node.example/mcp" in d and \
            "https://node.example/.well-known/oauth-protected-resource/mcp" in d, d
        assert time.time() - t0 < 20
    finally:
        e.close()


def test_the_kill_switch_and_the_infra_part():
    e = env(fac_yml=FAC + "    enabled: false\n")
    try:
        fac = e.fac()
        assert fac.participants()[1].http.configured and not fac.participants()[1].http.active
        assert "http" not in fac.infra().components()
    finally:
        e.close()
    e = env()
    try:
        fac = e.fac()
        assert "http" in fac.infra().components()
    finally:
        e.close()
    e = env(fac_yml="facilitator:\n  humans: [you]\n")
    try:
        assert "http" not in e.fac().infra().components()       # listen not set: nothing opens (ADR-0071)
    finally:
        e.close()


# ---------------------------------------------------------------- mesh.yml

def test_mesh_http_domain_level_and_new_keys():
    m = mesh_mod.parse(MESH)
    assert not m.findings, m.findings
    assert m.http_domain == f"http.{m.home_domain}" and m.http_level() == "public"
    assert m.exposure("jester") == "public" and m.exposure("other") == "local"
    p = mesh_mod.parse(f"preset: team\nnode:\n  id: n1\ntrust:\n  http.n1.local: private\n")
    assert not p.findings and p.http_level() == "private" and p.level_of_domain("http.n1.local") == "private", p.findings
    for text, rule in [("preset: team\nnode:\n  id: n1\ntrust:\n  http.n1.local: local\n", "bad-value"),
                       ("preset: solo\nnode:\n  id: n1\ntrust:\n  http.n1.local: private\n", "above-ceiling"),
                       ("preset: solo\nexpose:\n  x: public\n", "above-ceiling"),
                       ("preset: team\ntrust:\n  other.test: public\n", "above-ceiling"),
                       ("preset: team\nlimits:\n  public:\n    approval: sometimes\n", "bad-value"),
                       ("preset: team\nlimits:\n  public:\n    http_receive_wait: 0s\n", "bad-value")]:
        f = mesh_mod.parse(text).findings
        assert f and f[0].rule == rule, (text, f)
    ok = mesh_mod.parse("preset: team\nlimits:\n  public:\n    approval: none\n    approval_ttl: 7d\n    http_receive_wait: 10s\n")
    assert not ok.findings, ok.findings
    assert ok.limit("public", "approval")[0] == "none" and mesh_mod.seconds(ok.limit("public", "http_receive_wait")[0]) == 10
    d = mesh_mod.parse(MESH)
    assert d.limit("public", "approval")[0] == "first-contact" and d.limit("private", "approval")[0] == "none"
    assert mesh_mod.seconds(d.limit("public", "http_receive_wait")[0]) == 25
    assert mesh_mod.seconds(d.limit("private", "http_receive_wait")[0]) == 60
    assert d.limit("public", "approval_ttl")[0] == "30d"


# ---------------------------------------------------------------- the client table

def test_a_token_is_shown_once_kept_as_a_hash_and_revoked_at_once():
    e = env()
    try:
        fac = e.register_all()
        r = fac.enrol_http("cli-one", "you")
        tok = r["token"]
        assert tok.startswith("cli-one.") and r["level"] == "public" and r["approval"] == "first-contact"
        assert r["id"] == f"spiffe://http.{fac.mesh.node_id}.local/node/{fac.mesh.node_id}/http/cli-one"
        raw = (fac.state.home / "http" / "clients.json").read_text()
        assert tok.split(".", 1)[1] not in raw and clients_mod.hash_secret(tok.split(".", 1)[1]) in raw
        assert oct((fac.state.home / "http" / "clients.json").stat().st_mode & 0o777) == "0o600"
        assert fac.clients.check_token(tok)[0] == "cli-one"
        assert fac.clients.check_token(tok + "x") is None and fac.clients.check_token("cli-one.") is None
        assert fac.clients.check_token("nobody." + tok.split(".", 1)[1]) is None and fac.clients.check_token(None) is None
        assert fac.state.roster()["cli-one"]["kind"] == "http" and fac.signer.public("cli-one")
        for bad in ("jester", "you", "facilitator", "all"):
            try:
                fac.enrol_http(bad, "you")
                raise AssertionError(bad)
            except FacilitatorError as err:
                assert "name of its own" in str(err), err
        try:
            fac.enrol_http("cli-one", "you")
            raise AssertionError("a second token while live")
        except FacilitatorError as err:
            assert "exists" in str(err)
        fac.revoke_client("cli-one", "you")
        assert fac.clients.check_token(tok) is None                       # at once, and the hash is discarded
        assert '"token_hash": ""' in (fac.state.home / "http" / "clients.json").read_text()
        again = fac.enrol_http("cli-one", "you")["token"]                 # a new token after a revoke
        assert fac.clients.check_token(again) and fac.clients.check_token(tok) is None
    finally:
        e.close()


def test_forget_a_bearer_client_gives_its_name_a_new_token_and_is_a_persons_act():
    e = env()
    try:
        fac = e.register_all()
        tok = fac.enrol_http("cli-one", "you")["token"]
        try:
            fac.forget_client("cli-one", "you")
            raise AssertionError("a live client")
        except FacilitatorError as err:
            assert "revoke it first" in str(err)
        fac.revoke_client("cli-one", "you")
        r = cli(e, "http", "forget", "cli-one", extra={"CLAUDECODE": "1"})
        assert r.returncode == 1 and "refuses to run inside an agent's job" in r.stderr, r.stderr
        assert fac.clients.get("cli-one") is not None
        r = cli(e, "http", "forget", "cli-one")
        assert r.returncode == 0 and "forgotten by you" in r.stdout and "http token cli-one" in r.stdout, (r.stdout, r.stderr)
        assert fac.clients.get("cli-one") is None and fac.clients.check_token(tok) is None
        assert cli(e, "http", "forget", "cli-one").returncode == 1                 # unknown now
        new = fac.enrol_http("cli-one", "you")["token"]
        assert fac.clients.check_token(new)[0] == "cli-one"
        assert "forget" in [x["event"] for x in fac.clients.audit_log()] and fac.clients.audit_ok()[0]
    finally:
        e.close()


def test_pending_clients_are_capped_and_the_audit_chain_shows_an_edit():
    e = env()
    try:
        fac = e.register_all()
        for n in range(clients_mod.MAX_PENDING):
            fac.enrol_http(f"c{n}", "you")
        try:
            fac.enrol_http("one-too-many", "you")
            raise AssertionError("over the cap")
        except FacilitatorError as err:
            assert "not yet approved" in str(err), err
        fac.deny_client("c0", "you")
        fac.enrol_http("one-too-many", "you")                             # room again
        ok, detail = fac.clients.audit_ok()
        assert ok, detail
        events = [x["event"] for x in fac.clients.audit_log()]
        assert events[:2] == ["enrolled", "enrolled"] and "denied" in events
        f = fac.clients.audit_file
        lines = f.read_text().splitlines()
        f.write_text("\n".join(lines[:3] + lines[4:]) + "\n")             # a line cut out
        ok, detail = fac.clients.audit_ok()
        assert not ok and "cut or edited" in detail, detail
    finally:
        e.close()


# ---------------------------------------------------------------- the reach rule

def test_a_public_client_sees_only_public_exposed_agents():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        w = s.who()
        assert [p["handle"] for p in w["participants"]] == ["jester"], w
        assert w["you"] == "cli-one"
        for hidden in ("domain-expert-one", "you", "third", "nobody-at-all"):
            try:
                s.say("new", "hello", [hidden])
                raise AssertionError(hidden)
            except FacilitatorError as err:
                assert str(err) == f"@{hidden} is no participant (who lists the handles)", err    # the same words each time
        try:
            s.say(None, "@domain-expert-one are you there")                # a mention in a new conversation: same
            raise AssertionError("mention")
        except FacilitatorError as err:
            assert "is no participant" in str(err)
        r = s.say("new", "@jester hello")
        assert r["to"] == ["jester"], r
    finally:
        e.close()


def test_mapped_private_the_client_sees_private_agents_and_needs_no_approval():
    e = env(mesh="preset: team\nnode:\n  id: n1\ntrust:\n  http.n1.local: private\nexpose:\n  jester: public\n  "
                 "domain-expert-one: private\n  \"*\": local\n")
    try:
        fac = e.register_all()
        r, s = enrol(fac)
        assert r["level"] == "private" and r["approval"] == "none"
        assert sorted(p["handle"] for p in s.who()["participants"]) == ["domain-expert-one", "jester"]
        fac.state.seen("domain-expert-one")
        out = s.say("new", "@domain-expert-one hi")
        assert out["delivered"] and out["to"] == ["domain-expert-one"], out        # no first-contact hold at private
        assert fac.limits_for("private").rate_limit == 10
    finally:
        e.close()


# ---------------------------------------------------------------- first contact

def test_first_contact_is_held_shown_to_a_person_and_released_by_approve():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.state.seen("jester")
        out = s.say("new", "@jester tell me a joke")
        conv = out["conversation"]
        assert out["delivered"] is False and out["held"][0]["reason"] == "approval", out
        assert "a person must approve it" in out["notices"][0]
        j = e.session(fac, "jester")
        assert j.receive(0) is None                                      # nothing delivered yet
        m = fac.mail("you")
        assert [a["client"] for a in m["approvals"]] == ["cli-one"] and m["approvals"][0]["held"] == 1, m
        from facilitator.mcp import mail_text
        assert "cli-one waits for your approval" in mail_text(m)
        assert "cli-one waits for approval" in fac.mail_notice("you")
        a = e.session(fac, "you").approve("cli-one")                     # the person's tool
        assert a["released"][0]["delivered"] and a["released"][0]["to"] == ["jester"], a
        assert fac.pending_approvals() == []
        got = j.receive(0)
        assert got["parts"][0]["text"] == "@jester tell me a joke" and got["from"] == "cli-one"
        j.reply("Why did the packet cross the network?")
        back = s.receive(0)                                              # the client's receive
        assert back["from"] == "jester" and "packet" in back["text"], back
        s.reply("ha")                                                    # ... and answers: now an approved client
        _, proj, _ = fac.record.read(conv)
        kinds = [n["code"] for n in proj["notices"]]
        assert "approval" in kinds and "approved" in kinds, kinds
        out2 = s.say(conv, "another one")                                # approved: not held again
        assert out2["delivered"] is not False or out2["notices"], out2
        assert clients_mod.parse_iso(fac.clients.get("cli-one")["approved_at"]) > 0
    finally:
        e.close()


def test_a_message_held_more_than_seven_days_is_not_delivered_and_deny_drops_it():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac, "old-one")
        fac.state.seen("jester")
        out = s.say("new", "@jester hi")
        orig = app_mod.time.time
        app_mod.time.time = lambda: orig() + 8 * 86400
        try:
            r = fac.approve_client("old-one", "you")
        finally:
            app_mod.time.time = orig
        assert r["released"][0]["delivered"] is False, r
        assert e.session(fac, "jester").receive(0) is None
        _, proj, _ = fac.record.read(out["conversation"])
        assert any("more than 7 days" in n["text"] for n in proj["notices"])
        _, s2 = enrol(fac, "refused-one")
        o2 = s2.say("new", "@jester hi again")
        d = fac.deny_client("refused-one", "you")
        assert d["status"] == "denied" and d["dropped"] == 1, d
        assert fac.clients.check_token("refused-one.x") is None
        assert fac.pending_approvals() == [] or all(p["client"] != "refused-one" for p in fac.pending_approvals())
        _, proj, _ = fac.record.read(o2["conversation"])
        assert any(n["code"] == "denied" for n in proj["notices"])
    finally:
        e.close()


def test_an_approval_expires_after_approval_ttl():
    e = env(mesh=MESH + "limits:\n  public:\n    approval_ttl: 1h\n")
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.state.seen("jester")
        c = s.say("new", "@jester first")["conversation"]
        fac.approve_client("cli-one", "you")
        assert e.session(fac, "jester").receive(0) is not None
        assert s.say(c, "second")["delivered"] is not False
        orig = app_mod.time.time
        app_mod.time.time = lambda: orig() + 2 * 3600
        try:
            held = s.say(c, "third")
        finally:
            app_mod.time.time = orig
        assert held["delivered"] is False and held["held"][0]["reason"] == "approval", held
    finally:
        e.close()


# ---------------------------------------------------------------- the public limits

def test_public_limits_rate_hops_and_size():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.state.seen("jester")
        conv = s.say("new", "@jester one")["conversation"]
        fac.approve_client("cli-one", "you")
        assert fac.limits_for("public").hop_limit == 2 and fac.limits_for("public").message_budget == 10
        s.say(conv, "two")
        s.say(conv, "three")                                             # three written in the minute
        try:
            s.say(conv, "four")
            raise AssertionError("the rate")
        except FacilitatorError as err:
            assert "rate limit" in str(err) and "3 messages" in str(err), err
        _, proj, _ = fac.record.read(conv)
        assert len(proj["order"]) == 3                                   # the fourth was not written
        hops = [proj["messages"][m]["hops"] for m in proj["order"]]
        assert hops == [0, 1, 2], hops
        big = "x" * (16 * 1024 + 1)
        _, s2 = enrol(fac, "big-one")
        try:
            s2.say("new", "@jester " + big)
            raise AssertionError("the size")
        except FacilitatorError as err:
            assert "too large" in str(err) and "max_packet" in str(err), err
        # the hop limit of the public level holds the third hop of a chain: jester answers, the client answers, ...
        j = e.session(fac, "jester")
        j.receive(0)
        r = j.reply("an answer")
        assert r["delivered"] is not False
    finally:
        e.close()


def test_the_rate_is_the_clients_across_conversations_and_a_refusal_leaves_no_empty_conversation():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.approve_client("cli-one", "you")
        for n in range(3):
            s.say("new", f"@jester conversation {n}")           # a new conversation each time does not get round the rate
        before = len(fac.record.conversations())
        try:
            s.say("new", "@jester a fourth conversation")
            raise AssertionError("the rate across conversations")
        except FacilitatorError as err:
            assert "rate limit" in str(err) and "across all its conversations" in str(err), err
        assert len(fac.record.conversations()) == before         # refused before anything was made
        try:
            s.say("new", "@jester " + "x" * 20000)
        except FacilitatorError as err:
            assert "too large" in str(err)
        assert len(fac.record.conversations()) == before
    finally:
        e.close()


def test_the_level_of_a_conversation_with_a_client_bounds_the_agents_too():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.approve_client("cli-one", "you")
        fac.state.seen("jester")
        conv = s.say("new", "@jester hi")["conversation"]
        _, proj, _ = fac.record.read(conv)
        assert fac.conv_level(proj["thread"]) == "public"
        assert fac.level_of_message(proj, proj["order"][0]) == "public"
        j = e.session(fac, "jester")
        j.receive(0)
        assert j.reply("one")["delivered"] is not False           # a reply at hop 1 of the public limit of 2
        s.receive(0)
        s.reply("two")                                            # hop 2
        j.receive(0)
        r = j.reply("three")                                      # hop 3: past the public hop limit, held
        assert r["delivered"] is False and r["held"][0]["reason"] == "hop-limit", r
    finally:
        e.close()


# ---------------------------------------------------------------- via, and never a person

def test_via_in_every_packet_shown_by_transcript_and_checked_by_verify():
    from facilitator import transcript, verify
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.state.seen("jester")
        conv = s.say("new", "@jester hello there")["conversation"]
        fac.approve_client("cli-one", "you")
        j = e.session(fac, "jester")
        j.receive(0)
        j.reply("hi back")
        s.receive(0)
        s.reply("thanks")
        led, proj, _ = fac.record.read(conv)
        by_client = [led.valid[i] for i in led.order if led.valid[i].principal == "cli-one"]
        assert by_client and all(x.data.get("via") == {"transport": "http", "auth": "bearer", "client": "cli-one"}
                                 for x in by_client), [x.data for x in by_client]
        assert any(x.kind == "message" for x in by_client) and any(x.kind == "status" for x in by_client)
        assert not any("via" in led.valid[i].data for i in led.order if led.valid[i].principal in ("jester", "facilitator"))
        text = "\n".join(transcript.lines(fac, conv))
        assert "(via HTTP, authenticated by bearer token, client cli-one)" in text, text
        assert transcript.transcript(fac, conv)["messages"][0]["via"]["client"] == "cli-one"
        r = verify.verify(fac, conv)
        assert r["ok"], r["problems"]
        flat = "\n".join(l for ls in r["chains"].values() for l in ls)
        assert "via http (bearer, client cli-one): this node signed on the client's behalf" in flat, flat
        assert "begins with an HTTP client the node vouches for" in flat
        out = cli(e, "verify", "--conv", conv)
        assert out.returncode == 0 and "via http" in out.stdout, out.stdout + out.stderr
    finally:
        e.close()


def test_verify_flags_a_client_packet_with_no_via_or_the_wrong_client():
    from facilitator import verify
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        fac.approve_client("cli-one", "you")
        fac.state.seen("jester")
        conv = s.say("new", "@jester hello")["conversation"]
        assert verify.verify(fac, conv)["ok"]
        orig = fac.record.via
        fac.record.via = lambda p: None                                  # a node that forgot to say it vouches
        try:
            s.say(conv, "no via")
        finally:
            fac.record.via = orig
        r = verify.verify(fac, conv)
        assert not r["ok"] and any("carries no via" in p for p in r["problems"]), r["problems"]
        fac.record.via = lambda p: {"transport": "http", "auth": "bearer", "client": "someone-else"}
        try:
            c2 = s.say("new", "@jester again")["conversation"]
        finally:
            fac.record.via = orig
        r = verify.verify(fac, c2)
        assert not r["ok"] and any("via names the client someone-else" in p for p in r["problems"]), r["problems"]
    finally:
        e.close()


def test_a_client_is_never_a_person():
    e = env()
    try:
        fac = e.register_all()
        _, s = enrol(fac)
        conv = s.say("new", "@jester hello")["conversation"]
        assert s.human is False
        for call in (lambda: s.continue_(conv), lambda: s.approve("cli-one")):
            try:
                call()
                raise AssertionError("a client acted as a person")
            except FacilitatorError as err:
                assert "person" in str(err), err
        # the node's own checks: not a human of the conversation, so a continue entry by it would be ignored, and fac.continue_
        try:
            fac.continue_("cli-one", conv)
            raise AssertionError("fac.continue_")
        except FacilitatorError as err:
            assert "only a person" in str(err)
        _, proj, _ = fac.record.read(conv)
        assert "cli-one" not in proj["thread"]["humans"]
        try:
            HttpSession(fac, "jester")
            raise AssertionError("an agent as an HTTP client")
        except FacilitatorError as err:
            assert "not an HTTP client" in str(err)
        # reading: mail and transcript work (read only), for its own conversations only
        assert s.mail()["messages"] == []
        assert "cli-one" in "\n".join(s.transcript(conv))
        other = fac.new_conversation("you", ["jester"])
        try:
            s.transcript(other)
            raise AssertionError("someone else's conversation")
        except FacilitatorError as err:
            assert "you are not in" in str(err)
    finally:
        e.close()


# ---------------------------------------------------------------- the commands

def test_the_http_commands_and_the_agent_job_refusal():
    e = env()
    try:
        fac = e.register_all()
        r = cli(e, "http", "token", "cli-two", "--label", "laptop")
        assert r.returncode == 0, r.stderr
        tok = r.stdout.strip()
        assert tok.startswith("cli-two.") and "shown once" in r.stderr and tok not in r.stderr, r.stderr
        assert "claude mcp add --transport http cli-two http://127.0.0.1:18765/mcp" in r.stderr
        listing = cli(e, "http", "list")
        assert "cli-two" in listing.stdout and "enrolled" in listing.stdout and tok not in listing.stdout
        js = json.loads(cli(e, "http", "list", "--json").stdout)
        assert js[0]["client"] == "cli-two" and "token_hash" not in js[0]
        for act in ("token", "approve", "deny", "revoke"):
            x = cli(e, "http", act, "cli-two", extra={"CLAUDECODE": "1"})
            assert x.returncode == 1 and "refuses to run inside an agent's job" in x.stderr, (act, x.stderr)
        assert cli(e, "http", "approve", "cli-two", "--as", "nobody").returncode == 1
        a = cli(e, "http", "approve", "cli-two")
        assert a.returncode == 0 and "approved by you" in a.stdout, a.stderr
        assert cli(e, "http", "audit").returncode == 0
        rv = cli(e, "http", "revoke", "cli-two")
        assert rv.returncode == 0 and "no longer works" in rv.stdout
        assert cli(e, "http", "approve", "cli-two").returncode == 1                # a revoked client stays revoked
        chk = cli(e, "check", "--json")
        parts = {p["part"]: p for p in json.loads(chk.stdout)}
        assert parts["http endpoint"]["detail"].startswith("127.0.0.1:18765") and "http clients" in parts and "http level" in parts
        low = cli(e, "explain", "jester")
        assert "public:" in low.stdout and "approval" in low.stdout
    finally:
        e.close()


def test_http_insecure_lets_a_lan_url_be_plain_http_with_a_warning_and_never_under_open():
    """Ruling OA6: `http.insecure: true` waives https for http.url and TLS beyond loopback, warns, and is refused under open."""
    lan = ("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    url: http://192.168.1.20:8443\n"
           "    issuers:\n      - name: corp\n        issuer: https://idp.example\n")
    # refused without the flag: the url must be https, and beyond loopback TLS is required
    e = env(fac_yml=lan)
    try:
        ok, why = e.fac().http_ready()
        assert not ok and "must be https" in why and "http.insecure: true" in why, why
    finally:
        e.close()
    # accepted with it: the TLS waiver (no tls_cert, no behind_proxy) and the warning in check
    e = env(fac_yml=lan.replace("    url:", "    insecure: true\n    url:"))
    try:
        assert e.fac().http_ready() == (True, "ok"), e.fac().http_ready()
        h = e.fac().participants()[1].http
        assert h.insecure is True and h.tls_cert is None and not h.behind_proxy
        from facilitator import endpoint
        assert endpoint.base_url(h) == "http://192.168.1.20:8443"      # the metadata advertises the url as given
        assert endpoint.base_url(h) + endpoint.PATH == "http://192.168.1.20:8443/mcp"
        chk = cli(e, "check", "--json")
        parts = {p["part"]: p for p in json.loads(chk.stdout)}
        w = parts["http insecure"]
        assert w["ready"] is True and w["detail"].startswith("warning:") and "tokens travel in plain text" in w["detail"], w
        assert "plain (http.insecure)" in parts["http endpoint"]["detail"]
        from facilitator import oauth
        iss = h.issuers
        assert oauth.metadata(endpoint.base_url(h) + endpoint.PATH, iss)["resource"] == "http://192.168.1.20:8443/mcp"
    finally:
        e.close()
    # bearer tokens (no issuers) follow the same rule: beyond loopback needs TLS unless insecure
    for yml, want in (("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    url: http://10.0.0.5:8443\n", False),
                      ("facilitator:\n  http:\n    listen: 0.0.0.0:8443\n    url: http://10.0.0.5:8443\n    insecure: true\n", True)):
        e = env(fac_yml=yml)
        try:
            assert e.fac().http_ready()[0] is want, e.fac().http_ready()
        finally:
            e.close()
    # refused under open, in check and for the endpoint
    e = env(mesh="preset: open\n", fac_yml=lan.replace("    url:", "    insecure: true\n    url:"))
    try:
        ok, why = e.fac().http_ready()
        assert not ok and "refused under preset: open" in why, why
        chk = cli(e, "check", "--json")
        parts = {p["part"]: p for p in json.loads(chk.stdout)}
        assert parts["http endpoint"]["ready"] is False and "preset: open" in parts["http endpoint"]["detail"] and chk.returncode == 1
        from facilitator import endpoint
        try:
            endpoint.Daemon(e.fac())
            raise AssertionError("the endpoint started under open with http.insecure")
        except endpoint.EndpointError as x:
            assert "preset: open" in str(x)
    finally:
        e.close()
    # a non-boolean value is a lint finding like the other flags
    e = env(fac_yml="facilitator:\n  http:\n    listen: 127.0.0.1:8443\n    insecure: maybe\n")
    try:
        ok, why = e.fac().http_ready()
        assert not ok and "insecure" in why, why
    finally:
        e.close()


def test_check_says_why_http_is_refused():
    e = env(mesh="preset: solo\n")
    try:
        chk = cli(e, "check", "--json")
        parts = {p["part"]: p for p in json.loads(chk.stdout)}
        assert parts["http endpoint"]["ready"] is False and "preset solo" in parts["http endpoint"]["detail"], parts["http endpoint"]
        assert chk.returncode == 1
        t = cli(e, "http", "token", "x")
        assert t.returncode == 1 and "preset solo" in t.stderr
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
