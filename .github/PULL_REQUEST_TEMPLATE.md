## What

<!-- One or two sentences: which Feature / script, what changes. -->

## Why

<!-- Link the issue, or explain the motivation. -->

## Checklist

- [ ] `version` bumped in `src/<id>/devcontainer-feature.json` (semver)
- [ ] Downloads remain checksum-verified; nothing unverified is piped into a shell
- [ ] `install.sh` is idempotent and does not assume a `remoteUser`
- [ ] Tests updated (`test/<id>/test.sh`, `scenarios.json`) and `task test FEATURE=<id>` passes locally or in the workbench
- [ ] `task lint` passes
- [ ] `NOTES.md` updated if behaviour or options changed (README is generated)
