"""A local OAuth issuer for the tests of slice N5b (never a real one): an RSA key made on the spot, the JWKS and the
discovery document served on loopback, and access tokens minted from it. Under the bundle's python (it has `jwt` and
`cryptography`). No credentials: the key lives in memory, or in the folder the flow script names, and is thrown away.

    as a module   issuer = Issuer(); issuer.start(); tok = issuer.mint(aud=..., sub=...); issuer.stop()
    as a program  oauth_issuer.py serve <port> <folder>     serve until killed; writes <folder>/key.pem
                  oauth_issuer.py mint <port> <folder> <aud> <sub> [--client-id X] [--scope S] [--exp N] [--iss URL]
                                [--alg A] [--kid K] [--nokid]    prints one token
"""
from __future__ import annotations

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

SCOPE = "facilitator:participate"


def new_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def jwk_of(key, kid: str, alg: str = "RS256") -> dict:
    d = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    return {**d, "kid": kid, "use": "sig", "alg": alg}


class Issuer:
    """An issuer on 127.0.0.1: serves /.well-known/openid-configuration and /jwks; mints tokens with `mint`."""

    def __init__(self, port: int = 0, key=None, kid: str = "k1", discovery: bool = True):
        self.key, self.kid = key or new_key(), kid
        self.keys = {kid: self.key}              # more can be added (a rotation)
        self.discovery = discovery
        self.fail_jwks = False
        self.jwks_hits = 0
        self.port = port
        self.srv = None

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def jwks_url(self) -> str:
        return f"{self.url}/jwks"

    def jwks(self) -> dict:
        return {"keys": [jwk_of(k, kid) for kid, k in self.keys.items()]}

    def start(self):
        me = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):          # noqa: D401, ANN002
                pass

            def do_GET(self):                    # noqa: N802
                if self.path == "/jwks":
                    me.jwks_hits += 1
                    if me.fail_jwks:
                        self.send_response(500)
                        self.end_headers()
                        return
                    body = me.jwks()
                elif self.path in ("/.well-known/openid-configuration", "/.well-known/oauth-authorization-server") and me.discovery:
                    body = {"issuer": me.url, "jwks_uri": me.jwks_url, "token_endpoint": me.url + "/token",
                            "authorization_endpoint": me.url + "/authorize"}
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                raw = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        return self

    def stop(self):
        if self.srv:
            self.srv.shutdown()
            self.srv.server_close()

    def mint(self, aud, sub="alice", scope=SCOPE, exp_in=600, iss=None, alg="RS256", kid="__own__", client_id="claude-web",
             key=None, extra=None, now=None, scope_claim="scope") -> str:
        t = int(now if now is not None else time.time())
        claims = {"iss": iss or self.url, "sub": sub, "aud": aud, "iat": t, "exp": t + exp_in, "client_id": client_id,
                  **(extra or {})}
        if scope is not None:
            claims[scope_claim] = scope
        headers = {} if kid is None else {"kid": self.kid if kid == "__own__" else kid}
        return jwt.encode(claims, key or self.key, algorithm=alg, headers=headers)


def forge_none(claims: dict) -> str:
    """A token with `alg: none` and no signature, written by hand (the library will not encode one)."""
    import base64

    def b(x):
        return base64.urlsafe_b64encode(json.dumps(x).encode()).rstrip(b"=").decode()
    return f"{b({'alg': 'none', 'typ': 'JWT'})}.{b(claims)}."


def _main(argv):
    cmd, port, folder = argv[1], int(argv[2]), Path(argv[3])
    keyfile = folder / "key.pem"
    if cmd == "serve":
        key = new_key()
        folder.mkdir(parents=True, exist_ok=True)
        keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        keyfile.chmod(0o600)
        iss = Issuer(port, key).start()
        (folder / "ready").write_text(iss.url)
        threading.Event().wait()
        return 0
    if cmd == "mint":
        opts = {"client_id": "claude-web", "scope": SCOPE, "exp": "600", "alg": "RS256", "kid": "k1", "iss": None}
        rest = argv[6:]
        nokid = "--nokid" in rest
        i = 0
        while i < len(rest):
            if rest[i].startswith("--") and rest[i] != "--nokid":
                opts[rest[i][2:].replace("-", "_")] = rest[i + 1]
                i += 2
            else:
                i += 1
        key = serialization.load_pem_private_key(keyfile.read_bytes(), None)
        iss = Issuer(port, key)
        if opts["alg"] == "none":
            import time as _t
            print(forge_none({"iss": opts["iss"] or iss.url, "sub": argv[5], "aud": argv[4], "exp": int(_t.time()) + 600, "scope": opts["scope"]}))
            return 0
        print(iss.mint(argv[4], argv[5], scope=opts["scope"] or None, exp_in=int(opts["exp"]), iss=opts["iss"], alg=opts["alg"],
                       kid=None if nokid else opts["kid"], client_id=opts["client_id"]))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
