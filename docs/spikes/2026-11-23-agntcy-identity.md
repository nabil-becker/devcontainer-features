# Spike: AGNTCY Identity for agent badges (2026-11-23)

Backlog id `agntcy-identity-spike`; ruling PB1 put this before slice N5. Who it serves: the Operator, through
the host, and later the people who will expose agents publicly across facilitator nodes. Nothing was built and
no Feature code changed. Where something was read from source or docs and not run, it says **from source**.

## What was run

| Step | State |
|---|---|
| Release, licence, issues, images read from the GitHub API and registry | done |
| Source of v0.0.26 cloned (commit `d974bb9`) and read: issuer CLI, node, verify service | done |
| Node plus PostgreSQL in the devhost's Docker, issuer register, badge issue, publish, verify, revoke, verify again, verify with the node down | done (section 2) |
| Everything removed afterwards (containers, network, the three images); disk 53 GB used before and after | done |

## 1. Maturity (read, not run)

- Latest release **v0.0.26, 2026-09-29**; before it v0.0.25 (2026-09-28), v0.0.23 (2026-01-29), v0.0.20
  (2025-11-13). Long gaps, then a burst of release-engineering work (signed build provenance, OpenSSF
  Scorecard). Last commit on main 2026-09-29. Pre-1.0 and the API package is `v1alpha1`.
- Licence **Apache-2.0**. 20 open issues (about 9 real ones: a proposal to adopt a shared verifier for Directory
  IdentityClaims, docs requests, "TBAC support", "full SDK adoption"); 109 stars; not archived.
- Parts: the **Issuer CLI** (`identity`, Go, static binary 21 to 23 MB, linux amd64 and arm64, cosign-style
  `.sig` files and an in-toto provenance file per release) and the **Node backend** (Go, gRPC on 4001 and an
  HTTP gateway on 4000, PostgreSQL). Python SDK in `sdk/python`.
- **Still needs Docker and PostgreSQL**: the node is the only way to resolve an issuer's keys or publish a
  badge. The compose file uses `postgres:latest` (unpinned) and default passwords `postgres`.
- Node image `ghcr.io/agntcy/identity/node`: tag `0.0.26` (no `v` prefix) = `latest`, index digest
  `sha256:a3b3ff79a55ed2c766acc2e33068c3ae3e0109ee1ccd55d9dec13f91e198e46a`, **linux/amd64 and linux/arm64**
  (amd64 `sha256:90d86580...e196`, arm64 `sha256:6523ea76...f5f`). The Dockerfile is `golang:alpine` as the
  runtime image, so it is larger than it needs to be.
- Verification is a **call to a node**: `verify` resolves the badge's resolver-metadata ID on a node to get
  the public key, checks the JWS, then checks status. Offline verification is not a mode (from source,
  `internal/issuer/verify`). Embedded-proof badges are "not supported yet"; only JOSE (JWT) badges verify.
- The CLI has `vault`, `issuer`, `metadata`, `badge`, `verify`, `config`. **No revoke command**: revocation is
  a node gRPC/HTTP call (`Revoke`, "not reversible") and the credential carries a `credentialStatus` with
  purpose `revocation`.
- Registering an issuer needs **an OIDC identity provider** (the demo uses Okta client credentials); metadata
  generation needs a second one for the subject.

Versions and digests used: `identity` CLI 0.0.26 (sha256 from `identity_0.0.26_checksums.txt`, matched), node image
index `sha256:a3b3ff79...e46a` (amd64 pulled), `postgres:17-alpine`
`sha256:f9cf3e1f0066f0eb0c48707d864f0ac5941e9ff454a072077d97a4d278d07d73`, `golang:1.26.8-alpine` (only to build
the revoke helper; the digest is the one the upstream Dockerfile pins, `sha256:8ac98ca5...49a0c`). Sizes: node image
472 MB, postgres 424 MB, the CLI 22 MB; the postgres container idled at 35 MB. All on the host's loopback only,
invented names only (`corp.example`, agent `scribe`).

## 2. Run it for real

One Docker network, two containers, everything under an isolated `HOME` so the CLI's vault lived in the job's
scratch directory.

```text
docker network create idspike-net
docker run -d --name idspike-pg   --network idspike-net -e POSTGRES_PASSWORD=<pw> -e POSTGRES_DB=identity postgres:17-alpine@sha256:f9cf...7d73
docker run -d --name idspike-node --network idspike-net -p 127.0.0.1:4000:4000 \
   -e DB_HOST=idspike-pg -e DB_PORT=5432 -e DB_USERNAME=postgres -e DB_PASSWORD=<pw> \
   ghcr.io/agntcy/identity/node@sha256:a3b3...e46a        # logs: gRPC on 4001, gateway on 4000 (migrations run itself)

identity vault connect file -f $HOME/vault.json -v spike-vault      # a JSON file holding the private key in clear
identity vault key generate                                         # RSA, RS256 (not ed25519)
printf 'http://localhost:4000\n' | identity issuer register -n corp.example -o "Corp Example" -b agents
printf 'http://localhost:4000\n' | identity metadata generate      # -> AGNTCY-6e0d712e-...
identity badge issue oasf -o agent-record.json                      # any file; it is signed as an opaque string
printf '\nhttp://localhost:4000\n' | identity badge publish
curl -o vcs.json http://localhost:4000/v1alpha1/vc/<metadata id>/.well-known/vcs.json
identity verify -f vcs.json -i http://localhost:4000
```

The commands prompt for the node address even with `-i` missing, so scripts must feed stdin (a missing answer is
`EOF`, not a default). `-n corp.example` is **self-issued** registration: no identity provider at all; the node
takes the common name on trust and marks the issuer `verified: false` (**from source**,
`issuer_service.go`). With an IdP (Okta, Entra, Ping, any OIDC client-credentials issuer) the common name is
proved by a token and the issuer is `verified`. I did not run the IdP path (no IdP here; it is plain OIDC
client credentials).

| Step | Result |
|---|---|
| node start | up in 1 s, API on 4000 (HTTP gateway) and 4001 (gRPC), plain HTTP, no auth on the read APIs |
| issuer register (self) | ok; the node serves the issuer's JWKS at `/v1alpha1/issuer/corp.example/.well-known/jwks.json` |
| metadata generate | an ID `AGNTCY-<uuid>` (the "DID-like" identifier, `AGNTCY-` for self-issued) and a resolver document |
| badge issue + publish | a VC v2, one JWS (RS256), `type: [AgentBadge]`, `issuer: corp.example`, `credentialSubject: {id: <metadata id>, badge: "<the file's text>"}`; **no expiry, no `credentialStatus`** in what was issued |
| verify | `Badge verified successfully`: it resolves the metadata ID on the node for the public key, checks the JWS, then looks at status |
| tampered payload | refused (parse error; a weak test, the payload no longer decoded) |
| **revoke** | **no CLI command.** The node has `POST /v1alpha1/vc/revoke`; it wants a copy of the VC *re-signed by the issuer with a `credentialStatus` of purpose `revocation`*, plus a proof (here a self-issued JWT). I wrote a 40-line Go program against the repository's internal packages to do it: `200 {}` |
| verify the badge file downloaded **before** the revoke | **still verified** (the status is only in the node's stored copy; the holder's copy has none) |
| verify a badge re-downloaded **after** the revoke | refused: `The Verifiable Credential is revoked (ERROR_REASON_VERIFIABLE_CREDENTIAL_REVOKED)` |
| node stopped, verify | fails: `error resolving Resolver Metadata ID ... connection refused` |

What this says: issuing and verifying work and are small; revocation works only as "ask the node again", and
the CLI does not offer it. The issuer's private key is a plain JSON file in the vault by default (a vault
connector for others exists in the CLI; not tried).

## 3. Binding to the facilitator node card (H3)

**What a badge holds.** The signed content is the string `credentialSubject.badge` (an OASF record, an A2A
card from a URL, or an MCP server's description; the CLI signs any file as is) plus the subject `id`, which is
the resolver-metadata ID and **not** a SPIFFE ID or a `did:` URI (`AGNTCY-<uuid>`; the DID-style name is
internal). So a badge **can attest** the agent's SPIFFE ID and packet key, but only as text inside the badge
string; nothing in AGNTCY Identity understands or checks them. I issued one with
`{"annotations": {"facilitator.spiffe_id": "spiffe://corp.example/node/n1/agent/scribe", "facilitator.packet_key":
"ssh-ed25519 ...", "facilitator.node_card_sha256": "..."}}` and it verified and came back intact.

| Binding | Works? |
|---|---|
| badge carries the agent's packet public key (ed25519, OpenSSH text) | yes, as content; the badge's own signature key is RSA (RS256) from the CLI's vault, a different key |
| badge carries the SPIFFE ID `spiffe://<domain>/node/<id>/agent/<handle>` | yes, as content; the SPIFFE trust domain and the badge issuer name (`corp.example`) are two unrelated namespaces that a facilitator rule must tie together |
| lock two (a packet's signer looked up in the admitted node cards) | unchanged; a badge would be an extra, optional second proof of "this key is this agent, vouched for by issuer X", checked by a facilitator rule that compares the badge's content with the card |
| the badge replaces the node card | no: it needs the node, it is per agent, and the card is signed with the node's certificate key and verifies offline |

**Offline verification: no, as shipped.** `verify` needs the node for the issuer's key *and* for status. What
*is* possible, built by us: a verifier that holds the issuer's JWKS (fetched once, even carried in the node
card; the JWK is a plain RSA public key) and checks the JWS locally with any JOSE library. That gives
authenticity but **not revocation** and, with no expiry in the badge, not freshness either. A badge a holder
kept stays valid for a verifier that never calls home, which is the opposite of what the revoke row above
shows for the online path. To get "revoked within an hour" offline, the facilitator would have to issue badges
with `expirationDate` itself (the field exists in the VC type; the CLI does not set it) or republish the
roster with a revocation list: the same job the node cards and OpenBao certificates already do.

## 4. Who issues

| Option | Fits | Cost |
|---|---|---|
| Per node (each node is its own issuer, `corp.example` style common name) | a node vouches for its own agents; self-issued needs no IdP | every node runs a node backend and PostgreSQL (about 500 MB of images, one more service and database) or someone else's; the vouching adds nothing over the signed node card |
| Per trust domain, beside the OpenBao PKI | one issuer per domain (the hub): it already admits nodes and approves public joins by a person; badge issuance is the same approval, one more output | one identity node and a database at the hub; the issuer key is RSA in a file, not in OpenBao (OpenBao transit could hold it, but the CLI's vault connectors would need checking: not run); the issuer's name is a hostname string, so `corp.example` and the SPIFFE domain must be kept equal by convention |
| Shared public issuer | a public node's agents are vouched for by a third party that outsiders can check | AGNTCY runs no public production node that I found (docs point at running your own); a collection-wide issuer would be ours to run and keep, and a policy question the Operator has not been asked |
| Bring your own IdP | supported: any OIDC provider (Okta, Entra, Ping with tenant-aware names, others) proves the issuer's common name and gives `verified` | the facilitator would need to accept the node's "verified" flag, which is the node's own claim |

## 5. Recommendation for N5a

**Take (b): badges stay a later opt-in, the `identity` option stays refused through N5a.** Reasons, from what ran:

1. The trust in N5a is already closed without badges: a public node joins by key plus person's approval, its
   card is signed with its certificate, lock two checks the packet signer against admitted cards, and revoke
   works by the hub dropping the card within the hour. A badge does not do one of these jobs better.
2. The offline requirement of a public peer-to-peer mesh is not met: verification calls a node, and a revoked
   badge in a holder's hand still verifies. Making it offline-safe is our own code (expiry, a list), not an
   option of the product.
3. The cost is not small for what it adds: a Go service and PostgreSQL per issuer, a revoke the CLI lacks, an
   RSA key in a file, the project at 0.0.x with `v1alpha1` APIs and a release gap of eight months before the
   September burst.

What N5a should do to leave the door open, cheaply: reserve an optional `badge` field in the node card's
participant entry (a signed-by-issuer JWS, opaque to the code) and the roster; document the binding record
format above (SPIFFE ID, packet key, card hash) so a later badge layer attests the same values. Cost of (b): one
optional field and a paragraph. Cost of (a): the issuer service at the hub, a revocation path of our own, a
verifier we write because the shipped one is online, and a new test stack. Re-open (a) when a consumer asks for a third
party to vouch for a public agent, or when upstream ships offline verification, expiry by default and a revoke
command (its open proposal to adopt a shared verifier for Directory IdentityClaims and Agent Badges, #179, is the
sign to watch; the Directory's own signing may already cover part of this: from upstream issue titles only).

## Open questions

- IdP path not run (verified issuers, `verified: true`): a mock OIDC issuer would show it; a day, not hours.
- Whether OpenBao could hold the issuer key (vault connectors in the CLI beyond the file one) was not tried.
- Embedded-proof (Data Integrity) badges are unsupported at verify time; the DID resolution the docs describe
  (`did:` documents, `did:web` bridging in issue #163) was not exercised: the shipped IDs are `AGNTCY-<uuid>`.
- Whether the node's read APIs can be protected and rate limited for a public deployment: they had no auth here.
- A real tamper test (change one claim, keep the JWS well-formed) was not run; the signature check is standard
  JWX, but the run only showed a parse error.

## Ruling (2026-11-23)

The Operator ruled ID1 to ID3 as recommended:

- **ID1:** public nodes need no agent badges in slice N5a. Badges stay a later opt-in, and the Feature's
  `identity` option stays refused; N5a's trust rests on key plus approval, the signed node cards and lock two.
- **ID2:** N5a reserves an optional opaque `badge` field in each participant entry of the node card, and the
  NOTES describe the binding record (SPIFFE ID, packet key, card hash) a badge would carry.
- **ID3:** no further work on the identity-provider path or on keeping the issuer key in OpenBao until a
  consumer asks for badges; revisit when upstream ships offline verification, expiry and a revoke command
  (upstream issue #179).
