"""Run by test/facilitator/oauth_local_check.sh under the bundle's python: what Claude Code does at login, without a browser, against the
real Keycloak of `task facilitator:oauth-local` and the real node. Standard library only.

    oauth_local_drive.py <node-url> <user> <password-file> <token-out-file>

  1. POST <node>/mcp with no token: 401 with resource_metadata; read the protected-resource metadata (names the issuer)
  2. read the authorization server's metadata (RFC 8414, else OIDC discovery): registration, authorization, token endpoints
  3. dynamic client registration, anonymous, a public client with a localhost redirect URI
  4. authorization code with PKCE (S256) and resource=<node>/mcp: the Keycloak login form posted as a browser would
  5. the token endpoint with the code verifier and the resource; the access token is written to <token-out-file> (mode 600)
Prints one JSON line a step; exits 0 when every step held. The token itself is never printed (its claims are, minus the subject's value).
"""
import base64
import hashlib
import html
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request


def ok(what, **kw):
    print(json.dumps({"ok": what, **kw}), flush=True)


def need(cond, what):
    if not cond:
        print(json.dumps({"FAIL": what}), flush=True)
        sys.exit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)
jar = {}   # Keycloak's session cookies are Secure, which a browser accepts from http://localhost and the cookiejar module does not


def call(url, data=None, headers=None, method=None):
    """-> (status, headers, body bytes); an HTTP error status is a result, not an exception."""
    headers = dict(headers or {})
    if jar:
        headers["Cookie"] = "; ".join(f"{k}={v}" for k, v in jar.items())
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        r = opener.open(req, timeout=20)
    except urllib.error.HTTPError as e:
        r = e
    for c in r.headers.get_all("Set-Cookie") or []:
        name, _, rest = c.partition("=")
        value = rest.split(";", 1)[0]
        if value in ("", "deleted"):
            jar.pop(name, None)
        else:
            jar[name] = value
    return r.status if hasattr(r, "status") else r.code, r.headers, r.read()


def jget(url):
    st, _, body = call(url)
    return st, (json.loads(body) if st == 200 else None)


def main(argv):
    node, user, pwfile, out = argv[1], argv[2], argv[3], argv[4]
    password = open(pwfile).read().strip()
    resource = node.rstrip("/") + "/mcp"

    # 1. the challenge and the protected-resource metadata
    st, hdr, _ = call(resource, data=b"{}", headers={"Content-Type": "application/json"}, method="POST")
    need(st == 401, f"no token: expected 401, got {st}")
    m = re.search(r'resource_metadata="([^"]+)"', hdr.get("WWW-Authenticate", ""))
    need(m, "the 401 carries no resource_metadata")
    st, prm = jget(m.group(1))
    need(st == 200 and prm["resource"] == resource and prm["authorization_servers"], f"metadata: {st} {prm}")
    ok("401 with resource_metadata; metadata names the resource and the authorization server", authorization_servers=prm["authorization_servers"],
       scopes=prm.get("scopes_supported"))
    issuer = prm["authorization_servers"][0]

    # 2. the authorization server's metadata
    u = urllib.parse.urlsplit(issuer)
    md = None
    for url in (f"{u.scheme}://{u.netloc}/.well-known/oauth-authorization-server{u.path}",
                f"{u.scheme}://{u.netloc}/.well-known/openid-configuration{u.path}",
                f"{issuer}/.well-known/openid-configuration"):
        st, md = jget(url)
        if md:
            break
    need(md and md.get("issuer") == issuer, "no authorization server metadata that names the issuer")
    need(md.get("registration_endpoint") and md.get("authorization_endpoint") and md.get("token_endpoint"), "metadata lacks an endpoint")
    need("S256" in md.get("code_challenge_methods_supported", []), "no PKCE S256")
    ok("authorization server metadata: registration, authorization and token endpoints, PKCE S256")

    # 3. dynamic client registration
    redirect = "http://localhost:8976/callback"
    reg = {"client_name": "Claude Code (oauth-local check)", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
           "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": "facilitator:participate"}
    st, _, body = call(md["registration_endpoint"], data=json.dumps(reg).encode(), headers={"Content-Type": "application/json"}, method="POST")
    need(st == 201, f"dynamic client registration: {st} {body[:300]!r}")
    client = json.loads(body)
    client_id = client["client_id"]
    ok("dynamic client registration (anonymous, public client, localhost redirect)", registered=True)

    # 4. authorization code + PKCE + resource
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(12)
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": redirect, "scope": "facilitator:participate",
                                "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "resource": resource})
    st, _, body = call(md["authorization_endpoint"] + "?" + q)
    page = body.decode("utf-8", "replace")
    need(st == 200 and "kc-form-login" in page, f"authorization request: {st}, no login form ({page[:200]!r})")
    form = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) or re.search(r'<form[^>]*action="([^"]+)"[^>]*id="kc-form-login"', page)
    need(form, "no login form action")
    action = html.unescape(form.group(1))
    st, hdr, body = call(action, data=urllib.parse.urlencode({"username": user, "password": password, "credentialId": ""}).encode(),
                         headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
    loc = hdr.get("Location", "")
    need(st == 302 and loc.startswith(redirect), f"login: {st}, Location {loc[:120]!r} {re.sub(r'<[^>]*>', ' ', body.decode('utf-8', 'replace'))[-400:].split()!r}")
    qs = urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query)
    need(qs.get("state") == [state] and qs.get("code"), "the redirect carries no code, or a wrong state")
    ok("authorization code with PKCE S256 and resource=" + resource + ": the login form posted, redirected with a code and the state")

    # 5. the token
    st, _, body = call(md["token_endpoint"], data=urllib.parse.urlencode({
        "grant_type": "authorization_code", "code": qs["code"][0], "redirect_uri": redirect, "client_id": client_id,
        "code_verifier": verifier, "resource": resource}).encode(), headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
    need(st == 200, f"token endpoint: {st} {body[:300]!r}")
    tok = json.loads(body)
    at = tok["access_token"]
    need(tok.get("token_type", "").lower() == "bearer" and at.count(".") == 2, "the access token is not a JWT")
    seg = at.split(".")
    head = json.loads(base64.urlsafe_b64decode(seg[0] + "=" * (-len(seg[0]) % 4)))
    claims = json.loads(base64.urlsafe_b64decode(seg[1] + "=" * (-len(seg[1]) % 4)))
    aud = claims.get("aud")
    ok("token: a JWT access token", alg=head.get("alg"), iss=claims.get("iss"), aud=aud, scope=claims.get("scope"), has_sub=bool(claims.get("sub")),
       lifetime=claims.get("exp", 0) - claims.get("iat", 0))
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(at)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
