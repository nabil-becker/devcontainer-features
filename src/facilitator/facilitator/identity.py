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
                  "-addext", f"nameConstraints=critical,permitted;URI:{home_domain},permitted;DNS:{home_domain}"])
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
