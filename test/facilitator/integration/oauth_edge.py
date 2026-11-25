"""Run by test/facilitator/oauth_flow.sh under the bundle's python: the edge of the OAuth resource server, as a cloud AI
would meet it. No credentials: the tokens are throwaway ones the flow's own local issuer minted, in files.

    oauth_edge.py <base-url> <issuer-url[,issuer-url...]> <status>=<token file> ...

  - no token: 401 whose WWW-Authenticate carries resource_metadata (RFC 9728), and no error (nothing was refused yet)
  - that metadata: 200, resource <base>/mcp, authorization_servers naming the issuer, the scope, header bearer
  - each <status>=<file>: the token in the file is answered with that status (401 invalid_token for a token of another
    audience, expired, another issuer or alg none; 403 insufficient_scope for the wrong scope, which names the scope)
"""
import http.client
import json
import re
import sys
from urllib.parse import urlsplit


def raw(base, token, method="POST", path="/mcp"):
    u = urlsplit(base)
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    c.request(method, path, body=b"{}" if method == "POST" else None, headers=h)
    r = c.getresponse()
    out = (r.status, dict(r.getheaders()), r.read())
    c.close()
    return out


def need(cond, what):
    if not cond:
        print(json.dumps({"FAIL": what}), flush=True)
        sys.exit(1)
    print(json.dumps({"ok": what}), flush=True)


def main(argv):
    base, issuers = argv[1].rstrip("/"), argv[2].split(",")
    st, h, _ = raw(base, None)
    www = h.get("www-authenticate", "")
    m = re.search(r'resource_metadata="([^"]+)"', www)
    need(st == 401 and m and "error=" not in www, "no token: 401 with resource_metadata and no error")
    path = urlsplit(m.group(1)).path
    need(m.group(1) == f"{base}/.well-known/oauth-protected-resource/mcp", "resource_metadata names the node's own metadata URL")
    st, _, body = raw(base, None, "GET", path)
    d = json.loads(body)
    need(st == 200 and d["resource"] == f"{base}/mcp" and d["authorization_servers"] == issuers, "the protected-resource metadata names the node and the authorization server")
    need("facilitator:participate" in d["scopes_supported"] and d["bearer_methods_supported"] == ["header"], "the metadata names the scope and the header")
    st, _, body = raw(base, None, "GET", "/.well-known/oauth-protected-resource")
    need(st == 200 and json.loads(body)["resource"] == f"{base}/mcp", "the unsuffixed metadata path answers too")
    for arg in argv[3:]:
        want, _, f = arg.partition("=")
        tok = open(f).read().strip()
        st, h, body = raw(base, tok)
        www = h.get("www-authenticate", "")
        ok = st == int(want) and "resource_metadata=" in www
        if want == "403":
            ok = ok and 'error="insufficient_scope"' in www and 'scope="facilitator:participate"' in www
        else:
            ok = ok and 'error="invalid_token"' in www
        need(ok and tok.encode() not in body, f"{f.rsplit('/', 1)[-1]}: {want} with the challenge, no detail")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
