# To do

The repository's to-do list: engineering items that need no external answer, and the decisions
only the Operator can take. Kept by the **secretary**, a back (PROCESS.md): after each turn it
adds the items and decisions a session left open and ticks the finished ones; it never rewords,
removes or reorders, and a guard undoes a run that does. Hosts reword, merge, split, move or
remove items by hand, normally at a ledger review.

An item reads `- [ ] **ID Title** (owner). What and why. Added YYYY-MM-DD.`; the owner is host
(a session can do it), the Operator, or engineers; a ticked item ends `Done YYYY-MM-DD.` and
stays. Ids are `TD-nn`, numbered in creation order, never reused.

## Now

- [ ] **TD-01 Read the way of working** (the Operator). Read LEXICON.md and PROCESS.md, include `.devhost/CLAUDE.devhost.md` from CLAUDE.md, and strike what does not fit this repository. Added 2026-10-15.
- [ ] **TD-02 Decide how the repo true-up lands** (the Operator). PR #10 holds everything from 2026-10-15 in one branch (Features owning state, git/gh/az/common/devhost, the devhost of this repo). Merge as one squash, or split by Feature into follow-up PRs. Added 2026-10-15.
- [ ] **TD-03 Release the collection** (the Operator). Run the release workflow so git, gh, az, common and devhost exist on GHCR; until then consumers cannot pull them and `installsAfter` cannot name them. Added 2026-10-15.
- [ ] **TD-04 Sign in to Claude Code inside the devhost once** (the Operator). The backs run `claude -p` headless and need the login in the claude-code volume; the first `task devcontainer:claude` does it. Added 2026-10-15.
- [ ] **TD-05 First real back runs and the first ledger entries** (host). After TD-04, work one unit in the devhost and check the scribe's entry, the secretary's items and the cost report; file friction. Added 2026-10-15.

## Next

- [ ] **TD-06 Consumer repos adopt the release** (host). The office and DSNP follow their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md`: the include alias, the Features, `devhost` in place of their housekeeping scripts, deleting the local wrappers. Added 2026-10-15.
- [ ] **TD-07 kube state Feature** (host). A Feature that owns `KUBECONFIG` the way gh and az own theirs, so velero and kustomize users stop hand-mounting the kubeconfig. Added 2026-10-15.
- [ ] **TD-08 One common.py** (host). `src/devhost/share/bin/common.py` and `share/python/devhost_common.py` carry the same `DEVHOST_*` defaults; keep one. Added 2026-10-15.
- [ ] **TD-09 Re-add git to gh's installsAfter after the release** (host). Removed because an unpublished Feature in `installsAfter` fails the build; gh-setup is self-sufficient meanwhile. Added 2026-10-15.
- [ ] **TD-10 Feature tests on the workstation** (host). `task test` needs a Docker daemon; on `wslc` the devhost's docker-in-docker does not start. Either Docker Desktop for the test runs or a `wslc`-based runner for `devcontainer features test`. Added 2026-10-15.
- [ ] **TD-11 Bootstrap template host-disk override as a documented second template** (host). The starter writes the volume default; a repo on a synced checkout that wants host-disk state copies the mounts by hand. Decide whether `bootstrap.ps1` should offer it. Added 2026-10-15.
- [ ] **TD-12 dsc install does not depend on the GitHub API** (host). The asset digest comes from the unauthenticated Releases API, whose hourly limit the CI matrix exhausts (HTTP 403, the one flaky job of 2026-10-15). GITHUB_TOKEN from the workflow does not reach a Feature build. Read the digest from the release page instead, or pin per version. Added 2026-10-15.

## Decisions for the Operator
