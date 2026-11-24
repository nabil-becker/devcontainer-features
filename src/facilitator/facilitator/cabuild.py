"""Building X.509 certificates whose signature comes from somewhere else (slice hub-on-kubernetes, rulings K3 and K5;
ADR-0078): the CA key may be a file, or it may live in an ssh-agent that signs the bytes it is given and never shows
the key. Python's standard library has no X.509 writer, and OpenSSL's `x509 -req` needs the CA key as a file, so the
certificate's DER is assembled here (about 60 lines) and the signature, ed25519 over the exact TBSCertificate bytes, is
asked of a *signer*: a key file (`openssl pkeyutl -rawin`) or an ssh-agent (`agent_sign`). The spike
(docs/spikes/2026-11-23-ssh-agent-ca.md) proved SLIM accepts an agent-signed certificate; `openssl verify` checks the
same signature, which is how the unit tests prove these are well formed.

The CA certificates carry a DNS name constraint only (never a URI one: rustls-webpki, which SLIM uses, refuses a chain
whose CA constrains URIs). Everything is ed25519."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import os
import socket
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Callable

ED25519_ALG = bytes.fromhex("300506032b6570")                # AlgorithmIdentifier { id-Ed25519 }
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


class SignError(RuntimeError):
    pass


# ---------------------------------------------------------------- DER

def _len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag: int, body: bytes) -> bytes:
    return bytes([tag]) + _len(len(body)) + body


def seq(*parts: bytes) -> bytes:
    return tlv(0x30, b"".join(parts))


def read_tlv(b: bytes, i: int = 0) -> tuple[int, bytes, int]:
    """(tag, body, index after) of the element at b[i]."""
    tag = b[i]
    n = b[i + 1]
    j = i + 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(b[j:j + k], "big")
        j += k
    return tag, b[j:j + n], j + n


def children(body: bytes) -> list[tuple[int, bytes, bytes]]:
    """[(tag, body, whole element)] of a constructed element's body."""
    out, i = [], 0
    while i < len(body):
        tag, inner, j = read_tlv(body, i)
        out.append((tag, inner, body[i:j]))
        i = j
    return out


def oid(dotted: str) -> bytes:
    a = [int(x) for x in dotted.split(".")]
    body = bytes([a[0] * 40 + a[1]])
    for n in a[2:]:
        chunk = [n & 0x7F]
        n >>= 7
        while n:
            chunk.append(0x80 | (n & 0x7F))
            n >>= 7
        body += bytes(reversed(chunk))
    return tlv(0x06, body)


def integer(n: int) -> bytes:
    b = n.to_bytes(max(1, (n.bit_length() + 8) // 8), "big")
    return tlv(0x02, b)


def name(o: str, cn: str) -> bytes:
    """/O=<o>/CN=<cn> as a DER Name (UTF8String values)."""
    def rdn(oid_s: str, v: str) -> bytes:
        return tlv(0x31, seq(oid(oid_s), tlv(0x0C, v.encode())))
    return seq(rdn("2.5.4.10", o), rdn("2.5.4.3", cn))


def cn_name(cn: str) -> bytes:
    return seq(tlv(0x31, seq(oid("2.5.4.3"), tlv(0x0C, cn.encode()))))


def _time(t: float) -> bytes:
    d = dt.datetime.fromtimestamp(t, dt.timezone.utc)
    if d.year < 2050:
        return tlv(0x17, d.strftime("%y%m%d%H%M%SZ").encode())
    return tlv(0x18, d.strftime("%Y%m%d%H%M%SZ").encode())


def _ext(o: str, value: bytes, critical: bool = True) -> bytes:
    return seq(oid(o), *([tlv(0x01, b"\xff")] if critical else []), tlv(0x04, value))


def ext_basic(ca: bool, pathlen: int | None = None) -> bytes:
    body = (tlv(0x01, b"\xff") if ca else b"") + (integer(pathlen) if ca and pathlen is not None else b"")
    return _ext("2.5.29.19", seq(body))


def ext_key_usage(ca: bool) -> bytes:
    # keyCertSign (bit 5) + cRLSign (bit 6) for a CA, digitalSignature (bit 0) for a leaf
    return _ext("2.5.29.15", tlv(0x03, b"\x01\x06" if ca else b"\x07\x80"))


def ext_eku() -> bytes:
    return _ext("2.5.29.37", seq(oid("1.3.6.1.5.5.7.3.1"), oid("1.3.6.1.5.5.7.3.2")), critical=False)


def ext_san(dns: str, uri: str) -> bytes:
    return _ext("2.5.29.17", seq(tlv(0x82, dns.encode()), tlv(0x86, uri.encode())), critical=False)


def ext_dns_constraints(domains: list[str]) -> bytes:
    return _ext("2.5.29.30", seq(tlv(0xA0, b"".join(seq(tlv(0x82, d.encode())) for d in domains))))


def ext_ski(spki: bytes) -> bytes:
    key = spki[len(ED25519_SPKI_PREFIX):]
    return _ext("2.5.29.14", tlv(0x04, hashlib.sha1(key).digest()), critical=False)


def ext_aki(issuer_spki: bytes) -> bytes:
    key = issuer_spki[len(ED25519_SPKI_PREFIX):]
    return _ext("2.5.29.35", seq(tlv(0x80, hashlib.sha1(key).digest())), critical=False)


def pem(der: bytes, label: str = "CERTIFICATE") -> str:
    b = base64.b64encode(der).decode()
    return f"-----BEGIN {label}-----\n" + "\n".join(b[i:i + 64] for i in range(0, len(b), 64)) + f"\n-----END {label}-----\n"


def from_pem(text: str) -> bytes:
    lines = [ln for ln in text.strip().splitlines() if ln and not ln.startswith("-----")]
    return base64.b64decode("".join(lines))


def cert_parts(cert_der: bytes) -> dict:
    """{subject, issuer, spki} (each a whole DER element) of a certificate."""
    _, body, _ = read_tlv(cert_der)
    tbs = children(body)[0][1]
    f = children(tbs)
    k = 1 if f[0][0] == 0xA0 else 0          # an explicit version first
    return {"serial": f[k][1], "issuer": f[k + 2][2], "subject": f[k + 4][2], "spki": f[k + 5][2]}


def spki_of_pem_pubkey(pub_pem: str) -> bytes:
    der = from_pem(pub_pem)
    if not der.startswith(ED25519_SPKI_PREFIX):
        raise SignError("the key is not ed25519")
    return der


def build(*, serial: int, issuer: bytes, subject: bytes, spki: bytes, not_before: float, not_after: float,
          exts: list[bytes], sign: Callable[[bytes], bytes]) -> str:
    """A v3 certificate as PEM, its TBS signed by `sign` (ed25519, 64 bytes)."""
    tbs = seq(tlv(0xA0, integer(2)), integer(serial), ED25519_ALG, issuer,
              seq(_time(not_before), _time(not_after)), subject, spki, tlv(0xA3, seq(*exts)))
    sig = sign(tbs)
    if len(sig) != 64:
        raise SignError("the signature is not an ed25519 signature (64 bytes)")
    return pem(seq(tbs, ED25519_ALG, tlv(0x03, b"\x00" + sig)))


# ---------------------------------------------------------------- signers

def file_signer(key: Path) -> Callable[[bytes], bytes]:
    """Sign with an ed25519 key file: `openssl pkeyutl -sign -rawin` (pure Ed25519 over the bytes given)."""
    def sign(data: bytes) -> bytes:
        with tempfile.TemporaryDirectory(prefix="fac-sig-") as t:
            p = Path(t) / "tbs"
            p.write_bytes(data)
            r = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-in", str(p)],
                               capture_output=True, timeout=30)
        if r.returncode != 0:
            raise SignError("openssl pkeyutl: " + (r.stderr.decode(errors="replace").strip().splitlines() or ["failed"])[-1])
        return r.stdout
    return sign


def _ssh_string(b: bytes) -> bytes:
    return struct.pack(">I", len(b)) + b


def _agent_call(sock_path: str, msg_type: int, payload: bytes = b"") -> tuple[int, bytes]:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(sock_path)
        body = bytes([msg_type]) + payload
        s.sendall(struct.pack(">I", len(body)) + body)
        head = _read(s, 4)
        n = struct.unpack(">I", head)[0]
        if n > 1 << 20:
            raise SignError("the ssh-agent answered something too large")
        data = _read(s, n)
    except FileNotFoundError:
        raise SignError(f"ssh-agent unreachable at {sock_path} (no such socket)") from None
    except (ConnectionRefusedError, PermissionError) as e:
        raise SignError(f"ssh-agent unreachable at {sock_path}: {e.strerror or e}") from None
    except (socket.timeout, OSError) as e:
        raise SignError(f"ssh-agent at {sock_path}: {e}") from None
    finally:
        s.close()
    return data[0], data[1:]


def _read(s: socket.socket, n: int) -> bytes:
    out = b""
    while len(out) < n:
        c = s.recv(n - len(out))
        if not c:
            raise SignError("the ssh-agent closed the connection")
        out += c
    return out


def fingerprint(blob: bytes) -> str:
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def _unpack_strings(b: bytes, count: int) -> list[bytes]:
    out, i = [], 0
    for _ in range(count):
        n = struct.unpack(">I", b[i:i + 4])[0]
        out.append(b[i + 4:i + 4 + n])
        i += 4 + n
    return out


def agent_identities(sock_path: str) -> list[dict]:
    """[{blob, type, fingerprint, comment}] of the keys the agent holds (SSH2_AGENTC_REQUEST_IDENTITIES)."""
    t, data = _agent_call(sock_path, 11)
    if t != 12:
        raise SignError(f"ssh-agent at {sock_path} refused to list its keys (reply {t})")
    n = struct.unpack(">I", data[:4])[0]
    i, out = 4, []
    for _ in range(n):
        blob, comment = _unpack_strings(data[i:], 2)
        i += 8 + len(blob) + len(comment)
        kt = _unpack_strings(blob, 1)[0].decode(errors="replace")
        out.append({"blob": blob, "type": kt, "fingerprint": fingerprint(blob), "comment": comment.decode(errors="replace")})
    return out


def agent_key(sock_path: str, fp: str) -> dict:
    """The agent's ed25519 key whose SHA256 fingerprint is `fp`: matched by fingerprint, never 'the first key'."""
    keys = agent_identities(sock_path)
    for k in keys:
        if k["fingerprint"] == fp:
            if k["type"] != "ssh-ed25519":
                raise SignError(f"the agent's key {fp} is {k['type']}: only ssh-ed25519 signs a certificate's bytes as they are")
            return k
    raise SignError(f"the ssh-agent at {sock_path} does not hold {fp} (it holds {len(keys)} key(s))")


def agent_spki(key: dict) -> bytes:
    raw = _unpack_strings(key["blob"], 2)[1]
    return ED25519_SPKI_PREFIX + raw


def agent_signer(sock_path: str, fp: str) -> Callable[[bytes], bytes]:
    key = agent_key(sock_path, fp)

    def sign(data: bytes) -> bytes:
        t, reply = _agent_call(sock_path, 13, _ssh_string(key["blob"]) + _ssh_string(data) + struct.pack(">I", 0))
        if t != 14:
            raise SignError(f"the ssh-agent at {sock_path} refused to sign (reply {t}: the key may need confirmation, or be gone)")
        sig_blob = _unpack_strings(reply, 1)[0]
        alg, raw = _unpack_strings(sig_blob, 2)
        if alg != b"ssh-ed25519":
            raise SignError("the ssh-agent signed with something other than ssh-ed25519")
        return raw
    return sign


def new_serial() -> int:
    return int.from_bytes(os.urandom(8), "big") >> 1 | 1 << 62
