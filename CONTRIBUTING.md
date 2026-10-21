# Contributing

Thanks for helping! This repository is a collection of [Dev Container
Features](https://containers.dev/implementors/features/) listed in the public
[containers.dev index](https://containers.dev/collections), so changes here
reach anyone who references them. The rules below keep that safe.

- **Questions / ideas:** open an [issue](https://github.com/nabil-becker/devcontainer-features/issues).
- **Bugs:** use the bug report template.
- **Security issues:** never in the issue tracker - see [SECURITY.md](SECURITY.md).

## Workflow

1. Fork, branch from `main`, and run `task repo:setup` once in the clone
   (see "Sign your work" below). Opening the repo in its devcontainer
   (`.devcontainer/`) gives you every tool the checks need.
   Its `.devcontainer/devcontainer-lock.json` is committed; refresh it with
   `devcontainer upgrade` when a registry Feature there is bumped.
2. Make the change; run `task docs` (if the JSON or notes changed),
   `task lint` and, on Linux/macOS or inside the devcontainer,
   `task test FEATURE=<id>`.
3. Open a pull request using the template. CI (`validate`, `lint`, `tests`,
   `DCO`) must pass and a code owner must approve; `main` only accepts
   squash merges through pull requests.
4. A maintainer runs the release workflow, which publishes to
   `ghcr.io/nabil-becker/devcontainer-features/<id>`.

## Proposing a new Feature

Open a "New Feature proposal" issue first. We accept two kinds of Feature:

- **Installers**: one well-defined tool from a trustworthy, checksummed
  source that does not already exist in
  [devcontainers/features](https://github.com/devcontainers/features) (a
  checksum-verified alternative to an unverified community Feature is fine).
- **Augmentations**: the ecosystem pieces around a tool that an official
  Feature (or the base image) already installs - its persistent state, a
  launcher, a post-create hook, a wrapper, a Taskfile - such as
  `claude-code`, `git`, `gh` and `az`. These carry the same id as the tool,
  order themselves after the official Feature with `installsAfter` (never
  `dependsOn`, which would force that Feature's install method on everyone),
  and install the tool themselves only when it is absent, verified and
  pinnable. Wrappers are opt-in by option, generic (no repository paths or
  names), and fast (every call goes through them).

A Feature whose tool keeps state (a login, a config dir, transcripts) owns
that state: `containerEnv` sets the tool's directory variable to
`/var/lib/devcontainer-features/<id>`, `mounts` declares a named volume
`<id>-config-${devcontainerId}` on that target (the pattern of the official
docker-in-docker Feature), and the `<id>-setup` hook calls
`dcf-persist --label <id> "$VAR"` so the directory belongs to the remote
user and the post-create log says what backs it. A repo overrides the volume
with a host bind mount on the same target (its mount wins). Feature metadata
is static, so an option can never change a mount or a variable; `install.sh`
must not write into the target, which is not mounted at build time.

Something a consuming repo scripted in its own `.devcontainer/` is the usual
source of an augmentation; it qualifies once a second repo wants it, or once
it is clearly general.

## Adding a Feature

Once the proposal is accepted, follow these steps top to bottom. Each names
the file and a check, and the rules behind it are in "Feature development
conventions" below. Use an existing Feature as the template: `src/kube-state`
for one that owns state and installs no binary, `src/kubeconform` for an
installer.

1. **Create the folder.** `src/<id>/` and `test/<id>/` with the files listed
   under "Files" below; `id` equals the folder name. Check:
   `grep '"id"' src/<id>/devcontainer-feature.json`.
2. **Set the metadata.** In `src/<id>/devcontainer-feature.json`: `version`
   `1.0.0`, `documentationURL`, `licenseURL`, the `installTaskfile` option
   (and `version` for an installer). Check: `task lint` (the `validate` CI job
   runs the same schema check, `.github/workflows/validate.yml`).
3. **Order it with `installsAfter`, published Features only.** The CLI
   resolves every entry against the registry, so an unpublished Feature
   (including a new one of this collection) cannot be named until a release
   has published it; make a hook that needs another Feature's work
   self-sufficient instead. Check: `grep -A6 installsAfter
   src/<id>/devcontainer-feature.json`, and each
   `ghcr.io/nabil-becker/devcontainer-features/<x>` entry names a Feature
   already released (`.github/workflows/release.yaml` publishes them).

4. **State-owning Features: follow the gh/az volume pattern.** `containerEnv`
   with the tool's directory variable under
   `/var/lib/devcontainer-features/<id>`, a `mounts` volume
   `<id>-config-${devcontainerId}`, and `<id>-setup` calling `dcf-persist`
   (rules in "Proposing a new Feature" above). Copy it from
   `src/gh/devcontainer-feature.json` or `src/az/devcontainer-feature.json`.
   Check: `grep -n 'containerEnv\|mounts\|postCreateCommand'
   src/<id>/devcontainer-feature.json`.
5. **Vendor the shared helper.** A Feature with a `<id>-setup` hook carries a
   verbatim `src/<id>/dcf-persist.sh`, installed by `install.sh` to
   `/usr/local/bin/dcf-persist`. Run `task common:sync`; check
   `task common:check` (also part of `task lint`).
6. **Register the Taskfile.** `src/<id>/taskfile.yml` (rules under
   "`taskfile.yml`" below), installed by the verbatim "Feature Taskfile"
   block at the end of `install.sh` and switched by `installTaskfile`.
   Check: `grep -n 'includes.d' src/<id>/install.sh`.
7. **Write the tests.** `test/<id>/test.sh` plus `scenarios.json` per "Tests"
   below. Rules specific to this tree:
   - A scenario that calls `task` must list `"go-task": {}` in its
     `features` (`test/kube-state/scenarios.json` does for `with_kubectl`);
     without it `task` is not installed.
   - A `pinned_version` scenario is for installer Features only (the ones
     with a `version` option, e.g. `test/kubeconform/scenarios.json`); a
     Feature that installs no binary (`kube-state`) has none.
   - One scenario per other option, `installTaskfile: false` included.
   Check: `grep -L go-task test/<id>/scenarios.json` must not list the file
   when a scenario script runs `task`.
8. **Add it to both CI matrices.** `.github/workflows/test.yaml`, in
   `test-autogenerated` and again in `test-scenarios` (`features:` lists).
   Check: `grep -c -- '- <id>$' .github/workflows/test.yaml` prints `2`.
9. **Add it to the global scenario, three places.** The `tests` job needs no
   change, but `test/_global` has hard-coded lists that nothing derives from
   `src/` (known manual step, a gap: forgetting one fails only in CI, and
   only on the Linux/Docker run):
   - `test/_global/scenarios.json`: `"<id>": {}` in `features`.
   - `test/_global/all_features.sh`: a `check` for the binary or setup
     command; for a state-owning Feature its variable in the `for v in ...`
     list and a "state dir writable" check; the id in the `for f in ...` list
     of "registry lists every Feature"; one of its task names in the
     `grep -c -E '...'` pattern of "feature tasks resolve through the
     registry", **and the hard-coded count that follows (`grep -qx 16`) raised
     by one**.
   Check: `grep -n '<id>' test/_global/scenarios.json test/_global/all_features.sh`
   shows all of them, and the count equals the number of `|`-separated names
   in the pattern.
10. **Write `NOTES.md`, then generate the README.** `src/<id>/NOTES.md`
    (short sections, see "`NOTES.md`" below), then `task docs`; commit the
    regenerated `src/<id>/README.md`. Check: `task docs:check`.
11. **Add the row to the root `README.md`.** One line in the "Features" table,
    in the same shape as its neighbours, linking `src/<id>`. Check:
    `grep -n '(src/<id>)' README.md`.
12. **Lint and test.** `task lint` anywhere; `task test FEATURE=<id>` and
    `task test:global` where a Docker daemon runs (CI otherwise). Check: both
    green, then walk the PR template checklist
    (`.github/PULL_REQUEST_TEMPLATE.md`).
13. **After merge.** A maintainer runs the release workflow
    (`.github/workflows/release.yaml`); only then can another Feature name
    this one in `installsAfter` or a consumer pull it from the registry.

## Feature development conventions

Every Feature follows the same shape, so a reader who knows one knows all of
them. Copy an existing Feature folder and keep to these rules.

### Files

```
src/<id>/
  devcontainer-feature.json   id, version, name, description, options, installsAfter, hooks
  install.sh                  the installer (bash, runs as root at image build)
  <name>.sh                   scripts the installer puts on PATH (as <name>, no extension)
  dcf-persist.sh              verbatim copy of src/common/dcf-persist.sh (task common:sync; lint checks it)
  taskfile.yml                tasks for the tool, namespaced <id>:
  NOTES.md                    hand-written docs folded into README.md
  README.md                   generated by `task docs` - never edit
test/<id>/
  test.sh                     checks for the default options
  scenarios.json              one scenario per option worth exercising
  <scenario>.sh               checks for each scenario
```

### `devcontainer-feature.json`

- `id` equals the folder name and the binary's commonly known name.
- Every installer Feature has the `version` option (`latest` or a pinned
  release, with or without a leading `v`); every Feature has the
  `installTaskfile` boolean (default `true`).
- `installsAfter` lists `ghcr.io/nabil-becker/devcontainer-features/go-task`
  and `ghcr.io/devcontainers/features/common-utils`, plus anything the tool
  genuinely needs ordered before it, and for an augmentation the official
  Feature it augments. Use `dependsOn` only for hard requirements. Both may
  only name Features that are already published: the CLI resolves every
  entry against the registry, and an unpublished one fails the build (so a
  hook that needs another Feature's work done first, such as gh writing into
  git's global config, makes itself sufficient instead of relying on order).
- A Feature that must do something per container (make a mounted folder
  usable, mark a repo safe) declares `"postCreateCommand": "<id>-setup"`
  and installs that script on PATH; the hook runs as the remote user from
  the workspace folder, before the repo's own `postCreateCommand`. The same
  script is `task <id>:setup`. It is idempotent and never fatal: a problem
  is reported and the rest of post-create goes on. Features cannot set
  `remoteEnv`, only `containerEnv`; a repo's own `containerEnv` wins over
  the Feature's, which is how a repo points a tool elsewhere.
- Helpers shared between Features live in `src/common/` and are vendored
  verbatim into each Feature that uses them (`task common:sync`): a
  published Feature folder must be self-contained, and `dependsOn` on a
  Feature of this collection cannot be resolved by `devcontainer features
  test` before it is released.
- `documentationURL` and `licenseURL` point at this repository.
- Bump `version` per [semver](https://semver.org/) in the same PR as any
  change to the folder.

### `install.sh`

In this order, as the existing Features do:

1. `set -euo pipefail`; read options from their upper-cased environment
   variables with defaults (`VERSION="${VERSION:-latest}"`).
2. Refuse to run as non-root with a clear message.
3. Install `curl`/`tar`/`jq` with apt only if missing, and clean apt lists.
4. Map `uname -m` to the publisher's architecture names; fail on others.
5. Resolve `latest` through the `releases/latest` redirect (no API call, no
   token), then validate the version string.
6. **Verify what you download.** Fetch the publisher's checksum file (or the
   GitHub asset digest when there is none) and check with `sha256sum -c`
   before anything is installed. Never pipe a remote script into a shell.
7. Install a single binary with `install -m 0755` into `/usr/local/bin`, or a
   tool that needs its folder into `/opt/<id>` with a wrapper or symlink.
   Private toolchains (a Node.js only the tool uses) never go on PATH.
8. Print the installed version.
9. End with the Feature Taskfile block below, verbatim apart from `<id>`.
10. Be idempotent: running the script twice must succeed and leave the
    same result.

```bash
# ---------------------------------------------------- Feature Taskfile ----
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/<id>.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
```

### `taskfile.yml`

The tasks a user gets as `<id>:<task>` once their root Taskfile includes the
go-task registry (see the go-task Feature's notes).

- `version: '3'`, a leading comment naming the Feature and namespace, and a
  `desc:` on every task so `task --list` is self-explanatory.
- First task is `version`; then the two to five operations people run every
  day for that tool, no more. Name them after the tool's own verbs.
- Inputs are UPPERCASE vars with `requires:` when mandatory and
  `{{.X | default "..."}}` when optional; pass extra flags through with
  `{{.CLI_ARGS}}`; mark tasks that prompt or open a session
  `interactive: true`. Never name a var after an environment variable
  (`PATH`, `HOME`, `USER`): Task reads the environment as template vars,
  so the default would silently be the shell's value.
- A literal `{{` for the tool (kubeconform's `{{.Group}}`) is written
  `{{"{{"}}` in a Taskfile; backtick raw strings do not survive `default`.
- Tasks run in the user's current directory, so paths are relative to their
  project. No environment-, server- or project-specific values; those come
  from the user's `containerEnv` or `.env`.
- Plain `sh`-compatible commands; the Taskfile must not assume PowerShell or
  other Features are present unless its description says so.

### Tests

- `test.sh` checks, with the default options: the binary is on PATH, reports
  a version, is root-owned, and `/usr/local/share/go-task/includes.d/<id>.yml`
  exists.
- `scenarios.json` has at least `pinned_version` (a fixed `version`,
  `remoteUser: vscode`) with its script checking the exact version and that
  the tool runs as non-root. Add a scenario for every other option, e.g.
  `installTaskfile: false` verifying the file is absent.
- `test/_global/` installs every Feature into one image and checks the
  registry; step 9 of "Adding a Feature" lists the places to touch.
- Sourced test helpers need `# shellcheck disable=SC1091`; single-quoted
  `bash -c` bodies need `# shellcheck disable=SC2016`.

### `NOTES.md`

Requirement NFR-8 (`docs/principles/non-functional-requirements.md`) says
`NOTES.md` MUST cover its ten items, or say in one line that an item does not
apply, so that a missing topic always means "forgotten" and
never "not applicable". Short sections, one per topic:

- what the Feature installs and where it lands, and how the download is
  verified (the checksum or signature, or the plain statement that it is
  not);
- each option: what it does and when to change it;
- state: which environment variable persists the tool's login or config
  across rebuilds, and the volume behind it (NFR-1), or that there is none;
- a copy-pasteable `features` block for `devcontainer.json`;
- how to check that it works (the command and what it prints);
- what it pairs with, and what it needs from other Features;
- every task in its `taskfile.yml`, by name (NFR-2);
- its limits and known gaps, stated plainly;
- why it exists, in one paragraph, if a similar Feature is published
  elsewhere: which one and what differs (NFR-9);
- version and upgrade: how a version is pinned or changed, and what an
  upgrade changes.

NFR-8 is the authority: if it and this list disagree, fix this list.

### Code style

- Shell: bash, `shellcheck`-clean, 2-space indent, `set -euo pipefail`.
- YAML: `yamllint`-clean under `.yamllint`, and block style rather than
  `{ }` / `[ ]` flow mappings with inner spaces - files vendored into other
  repos (`bootstrap/devcontainer.yml`) get linted by their default rules.
- PowerShell: PowerShell 7, `PSScriptAnalyzer`-clean, comment-based help.
- Host-side tooling ships in two flavours that must stay in step:
  `bootstrap/host/*.ps*1` + `bootstrap/bootstrap.ps1` (Windows, primary)
  and `src/devcontainer-cli/devcontainer-cli.sh`,
  `bootstrap/host/devcontainer-homes.sh` + `bootstrap/bootstrap.sh`
  (Linux/macOS). The devcontainer-cli bash script is also that Feature's
  installer (`install` mode), so it is the single source of the bash logic;
  the bootstrap vendors it into consuming repos as
  `bootstrap/host/devcontainer-cli.sh`. A behaviour or setting added to one
  flavour goes into the other in the same PR, with the same `DEVCONTAINER_*`
  variable name, and into the vendored lists of both bootstrap scripts.
- `bootstrap/devcontainer.yml` never declares a global `env:` and never
  uses a per-command `if:`: Task 3.45 lets the first swallow `.env` values
  for the whole project and ignores the second. Branch in the template
  (`{{if ._IN_CONTAINER}}...{{else}}...{{end}}`) instead.
- Keep comments to the *why*; the code says the *what*.

## Sign your work (DCO)

Every commit must carry a `Signed-off-by: Your Name <you@example.com>`
trailer. By adding it you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/):
that you wrote the change or otherwise have the right to submit it under
this project's MIT license. The `DCO` check on each pull request enforces
it; no CLA, no separate signing.

You should not have to think about it:

- `task repo:setup` activates the tracked [`.gitconfig`](.gitconfig) for
  your clone (`git config --local include.path ../.gitconfig`). That turns
  on the repo hook `.githooks/prepare-commit-msg`, which adds the trailer to
  every commit automatically, and defines `git cs` as `commit -s`. Only
  this clone's `.git/config` is touched, never your global git config.
- VS Code's Source Control view signs off too
  ([`.vscode/settings.json`](.vscode/settings.json) sets `git.alwaysSignOff`).
- Edits made in the GitHub web editor are signed off by the repository
  setting.

Forgot one? `git commit --amend -s` (or `git rebase --signoff main` for a
whole branch) and force-push your branch.

## AI-assisted contributions

This project is maintained with AI assistance (Claude Code co-authors
commits), and AI-assisted contributions are welcome under the same terms as
any other:

- **You are the author.** You must understand, test and be able to explain
  every line you submit, and your sign-off certifies you have the right to
  contribute it. "The model wrote it" is not an answer in review.
- **Say so.** Add a `Co-Authored-By:` trailer or a sentence in the PR when a
  model produced a substantial part of the change.
- **Quality bar is unchanged.** Unsolicited bulk or low-effort generated
  pull requests, issues or reviews will be closed without discussion.
- **Security reports need a reproduction.** A model's guess that something
  might be vulnerable is not a report; see [SECURITY.md](SECURITY.md).

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
