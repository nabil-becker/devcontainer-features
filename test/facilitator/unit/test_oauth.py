"""Slice N5b: the node as an OAuth 2.1 resource server (oauth.py; the endpoint with http.issuers). A local issuer (a key
made on the spot, its JWKS and discovery document on loopback; test/facilitator/integration/oauth_issuer.py) mints the
tokens. The verifier alone: a good token; the wrong audience, an expired token, the wrong issuer, an unlisted one, the
wrong scope (scope and scp), alg none, a shared-secret HS256 forged from the public key, the wrong key, no exp; keys
found by kid and re-read once when rotated, kept (one fetch), a JWKS that cannot be read refusing the token (closed,
and said), a discovery document naming another issuer, the entry's own audience, algorithms and scope. The endpoint:
401 with resource_metadata for no token (not counted as a failure) and invalid_token for a bad one, 403
insufficient_scope, the RFC 9728 metadata, 503 when the keys cannot be read, a valid token enrolling the (issuer,
subject) client, its first message held until a person approves, answered, received, `via` naming oauth, issuer and
subject in the transcript and verify, a bearer client working beside it, a revoked OAuth client refused at once, two
subjects two clients. Needs `jwt`, `cryptography` and the `mcp` library: runs under a python that has them
(FACILITATOR_TEST_MCP_PYTHON, the bundle's own interpreter), else skipped."""
import os
import sys

try:
    import jwt  # noqa: F401
    import mcp  # noqa: F401
except ImportError:
    py = os.environ.get("FACILITATOR_TEST_MCP_PYTHON")
    if py and os.path.isfile(py) and not os.environ.get("_FAC_REEXEC"):
        os.environ["_FAC_REEXEC"] = "1"
        os.execv(py, [py, "-I", os.path.abspath(__file__)])
    print("skip: jwt and the mcp library are not importable here (FACILITATOR_TEST_MCP_PYTHON names a python that has them)")
    sys.exit(0)

from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "integration"))
import helpers  # noqa: E402

import asyncio  # noqa: E402
import base64  # noqa: E402
import contextlib  # noqa: E402
import http.client  # noqa: E402
import json  # noqa: E402
import socket  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import warnings  # noqa: E402

warnings.simplefilter("ignore")
import oauth_issuer  # noqa: E402
from facilitator import clients as clients_mod, endpoint, oauth, participants  # noqa: E402
from facilitator.app import FacilitatorError  # noqa: E402
from facilitator.participants import Issuer  # noqa: E402

RES = "https://node.example/mcp"
MESH = """preset: team
expose:
  jester: public
  "*": local
limits:
  public:
    http_receive_wait: 2s
"""


def verifier(iss, clock=None, **kw):
    entry = Issuer("corp", iss.url, jwks_uri=kw.pop("jwks_uri", None), **kw)
    return oauth.Verifier([entry], RES, **({"clock": clock} if clock else {})), entry


def refused(v, token, code="invalid_token"):
    try:
        v.verify(token)
    except oauth.OAuthError as e:
        assert e.code == code, (e.code, e.why)
        return e
    raise AssertionError("the token was accepted")


def test_a_good_token_names_issuer_subject_and_client():
    iss = oauth_issuer.Issuer().start()
    try:
        v, _ = verifier(iss)
        p = v.verify(iss.mint(RES, sub="alice", client_id="claude-web"))
        assert (p.issuer_name, p.issuer, p.subject, p.client_id) == ("corp", iss.url, "alice", "claude-web")
        assert oauth_issuer.SCOPE in p.scopes
        p = v.verify(iss.mint(RES, sub="bob", scope=["x", oauth_issuer.SCOPE], scope_claim="scp"))     # scp as a list
        assert p.subject == "bob"
    finally:
        iss.stop()


def test_refusals_audience_expiry_issuer_scope_signature_algorithm():
    iss = oauth_issuer.Issuer().start()
    other = oauth_issuer.Issuer().start()
    try:
        v, _ = verifier(iss)
        assert "audience" in refused(v, iss.mint("https://elsewhere.example/mcp")).why           # RFC 8707
        assert "expired" in refused(v, iss.mint(RES, exp_in=-120)).why                           # past the 30 s leeway
        assert "not in http.issuers" in refused(v, other.mint(RES, kid="k1")).why                # an issuer not listed
        assert "not in http.issuers" in refused(v, iss.mint(RES, iss="https://other.example")).why   # wrong iss claim
        e = refused(v, iss.mint(RES, scope="read"), "insufficient_scope")
        assert "facilitator:participate" in e.why
        refused(v, iss.mint(RES, scope=None), "insufficient_scope")
        assert "signature" in refused(v, iss.mint(RES, key=oauth_issuer.new_key())).why.lower()  # the right kid, another key
        # alg none, and a shared-secret token forged with the public key as the secret (algorithm confusion)
        claims = {"iss": iss.url, "sub": "x", "aud": RES, "exp": int(time.time()) + 600, "scope": oauth_issuer.SCOPE}
        assert "algorithm" in refused(v, oauth_issuer.forge_none(claims)).why
        pub = iss.jwks()["keys"][0]
        secret = base64.b64encode(json.dumps(pub).encode()).decode() * 4
        hs = jwt.encode(claims, secret, algorithm="HS256", headers={"kid": "k1"})
        assert "algorithm" in refused(v, hs).why
        no_exp = jwt.encode({k: x for k, x in claims.items() if k != "exp"}, iss.key, algorithm="RS256", headers={"kid": "k1"})
        refused(v, no_exp)
        refused(v, "not.a.jwt")
        refused(v, "x")
        refused(v, "")
        refused(v, "a" * 9000 + ".b.c")
    finally:
        iss.stop()
        other.stop()


def test_the_entrys_own_algorithms_audience_and_scope():
    iss = oauth_issuer.Issuer().start()
    try:
        v, _ = verifier(iss, algorithms=["ES256"])
        assert "algorithm" in refused(v, iss.mint(RES)).why                                      # RS256 not allowed here
        v, _ = verifier(iss, audience="api://node", scope="node.use")
        assert v.verify(iss.mint("api://node", scope="node.use")).subject == "alice"
        refused(v, iss.mint(RES, scope="node.use"))                                              # the default resource is not it
        refused(v, iss.mint("api://node"), "insufficient_scope")
    finally:
        iss.stop()


def test_keys_are_found_by_kid_kept_and_re_read_once_when_rotated():
    now = [time.time()]                                       # the verifier's clock moves; the tokens last a day
    iss = oauth_issuer.Issuer().start()
    big = 86400
    try:
        v, _ = verifier(iss, clock=lambda: now[0])
        for _ in range(3):
            v.verify(iss.mint(RES, exp_in=big))
        assert iss.jwks_hits == 1                                                                # kept: one fetch
        k2 = oauth_issuer.new_key()
        iss.keys["k2"] = k2
        t2 = iss.mint(RES, kid="k2", key=k2, exp_in=big)
        assert "no key" in refused(v, t2).why                                                    # re-read too soon after the first
        now[0] += oauth.JWKS_RETRY + 1
        assert v.verify(iss.mint(RES, kid="k2", key=k2, exp_in=big)).subject == "alice"          # rotated: read again, found
        assert iss.jwks_hits == 2
        for _ in range(5):
            refused(v, iss.mint(RES, kid="nope", exp_in=big))                                    # an unknown kid cannot make us fetch at will
        assert iss.jwks_hits <= 3
        v2, _ = verifier(iss, clock=lambda: now[0])                                              # no kid: only with one key
        iss.keys.pop("k2")
        assert v2.verify(iss.mint(RES, kid=None, exp_in=big)).subject == "alice"
    finally:
        iss.stop()


def test_keys_that_cannot_be_read_close_the_door_and_say_why():
    iss = oauth_issuer.Issuer().start()
    try:
        iss.fail_jwks = True
        v, _ = verifier(iss)
        e = refused(v, iss.mint(RES))
        assert e.server and "JWKS" in e.why and "500" in e.why, e.why
        down = oauth_issuer.Issuer(discovery=False).start()
        v, _ = verifier(down)
        e = refused(v, down.mint(RES))
        assert e.server and "no discovery document" in e.why and "jwks_uri" in e.why, e.why
        down.stop()
        gone = Issuer("gone", "http://127.0.0.1:9", None)
        v = oauth.Verifier([gone], RES)
        e = refused(v, iss.mint(RES, iss="http://127.0.0.1:9"))
        assert e.server and "no discovery document" in e.why and "cannot be read" in e.why, e.why
        ok, why = v.check_reachable(gone)
        assert not ok and "cannot be read" in why
        iss.fail_jwks = False
        v, entry = verifier(iss)
        ok, why = v.check_reachable(entry)
        assert ok and "1 key(s)" in why, why
    finally:
        iss.stop()


def test_a_discovery_document_for_another_issuer_is_refused_and_a_stale_cache_is_not_used():
    iss = oauth_issuer.Issuer().start()
    try:
        v = oauth.Verifier([Issuer("corp", iss.url)], RES,
                           fetch=lambda url, what: {"issuer": "https://mallory.example", "jwks_uri": iss.jwks_url})
        e = refused(v, iss.mint(RES))
        assert e.server and "names the issuer" in e.why, e.why
        now = [time.time()]
        v, _ = verifier(iss, clock=lambda: now[0])
        v.verify(iss.mint(RES, exp_in=86400))
        iss.fail_jwks = True
        now[0] += oauth.JWKS_TTL + 10
        e = refused(v, iss.mint(RES, exp_in=86400))                                                # stale and unreadable: refused
        assert e.server
    finally:
        iss.stop()


def test_metadata_and_challenge_shapes():
    m = oauth.metadata(RES, [Issuer("corp", "https://login.example.org"), Issuer("two", "https://b.example", scope="b.use")])
    assert m["resource"] == RES and m["authorization_servers"] == ["https://login.example.org", "https://b.example"]
    assert m["scopes_supported"] == ["b.use", "facilitator:participate"] and m["bearer_methods_supported"] == ["header"]
    assert oauth.challenge("https://n/m") == b'Bearer resource_metadata="https://n/m"'
    assert oauth.challenge("https://n/m", "invalid_token") == b'Bearer error="invalid_token", resource_metadata="https://n/m"'
    assert oauth.challenge("https://n/m", "insufficient_scope", "s") == \
        b'Bearer error="insufficient_scope", scope="s", resource_metadata="https://n/m"'


# ---------------------------------------------------------------- the endpoint


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Node:
    """A node whose endpoint trusts one local issuer."""

    def __init__(self, issuer=None, issuer_extra=""):
        self.iss = issuer or oauth_issuer.Issuer().start()
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.resource = f"{self.url}/mcp"
        yml = (f"facilitator:\n  humans: [you]\n  http:\n    listen: 127.0.0.1:{self.port}\n    url: {self.url}\n"
               f"    issuers:\n      - name: corp\n        issuer: {self.iss.url}\n{issuer_extra}")
        self.e = helpers.Env(facilitator_yml=yml)
        (self.e.root / ".devcontainer" / "mesh.yml").write_text(MESH)
        self.fac = self.e.register_all()
        self.bearer = self.fac.enrol_http("cli-one", "you")["token"]
        self.d = endpoint.Daemon(self.fac)
        threading.Thread(target=self.d.run, daemon=True).start()
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    def close(self):
        if self.d.server:
            self.d.server.should_exit = True
            time.sleep(0.3)
        self.iss.stop()
        self.e.close()

    def tok(self, **kw):
        return self.iss.mint(self.resource, **kw)

    def raw(self, token, method="POST", path="/mcp", body=b"{}"):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if token:
            h["Authorization"] = f"Bearer {token}"
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            c.request(method, path, body=body, headers=h)
            r = c.getresponse()
            return r.status, dict(r.getheaders()), r.read()
        finally:
            c.close()

    def session(self, token):
        import httpx2
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client

        @contextlib.asynccontextmanager
        async def go():
            async with httpx2.AsyncClient(headers={"Authorization": f"Bearer {token}"}, timeout=30) as hc:
                async with streamable_http_client(self.resource, http_client=hc) as (r, w):
                    async with ClientSession(r, w) as s:
                        await s.initialize()
                        yield s
        return go()

    def call(self, token, name, args=None):
        async def go():
            async with self.session(token) as s:
                r = await s.call_tool(name, args or {})
                return r.is_error, r.content[0].text
        return asyncio.run(go())


INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}).encode()


def test_challenge_metadata_and_status_codes():
    n = Node()
    try:
        st, h, _ = n.raw(None)
        meta = f'resource_metadata="{n.url}/.well-known/oauth-protected-resource/mcp"'
        assert st == 401 and h["www-authenticate"] == "Bearer " + meta, (st, h)
        st, h, _ = n.raw("garbage")
        assert st == 401 and 'error="invalid_token"' in h["www-authenticate"] and meta in h["www-authenticate"]
        st, h, out = n.raw(n.tok(exp_in=-300))
        assert st == 401 and b"expired" not in out                                              # no detail to the caller
        st, h, _ = n.raw(n.tok(scope="read"))
        assert st == 403 and 'error="insufficient_scope"' in h["www-authenticate"] and 'scope="facilitator:participate"' in h["www-authenticate"]
        for path in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
            st, h, out = n.raw(None, "GET", path)
            d = json.loads(out)
            assert st == 200 and d["resource"] == n.resource and d["authorization_servers"] == [n.iss.url], (st, out)
        assert n.raw(None, "GET", "/.well-known/other")[0] == 404
        st, _, out = n.raw(n.tok(), body=INIT)
        assert st == 200 and b"facilitator" in out, (st, out[:200])
        assert n.raw(n.bearer, body=INIT)[0] == 200                                              # a bearer token still works beside
        for _ in range(endpoint.FAIL_LIMIT + 3):                                                 # no token: never the back-off
            n.raw(None)
        assert n.raw(n.bearer, body=INIT)[0] == 200
        n.iss.fail_jwks = True
        n.d.verified.clear()
        n.d.oauth.cache.clear()
        st, h, _ = n.raw(n.tok(sub="carol"))
        assert st == 503 and "www-authenticate" not in h                                         # closed, not the caller's fault
        for _ in range(endpoint.FAIL_LIMIT + 3):
            n.raw(n.tok(sub="carol"))
        assert n.raw(n.bearer, body=INIT)[0] == 200                                              # a failing issuer is not counted
        assert n.fac.clients.get("corp-carol") is None                                           # nothing enrolled
    finally:
        n.close()


def test_an_oauth_client_is_enrolled_held_approved_and_signed_as_oauth():
    n = Node()
    try:
        fac = n.fac
        fac.state.seen("jester")
        t = n.tok(sub="alice", client_id="claude-web")
        err, text = n.call(t, "who")
        assert not err and "@jester" in text and "domain-expert-one" not in text, text
        c = fac.clients.get("corp-alice")
        assert c["status"] == "enrolled" and c["auth"] == "oauth" and c["subject"] == "alice" and c["issuer"] == n.iss.url
        assert c["client_id"] == "claude-web" and c["token_hash"] == ""
        assert fac.is_http("corp-alice") and fac.caller_level("corp-alice") == "public"
        err, text = n.call(t, "say", {"text": "@jester tell me a joke"})
        assert not err and "held" in text and "a person must approve" in text, text
        assert any(p["client"] == "corp-alice" for p in fac.pending_approvals())
        assert fac.clients.check_token("corp-alice.") is None and fac.clients.check_token(t) is None   # no bearer way in
        j = n.e.session(fac, "jester")
        assert j.receive(0) is None
        fac.approve_client("corp-alice", "you")
        got = j.receive(0)
        assert got["from"] == "corp-alice"
        j.reply("Why did the packet cross the network?")
        err, text = n.call(t, "receive", {"wait_seconds": 5})
        assert not err and "packet" in text, text
        err, text = n.call(t, "reply", {"text": "ha"})
        assert not err and "sent" in text, text
        conv = fac.conversations_of("corp-alice")[0]
        err, text = n.call(t, "transcript", {"conversation": conv})
        want = f"(via HTTP, authenticated by OAuth, client corp-alice, issuer {n.iss.url}, subject alice)"
        assert not err and want in text, text
        from facilitator import verify
        r = verify.verify(fac, conv)
        flat = json.dumps(r["chains"])
        assert r["ok"] and f"via http (oauth, client corp-alice, issuer {n.iss.url}, subject alice): this node signed on" in flat, flat
        # never continue or approve
        for name in ("continue", "approve"):
            try:
                err, text = n.call(t, name, {"conversation": conv, "client": "corp-alice"})
                assert err
            except Exception:                                                                    # noqa: BLE001
                pass
        # another subject of the same issuer is another client, held on its own
        t2 = n.tok(sub="Bob Smith/ops", client_id="claude-web")
        err, text = n.call(t2, "say", {"text": "@jester hi"})
        h2 = [x for x in fac.clients.all() if x not in ("corp-alice", "cli-one")]
        assert len(h2) == 1 and fac.clients.get(h2[0])["subject"] == "Bob Smith/ops" and "held" in text, (h2, text)
        assert h2[0].startswith("corp-bob-smith-ops-") and len(h2[0]) < 64
        # revoked: refused at once, and a new token does not bring it back
        fac.revoke_client("corp-alice", "you")
        assert n.raw(t)[0] == 401 and n.raw(n.tok(sub="alice"))[0] == 401
        assert n.raw(n.bearer, body=INIT)[0] == 200
        log = fac.clients.audit_log()
        assert any(x["event"] == "enrolled" and x["client"] == "corp-alice" and x["by"] == "oauth: corp" for x in log)
        assert t not in json.dumps(fac.clients.all()) and t not in json.dumps(log)               # no token is kept
    finally:
        n.close()


def test_forget_lets_a_revoked_or_denied_oauth_client_enrol_anew_and_refuses_a_live_one():
    n = Node()
    try:
        fac = n.fac
        t = n.tok(sub="alice", client_id="claude-web")
        n.call(t, "who")
        try:
            fac.forget_client("corp-alice", "you")
            raise AssertionError("a live (enrolled) client")
        except FacilitatorError as err:
            assert "revoke it first" in str(err), err
        fac.approve_client("corp-alice", "you")
        try:
            fac.forget_client("corp-alice", "you")
            raise AssertionError("a live (approved) client")
        except FacilitatorError as err:
            assert "revoke it first" in str(err), err
        fac.revoke_client("corp-alice", "you")
        assert n.raw(n.tok(sub="alice"))[0] == 401
        r = fac.forget_client("corp-alice", "you")
        assert r["was"] == "revoked" and fac.clients.get("corp-alice") is None
        err, text = n.call(n.tok(sub="alice"), "say", {"text": "@jester hi"})        # new: enrolled, held
        assert not err and "held" in text and fac.clients.get("corp-alice")["status"] == "enrolled", text
        assert any(p["client"] == "corp-alice" for p in fac.pending_approvals())
        fac.deny_client("corp-alice", "you")
        assert fac.forget_client("corp-alice", "you")["was"] == "denied"
        try:
            fac.forget_client("nobody", "you")
            raise AssertionError("unknown")
        except FacilitatorError as err:
            assert "no HTTP client nobody" in str(err)
        evs = [x["event"] for x in fac.clients.audit_log()]
        assert evs.count("forget") == 2 and fac.clients.audit_ok()[0]
        assert [x["event"] for x in fac.audit.events()].count("forget") == 2 and fac.audit.verify()[0]
    finally:
        n.close()


def test_the_pending_cap_refuses_a_new_oauth_client():
    n = Node()
    try:
        for i in range(19):                                                                       # cli-one is enrolled too: 20 pending
            assert n.raw(n.tok(sub=f"user{i}"), body=INIT)[0] == 200
        st, h, _ = n.raw(n.tok(sub="one-too-many"), body=INIT)
        assert st == 401, st
        assert n.fac.clients.get("corp-one-too-many") is None
    finally:
        n.close()


def test_a_handle_is_the_subject_when_plain_and_hashed_when_not():
    h = clients_mod.Clients.oauth_handle
    assert h("corp", "https://i", "alice") == "corp-alice"
    a, b = h("corp", "https://i", "Alice"), h("corp", "https://i", "alice")
    assert a != b and b == "corp-alice" and a.startswith("corp-alice-") and len(a) == len("corp-alice-") + 8
    assert h("corp", "https://i", "x" * 80).startswith("corp-" + "x" * 28 + "-")
    for sub in ("ünï@x.y/z", "!!!", "a b"):
        assert participants.HANDLE_RE.fullmatch(h("corp", "https://i", sub)), sub
    assert h("corp", "https://a", "A") != h("corp", "https://b", "A")


def test_the_entry_decides_the_audience_the_endpoint_accepts():
    n = Node(issuer_extra="        audience: api://the-node\n")
    try:
        assert n.raw(n.tok())[0] == 401                                                           # the default resource is not accepted
        assert n.raw(n.iss.mint("api://the-node"), body=INIT)[0] == 200
    finally:
        n.close()


def test_a_plain_http_jwks_uri_off_loopback_is_read_only_with_insecure():
    """http.insecure (a local cluster: the issuer is localhost for the browser, its service name for the node)."""
    url = "http://keycloak.invalid:8080/certs"
    try:
        oauth._get_json(url, "JWKS")
        raise AssertionError("a plain http address off loopback was read")
    except oauth.OAuthError as e:
        assert "not an https:// address" in e.why, e.why
    try:
        oauth._get_json(url, "JWKS", insecure=True)
        raise AssertionError("keycloak.invalid answered")
    except oauth.OAuthError as e:                        # past the scheme check; the name does not resolve
        assert "cannot be read" in e.why, e.why


if __name__ == "__main__":
    helpers.run_tests(globals())
