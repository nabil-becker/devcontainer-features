"""The identity module (proposal facilitator-node, section 5; ADR-0069): a node's certificate in each trust
domain it belongs to, the domains' trust bundles, the node's card, join tokens and the hub's issuer.

Certificates are ed25519 X.509 files with a URI SAN `spiffe://<domain>/node/<id>` and a DNS SAN equal to the
`server_name` its dialers use, `CA:false`, server and client auth (spike 2's shape). They are issued by an
OpenBao PKI per domain (the hub's; the root CA offline, an intermediate in OpenBao), or, for the node's own
home domain `<id>.local`, by a CA the node makes itself. SLIM reads its TLS key from a file, so a node's
certificate key is a file in the state volume, mode 600 (the written exception of ADR-0069 decision 4, which
the 0.1.0 key fallback set the pattern for). Every operation is the `openssl` command (it comes with
ca-certificates on Debian): Python's standard library has no X.509 parser.

    mesh/certs/<domain>/node.key  node.pem  bundle.pem    the node's key, certificate, the domain's trust bundle
    mesh/ca/                                               the home domain's self-issued CA (key mode 600)
    mesh/cards/<node>.json                                 other nodes' cards, as the hub served them
    mesh/invites.json                                      a hub's join tokens: hashed, 15 minutes, single use
    mesh/roster.json                                       a hub's roster: the nodes it issued for, revoked or not
    mesh/secret                                            the mesh's SLIM app secret (the hub makes it, a join hands it over)
    mesh/ca/<domain>/                                      a CA this node keeps for a domain it issues in (a peer's own, a public one)
    mesh/requests.json                                     public join requests: a key, waiting for a person's approval (slice N5a)

A participant entry of a card may carry an opaque `badge` (ruling ID2, AGNTCY Identity, slice N5a): a string the card's
signature covers and lock two ignores; a later slice verifies it (see the NOTES, "Agent badges").

A **card** is how a node says who it is and which of its participants the mesh may reach: its certificate,
its facilitator's packet key, and each participant exposed at least as wide as its domain's level, with its
packet key; signed with the node's certificate key. Lock two (mesh.Mesh.admit) runs on the certificate, and
the card's signature binds the packet keys to that certificate: a packet's SPIFFE ID comes from its signer's
key and this roster of cards (proposal 5.2's fallback, an issuer-vouched binding instead of one key)."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import cabuild
from . import mesh as mesh_mod

TOKEN_SECONDS = 15 * 60
TOKEN_PREFIX = "fj1."


class IdentityError(RuntimeError):
    pass


def _openssl() -> str:
    p = shutil.which("openssl")
    if not p:
        raise IdentityError("openssl is not installed (it comes with ca-certificates; apt-get install openssl)")
    return p


def _run(args: list[str], stdin: bytes | None = None, check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run([_openssl(), *args], input=stdin, capture_output=True, timeout=30)
    if check and r.returncode != 0:
        raise IdentityError(f"openssl {args[0]}: {r.stderr.decode(errors='replace').strip().splitlines()[-1:] or ['failed']}")
    return r


def _private(path: Path, data: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".w-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data.encode() if isinstance(data, str) else data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical(d: dict) -> bytes:
    return json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def pem_blocks(text: str) -> list[str]:
    return re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", text or "", re.S)


# ---------------------------------------------------------------- keys, requests, certificates

def new_key(path: Path) -> None:
    r = _run(["genpkey", "-algorithm", "ed25519"])
    _private(path, r.stdout)


def csr(key: Path, cn: str) -> str:
    return _run(["req", "-new", "-key", str(key), "-subj", f"/CN={cn}"]).stdout.decode()


def cert_info(pem: str) -> dict:
    """{uris, dns, not_before, not_after (epoch seconds), serial, raw_key (32 bytes, ed25519), key_type}."""
    first = (pem_blocks(pem) or [pem])[0].encode()
    r = _run(["x509", "-noout", "-ext", "subjectAltName", "-startdate", "-enddate", "-serial"], stdin=first)
    out = r.stdout.decode()
    uris = re.findall(r"URI:([^,\s]+)", out)
    dns = re.findall(r"DNS:([^,\s]+)", out)

    def when(label: str) -> float:
        m = re.search(label + r"=(.+)", out)
        return dt.datetime.strptime(m.group(1).strip(), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc).timestamp()

    serial = re.search(r"serial=([0-9A-Fa-f]+)", out).group(1)
    pub = _run(["x509", "-noout", "-pubkey"], stdin=first).stdout.decode()
    der = base64.b64decode("".join(pub.strip().splitlines()[1:-1]))
    key_type = "ed25519" if der.startswith(bytes.fromhex("302a300506032b6570032100")) else "other"
    return {"uris": uris, "dns": dns, "not_before": when("notBefore"), "not_after": when("notAfter"),
            "serial": serial.lower(), "raw_key": der[-32:] if key_type == "ed25519" else der, "key_type": key_type,
            "pubkey_pem": pub}


def ssh_key(raw32: bytes) -> str:
    """The ssh-ed25519 public key line for a raw ed25519 key (how sign-packet names keys)."""
    def s(b: bytes) -> bytes:
        return len(b).to_bytes(4, "big") + b
    return "ssh-ed25519 " + base64.b64encode(s(b"ssh-ed25519") + s(raw32)).decode()


def chain_ok(cert_pem: str, bundle: Path) -> bool:
    """The certificate (the first block; any further blocks are untrusted intermediates) chains to the bundle
    and is valid now."""
    blocks = pem_blocks(cert_pem)
    if not blocks or not Path(bundle).is_file():
        return False
    with tempfile.TemporaryDirectory(prefix="fac-verify-") as t:
        leaf = Path(t) / "leaf.pem"
        leaf.write_text(blocks[0] + "\n")
        args = ["verify", "-CAfile", str(bundle), "-purpose", "any"]
        if len(blocks) > 1:
            (Path(t) / "chain.pem").write_text("\n".join(blocks[1:]) + "\n")
            args += ["-untrusted", str(Path(t) / "chain.pem")]
        r = _run(args + [str(leaf)], check=False)
        return r.returncode == 0


def chain_domain(cert_pem: str, bundles: dict[str, Path]) -> str | None:
    """The trust domain whose bundle the certificate chains to (the "domain whose CA signed it" of lock two),
    or None. When two bundles both verify it (a shared CA), the domain the certificate names wins, else none."""
    ok = [d for d, b in sorted(bundles.items()) if chain_ok(cert_pem, b)]
    if len(ok) == 1:
        return ok[0]
    if len(ok) > 1:
        info = cert_info(cert_pem)
        named = [mesh_mod.parse_id(u) for u in info["uris"]]
        for sid in named:
            if sid and sid.domain in ok:
                return sid.domain
    return None


def sign_bytes(key: Path, data: bytes) -> str:
    with tempfile.TemporaryDirectory(prefix="fac-sign-") as t:
        f = Path(t) / "data"
        f.write_bytes(data)
        r = _run(["pkeyutl", "-sign", "-inkey", str(key), "-rawin", "-in", str(f)])
        return base64.b64encode(r.stdout).decode()


def verify_bytes(pubkey_pem: str, data: bytes, sig_b64: str) -> bool:
    try:
        sig = base64.b64decode(sig_b64, validate=True)
    except (ValueError, TypeError):
        return False
    with tempfile.TemporaryDirectory(prefix="fac-verify-") as t:
        (Path(t) / "data").write_bytes(data)
        (Path(t) / "sig").write_bytes(sig)
        (Path(t) / "pub.pem").write_text(pubkey_pem)
        r = _run(["pkeyutl", "-verify", "-pubin", "-inkey", str(Path(t) / "pub.pem"), "-rawin", "-in",
                  str(Path(t) / "data"), "-sigfile", str(Path(t) / "sig")], check=False)
        return r.returncode == 0


# ---------------------------------------------------------------- the node's files

class Store:
    """The mesh files in the state folder."""

    def __init__(self, home: Path):
        self.root = Path(home) / "mesh"
        self.certs = self.root / "certs"
        self.ca = self.root / "ca"
        self.cards = self.root / "cards"
        self.convs = self.root / "convs"
        self.outbox = self.root / "outbox"
        self.invites = self.root / "invites.json"
        self.requests_file = self.root / "requests.json"
        self.window_file = self.root / "request-window"
        self.rotation_file = self.root / "rotation.json"
        self.roster_file = self.root / "roster.json"
        self.secret_file = self.root / "secret"
        self.status_file = self.root / "status.json"
        self.refused_log = self.root / "refused.log"

    def ensure(self) -> None:
        for d, mode in ((self.root, 0o700), (self.certs, 0o700), (self.ca, 0o700), (self.cards, 0o755),
                        (self.convs, 0o755), (self.outbox, 0o700)):
            d.mkdir(parents=True, exist_ok=True)
            os.chmod(d, mode)

    def dom(self, domain: str) -> Path:
        return self.certs / domain

    def key(self, domain: str) -> Path:
        return self.dom(domain) / "node.key"

    def cert(self, domain: str) -> Path:
        return self.dom(domain) / "node.pem"

    def bundle(self, domain: str) -> Path:
        return self.dom(domain) / "bundle.pem"

    def bundles(self, trust: dict[str, str], level: str | None = None) -> dict[str, Path]:
        """{domain: bundle file} of the domains in trust (of one level when given) that have a bundle on disk."""
        return {d: self.bundle(d) for d, lv in trust.items() if (level is None or lv == level) and self.bundle(d).is_file()}

    def write_bundle(self, domain: str, pem: str) -> None:
        self.dom(domain).mkdir(parents=True, exist_ok=True)
        os.chmod(self.dom(domain), 0o700)
        (self.bundle(domain)).write_text("\n".join(pem_blocks(pem)) + "\n")

    def mesh_secret(self, create: bool = False) -> str | None:
        try:
            return self.secret_file.read_text().strip() or None
        except OSError:
            if not create:
                return None
        s = secrets.token_urlsafe(36)
        self.ensure()
        _private(self.secret_file, s + "\n")
        return s

    def set_mesh_secret(self, s: str) -> None:
        self.ensure()
        _private(self.secret_file, s.strip() + "\n")

    # ------------------------------------------------------------ the node's certificate in a domain

    def cert_state(self, domain: str) -> dict:
        """{present, id, dns, not_after, half_life_at, expired, renew_due}"""
        p = self.cert(domain)
        if not p.is_file():
            return {"present": False}
        info = cert_info(p.read_text())
        life = info["not_after"] - info["not_before"]
        now = time.time()
        return {"present": True, "id": (info["uris"] or [""])[0], "dns": info["dns"], "serial": info["serial"],
                "not_after": info["not_after"], "half_life_at": info["not_before"] + life / 2,
                "expired": now >= info["not_after"], "renew_due": now >= info["not_before"] + life / 2}

    # ------------------------------------------------------------ the home domain's own CA (ADR-0069 decision 4)

    def ensure_local_ca(self, home_domain: str) -> Path:
        cap, cak = self.ca / "ca.pem", self.ca / "ca.key"
        if cap.is_file() and cak.is_file():
            return cap
        self.ensure()
        new_key(cak)
        r = _run(["req", "-x509", "-new", "-key", str(cak), "-subj", f"/O={home_domain}/CN={home_domain} local CA",
                  "-days", "3650", "-addext", "basicConstraints=critical,CA:true,pathlen:0",
                  "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                  "-addext", f"nameConstraints=critical,permitted;DNS:{home_domain}"])
        cap.write_bytes(r.stdout)
        return cap

    def issue_local(self, home_domain: str, node_id: str, dns: str) -> None:
        """The node's certificate in its home domain, from its own CA (24 h)."""
        ca = self.ensure_local_ca(home_domain)
        d = home_domain
        self.dom(d).mkdir(parents=True, exist_ok=True)
        if not self.key(d).is_file():
            new_key(self.key(d))
        req = csr(self.key(d), dns)
        with tempfile.TemporaryDirectory(prefix="fac-ca-") as t:
            (Path(t) / "req.csr").write_text(req)
            (Path(t) / "ext").write_text(
                "basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                f"extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:{dns},URI:spiffe://{d}/node/{node_id}\n")
            r = _run(["x509", "-req", "-in", str(Path(t) / "req.csr"), "-CA", str(ca), "-CAkey", str(self.ca / "ca.key"),
                      "-days", "1", "-extfile", str(Path(t) / "ext"), "-set_serial", "0x" + secrets.token_hex(8)])
        self.cert(d).write_bytes(r.stdout)
        self.write_bundle(d, ca.read_text())


# ---------------------------------------------------------------- cards

def make_card(store: Store, domain: str, node_id: str, facilitator_key: str, participants: list[dict]) -> dict:
    """This node's card in a domain, signed with its certificate key. `participants`: [{handle, key, kind,
    exposure, description?, skills?, cid?}] already filtered to those the domain's level may reach."""
    pem = store.cert(domain).read_text()
    body = {"v": 1, "node": node_id, "domain": domain, "id": f"spiffe://{domain}/node/{node_id}", "cert": pem,
            "facilitator": facilitator_key, "participants": sorted(participants, key=lambda p: p["handle"]),
            "at": now_utc()}
    return {**body, "sig": sign_bytes(store.key(domain), canonical(body))}


def check_card(card: dict, m: "mesh_mod.Mesh", bundles: dict[str, Path], revoked=frozenset()) -> tuple[bool, str, str]:
    """Lock two on a card: (admitted, level, why). The certificate chains to a domain's bundle, its ID's domain
    is that domain (else: an impostor), the domain is trusted at a level within the preset, the node is not
    revoked, the card's node and ID agree with the certificate, and the card is signed by the certificate's key."""
    if not isinstance(card, dict) or card.get("v") != 1 or not isinstance(card.get("cert"), str):
        return False, "", "not a card"
    try:
        info = cert_info(card["cert"])
    except IdentityError as e:
        return False, "", f"its certificate cannot be read: {e}"
    ca_domain = chain_domain(card["cert"], bundles)
    claimed = (info["uris"] or [""])[0]
    ok, level, why = m.admit(claimed, ca_domain, revoked)
    if not ok:
        return False, "", why
    sid = mesh_mod.parse_id(claimed)
    if sid.handle or card.get("id") != claimed or card.get("node") != sid.node or card.get("domain") != sid.domain:
        return False, "", f"the card names {card.get('id')!r}, its certificate {claimed}"
    body = {k: v for k, v in card.items() if k != "sig"}
    if not verify_bytes(info["pubkey_pem"], canonical(body), card.get("sig", "")):
        return False, "", "the card's signature is not its certificate key's"
    for p in card.get("participants", []):
        if not mesh_mod.HANDLE_RE.fullmatch(str(p.get("handle", ""))) or p.get("exposure") not in mesh_mod.LEVELS:
            return False, "", f"a participant entry is malformed: {p!r}"
        if "badge" in p and not (isinstance(p["badge"], str) and len(p["badge"]) <= 8192):
            return False, "", f"a participant's badge is malformed (an opaque string up to 8 KiB): {p.get('handle')}"
        if not mesh_mod.reach_ok(level, p["exposure"]):
            return False, "", f"the card lists {p['handle']} exposed {p['exposure']}, narrower than {level}"
    return True, level, why


def sign_envelope(store: Store, domain: str, body: dict) -> dict:
    return {**body, "sig": sign_bytes(store.key(domain), canonical(body))}


def check_envelope(env: dict, card: dict) -> bool:
    """An envelope's signature by the key of the (already admitted) card of the node it says it is from."""
    try:
        info = cert_info(card["cert"])
    except (IdentityError, KeyError):
        return False
    body = {k: v for k, v in env.items() if k != "sig"}
    return env.get("from") == card.get("node") and verify_bytes(info["pubkey_pem"], canonical(body), env.get("sig", ""))


# ---------------------------------------------------------------- join tokens (a hub's; proposal 5.3)

def _invites(store: Store) -> list[dict]:
    try:
        return json.loads(store.invites.read_text())
    except (OSError, ValueError):
        return []


def make_token(store: Store, join_addr: str, hub_name: str, bundle_pem: str, now: float | None = None,
               seconds: int = TOKEN_SECONDS) -> str:
    """A single-use join token valid for 15 minutes: the join endpoint, the hub's DNS name, a secret (stored
    hashed) and the SHA-256 of the domain's trust bundle, so the joining node checks it before it trusts the
    hub's certificate (no trust on first use)."""
    now = time.time() if now is None else now
    s = secrets.token_urlsafe(24)
    tid = secrets.token_hex(4)
    rows = [r for r in _invites(store) if r["expires"] > now]      # a used one is kept until it expires: "used already"
    rows.append({"id": tid, "hash": hashlib.sha256(s.encode()).hexdigest(), "expires": now + seconds, "used": False,
                 "made": now})
    store.ensure()
    _private(store.invites, json.dumps(rows, indent=2) + "\n")
    payload = {"j": join_addr, "n": hub_name, "i": tid, "s": s, "b": hashlib.sha256(bundle_pem.encode()).hexdigest()}
    return TOKEN_PREFIX + base64.urlsafe_b64encode(canonical(payload)).decode().rstrip("=")


def parse_token(token: str) -> dict:
    t = (token or "").strip()
    if not t.startswith(TOKEN_PREFIX):
        raise IdentityError("not a join token (it starts with fj1.)")
    raw = t[len(TOKEN_PREFIX):]
    try:
        d = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, TypeError):
        raise IdentityError("a damaged join token") from None
    if not {"j", "n", "i", "s", "b"} <= set(d):
        raise IdentityError("a damaged join token")
    return d


def live_tokens(store: Store, now: float | None = None) -> int:
    now = time.time() if now is None else now
    return sum(1 for r in _invites(store) if r["expires"] > now and not r["used"])


def consume_token(store: Store, tid: str, secret: str, now: float | None = None) -> tuple[bool, str]:
    """(ok, why). Single use: a used token is refused, so is an expired one; the comparison is constant time."""
    now = time.time() if now is None else now
    rows = _invites(store)
    for r in rows:
        if r["id"] != tid:
            continue
        if not hmac.compare_digest(r["hash"], hashlib.sha256((secret or "").encode()).hexdigest()):
            return False, "the token is not one this hub made"
        if r["used"]:
            return False, "the token was used already (a join token is single use)"
        if r["expires"] <= now:
            return False, "the token expired (a join token lasts 15 minutes)"
        r["used"] = True
        r["used_at"] = now
        _private(store.invites, json.dumps(rows, indent=2) + "\n")
        return True, "ok"
    return False, "the token is not one this hub made"


# ---------------------------------------------------------------- the hub's roster

def roster(store: Store) -> dict:
    try:
        return json.loads(store.roster_file.read_text())
    except (OSError, ValueError):
        return {"nodes": {}}


def save_roster(store: Store, r: dict) -> None:
    store.ensure()
    _private(store.roster_file, json.dumps(r, indent=2, sort_keys=True) + "\n")


def revoked(r: dict) -> set[str]:
    return {n for n, v in r.get("nodes", {}).items() if v.get("revoked")}


# ---------------------------------------------------------------- the hub's issuer: OpenBao PKI over HTTP

class Issuer:
    """The OpenBao PKI of a hub's domain (ADR-0069): it signs a node's request with the SANs the hub decides
    (never the requester), for svid_ttl. Login: an AppRole from the file node.issuer.approle (lines
    role_id=..., secret_id=...), or a token in FACILITATOR_OPENBAO_TOKEN (tests). OpenBao must be unsealed
    by hand after each start (ADR-0048): while it is sealed no certificate is issued or renewed."""

    def __init__(self, cfg: dict, environ: dict | None = None):
        env = os.environ if environ is None else environ
        self.addr = (cfg.get("openbao") or env.get("BAO_ADDR") or "http://127.0.0.1:8200").rstrip("/")
        self.mount = cfg.get("mount") or "pki"
        self.role = cfg.get("role") or "node"
        self.kv = cfg.get("kv") or "secret"
        self.approle = cfg.get("approle")
        self.domain = cfg["domain"]
        self._token = env.get("FACILITATOR_OPENBAO_TOKEN") or None

    def _call(self, method: str, path: str, body: dict | None = None, token: bool = True, raw: bool = False):
        req = urllib.request.Request(f"{self.addr}/v1/{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("X-Vault-Token", self.token())
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if e.code == 503:
                raise IdentityError("OpenBao is sealed (unseal it by hand: bao operator unseal)") from None
            raise IdentityError(f"OpenBao {path}: HTTP {e.code} {detail}") from None
        except (urllib.error.URLError, OSError) as e:
            raise IdentityError(f"OpenBao at {self.addr} is not reachable: {e}") from None
        return data.decode() if raw else (json.loads(data) if data else {})

    def token(self) -> str:
        if self._token:
            return self._token
        if not self.approle:
            raise IdentityError("no OpenBao login: node.issuer.approle names a file with role_id= and secret_id= lines")
        vals = {}
        try:
            text = Path(self.approle).read_text()
        except OSError as e:
            raise IdentityError(f"no OpenBao login: the AppRole file {self.approle} cannot be read ({e.strerror or e}); "
                                "the Operator writes it (role_id= and secret_id= lines) after creating the hub's AppRole") from None
        for line in text.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
        r = self._call("POST", "auth/approle/login", {"role_id": vals.get("role_id"), "secret_id": vals.get("secret_id")},
                       token=False)
        self._token = r["auth"]["client_token"]
        return self._token

    def sealed(self) -> bool | None:
        try:
            return bool(self._call("GET", "sys/seal-status", token=False).get("sealed"))
        except IdentityError:
            return None

    def bundle(self) -> str:
        """The domain's trust bundle: the CA chain OpenBao holds (the intermediate and the offline root, imported
        together). SLIM sends only the first certificate of a file, so a dialer's bundle carries the intermediate."""
        d = self._call("GET", f"{self.mount}/cert/ca_chain", token=False)
        pem = (d.get("data") or {}).get("ca_chain") or (d.get("data") or {}).get("certificate") or ""
        if not pem_blocks(pem):
            raise IdentityError(f"OpenBao {self.mount}: no CA chain (import the intermediate with its root)")
        return pem

    def sign(self, request_pem: str, node_id: str, dns: str, ttl_seconds: int) -> dict:
        d = self._call("POST", f"{self.mount}/sign/{self.role}", {
            "csr": request_pem, "common_name": dns, "alt_names": dns, "uri_sans": f"spiffe://{self.domain}/node/{node_id}",
            "ttl": f"{ttl_seconds}s", "format": "pem"})["data"]
        return {"cert": d["certificate"], "chain": "\n".join(d.get("ca_chain") or [d.get("issuing_ca", "")]),
                "serial": d.get("serial_number", "")}

    def revoke(self, serial: str) -> None:
        self._call("POST", f"{self.mount}/revoke", {"serial_number": serial})

    def backup_roster(self, r: dict) -> None:
        """The hub's roster into OpenBao's KV, so its snapshot carries it (ruling BH)."""
        self._call("POST", f"{self.kv}/data/facilitator/mesh/roster", {"data": {"roster": json.dumps(r, sort_keys=True)}})

    def restore_roster(self) -> dict:
        d = self._call("GET", f"{self.kv}/data/facilitator/mesh/roster")
        return json.loads(d["data"]["data"]["roster"])



# ---------------------------------------------------------------- an issuer a node keeps itself (slice N5a)

def _stamp(t: float) -> str:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y%m%d%H%M%SZ")


class LocalIssuer:
    """A CA this node keeps for a domain it issues in: a peer's own domain (its own certificate, and what it needs to
    be dialled) and the public domain a node issues for (1 h certificates, after a person approves a join request,
    ruling AH). The CA key is a file in the state volume, mode 600, and the CA certificate is constrained to DNS
    names (the domain's and the issuing node's), not to URIs: rustls-webpki, which SLIM uses, refuses a chain with a URI name
    constraint (NameConstraintViolation, found running slice N5a), so the SPIFFE ID's domain is checked by lock two alone. It has the same face as the OpenBao
    Issuer: sign, bundle, revoke. Short lifetimes are the revocation (proposal 12.2); no CRL exists across SLIM's
    checks. A lifetime under a day needs OpenSSL 3.4 or later (x509 -not_after)."""

    def __init__(self, store: Store, domain: str, dns: tuple = ()):
        self.store = store
        self.domain = domain
        self.dns = tuple(dns)            # DNS names its certificates may carry besides the domain's (the issuing node's name)
        self.dir = store.ca / domain
        self.ca_pem, self.ca_key = self.dir / "ca.pem", self.dir / "ca.key"

    def ensure(self) -> Path:
        if self.ca_pem.is_file() and self.ca_key.is_file():
            return self.ca_pem
        self.store.ensure()
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        new_key(self.ca_key)
        r = _run(["req", "-x509", "-new", "-key", str(self.ca_key), "-subj", f"/O={self.domain}/CN={self.domain} CA",
                  "-days", "3650", "-addext", "basicConstraints=critical,CA:true,pathlen:0",
                  "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                  "-addext", "nameConstraints=critical," + ",".join(
                      f"permitted;DNS:{d}" for d in dict.fromkeys((self.domain, *self.dns)))])
        self.ca_pem.write_bytes(r.stdout)
        return self.ca_pem

    def bundle(self) -> str:
        return self.ensure().read_text()

    def sign(self, request_pem: str, node_id: str, dns: str, ttl_seconds: int) -> dict:
        ca = self.ensure()
        serial = secrets.token_hex(8)
        now = time.time()
        with tempfile.TemporaryDirectory(prefix="fac-ca-") as t:
            (Path(t) / "req.csr").write_text(request_pem)
            (Path(t) / "ext").write_text(
                "basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                f"extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:{dns},URI:spiffe://{self.domain}/node/{node_id}\n")
            args = ["x509", "-req", "-in", str(Path(t) / "req.csr"), "-CA", str(ca), "-CAkey", str(self.ca_key),
                    "-extfile", str(Path(t) / "ext"), "-set_serial", "0x" + serial,
                    "-not_before", _stamp(now - 5), "-not_after", _stamp(now + ttl_seconds)]
            r = _run(args, check=False)
            if r.returncode != 0:
                err = r.stderr.decode(errors="replace")
                if "Unknown option" in err or "unknown option" in err or "-not_after" in err:
                    raise IdentityError("a certificate with a set lifetime needs OpenSSL 3.4 or later (x509 -not_after); "
                                        "this node has " + (subprocess.run([_openssl(), "version"], capture_output=True,
                                                                           text=True).stdout.strip() or "an older one"))
                raise IdentityError(f"openssl x509: {err.strip().splitlines()[-1:] or ['failed']}")
        return {"cert": r.stdout.decode(), "chain": "", "serial": serial}

    def revoke(self, serial: str) -> None:        # no CRL: the certificate is not renewed and expires (12.2)
        return None

    def backup_roster(self, r: dict) -> None:      # the roster is in this node's state volume
        return None

    def issue_self(self, node_id: str, dns: str, ttl_seconds: int) -> None:
        """This node's own certificate in this domain: its key, a request, and the CA's signature."""
        k = self.store.key(self.domain)
        self.store.dom(self.domain).mkdir(parents=True, exist_ok=True)
        os.chmod(self.store.dom(self.domain), 0o700)
        if not k.is_file():
            new_key(k)
        got = self.sign(csr(k, dns), node_id, dns, ttl_seconds)
        self.store.write_bundle(self.domain, self.bundle())
        self.store.cert(self.domain).write_text(got["cert"])


def agent_socket(cfg: dict, environ: dict | None = None) -> str:
    """node.issuer.ssh_agent.socket: a path, or $SSH_AUTH_SOCK (an environment variable's name after a $)."""
    env = os.environ if environ is None else environ
    sock = str(cfg.get("socket") or "").strip()
    if sock.startswith("$"):
        sock = env.get(sock[1:].strip("{}"), "")
    return sock


class BuiltinIssuer(LocalIssuer):
    """The issuer a hub is when no OpenBao is named (rulings K3, K4, K5; ADR-0078): a CA of its own, DNS-name constrained,
    that needs no unseal. Two shapes, by where the CA key is:

    - **file** (`node.issuer.ssh_agent` absent; the last resort, `check` warns): a *root* (root.pem, root.key) that signed
      one *issuing CA* (ca.pem, ca.key) once; leaves are signed by the issuing CA, and the trust bundle holds both, so
      `facilitator node issuer export-root` can take the root key out of the volume (a person's act) with nothing
      changing for a spoke that has the bundle. A hub built by 0.6.0 has a single CA (ca.pem, ca.key): kept as it is.
    - **ssh-agent** (`node.issuer.ssh_agent: {socket, key}`): the agent's ed25519 key *is* the CA (self-signed root,
      once); no key file exists. Every leaf is one signing round trip to the agent. The key is matched by its SHA256
      fingerprint, never 'the first key'. With the agent gone nothing is issued or renewed and every certificate
      already issued stays valid until it expires.

    Certificates are built by cabuild (the signature is over the TBS bytes, ed25519), so no OpenSSL 3.4 is needed. The
    roster is backed up to a file beside it in the same volume (the OpenBao KV does that for the OpenBao tier)."""

    ROOT_DAYS = 7300
    CA_DAYS = 3650

    def __init__(self, store: Store, domain: str, dns: tuple = (), agent: dict | None = None, environ: dict | None = None):
        super().__init__(store, domain, dns)
        self.agent = agent or None
        self.sock = agent_socket(agent, environ) if agent else ""
        self.root_pem, self.root_key = self.dir / "root.pem", self.dir / "root.key"
        self.backup_file = store.root / "roster.backup.json"

    @property
    def tier(self) -> str:
        return "ssh-agent" if self.agent else "file"

    def _constraints(self) -> list[str]:
        return list(dict.fromkeys((self.domain, *self.dns)))

    def _signer_for_ca(self):
        """The signer of the issuing CA, and what makes it so."""
        try:
            if self.agent:
                return cabuild.agent_signer(self.sock, self.agent.get("key", ""))
            if not self.ca_key.is_file():
                raise IdentityError(f"the issuing CA key {self.ca_key} is missing (restore the volume)")
            return cabuild.file_signer(self.ca_key)
        except cabuild.SignError as e:
            raise IdentityError(str(e)) from None

    def _make(self, signer, issuer_der: bytes | None, subject_o_cn: tuple[str, str], spki: bytes, issuer_spki: bytes | None,
              days: int, pathlen: int) -> str:
        subj = cabuild.name(*subject_o_cn)
        now = time.time()
        exts = [cabuild.ext_basic(True, pathlen), cabuild.ext_key_usage(True), cabuild.ext_dns_constraints(self._constraints()),
                cabuild.ext_ski(spki)]
        if issuer_spki is not None:
            exts.append(cabuild.ext_aki(issuer_spki))
        try:
            return cabuild.build(serial=cabuild.new_serial(), issuer=issuer_der or subj, subject=subj, spki=spki,
                                 not_before=now - 5, not_after=now + days * 86400, exts=exts, sign=signer)
        except cabuild.SignError as e:
            raise IdentityError(str(e)) from None

    def ensure(self) -> Path:
        o, cn = self.domain, f"{self.domain} CA"
        if self.ca_pem.is_file() and (self.agent or self.ca_key.is_file()):
            if self.agent:
                self._check_agent_matches()
            return self.ca_pem
        self.store.ensure()
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        if self.agent:
            try:
                key = cabuild.agent_key(self.sock, self.agent.get("key", ""))
            except cabuild.SignError as e:
                raise IdentityError(str(e)) from None
            spki = cabuild.agent_spki(key)
            pem = self._make(self._signer_for_ca(), None, (o, cn), spki, None, self.ROOT_DAYS, 0)
            self.ca_pem.write_text(pem)
            return self.ca_pem
        # a root, then the issuing CA it signs: the root key is only needed to sign the issuing CA
        new_key(self.root_key)
        root_spki = cabuild.spki_of_pem_pubkey(_run(["pkey", "-in", str(self.root_key), "-pubout"]).stdout.decode())
        root_pem = self._make(cabuild.file_signer(self.root_key), None, (o, f"{self.domain} root CA"), root_spki, None,
                              self.ROOT_DAYS, 1)
        new_key(self.ca_key)
        ca_spki = cabuild.spki_of_pem_pubkey(_run(["pkey", "-in", str(self.ca_key), "-pubout"]).stdout.decode())
        root_subject = cabuild.cert_parts(cabuild.from_pem(root_pem))["subject"]
        ca_pem = self._make(cabuild.file_signer(self.root_key), root_subject, (o, cn), ca_spki, root_spki, self.CA_DAYS, 0)
        self.root_pem.write_text(root_pem)
        self.ca_pem.write_text(ca_pem)
        return self.ca_pem

    def _check_agent_matches(self) -> None:
        """The root on disk must be the agent key's (a root made by another key is not this hub's CA)."""
        try:
            key = cabuild.agent_key(self.sock, self.agent.get("key", ""))
        except cabuild.SignError as e:
            raise IdentityError(str(e)) from None
        if cert_info(self.ca_pem.read_text())["raw_key"] != cabuild.agent_spki(key)[-32:]:
            raise IdentityError(f"the CA certificate {self.ca_pem} is not for the agent key {self.agent.get('key')} "
                                "(node.issuer.ssh_agent.key changed: a new key is a new CA, and every node must join again)")

    def bundle(self) -> str:
        self.ensure()
        return self.ca_pem.read_text() + (self.root_pem.read_text() if self.root_pem.is_file() else "")

    def sign(self, request_pem: str, node_id: str, dns: str, ttl_seconds: int) -> dict:
        ca = self.ensure()
        csr_check(request_pem)
        pub = _run(["req", "-noout", "-pubkey"], stdin=request_pem.encode()).stdout.decode()
        try:
            spki = cabuild.spki_of_pem_pubkey(pub)
        except cabuild.SignError as e:
            raise IdentityError(str(e)) from None
        parts = cabuild.cert_parts(cabuild.from_pem(ca.read_text()))
        now = time.time()
        serial = cabuild.new_serial()
        try:
            pem = cabuild.build(
                serial=serial, issuer=parts["subject"], subject=cabuild.cn_name(dns), spki=spki, not_before=now - 5,
                not_after=now + ttl_seconds,
                exts=[cabuild.ext_basic(False), cabuild.ext_key_usage(False), cabuild.ext_eku(),
                      cabuild.ext_san(dns, f"spiffe://{self.domain}/node/{node_id}"), cabuild.ext_ski(spki),
                      cabuild.ext_aki(parts["spki"])],
                sign=self._signer_for_ca())
        except cabuild.SignError as e:
            raise IdentityError(str(e)) from None
        return {"cert": pem, "chain": "", "serial": f"{serial:x}"}

    def backup_roster(self, r: dict) -> None:
        self.store.ensure()
        _private(self.backup_file, json.dumps(r, sort_keys=True))

    def restore_roster(self) -> dict:
        try:
            return json.loads(self.backup_file.read_text())
        except (OSError, ValueError) as e:
            raise IdentityError(f"no roster backup at {self.backup_file}: {e}") from None

    # ------------------------------------------------------------ what a person does with the built-in CA

    def status(self) -> dict:
        """{tier, ca, root_offline, agent: {...}} for `node issuer status` and check; never a secret."""
        out: dict = {"tier": self.tier, "domain": self.domain, "ca_present": self.ca_pem.is_file()}
        if self.ca_pem.is_file():
            info = cert_info(self.ca_pem.read_text())
            out["ca_expires"] = info["not_after"]
            out["ca_key"] = ssh_key(info["raw_key"]) if info["key_type"] == "ed25519" else "other"
        if self.agent:
            out["agent"] = {"socket": self.sock, "key": self.agent.get("key")}
            try:
                keys = cabuild.agent_identities(self.sock)
                out["agent"].update(reachable=True, holds_key=any(k["fingerprint"] == self.agent.get("key") for k in keys),
                                    other_keys=sum(1 for k in keys if k["fingerprint"] != self.agent.get("key")))
                mine = [k for k in keys if k["fingerprint"] == self.agent.get("key")]
                out["agent"]["key_type"] = mine[0]["type"] if mine else None
            except cabuild.SignError as e:
                out["agent"].update(reachable=False, error=str(e))
        else:
            out["key_file"] = str(self.ca_key)
            out["two_level"] = self.root_pem.is_file()
            out["root_offline"] = self.root_pem.is_file() and not self.root_key.is_file()
        return out

    def export_root(self, out: Path) -> dict:
        """Write the root CA (certificate and key) to a new file at `out`, mode 600, and remove the root key from the volume
        (ruling K4). After it the hub still issues (the issuing CA signs) and the spokes' bundles are unchanged; what the root
        key is still needed for is a new issuing CA, in ten years or after a compromise. Refuses to overwrite a file."""
        if self.agent:
            raise IdentityError("export-root: the CA key is in an ssh-agent; there is no key file to take out")
        self.ensure()
        if not self.root_pem.is_file():
            raise IdentityError("export-root: this hub's CA was made by 0.6.0 with no separate root (the CA key is the only one); "
                                "migrate it to OpenBao, or issue again with a new built-in CA")
        if not self.root_key.is_file():
            raise IdentityError("export-root: the root key is not in this volume any more (taken out already)")
        out = Path(out)
        if out.exists():
            raise IdentityError(f"export-root: {out} exists; name a new file")
        out.parent.mkdir(parents=True, exist_ok=True)
        _private(out, self.root_key.read_text() + self.root_pem.read_text())
        if out.read_text() != self.root_key.read_text() + self.root_pem.read_text():
            raise IdentityError("export-root: the copy does not match; the key was left in the volume")
        self.root_key.unlink()
        return {"file": str(out), "root": str(self.root_pem)}

    def _issuer_is_ours(self, bao: "Issuer", mount: str, issuer_id: str) -> bool:
        """The imported issuer whose certificate is this hub's issuing CA (the import may also bring the root)."""
        d = bao._call("GET", f"{mount}/issuer/{issuer_id}")
        return cert_info((d.get("data") or {}).get("certificate", ""))["serial"] == cert_info(self.ca_pem.read_text())["serial"]

    def migrate_to_openbao(self, bao: "Issuer", token: str, ttl_max: str = "720h") -> dict:
        """Move the issuing CA onto an OpenBao PKI mount, keeping the very same CA (ruling K3): the issuing key and its
        certificate are imported (config/ca) and the node role is made, so the certificates every spoke holds and the
        bundle they trust stay valid and nobody joins again. The key then leaves the volume. Needs a token that may
        configure the mount (the Operator's own; the hub's AppRole may only sign)."""
        if self.agent:
            raise IdentityError("migrate: the CA key is in an ssh-agent and cannot be imported into OpenBao; "
                                "issue the PKI's intermediate from the agent's CA by hand, and every node joins again")
        if not self.ca_key.is_file():
            raise IdentityError("migrate: the issuing CA key is not in this volume")
        bao._token = token
        mount = bao.mount
        bundle_pem = self.ca_key.read_text() + self.ca_pem.read_text() + (self.root_pem.read_text() if self.root_pem.is_file() else "")
        try:
            mounts = bao._call("GET", "sys/mounts")
            if f"{mount}/" not in (mounts.get("data") or mounts):
                bao._call("POST", f"sys/mounts/{mount}", {"type": "pki", "config": {"max_lease_ttl": ttl_max}})
            got = bao._call("POST", f"{mount}/config/ca", {"pem_bundle": bundle_pem})
            ours = [i for i in ((got.get("data") or {}).get("imported_issuers") or [])]
            ca_issuer = next((i for i in ours if self._issuer_is_ours(bao, mount, i)), None)
            if ca_issuer:                    # a mount that had a CA keeps it as the default until told
                bao._call("POST", f"{mount}/config/issuers", {"default": ca_issuer})
            bao._call("POST", f"{mount}/roles/{bao.role}", node_role(self.domain, ttl_max))
            if f"{bao.kv}/" not in (mounts.get("data") or mounts):
                bao._call("POST", f"sys/mounts/{bao.kv}", {"type": "kv", "options": {"version": "2"}})
            # prove it before the key leaves: a throwaway request signed by OpenBao must verify against the bundle
            with tempfile.TemporaryDirectory(prefix="fac-mig-") as t:
                k = Path(t) / "k"
                new_key(k)
                got = bao.sign(csr(k, f"migrate-check.{self.domain}"), "migrate-check", f"migrate-check.{self.domain}", 300)
                (Path(t) / "bundle.pem").write_text(self.bundle())
                if not chain_ok(got["cert"], Path(t) / "bundle.pem"):
                    raise IdentityError("migrate: a certificate OpenBao signed does not chain to the hub's bundle; the key was left in the volume")
        except IdentityError:
            raise
        r = roster(self.store)
        bao.backup_roster(r)
        self.ca_key.unlink()
        return {"mount": mount, "role": bao.role, "nodes": len(r.get("nodes", {}))}


def node_role(domain: str, max_ttl: str = "720h") -> dict:
    """The OpenBao PKI role a hub's signing uses: names under the domain only (ADR-0069), the SANs the hub decides (never
    the request's), ed25519 keys, server and client auth. The same role the openbao:pki:role task writes."""
    return {"allowed_domains": domain, "allow_subdomains": True, "allow_bare_domains": True, "enforce_hostnames": True,
            "allowed_uri_sans": f"spiffe://{domain}/*", "key_type": "ed25519", "server_flag": True, "client_flag": True,
            "key_usage": "DigitalSignature", "ext_key_usage": "ServerAuth,ClientAuth", "use_csr_common_name": False,
            "use_csr_sans": False, "max_ttl": max_ttl, "ttl": "24h", "require_cn": False}


def make_issuer(m: "mesh_mod.Mesh", store: Store, domain: str):
    """The issuer of a domain this node issues in, in the order of ruling K5 (ADR-0078): an OpenBao PKI when
    node.issuer.openbao names one; else an ssh-agent that holds the CA key (node.issuer.ssh_agent); else the node's own CA
    with its key in a file: the built-in one on a hub, the single-level one of a peer or of a public domain."""
    iss = m.node.get("issuer") or {}
    dns = tuple(x for x in (m.node.get("name"),) if x)
    if domain == m.domain and iss.get("openbao"):
        return Issuer({**iss, "domain": domain})
    if domain == m.domain and iss.get("ssh_agent"):
        return BuiltinIssuer(store, domain, dns, agent=iss["ssh_agent"])
    if domain == m.domain and m.role == "hub":
        return BuiltinIssuer(store, domain, dns)
    return LocalIssuer(store, domain, dns)


# ---------------------------------------------------------------- public join requests (a key, then a person's approval)

REQUEST_WINDOW_SECONDS = 15 * 60
MAX_PENDING_REQUESTS = 20


def csr_check(pem: str) -> str:
    """The sha256 of an ed25519 request's public key (what a person approves); refuses anything else, and a
    request whose own signature does not verify (proof of holding the key)."""
    if "BEGIN CERTIFICATE REQUEST" not in (pem or "") or len(pem) > 4096:
        raise IdentityError("not a certificate request")
    r = _run(["req", "-verify", "-noout"], stdin=pem.encode(), check=False)
    if r.returncode != 0:
        raise IdentityError("the request's signature does not verify (it must be signed by the key it carries)")
    pub = _run(["req", "-noout", "-pubkey"], stdin=pem.encode()).stdout.decode()
    der = base64.b64decode("".join(pub.strip().splitlines()[1:-1]))
    if not der.startswith(bytes.fromhex("302a300506032b6570032100")):
        raise IdentityError("the request's key is not ed25519")
    return hashlib.sha256(der[-32:]).hexdigest()


def requests(store: Store) -> list[dict]:
    try:
        return json.loads(store.requests_file.read_text())
    except (OSError, ValueError):
        return []


def _save_requests(store: Store, rows: list[dict]) -> None:
    store.ensure()
    _private(store.requests_file, json.dumps(rows, indent=2, sort_keys=True) + "\n")


def open_window(store: Store, seconds: int = REQUEST_WINDOW_SECONDS, now: float | None = None) -> float:
    until = (time.time() if now is None else now) + seconds
    store.ensure()
    _private(store.window_file, f"{until}\n")
    return until


def window_open(store: Store, now: float | None = None) -> bool:
    try:
        return float(store.window_file.read_text()) > (time.time() if now is None else now)
    except (OSError, ValueError):
        return False


def add_request(store: Store, node: str, domain: str, csr_pem: str, secret_hash: str, now: float | None = None) -> dict:
    """A public node's join request: its node id and key, waiting for a person (`node approve`). The node id is its
    own claim until a person approves its key for that domain. One pending request per node id; a request
    window (`node invite --level public`) must be open; at most MAX_PENDING_REQUESTS wait."""
    now = time.time() if now is None else now
    if not window_open(store, now):
        raise IdentityError("no request window is open on this node (a person runs `facilitator node invite --level public`)")
    fp = csr_check(csr_pem)
    rows = requests(store)
    if sum(1 for r in rows if r["status"] == "pending") >= MAX_PENDING_REQUESTS:
        raise IdentityError(f"{MAX_PENDING_REQUESTS} join requests wait for a person: approve or deny some first")
    if any(r["node"] == node and r["status"] in ("pending", "approved") for r in rows):
        raise IdentityError(f"a join request of {node} waits or was approved already")
    row = {"id": "r-" + secrets.token_hex(4), "node": node, "domain": domain, "csr": csr_pem, "fp": fp,
           "secret_hash": secret_hash, "at": now_utc(), "status": "pending"}
    rows.append(row)
    _save_requests(store, rows)
    return row


def get_request(store: Store, rid: str) -> dict | None:
    return next((r for r in requests(store) if r["id"] == rid), None)


def update_request(store: Store, rid: str, **fields) -> dict:
    rows = requests(store)
    for r in rows:
        if r["id"] == rid:
            r.update(fields)
            _save_requests(store, rows)
            return r
    raise IdentityError(f"no join request {rid} (facilitator node requests)")


def live_requests(store: Store) -> int:
    """Requests the join endpoint still has to serve: waiting for a person, or approved and not yet collected."""
    return sum(1 for r in requests(store) if r["status"] in ("pending", "approved"))


def request_view(r: dict) -> dict:
    return {k: r[k] for k in ("id", "node", "domain", "fp", "at", "status") if k in r} | {
        k: r[k] for k in ("approved_by", "approved_at") if k in r}


# ---------------------------------------------------------------- rotating the mesh's SLIM app secret (ruling H4)

ROTATION_WAIT_SECONDS = 120


def rotation(store: Store) -> dict | None:
    try:
        return json.loads(store.rotation_file.read_text())
    except (OSError, ValueError):
        return None


def save_rotation(store: Store, rot: dict) -> None:
    store.ensure()
    _private(store.rotation_file, json.dumps(rot, indent=2, sort_keys=True) + "\n")


def begin_rotation(store: Store, rid: str | None, new: str | None, at: str | None, origin: str, pending: list[str],
                   reason: str = "", now: float | None = None) -> dict:
    """The record the peers part works from: the new secret, the nodes still owed it, a deadline. `node revoke` makes one
    (a new secret, the nodes that remain); a node that takes one from another passes it on the same way."""
    rot = {"rid": rid or secrets.token_hex(8), "new": new or secrets.token_urlsafe(36), "at": at or now_utc(),
           "origin": origin, "pending": sorted(set(pending)), "reason": reason, "state": "sending",
           "deadline": (time.time() if now is None else now) + ROTATION_WAIT_SECONDS}
    save_rotation(store, rot)
    return rot
