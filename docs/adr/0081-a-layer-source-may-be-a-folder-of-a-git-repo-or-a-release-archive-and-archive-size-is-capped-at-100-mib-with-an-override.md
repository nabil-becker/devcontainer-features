# ADR-0081: A layer source may be a folder of a git repo or a release archive, and archive size is capped at 100 MiB with an override

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

A registry layer source (ADR-0063, ADR-0079) was a whole git repo, or one `.layer` file fetched
over http. A team that keeps its layers in a folder of a bigger repo (a monorepo), or that
publishes them as a release bundle, had to script around the registry. Anything a consuming repo
scripts around is a gap to close in the Features. Fetching archives from the web adds a risk
the single-file http source did not carry: an archive can hold entries that escape the target
folder, links, device files, or be far larger than a text layer needs.

## Decision

The component-registry (2.2.0) gains two source forms and a size cap.

- A git source takes an optional `path:`, the folder of the repo that holds the layer. Only that
  folder is fetched where git allows (a blob-less fetch, then a sparse checkout, falling back to a
  plain shallow fetch when the server refuses the filter). The version check stays the repo
  commit. A `path:` that is absolute, uses `..` or does not exist is refused.
- An http source takes an optional `archive: tar.gz | tgz | zip`, with an optional `sha256:` pin
  and an optional `path:` inside the archive. Without `archive:` it fetches one `.layer` file
  exactly as before. A `sha256` pin is the version itself, and a mismatch replaces nothing.
- Extraction refuses entries that are absolute, use `..` or a drive letter, device files, links
  that point outside the folder (and any symlink in a zip), and anything over the cap.
- The cap is 100 MiB for the download and 100 MiB extracted. It is overridden per source with
  `max-size:` on an http source, or for the whole container with
  `COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE`; the per-source setting wins. The error at the cap names
  both ways to raise it.
- `archive`, `sha256` and `max-size` are refused on `path`, `db` and `cloud-folder` sources, like
  any other key that does not belong to the kind.

## Options considered

### Option 1: both forms, git `path:` and http archives (chosen)

The Operator chose it. It covers the monorepo and the release-bundle cases with one small
addition each, keeps plain http unchanged, and needs no new source kind.

### Option 2: git `path:` only

Covers monorepos but leaves release bundles scripted by each consumer; lost.

### Option 3: a test-only environment variable for the cap

It would not count as a documented override; lost for a real per-source and container-wide
setting.

## Consequences

- Layers can live in a monorepo folder or a GitHub, GitLab or web-server release archive.
- A zip can misstate its sizes, so up to its real size may be written before the check after
  extraction refuses it; a `sha256` pin removes that risk, and NOTES recommends pinning.
- A git `path:` fetch re-fetches an identical folder when the repo commit changes elsewhere.
- Release: component-registry 2.2.0, after the Operator merges the pull request.

## Change log

| Date | Change |
|---|---|
| 2026-11-24 | First draft, accepted by the Operator. |
