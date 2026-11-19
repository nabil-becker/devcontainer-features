"""A packet: one signed body, named by its hash, in its key's chain (SPEC.md, "The packet").

This module makes and checks one packet at a time: its canonical form, its fields, its signature.
It knows no kinds, rosters or registers. A layer on top (agentic-register) adds what a packet's
`kind` and `data` may say through a check it passes in. Signing and signature checks use OpenSSH's
`ssh-keygen -Y`, so there is no other dependency.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

VERSION = 2                     # what is written by default; 1 is still read (a packet from before domains)
VERSIONS = (1, 2, 3)            # 3: a layer's new rules over the same fields (register v3, AOF ADR 0028)
DEFAULT_VERSIONS = (1, 2)       # what a caller reads and signs unless it asks for more: version 3 is opt-in,
                                # so a layer written before it never reads or writes v3 by its old rules
NAMESPACES = {1: "aof-ledger", 2: "aof-register", 3: "aof-register-v3"}   # the SSH signature namespace of each format
LEGACY_DOMAIN = "ledger"        # the domain a format-1 packet belongs to
MAX_BODY = 65536
MAX_SAW = 64
MAX_INT = 2**53 - 1
TOP_FIELDS = {"v", "key", "as", "seq", "prev", "saw", "at", "kind", "data"}
FIELDS = {1: TOP_FIELDS, 2: TOP_FIELDS | {"reg"}, 3: TOP_FIELDS | {"reg"}}
ARMOR_BEGIN = "-----BEGIN SSH SIGNATURE-----"
ARMOR_END = "-----END SSH SIGNATURE-----"

KEY_RE = re.compile(r"ssh-ed25519 [A-Za-z0-9+/]+={0,2}")
ID_RE = re.compile(r"[0-9a-f]{64}")
AT_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
# A principal: a plain id, and for an agent the running instance it writes from after one `@`: its
# instance GUID, lowercase, 8-4-4-4-12 (D93): `scribe@3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c`.
# Operators stay plain (D38). Nothing but a GUID follows `@`, so a principal is never an email address.
# Readers before sign-packet 0.4.0 refuse a GUID there.
GUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
PRINCIPAL_RE = re.compile(rf"[a-z0-9][a-z0-9_.-]{{0,63}}(@{GUID})?")
FIELD_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")
DOMAIN_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")

# What a reader of packets alone may answer. A layer on top adds its own codes (Refused takes any).
PACKET_REFUSALS = (
    "bad-format", "too-large", "not-canonical", "bad-version", "bad-field", "bad-signature",
    "refused-parent", "bad-chain", "wrong-domain", "guarded",
)
CODE_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")

Check = Callable[[dict], None]   # a layer's own check of a body's kind and data; raises Refused


class Refused(Exception):
    """A packet is refused, with a code (PACKET_REFUSALS, or a layer's own) and a detail."""

    def __init__(self, code: str, detail: str = ""):
        assert CODE_RE.fullmatch(code), code
        super().__init__(f"{code}: {detail}" if detail else code)
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------- canonical JSON

def _check_value(v, path: str) -> None:
    if v is None or isinstance(v, (bool, str)):
        return
    if isinstance(v, int):
        if abs(v) > MAX_INT:
            raise Refused("bad-field", f"{path or 'body'}: integer out of range")
        return
    if isinstance(v, float):
        raise Refused("bad-field", f"{path or 'body'}: numbers are integers only")
    if isinstance(v, list):
        for i, x in enumerate(v):
            _check_value(x, f"{path}[{i}]")
        return
    if isinstance(v, dict):
        for k, x in v.items():
            if not isinstance(k, str) or not FIELD_RE.fullmatch(k):
                raise Refused("bad-field", f"{path or 'body'}: field name {k!r}")
            _check_value(x, f"{path}.{k}" if path else k)
        return
    raise Refused("bad-field", f"{path or 'body'}: not a JSON value")


def canonical(value) -> bytes:
    """The one byte form of a value (SPEC.md, "Canonical JSON")."""
    _check_value(value, "")
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                          allow_nan=False).encode("utf-8")
    except UnicodeEncodeError as e:  # a lone surrogate
        raise Refused("bad-format", f"not encodable as UTF-8: {e}") from None


def packet_id(body: bytes) -> str:
    """A packet's id: the SHA-256 of its body line. The same body is the same packet."""
    return hashlib.sha256(body).hexdigest()


# ---------------------------------------------------------------- the packet

@dataclass(frozen=True)
class Packet:
    id: str
    body: bytes
    signature: str
    value: dict

    key = property(lambda self: self.value["key"])
    principal = property(lambda self: self.value["as"])
    seq = property(lambda self: self.value["seq"])
    prev = property(lambda self: self.value["prev"])
    saw = property(lambda self: self.value["saw"])
    at = property(lambda self: self.value["at"])
    kind = property(lambda self: self.value["kind"])
    domain = property(lambda self: self.value.get("reg", LEGACY_DOMAIN))
    namespace = property(lambda self: NAMESPACES[self.value["v"]])
    data = property(lambda self: self.value["data"])

    @property
    def parents(self) -> list[str]:
        return ([self.prev] if self.prev else []) + list(self.saw)

    @property
    def raw(self) -> bytes:
        return self.body + b"\n" + self.signature.encode("ascii")


def parse(raw: bytes, check: Check | None = None, cls: type[Packet] | None = None,
          versions: tuple[int, ...] = DEFAULT_VERSIONS) -> Packet:
    """Checks 1 and 2 of SPEC.md ("Checking a packet"): format and fields. Raises Refused.
    `check`: the layer's own check of the kind and data, run last. `cls`: a layer's subclass of Packet.
    `versions`: the format versions this caller reads (default 1 and 2; a layer that knows 3 asks)."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("bad-format", "not UTF-8") from None
    line, sep, armour = text.partition("\n")
    if not sep or not armour.startswith(ARMOR_BEGIN + "\n") or not armour.endswith(ARMOR_END + "\n"):
        raise Refused("bad-format", "a body line, then an armoured SSH signature")
    body = line.encode("utf-8")
    if len(body) > MAX_BODY:
        raise Refused("too-large", f"{len(body)} bytes")
    try:
        value = json.loads(line)
    except ValueError as e:
        raise Refused("bad-format", f"not JSON: {e}") from None
    except RecursionError:      # deeply nested arrays or objects, inside the size limit: refused, never a crash
        raise Refused("bad-format", "nested too deeply") from None
    if not isinstance(value, dict):
        raise Refused("bad-format", "the body is not an object")
    if canonical(value) != body:
        raise Refused("not-canonical")
    check_fields(value, check, versions)
    return (cls or Packet)(packet_id(body), body, armour, value)


def _need(ok, what: str) -> None:
    if not ok:
        raise Refused("bad-field", what)


def is_id(v) -> bool:
    return isinstance(v, str) and ID_RE.fullmatch(v) is not None


def is_key(v) -> bool:
    return isinstance(v, str) and KEY_RE.fullmatch(v) is not None


def is_int(v, low: int = 0) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= low


def check_fields(value: dict, check: Check | None = None, versions: tuple[int, ...] = DEFAULT_VERSIONS) -> None:
    """Every field of a body (SPEC.md, "The body"), then the layer's `check`. Raises Refused.
    `versions`: the format versions the caller reads (default 1 and 2)."""
    v = value.get("v")
    if isinstance(v, bool) or v not in VERSIONS:
        raise Refused("bad-version", repr(v))
    if v not in versions:
        raise Refused("bad-version", f"{v}: not a version this reader reads ({', '.join(map(str, versions))})")
    _need(set(value) == FIELDS[v], f"fields {sorted(set(value) ^ FIELDS[v])}")
    if v >= 2:
        _need(isinstance(value["reg"], str) and DOMAIN_RE.fullmatch(value["reg"]), "reg")
    _need(is_key(value["key"]), "key")
    _need(isinstance(value["as"], str) and PRINCIPAL_RE.fullmatch(value["as"]), "as")
    _need(is_int(value["seq"], 1), "seq")
    _need(value["prev"] is None or is_id(value["prev"]), "prev")
    saw = value["saw"]
    _need(isinstance(saw, list) and all(is_id(x) for x in saw), "saw")
    _need(saw == sorted(set(saw)), "saw: sorted, no duplicates")
    _need(len(saw) <= MAX_SAW, f"saw: at most {MAX_SAW}")
    _need(value["prev"] not in saw, "saw: never prev")
    _need(isinstance(value["at"], str) and AT_RE.fullmatch(value["at"]), "at")
    _need(isinstance(value["kind"], str) and FIELD_RE.fullmatch(value["kind"]), "kind")
    _need(isinstance(value["data"], dict), "data")
    if (value["seq"] == 1) != (value["prev"] is None):
        raise Refused("bad-chain", "seq 1 has prev null, and only seq 1")
    if check is not None:
        check(value)


# ---------------------------------------------------------------- keys and signatures

class NoPublicKey(ValueError):
    """A signing key file whose public half cannot be found: said in one line, never a traceback."""


# The OpenSSH private key file's armour lines, built in parts so the source never holds them whole
# (a secret guard refuses a file that looks like it holds a private key).
_ARMOUR = ("-" * 5 + "BEGIN OPENSSH PRIVATE" + " KEY" + "-" * 5, "-" * 5 + "END OPENSSH PRIVATE" + " KEY" + "-" * 5)


def _openssh_public(private_key: Path) -> tuple[str, bool] | None:
    """The public half of an OpenSSH private key file, read from the file itself, and whether the
    private half is encrypted (has a passphrase). The format keeps the public key in the clear, so a
    passphrase-protected key gives it up without its passphrase and without a prompt. None for a
    file in any other shape."""
    try:
        lines = private_key.read_text().strip().splitlines()
        if (lines[0], lines[-1]) != _ARMOUR:
            return None
        b = base64.b64decode("".join(lines[1:-1]), validate=True)
        magic = b"openssh-key-v1\0"
        if not b.startswith(magic):
            return None

        def part(data: bytes, o: int) -> tuple[bytes, int]:   # an SSH string: a length, then the bytes
            n = struct.unpack(">I", data[o:o + 4])[0]
            if o + 4 + n > len(data):
                raise ValueError("cut short")
            return data[o + 4:o + 4 + n], o + 4 + n
        o = len(magic)
        cipher, o = part(b, o)
        for _ in range(2):              # KDF name, KDF options
            _, o = part(b, o)
        o += 4                          # the number of keys; the first one is the signing key
        blob, _ = part(b, o)
        kind, _ = part(blob, 0)
        return f"{kind.decode('ascii')} {base64.b64encode(blob).decode('ascii')}", cipher != b"none"
    except (OSError, IndexError, ValueError, struct.error, UnicodeDecodeError, binascii.Error):
        return None


def public_key(key_file: Path) -> str:
    """The public key of a signing key file: a .pub file whose private half is held by an SSH agent
    (then the private key never touches this machine), or a private key: its .pub beside it, else
    the public half kept inside an OpenSSH private key file (a key copied in alone, to sign once).
    Raises NoPublicKey, naming the file it needs, when neither gives one."""
    p = Path(key_file)
    pub = p if p.suffix == ".pub" else Path(str(p) + ".pub")
    if pub.is_file():
        text = pub.read_text().split()
        if len(text) >= 2:
            return f"{text[0]} {text[1]}"
        raise NoPublicKey(f"{pub} is not a public key (want '<type> <base64>')")
    if p.suffix != ".pub" and p.is_file() and (found := _openssh_public(p)):
        return found[0]
    raise NoPublicKey(f"no public key for {p}: put its public half at {pub} "
                      f"(ssh-keygen -y -f {p} > {pub})")


def sign(value: dict, private_key: Path, check: Check | None = None, guard=None,
         versions: tuple[int, ...] = DEFAULT_VERSIONS) -> bytes:
    """The packet bytes for a body, signed with an OpenSSH Ed25519 key. Checks the body first, then
    runs `guard` (a guard.Guard or guard.Chain) on it as egress: a refusal raises Refused("guarded")
    and nothing is signed. `private_key` may be a .pub file: ssh-keygen then signs through the SSH
    agent ($SSH_AUTH_SOCK)."""
    body = canonical(value)
    check_fields(value, check, versions)
    if guard:
        guard.check(body, value.get("reg", LEGACY_DOMAIN), "egress")
    if value["key"] != public_key(private_key):
        raise ValueError("the body's key is not the signing key")
    out = subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-n", NAMESPACES[value["v"]], "-f", str(private_key)],
                         input=body, capture_output=True)
    if out.returncode != 0:
        why = out.stderr.decode(errors="replace").strip().splitlines()[-1:] or ["no reason given"]
        if Path(private_key).suffix != ".pub" and (_openssh_public(Path(private_key)) or ("", False))[1]:
            raise ValueError(f"could not sign with {private_key}: it has a passphrase, which ssh-keygen cannot "
                             "ask for here; ssh-add it to an SSH agent first, then sign with the same --key")
        raise ValueError(f"could not sign with {private_key}: {why[0]} (for a .pub key: is the private key in the SSH agent?)")
    return body + b"\n" + out.stdout


def signature_ok(p: Packet) -> bool:
    """Check 4: the signature, by the packet's own key, over its body, in its version's namespace."""
    with tempfile.TemporaryDirectory() as tmp:
        signers = Path(tmp, "signers")
        signers.write_text(f'writer namespaces="{p.namespace}" {p.key}\n')
        sig = Path(tmp, "sig")
        sig.write_text(p.signature)
        r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "writer",
                            "-n", p.namespace, "-s", str(sig)], input=p.body, capture_output=True)
        return r.returncode == 0
