# Spike: AGNTCY Identity for agent badges (2026-11-23)

PARTIAL, written as it goes (container rebuild expected); the "What was run" table says how far it got.
Backlog id `agntcy-identity-spike`; ruling PB1 put this before slice N5. Who it serves: the Operator, through
the host, and later the people who will expose agents publicly across facilitator nodes. Nothing was built and
no Feature code changed. Where something was read from source or docs and not run, it says **from source**.

## What was run

| Step | State |
|---|---|
| Release, licence, issues, images read from the GitHub API and registry | done |
| Source of v0.0.26 cloned (commit `d974bb9`) and read: issuer CLI, node, verify service | done |
| Node plus PostgreSQL in the devhost's Docker, issuer register, badge issue, verify, revoke | in progress |

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
