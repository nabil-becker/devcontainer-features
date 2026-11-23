# Spike: an ssh-agent as the hub's CA (2026-11-23)

Backlog id `hub-on-kubernetes`; it tests ruling K5 of `docs/proposals/facilitator-node.md` ("an ssh-agent tier: yes,
after a test"). Who it serves: the Operator, through the host, and the people who will run a facilitator hub
without OpenBao and without a readable CA key file. Nothing in the Feature was changed. Everything ran in this
devhost (x86_64), with throwaway `ssh-agent` processes (OpenSSH, started and killed by pid), invented names
(`corp.test`, `hub`, `spoke-a`), and the SLIM node of the bundle `facilitator-bundle-v0.5.0` (`slimctl` from
`facilitator-0.5.0-linux-amd64.tar.gz`, sha256 checked against the release's `SHA256SUMS`: OK; slim-bindings 3.3.9,
the node of the earlier spike), run natively on loopback, no Docker. Where something was read from documentation
and not run, it says **from docs**.

## Result in one paragraph

**It works.** An ed25519 key held in an ssh-agent signs the exact bytes it is given (no prehash, flags 0), so a
hub can build an X.509 TBSCertificate, have the agent sign it, and wrap it: `openssl verify` accepts the agent-signed
root and leaves, and two SLIM nodes link over mTLS with them (`completed full sync for peer`), while a leaf signed
by a different agent key is refused in the handshake. The CA key was never a file; about ten lines of DER assembly are the only
non-library code. **Two things push back.** (1) A **URI name constraint on the CA breaks SLIM**:
`permitted;URI:corp.test`, which is what `ensure_local_ca` in `identity.py` writes today, makes SLIM's TLS stack
(rustls-webpki) refuse every leaf with `NameConstraintViolation`, with an agent-signed CA and with a plain
`openssl` one alike; the DNS constraint alone is accepted. That is a finding against the built-in issuer (K3), not
only against K5. (2) Only **ed25519 (and a hardware key that does raw EdDSA)** gives "sign these bytes"; RSA and ECDSA keys
in an agent hash, and an ECDSA agent signature comes back in SSH's format, so a hub supporting them needs more code.

## 1. An agent-signed root and leaf

### What the agent protocol offers

`SSH2_AGENTC_SIGN_REQUEST` (type 13): `string key-blob, string data, uint32 flags`; the answer is `SSH2_AGENT_SIGN_RESPONSE`
(14) with `string signature`, itself `string algorithm, string signature-bytes`. The agent never says what the data
is. (draft-miller-ssh-agent; it is the request `ssh` itself sends, with the session-bound authentication blob as
data.) I wrote a 20-line socket client and did not need `paramiko`: it was installed and not used.

### Run

```text
python3 -m venv venv && venv/bin/pip install cryptography paramiko            # cryptography 50.0.2
eval "$(ssh-agent -s)" ; ssh-keygen -q -t ed25519 -N '' -C hub-ca-test -f ca1 ; ssh-add ca1
ssh-add -l          # 256 SHA256:CZ6EJX...MyA hub-ca-test (ED25519)
venv/bin/python agentca.py "$SSH_AUTH_SOCK" pki A hub spoke-a spoke-b          # the script is in the appendix
```

The script builds the certificate with `cryptography`'s `CertificateBuilder`, but signs it with a *throwaway*
in-memory ed25519 key only to obtain `tbs_certificate_bytes`; it then sends those bytes to the agent and assembles
`SEQUENCE { tbs, AlgorithmIdentifier(Ed25519), BIT STRING signature }` by hand. A throwaway Ed25519 key is
needed because `cryptography` has no "external signer" hook; the algorithm identifier must match (Ed25519 has no
parameters), so the TBS carries the right one. The agent was asked **four times** (root 329 bytes, hub, two
spokes), each answer `ssh-ed25519`, 64 bytes.

The root: self-signed, `CA:TRUE, pathlen:0`, `keyUsage keyCertSign,cRLSign`, name constraints (below), 10 years.
The leaf: its own EC P-256 key (a file, as SLIM needs), `CA:false`, `digitalSignature`, EKU server and client auth,
SAN `DNS:spoke-a.corp.test` and `URI:spiffe://corp.test/node/spoke-a`, 24 h, authority key identifier of the agent key.

```text
$ openssl verify -CAfile caA.pem hubA.pem spoke-aA.pem spoke-bA.pem
hubA.pem: OK    spoke-aA.pem: OK    spoke-bA.pem: OK
$ openssl x509 -in spoke-aA.pem -noout -text | grep -E "Signature Algorithm|URI|DNS|TLS|Not After"
    Signature Algorithm: ED25519        Not After : Nov 24 20:33:47 2026 GMT
    TLS Web Server Authentication, TLS Web Client Authentication
    DNS:spoke-a.corp.test, URI:spiffe://corp.test/node/spoke-a
```

`openssl verify` checks the Ed25519 signature over the TBS, so "raw bytes, no prehash" is proved by acceptance, not
only by the signature length. A leaf from a second agent (other key, **same issuer name**, so only the key differs)
fails: `unable to get local issuer certificate` against the first root, and `OK` against its own root.

### What the agent signs, and what differs by key type

Run on throwaway keys (`flags.log`):

| Key | Flags | Answer | Notes |
|---|---|---|---|
| ed25519 | 0 | `ssh-ed25519`, 64 bytes | **raw**: the pure Ed25519 signature of the data; usable as an X.509 signature as is |
| RSA 2048 | 0 / 2 / 4 | `ssh-rsa` (SHA-1) / `rsa-sha2-256` / `rsa-sha2-512`, 256 bytes | the agent **hashes** (the flag picks which); X.509 `sha256WithRSAEncryption` would need flag 2 and a PKCS#1 v1.5 signature, which is what the SSH one is, so it would work but only with the right flag and algorithm identifier |
| ECDSA P-256 | 0 | `ecdsa-sha2-nistp256`, 74 bytes | hashes with the curve's hash (SHA-256) and returns `mpint r, mpint s`, not DER; X.509 `ecdsa-with-SHA256` wants a DER `SEQUENCE {INTEGER, INTEGER}`: a conversion, not a blocker |

So ed25519 is the one that is "just sign my bytes"; it is also what `identity.py` uses for the card signature and what
the proposal says. Any other type is a (small) per-type adapter. **From docs, not run:**

- A **FIDO key** (`ed25519-sk`, `ecdsa-sk`) is not usable: the signature covers the application hash, flags and a
  counter around the data, so it cannot be an X.509 signature.
- A **hardware key behind the agent**: an OpenPGP card (YubiKey, Nitrokey) with an ed25519 key, reached through
  `gpg-agent --enable-ssh-support`, signs through the same protocol and, being EdDSA, is the same raw signature, so
  the hub code would not change. A **PIV** key (`ssh-add -s libykcs11.so`, PKCS#11) is RSA or ECDSA only on most
  tokens, so it falls in the hashing rows above. `ssh-add -c` makes the agent ask for confirmation on each signing and
  `ssh-add -t <seconds>` gives a key a lifetime; the touch policy of a YubiKey key makes each signature a touch,
  which suits an offline-ish root and not a hub that issues every 12 h unattended.
- The agent will sign **anything** for a key it holds: a CA key loaded in an agent that a person also uses for `ssh`
  is also a CA to whoever can reach the socket. Use a **dedicated agent** (its own socket, only the CA key).

## 2. SLIM accepts the agent-signed certificates

Two throwaway agents (keys `hub-ca-test` and `other-ca-test`); one node as the hub (server on `127.0.0.1:46420`,
`client_ca` = the agent-signed root), spokes that dial it as a `peer` client with their agent-signed leaf and the
root as `ca_source` (the shape `infra.py` writes). No Docker; `slimctl slim start -c <file>`.

```yaml
# hub                                              # spoke (server_name is a sibling of tls, not inside it)
services:                                          services:
  slim/0:                                            slim/0:
    node_id: hub                                       node_id: sa
    dataplane:                                         dataplane:
      servers:                                           servers: [{endpoint: "127.0.0.1:46421", tls: {insecure: true}}]
        - endpoint: "127.0.0.1:46420"                    clients:
          tls:                                             - endpoint: "https://127.0.0.1:46420"
            source:    {type: file, cert: hubA.pem, key: hubA.key}   connection_type: peer
            client_ca: {type: file, path: caA.pem}                   server_name: hub.corp.test
                                                                     tls:
                                                                       source:    {type: file, cert: spoke-aA.pem, key: spoke-aA.key}
                                                                       ca_source: {type: file, path: caA.pem}
```

| Case | Result |
|---|---|
| spoke `spoke-a`, leaf from the agent CA, root with a **DNS** name constraint | **linked**: hub `upgrading server-side connection to Peer ... remote_node_id=sa` and `completed full sync for peer`, spoke the same |
| spoke `spoke-x`, leaf signed by the **other agent key**, same issuer name, same everything else | **refused by the hub**: the connection is cancelled in the handshake (`connection closed`), no peer, the spoke keeps retrying; the hub logs nothing (as in the earlier spike) |
| root with **no** name constraint | linked |
| root with **both** URI and DNS constraints (`permitted;URI:corp.test,permitted;DNS:corp.test`) | **refused by the spoke**: `invalid peer certificate: Other(OtherError(NameConstraintViolation))`, before the name check |
| root with a **URI** constraint only | the same refusal |
| the same URI+DNS constraints on a CA made with plain `openssl req -x509` and `openssl x509 -req`, exactly as `ensure_local_ca` and `issue_local` do | **the same refusal**: so it is not the agent, it is the constraint |
| the node dialled by IP, `server_name` omitted | refused: `certificate not valid for name "127.0.0.1"`; with `server_name: hub.corp.test` accepted (the earlier spike's DNS SAN finding, unchanged) |

The proof of "accepts" is the link forming and syncing; I did not push application messages over it (the earlier
spike did that over exactly this kind of link, and the TLS layer is the only thing that changed). `openssl verify`
accepted the URI-constrained chain, so OpenSSL and rustls-webpki disagree about a URI constraint on a `spiffe://`
name. My reading, not checked in webpki's source: a URI constraint is applied to the URI's host and a `spiffe://`
URI with a host and a path is rejected under it. Whatever the reason, **a CA that SLIM must accept cannot carry
`permitted;URI:...`**; the domain restriction for SPIFFE IDs has to be a check of ours (the card's lock two, which
already checks the ID's domain, and SLIM never reads the ID anyway: the earlier spike's impostor test).

## 3. When the agent is gone

`kill` of the agent and a run of the script: `FileNotFoundError: ... agent.NNN` (the socket is removed with the
agent; a socket that exists but whose agent has no key answers `SSH2_AGENT_FAILURE`, type 5, which the client turns
into `agent refused`). Nothing that was issued is affected: a certificate is a signed document and is valid till
its `not_after` with the agent dead, which is how the file-key CA behaves too. What stops is issuing and renewing.

## Recommendation for K5's tier

Build it. It costs one small module and the property the Operator wants (the CA key never a file) is real.

- **Config**: `node.issuer.ssh_agent: {socket: <path or $SSH_AUTH_SOCK>, key: <SHA256:... fingerprint>}`; the key is
  found by listing identities (type 11) and matching the fingerprint, never "the first key"; ed25519 only in the
  first version (`facilitator node issuer check` says so for anything else). The root's public key is the agent
  key's; the root certificate is made once (`node issuer init`: the agent signs it, the file is the public root,
  distributed like any bundle), and `check` shows the fingerprint, the root's expiry and whether the agent answers.
- **Issuing**: the hub builds the TBS with a throwaway signer as in the appendix, asks the agent, assembles; spokes'
  leaves stay as now (their own key a file, 24 h, renewed at half life). A leaf needs one agent round trip (about a
  millisecond on a socket), so renewals are cheap.
- **Gone**: issuing and renewing return a clear error (`ssh-agent unreachable at <socket>`), `check` reports it
  and how long the current leaves last, the hub keeps serving; with 24 h leaves renewed at 12 h, an agent that is back
  within 12 h costs nothing. Say that in the docs, and add a longer leaf lifetime option for a hub whose agent is
  often absent (laptop sleep) rather than hiding the gap.
- **Constraint**: drop `permitted;URI:` from the built-in CA now (a one-line change in `ensure_local_ca`; keep the
  DNS constraint), and keep the ID-domain check in the card lock. **This matters beyond K5**: a hub on the built-in
  issuer (K3) cannot link SLIM nodes at all with the constraint as it is written. Check whether N5a's tests link
  real SLIM nodes over the local CA; if they only verify with `openssl`, they could not have seen it.
- **Dedicated agent**: document `ssh-agent -a <socket>` with only the CA key, and refuse (warn in `check`) when the
  agent holds other keys.

## Open questions

- **Kubernetes: reaching an agent from a pod.** An agent is a Unix socket on one host. Options, none run:
  (1) a sidecar `ssh-agent` in the hub pod holding the CA key from a Kubernetes Secret, which puts the key
  on a volume again for the pod's lifetime (memory-backed `emptyDir`, loaded with `ssh-add` by an init step, then
  the Secret unmounted): better than a file in the volume, and no better than a sealed secret otherwise; (2) a
  socket-forwarding bridge (`socat` or `ssh -R` from the operator's workstation to the pod) so the key stays on the
  workstation or on a hardware token: it is "the agent is gone when the laptop sleeps" by design, so it fits a
  *root* the Operator uses sometimes, not a hub issuing 24 h leaves; (3) a cloud KMS or an HSM behind a small signing
  service speaking the agent protocol: the right shape for a cluster and a different K. Which of these K5 targets
  decides the Helm chart's values; my lean is (2) for a lab hub and "use OpenBao or a KMS" for a production one.
- **Hardware key with touch**: confirm a YubiKey OpenPGP ed25519 key through `gpg-agent` end to end (no hardware here).
- **RSA and ECDSA**: only if a person asks; the adapters are known (flag 2 and PKCS#1, r and s to DER).
- **Root lifetime and rotation**: the agent key is the root key; rotating it means a new root and a bundle
  distribution, which the existing `node issuer` verbs would have to carry. Not tried.
- **Does the webpki URI-constraint behaviour change** in a later SLIM or rustls-webpki? Pin the bundle's SLIM and re-test on each bump (a one-minute test: the table above).

## Appendix: `agentca.py` (the whole script, scratch, not committed code)

```python
"""Minimal ssh-agent client + X.509 assembly with the signature from the agent. Invented names only."""
import os, socket, struct, sys, datetime, hashlib, base64
from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ed25519, ec

def s(b): return struct.pack(">I", len(b)) + b
def rd(buf, o):
    n = struct.unpack(">I", buf[o:o+4])[0]; return buf[o+4:o+4+n], o+4+n
def call(sock, t, payload):
    sock.sendall(s(bytes([t]) + payload))
    n = struct.unpack(">I", sock.recv(4))[0]; d = b""
    while len(d) < n: d += sock.recv(n - len(d))
    return d[0], d[1:]

class Agent:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX); self.sock.connect(path)
    def identities(self):
        t, d = call(self.sock, 11, b""); assert t == 12
        n = struct.unpack(">I", d[:4])[0]; o = 4; out = []
        for _ in range(n):
            blob, o = rd(d, o); com, o = rd(d, o); out.append((blob, com.decode()))
        return out
    def sign(self, blob, data, flags=0):
        t, d = call(self.sock, 13, s(blob) + s(data) + struct.pack(">I", flags))
        if t != 14: raise RuntimeError(f"agent refused (type {t})")
        sig, _ = rd(d, 0); alg, o = rd(sig, 0); raw, _ = rd(sig, o)
        return alg.decode(), raw

def fingerprint(blob): return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).rstrip(b"=").decode()
def pubkey_from_blob(blob):
    _, o = rd(blob, 0); raw, _ = rd(blob, o)
    return ed25519.Ed25519PublicKey.from_public_bytes(raw)

def der_len(n):
    if n < 128: return bytes([n])
    b = n.to_bytes((n.bit_length()+7)//8, "big"); return bytes([0x80|len(b)]) + b
def tlv(tag, body): return bytes([tag]) + der_len(len(body)) + body

class AgentSigned:
    """Build a cert with a throwaway signer to get the exact TBS, then replace the signature by the agent's."""
    def __init__(self, agent, blob):
        self.agent, self.blob = agent, blob; self.pub = pubkey_from_blob(blob)
        self._dummy = ed25519.Ed25519PrivateKey.generate()   # never used for the output signature
        self.calls = []
    def finish(self, builder):
        c = builder.sign(self._dummy, None)                  # for the TBS bytes only
        tbs = c.tbs_certificate_bytes
        alg, sig = self.agent.sign(self.blob, tbs, 0)
        assert alg == "ssh-ed25519" and len(sig) == 64
        self.calls.append((len(tbs), alg, len(sig)))
        sigalg = tlv(0x30, bytes.fromhex("06032b6570"))      # Ed25519, OID 1.3.101.112, no parameters
        der = tlv(0x30, tbs + sigalg + tlv(0x03, b"\x00" + sig))
        return x509.load_der_x509_certificate(der)

def constraints():
    m = os.environ.get("CONSTR", "both")
    p = {"both": [x509.UniformResourceIdentifier("corp.test"), x509.DNSName("corp.test")], "dns": [x509.DNSName("corp.test")],
         "uri": [x509.UniformResourceIdentifier("corp.test")]}.get(m)
    return (x509.NameConstraints(p, None), True) if p else (x509.InhibitAnyPolicy(0), False)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "corp.test"), x509.NameAttribute(NameOID.COMMON_NAME, cn)])

def main(sock, outdir, tag):
    ag = Agent(sock); ids = ag.identities(); blob, com = ids[0]
    print("agent key:", com, fingerprint(blob)); a = AgentSigned(ag, blob); now = datetime.datetime.now(datetime.timezone.utc)
    cab = (x509.CertificateBuilder().subject_name(name("corp.test agent CA")).issuer_name(name("corp.test agent CA"))
        .public_key(a.pub).serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
        .add_extension(x509.KeyUsage(False,False,False,False,False,True,True,False,False), True)
        .add_extension(*constraints(), ) 
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(a.pub), False))
    ca = a.finish(cab)
    open(f"{outdir}/ca{tag}.pem", "wb").write(ca.public_bytes(serialization.Encoding.PEM))
    for node in sys.argv[4:]:
        k = ec.generate_private_key(ec.SECP256R1()); dns = f"{node}.corp.test"
        lb = (x509.CertificateBuilder().subject_name(name(node)).issuer_name(ca.subject).public_key(k.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(hours=24))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
            .add_extension(x509.KeyUsage(True,False,False,False,False,False,False,False,False), True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH, ExtendedKeyUsageOID.CLIENT_AUTH]), False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(dns), x509.UniformResourceIdentifier(f"spiffe://corp.test/node/{node}")]), False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(a.pub), False))
        lc = a.finish(lb)
        open(f"{outdir}/{node}{tag}.pem", "wb").write(lc.public_bytes(serialization.Encoding.PEM))
        open(f"{outdir}/{node}{tag}.key", "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    print("agent sign calls (tbs bytes, alg, siglen):", a.calls)
main(sys.argv[1], sys.argv[2], sys.argv[3])
```

Scratch and logs: `/var/lib/devcontainer-features/claude-code/jobs/d6c9f143/tmp/sshca/` (outside the repository).
