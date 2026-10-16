# To do

The repository's to-do list: engineering items that need no external answer, and the decisions
only the Operator can take. Kept by the **secretary**, a back (PROCESS.md): after each turn it
adds the items and decisions a session left open and ticks the finished ones; it never rewords,
removes or reorders, and a guard undoes a run that does. Hosts reword, merge, split, move or
remove items by hand, normally at a ledger review.

An item reads `- [ ] **ID Title** (owner). What and why. Added YYYY-MM-DD.`; the owner is host
(a session can do it), the Operator, or engineers; a ticked item ends `Done YYYY-MM-DD.` and
stays. Ids are short descriptive slugs (two to four kebab-case words naming the item), unique in the file, never reused, never renamed.

## Now

- [ ] **read-way-of-working Read the way of working** (the Operator). Read LEXICON.md and PROCESS.md, include `.devhost/CLAUDE.devhost.md` from CLAUDE.md, and strike what does not fit this repository. (was TD-01) Added 2026-10-15.
- [ ] **land-repo-true-up Decide how the repo true-up lands** (the Operator). PR #10 holds everything from 2026-10-15 in one branch (Features owning state, git/gh/az/common/devhost, the devhost of this repo). Merge as one squash, or split by Feature into follow-up PRs. (was TD-02) Added 2026-10-15.
- [ ] **release-collection Release the collection** (the Operator). Run the release workflow so git, gh, az, common and devhost exist on GHCR; until then consumers cannot pull them and `installsAfter` cannot name them. (was TD-03) Added 2026-10-15.
- [ ] **devhost-claude-login Sign in to Claude Code inside the devhost once** (the Operator). The backs run `claude -p` headless and need the login in the claude-code volume; the first `task devcontainer:claude` does it. (was TD-04) Added 2026-10-15.
- [ ] **first-back-runs First real back runs and the first ledger entries** (host). After devhost-claude-login, work one unit in the devhost and check the scribe's entry, the secretary's items and the cost report; file friction. (was TD-05) Added 2026-10-15.

## Next

- [ ] **consumers-adopt-release Consumer repos adopt the release** (host). The office and DSNP follow their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md`: the include alias, the Features, `devhost` in place of their housekeeping scripts, deleting the local wrappers. (was TD-06) Added 2026-10-15.
- [ ] **kube-state-feature kube state Feature** (host). A Feature that owns `KUBECONFIG` the way gh and az own theirs, so velero and kustomize users stop hand-mounting the kubeconfig. (was TD-07) Added 2026-10-15.
- [ ] **one-devhost-defaults One common.py** (host). `src/devhost/share/bin/common.py` and `share/python/devhost_common.py` carry the same `DEVHOST_*` defaults; keep one. (was TD-08) Added 2026-10-15.
- [ ] **gh-installs-after-git Re-add git to gh's installsAfter after the release** (host). Removed because an unpublished Feature in `installsAfter` fails the build; gh-setup is self-sufficient meanwhile. (was TD-09) Added 2026-10-15.
- [ ] **workstation-feature-tests Feature tests on the workstation** (host). `task test` needs a Docker daemon; on `wslc` the devhost's docker-in-docker does not start. Either Docker Desktop for the test runs or a `wslc`-based runner for `devcontainer features test`. (was TD-10) Added 2026-10-15.
- [ ] **bootstrap-host-disk-docs Bootstrap template host-disk override as a documented second template** (host). The starter writes the volume default; a repo on a synced checkout that wants host-disk state copies the mounts by hand. Decide whether `bootstrap.ps1` should offer it. (was TD-11) Added 2026-10-15.
- [ ] **dsc-without-github-api dsc install does not depend on the GitHub API** (host). The asset digest comes from the unauthenticated Releases API, whose hourly limit the CI matrix exhausts (HTTP 403, the one flaky job of 2026-10-15). GITHUB_TOKEN from the workflow does not reach a Feature build. Read the digest from the release page instead, or pin per version. (was TD-12) Added 2026-10-15.

## Decisions for the Operator
