# Security policy

These Features run as root inside container image builds, so a compromised
download or install script is a supply-chain issue for everyone who
references them. Please report problems privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository:
<https://github.com/nabil-becker/devcontainer-features/security/advisories/new>

Please do not open public issues for security problems. You can expect an
acknowledgement within 5 working days and a fix or mitigation plan within 30
days for confirmed issues.

## Scope

- `src/*/install.sh` and `devcontainer-feature.json`
- the host-side scripts in `taskfiles/` and `bootstrap.ps1`
- the release and CI workflows in `.github/workflows/`

## What we do to keep it safe

- Every artifact a Feature downloads is checked against the publisher's
  checksum file or a pinned sha256.
- GitHub Actions are pinned to commit SHAs and run with least-privilege
  tokens; Dependabot keeps them current.
- `main` is protected: changes land only through reviewed pull requests with
  passing CI; releases are manual (`workflow_dispatch`) by maintainers.
- Features are published to GHCR by the release workflow only.
