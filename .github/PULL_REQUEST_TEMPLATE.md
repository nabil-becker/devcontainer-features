## What

<!-- One or two sentences: which Feature / script, what changes. -->

## Why

<!-- Link the issue, or explain the motivation. -->

## Checklist

- [ ] Every commit is signed off (`Signed-off-by:`, DCO) - automatic after `task repo:setup`
- [ ] `version` bumped in `src/<id>/devcontainer-feature.json` (semver)
- [ ] Downloads remain checksum-verified; nothing unverified is piped into a shell
- [ ] `install.sh` is idempotent and does not assume a `remoteUser`
- [ ] Tests updated (`test/<id>/test.sh`, `scenarios.json`) and `task test FEATURE=<id>` passes (in this repo's devcontainer or on Linux/macOS)
- [ ] `taskfile.yml` present and registered via `installTaskfile` (new Features)
- [ ] `task lint` passes
- [ ] `NOTES.md` updated if behaviour or options changed, and `task docs` run so `src/<id>/README.md` is current
