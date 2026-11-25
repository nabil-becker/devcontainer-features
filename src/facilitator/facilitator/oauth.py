"""The node as an OAuth 2.1 resource server (slice N5b; ADR-0070 decisions 1, 2 and 5 to 8, ruling PB3).

A cloud AI (claude.ai custom connector, another vendor's hosted assistant) reaches the endpoint with an access token
that an authorization server of the person's choice issued. The node hosts no authorization server: it accepts a JWT
access token from an issuer in the allow list `facilitator.http.issuers` and checks, in this order,

    the issuer         `iss` is exactly an allow-listed issuer's URL (the token is read unverified only to find that)
    the algorithm      the entry's `algorithms` (default RS256 and ES256); `none` and every HS* are never accepted
    the signature      by a key in the issuer's JWKS, found by `kid` (the JWKS is fetched over HTTPS, kept an hour,
                       re-read at most once a minute when a `kid` is unknown; a fetch that fails refuses the token)
    exp, nbf, iat      with 30 s leeway; `exp`, `iss`, `aud` and `sub` must be there
    the audience       RFC 8707: `aud` names this node's resource URL (https://<host>/mcp), or the entry's `audience`
    the scope          `facilitator:participate` (or the entry's `scope`), in `scope` or `scp`

and returns who it was: (issuer, subject, the OAuth client). A client of the node is the pair (issuer, subject), see
`clients.oauth_handle`. Nothing here keeps a token. The `jwt` library (PyJWT, with `cryptography`) is imported only
when a token is checked: a node without issuers never needs it. Only JWKS and discovery documents are fetched, and
only from the issuer's own HTTPS addresses (http only for a loopback host, for tests), without redirects, in at most
256 KiB, in five seconds.
"""
from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from . import clients as clients_mod

JWKS_TTL = 3600          # keys are kept this long
JWKS_RETRY = 60          # an unknown kid re-reads the set, at most this often
FETCH_TIMEOUT = 5
FETCH_MAX = 256 * 1024
MAX_TOKEN = 8192
LEEWAY = 30


class OAuthError(Exception):
    """A token that is refused. `code` is the RFC 6750 error (invalid_token, insufficient_scope); `why` is for the node's
    log and `check`, never for the client (the answer carries the code only). `server` is True when the fault is the
    node's or its issuer's (a JWKS that cannot be read), not the token's: the answer is then 503, and it is not
    counted against the caller's address."""

    def __init__(self, code: str, why: str, server: bool = False):
        super().__init__(why)
        self.code, self.why, self.server = code, why, server


@dataclass
class Principal:
    """Who a verified token names."""
    issuer_name: str
    issuer: str
    subject: str
    client_id: str
    scopes: list[str]
    expires_at: int


@dataclass
class _Keys:
    keys: dict = field(default_factory=dict)      # kid -> PyJWK
    anon: list = field(default_factory=list)      # keys with no kid
    fetched: float = 0.0
    tried: float = 0.0
    uri: str = ""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):          # noqa: D401, ANN002
        return None


def _get_json(url: str, what: str, insecure: bool = False) -> dict:
    """One JSON document over HTTPS (or loopback HTTP; any plain http:// when `insecure`, http.insecure: a local machine or a
    test environment), no redirects, bounded; every failure is said in words."""
    from .participants import _http_url, _https_or_loopback
    if not (_https_or_loopback(url) or (insecure and _http_url(url))):
        raise OAuthError("invalid_token", f"{what} {url}: not an https:// address", server=True)
    op = urllib.request.build_opener(_NoRedirect)
    try:
        with op.open(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=FETCH_TIMEOUT) as r:
            raw = r.read(FETCH_MAX + 1)
    except urllib.error.HTTPError as e:
        raise OAuthError("invalid_token", f"{what} {url}: the server answered {e.code}", server=True) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        raise OAuthError("invalid_token", f"{what} {url}: cannot be read ({reason})", server=True) from None
    if len(raw) > FETCH_MAX:
        raise OAuthError("invalid_token", f"{what} {url}: more than {FETCH_MAX // 1024} KiB", server=True)
    try:
        d = json.loads(raw)
    except ValueError:
        raise OAuthError("invalid_token", f"{what} {url}: not JSON", server=True) from None
    if not isinstance(d, dict):
        raise OAuthError("invalid_token", f"{what} {url}: not a JSON object", server=True)
    return d


class Verifier:
    """The allow list of issuers, their keys, and the check of one token. Thread-safe (the endpoint calls it from worker
    threads); `clock` and `fetch` are there for the tests."""

    def __init__(self, issuers, resource: str, clock=time.time, fetch=None, insecure: bool = False):
        self.issuers = {i.issuer: i for i in issuers}
        self.resource = resource
        self.clock = clock
        # insecure (http.insecure): a jwks_uri or discovery document may be plain http on any host, e.g. the issuer's
        # in-cluster service while the issuer URL the browser sees is localhost
        self.fetch = fetch or (lambda url, what: _get_json(url, what, insecure=insecure))
        self.cache: dict[str, _Keys] = {}
        self.lock = threading.Lock()

    # ------------------------------------------------------------ the keys

    def jwks_uri(self, i) -> str:
        """The entry's jwks_uri, else the one its discovery document names (OIDC, then RFC 8414); the document must
        name this issuer."""
        if i.jwks_uri:
            return i.jwks_uri
        base = i.issuer.rstrip("/")
        last = ""
        for url in (f"{base}/.well-known/openid-configuration", f"{base}/.well-known/oauth-authorization-server"):
            try:
                d = self.fetch(url, f"issuer {i.name}: discovery document")
            except OAuthError as e:
                last = e.why
                continue
            if d.get("issuer") != i.issuer:
                raise OAuthError("invalid_token", f"issuer {i.name}: its discovery document {url} names the issuer "
                                 f"{d.get('issuer')!r}, not {i.issuer}", server=True)
            if not d.get("jwks_uri"):
                raise OAuthError("invalid_token", f"issuer {i.name}: its discovery document {url} has no jwks_uri; "
                                 "set jwks_uri in facilitator.yml", server=True)
            return str(d["jwks_uri"])
        raise OAuthError("invalid_token", f"issuer {i.name}: no discovery document ({last}); set jwks_uri in facilitator.yml "
                         "or fix the issuer URL", server=True)

    def load(self, i, force: bool = False) -> _Keys:
        """The issuer's keys, from the cache or read now. A failed read leaves the cache as it was and raises."""
        import jwt
        with self.lock:
            now = self.clock()
            k = self.cache.get(i.issuer)
            if k and not force and now - k.fetched < JWKS_TTL:
                return k
            if k and force and now - k.tried < JWKS_RETRY:
                return k
            if k:
                k.tried = now
        try:
            uri = (k.uri if k and k.uri else None) or self.jwks_uri(i)
            doc = self.fetch(uri, f"issuer {i.name}: JWKS")
            keys, anon = {}, []
            for jk in doc.get("keys", []) if isinstance(doc.get("keys"), list) else []:
                try:
                    pk = jwt.PyJWK(jk)
                except Exception:                    # noqa: BLE001 - a key this library cannot use is not ours to use
                    continue
                (keys.__setitem__(pk.key_id, pk) if pk.key_id else anon.append(pk))
            if not keys and not anon:
                raise OAuthError("invalid_token", f"issuer {i.name}: its JWKS {uri} holds no usable key", server=True)
        except OAuthError as e:
            if k and not force and now - k.fetched >= JWKS_TTL:
                self.cache.pop(i.issuer, None)         # stale and unreadable: refused until it can be read
            raise e
        with self.lock:
            fresh = _Keys(keys, anon, now, now, uri)
            self.cache[i.issuer] = fresh
            return fresh

    def check_reachable(self, i) -> tuple[bool, str]:
        """For `facilitator http issuers`: fetch this issuer's keys now; (ok, a sentence)."""
        try:
            k = self.load(i, force=False)
        except OAuthError as e:
            return False, e.why
        except ImportError as e:
            return False, f"the jwt library is not installed here ({e}); the node bundle carries it"
        return True, f"JWKS {k.uri}: {len(k.keys) + len(k.anon)} key(s), algorithms {', '.join(i.algorithms)}"

    # ------------------------------------------------------------ one token

    def verify(self, token: str) -> Principal:
        try:
            import jwt
        except ImportError as e:
            raise OAuthError("invalid_token", f"the jwt library is not installed here ({e})", server=True) from None
        if not token or len(token) > MAX_TOKEN or token.count(".") != 2:
            raise OAuthError("invalid_token", "not a JWT")
        try:
            unverified = jwt.decode(token, options={"verify_signature": False})
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError:
            raise OAuthError("invalid_token", "not a readable JWT") from None
        iss = unverified.get("iss")
        i = self.issuers.get(iss) if isinstance(iss, str) else None
        if i is None:
            raise OAuthError("invalid_token", f"the issuer {str(iss)[:100]!r} is not in http.issuers")
        alg = header.get("alg")
        if alg not in i.algorithms:                     # catches none and HS* before any key is touched
            raise OAuthError("invalid_token", f"the algorithm {str(alg)[:20]!r} is not accepted for issuer {i.name}")
        kid = header.get("kid")
        keys = self.load(i)
        key = self._pick(keys, kid)
        if key is None and kid:                         # a rotated key: one re-read (rate limited)
            key = self._pick(self.load(i, force=True), kid)
        if key is None:
            raise OAuthError("invalid_token", f"no key {str(kid)[:40]!r} in issuer {i.name}'s JWKS")
        aud = i.audience or self.resource
        try:
            claims = jwt.decode(token, key.key, algorithms=[alg], audience=aud, issuer=i.issuer, leeway=LEEWAY,
                                options={"require": ["exp", "iss", "aud", "sub"]})
        except jwt.ExpiredSignatureError:
            raise OAuthError("invalid_token", "the token has expired") from None
        except jwt.InvalidAudienceError:
            raise OAuthError("invalid_token", f"the token's audience is not this node's resource {aud} (RFC 8707)") from None
        except jwt.PyJWTError as e:
            raise OAuthError("invalid_token", f"{type(e).__name__}: {str(e)[:100]}") from None
        sub = claims["sub"]
        if not isinstance(sub, str) or not sub or len(sub) > 200:
            raise OAuthError("invalid_token", "sub: a non-empty string of at most 200 characters")
        scopes = _scopes(claims)
        need = i.scope or clients_mod.SCOPE
        if need not in scopes:
            raise OAuthError("insufficient_scope", f"the token has no scope {need} (it has: {', '.join(scopes) or 'none'})")
        cid = claims.get("client_id") or claims.get("azp") or ""
        return Principal(i.name, i.issuer, sub, str(cid)[:200], scopes, int(claims["exp"]))

    @staticmethod
    def _pick(k: _Keys, kid):
        if kid:
            return k.keys.get(kid)
        everything = list(k.keys.values()) + k.anon
        return everything[0] if len(everything) == 1 else None


def _scopes(claims: dict) -> list[str]:
    out: list[str] = []
    for name in ("scope", "scp"):
        v = claims.get(name)
        if isinstance(v, str):
            out += v.split()
        elif isinstance(v, list):
            out += [x for x in v if isinstance(x, str)]
    return out


def metadata(resource: str, issuers, scope: str = clients_mod.SCOPE) -> dict:
    """RFC 9728 protected-resource metadata: this node's resource and the authorization servers that may issue for it."""
    return {"resource": resource, "authorization_servers": [i.issuer for i in issuers],
            "scopes_supported": sorted({scope, *(i.scope for i in issuers if i.scope)}),
            "bearer_methods_supported": ["header"], "resource_name": "facilitator node"}


def challenge(metadata_url: str, error: str | None = None, scope: str | None = None) -> bytes:
    """The WWW-Authenticate value: Bearer with resource_metadata (RFC 9728), and the RFC 6750 error when a token was
    sent and refused; no description (the reason stays in the node's log)."""
    parts = []
    if error:
        parts.append(f'error="{error}"')
    if scope:
        parts.append(f'scope="{scope}"')
    parts.append(f'resource_metadata="{metadata_url}"')
    return ("Bearer " + ", ".join(parts)).encode()
