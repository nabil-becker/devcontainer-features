# ADR-0086: One release workflow builds, pins and publishes the facilitator, and waits for the pin pull request to merge

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-25 |
| **Deciders** | the Operator; proposed by the host, after a con's design note |

## Context

A facilitator release took four manual steps with a wait between each: the Operator ran
`release-bundle` (builds the node bundle per architecture, publishes the release with
`SHA256SUMS` and attestations); the host ran `task bundle:pin` (checks each asset against
`SHA256SUMS`, GitHub's digest and its attestation, adds lines to `src/facilitator/digests.txt`,
amends the changelog line) and opened a pin pull request, which the Operator merged; the Operator
ran the Feature release (`release.yaml`); then ran `release-node-image`, which checks the bundle
against the pins on `main` and publishes the image with provenance. On 2026-11-25 the Operator
asked to consolidate this into one release workflow they start by hand.

Forces that do not move: `main` is protected (pull requests only, squash merges, required checks
`validate`, `lint`, `tests`, `DCO`; no approval since #251; ADR-0085); only the Operator starts a
release; the actions allow-list is GitHub-owned actions and `devcontainers/*`; the published
Feature's `digests.txt` must be what is on `main`; the supply-chain checks must not weaken.

## Decision

One `workflow_dispatch` workflow, `.github/workflows/release-facilitator.yaml`, runs the four
steps in order through the existing workflows (`workflow_call`): plan, bundle, pin, Feature, node
image, then a summary. The pin stage runs the single implementation
`.github/scripts/pin-bundle.sh` (also behind `task bundle:pin`), commits the pin to a topic branch,
opens the pin pull request, asks for auto-merge and waits for the merge. The Feature and the image
are then published from the merge commit on `main`. The workflow never pushes to `main` and never
bypasses protection; with the `RELEASE_PR_TOKEN` secret the pin pull request is an ordinary one whose
required checks start by themselves, and auto-merge merges it when they pass (rulings RW1–RW3). It has a `dry_run` input that builds and checks but publishes, pushes and opens
nothing. `release-bundle` and `release-node-image` stay callable as the manual fallback.

## Options considered

### Option 1 (chosen): the workflow opens the pin pull request, waits for its merge, then publishes

The digest exists only after the build, so the pin cannot be in git before it. Here git equals
what is published, protection is untouched, and the pin's pull request history is kept.

### Option 2: verify the pins at install from the release's own checksums and attestation

It removes the pull request but the Feature would trust whatever a release of this repository
says, so the pin in git stops being a second key. Rejected as a weakening of the trust chain.

### Option 3: build and pin in the pull request that bumps the version, before the merge

Not possible: builds are not byte-identical, so the digest is unknown until the release is built.

## Consequences

- The Operator starts one workflow; the pin pull request merges itself once its checks pass (no
  approval is required since #251, and auto-merge is on).
- A bot-opened pull request starts no `pull_request` workflows, so the workflow dispatches
  `validate`, `lint` and `test` on the pin branch; whether their results satisfy the required checks
  is untested until the first real run.
- Settled by the Operator (2026-11-25): auto-merge on (RW1), the `RELEASE_PR_TOKEN` secret set (RW2),
  no approval on the pin pull request (RW3, then #251 for every pull request). Open: keep or retire the
  two superseded workflows after the first real run.
- Strict up-to-date checks mean that if `main` moves while the pin pull request waits, someone must
  update its branch; the wait loop prints a notice but does not.
- Accepted 2026-11-25 on rulings RW1–RW3; the first real run is the check.

## Change log

| Date | Change |
|---|---|
| 2026-11-25 | First draft. |
