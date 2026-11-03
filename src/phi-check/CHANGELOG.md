# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.0.0 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.0.1] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.0.0] - 2026-10-29

### Added

- First release: `phi-check <path>...`, a linter-style command that refuses files holding protected health information (US Social Security numbers, Medicare Beneficiary Identifiers, X12, HL7 v2 and FHIR Patient data, and a record id or date of birth next to a diagnosis, a name label or another id). It never prints the matched text and knows nothing of git or hooks: your repository wires it into its own checks. ([#99](https://github.com/nabil-becker/devcontainer-features/pull/99))

