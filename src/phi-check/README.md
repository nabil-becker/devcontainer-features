
# phi-check (refuse files that hold PHI) (phi-check)

A linter-style command, `phi-check <path>...`, that refuses files holding protected health information: US Social Security numbers, Medicare Beneficiary Identifiers, X12, HL7 v2 and FHIR Patient data on sight, and a record id or date of birth next to a diagnosis, a name label or another id. It never prints the matched text, knows nothing of git or hooks (the repository wires it into pre-commit, a hook or CI), and fails closed (binary, missing and unreadable files are findings). Python 3 standard library only, nothing downloaded: Python comes through dependsOn on ghcr.io/devcontainers/features/python (os-provided, no tools). The patterns are one importable module, /usr/local/share/phi-check/phi_patterns.py, for other guards. Plus the Feature Taskfile.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/phi-check:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| exceptions | The exceptions file phi-check reads when --exceptions is not given: one line per file, `<path> <YYYY-MM-DD> <why>`, for synthetic fixtures. Resolved against the current folder (or --cwd), so a bare name means the repository root when the tool runs from there. A missing default file is fine. Override per container with PHI_CHECK_EXCEPTIONS in containerEnv. | string | .phi-exceptions.txt |

## What it installs, and what it is

`phi-check` is a linter in the way `yamllint`, `shellcheck` and `ruff` are:
it checks what it is given and knows nothing of git, staged changes or
hooks. It is for a repository whose workspace rule is "PHI never enters it":
the repository decides where it runs (see "Wiring it in"); the Feature
installs no hook.

- `/usr/local/bin/phi-check`, one Python 3 script, standard library only.
- `/usr/local/share/phi-check/phi_patterns.py`, the module every pattern
  lives in (see "The module"), and `exceptions-default`, the baked value of
  the `exceptions` option.
- Nothing is downloaded, so there is no checksum to verify and nothing to
  pin: the Feature's version is the tool's version. Python comes through
  `dependsOn` on `ghcr.io/devcontainers/features/python` with
  `version: os-provided` and `installTools: false` (the distribution's
  Python, no pip tools). A hard requirement, as `az` needs the Azure CLI.

## Using it

```sh
phi-check [options] <path>...
```

Every file given is scanned; a folder means every file under it, sorted
(`.git` folders are skipped). `-` reads standard input and
`--stdin-filename <name>` names it in the output.

| Option | Effect |
| --- | --- |
| `--format text\|json\|github` | text (default): `path:line: rule`; json; github: `::error` annotations. |
| `--exceptions <file>` | the exceptions file (default: the `exceptions` option). |
| `--no-exceptions` | ignore the exceptions file, for exports. |
| `--stdin-filename <name>` | the name shown for `-`. |
| `--cwd <dir>` | change to this folder first; paths and the exceptions file resolve there. |
| `--version` | print the version. |

Text output is one line per hit, `path:line: rule`, and the last line is
`phi-check: clean, <n> file(s)` or `phi-check: refused, <k> finding(s) in <n>
file(s)`. **The matched text is never printed**, in any format: only the
path, the line and the rule. Exit codes are a linter's: 0 clean, 1 findings,
2 usage or internal error.

It fails closed. A file that is not UTF-8 text (a NUL in the first 8 KiB, or
a decode error), a missing path and an unreadable file are findings
(`path: not text; cannot be checked`), so binaries are refused rather than
passed. An exception never yields 0 for a problem: a malformed exceptions
line is a finding too, and an internal error is exit 2, never a pass.

## What it refuses

Tier 1, refused on sight:

- A US Social Security number: dashed `ddd-dd-dddd` as a whole token outside
  the never-issued ranges (area 000, 666, 900-999; group 00; serial 0000), or
  nine digits right after "SSN", "social security number", "social security
  no." or "social security #".
- A Medicare Beneficiary Identifier: the CMS 11-character layout, upper case,
  whole token, optional dashes after the 4th and 7th characters.
- X12 segments with data (separator `*`): `NM1` for an insured or patient
  person, `DMG*D8*` with a date, `INS` for a subscriber or dependent, `HI*BK:`
  or `HI*ABK:` with a code, `CLM` with a claim id and amount.
- An HL7 v2 line starting with a `PID` or `NK1` segment that has a field.
- A FHIR JSON `"resourceType": "Patient"` with an `identifier`, `birthDate` or
  `name` key within 20 lines.

Tier 2, refused only in combination: an anchor with any other signal within a
window of three lines centred on the anchor (the anchor's own line and the
one on each side).

- Anchors: an identifier label (MRN, medical record number, member,
  subscriber or patient id or number, account #, claim # or id) followed by
  a token of five or more letters, digits or dashes holding a digit; a
  date-of-birth label (DOB, date of birth, birth date, born, born on)
  followed by a date.
- Other signals: an upper-case ICD-10-CM-shaped code, a diagnosis word
  (diagnosed, diagnosis, diagnoses, admitted, discharged, prescribed), a
  person-name label (`Patient:`, `Member:`, `Subscriber:`, `Insured:`,
  "patient name", "member name", Mr, Mrs, Ms or Miss with a capitalised
  word), or another anchor.

The rule reads `PHI tier 2: <anchor> near <signal>`. ICD code lists, NPIs,
plain dates and names on their own pass.

## No inline disable comments

There is no `# phi-check: ignore`, by design: a comment anyone can write is a
hole anyone can use. The only way past a finding is the exceptions file, which
is reviewed like any other file.

## The exceptions file

For synthetic fixtures: one line per file, `<path> <YYYY-MM-DD> <why>`
(blank lines and lines starting with `#` are ignored; paths do not contain
spaces). Paths are resolved against the current folder (or `--cwd`). Only the
exact file listed is skipped, and each skip is noted in the output with the
file's name. A malformed line is reported (`<exceptions file>:<line>: malformed
exception line ...`) and the result is non-zero. `--no-exceptions` ignores the
file, which is what an export check wants. A missing default file is fine; a
missing file named with `--exceptions` is a usage error (exit 2).

## The module

All patterns are in `/usr/local/share/phi-check/phi_patterns.py`, so a
commit, export or ledger or board write guard can import the same rules:

```python
import sys
sys.path.insert(0, "/usr/local/share/phi-check")
import phi_patterns

phi_patterns.scan(text)   # [(line, rule), ...]  1-based lines, sorted
phi_patterns.find(text)   # [rule, ...]          the distinct rules
```

Neither returns the matched text.

## Wiring it in

The repository decides; the Feature installs no hook. CI is what enforces
the rule, because a local hook can be skipped. A hook manager passes whole
staged files, which is stricter than checking added lines: a file that
already holds a hit is refused even when the change did not touch it.

CI step (GitHub Actions, inside the repository's devcontainer or any image
with the Feature):

```yaml
- run: git ls-files -z | xargs -0 -r phi-check --format github
```

The `pre-commit` framework, a `repo: local` entry:

```yaml
repos:
  - repo: local
    hooks:
      - id: phi-check
        name: phi-check
        entry: phi-check
        language: system
        types: [text]
```

A plain `.githooks/pre-commit`:

```sh
git diff --cached --name-only --diff-filter=ACM -z | xargs -0 -r phi-check
```

There is no history scanning: that is a separate job, as `gitleaks` is for
secrets.

## What it cannot do

It is a set of patterns, and a pass is not a guarantee.

- Free speech has no pattern: a clinical note in prose passes.
- Names are not recognised in general. There is no "two capitalised words"
  rule, because it fires on product names; a name counts only after a label.
- A payer-specific id is unknown unless it is labelled (member id, claim #).
- Not caught: undashed Social Security numbers without a label, ones with
  spaces, lower-case MBIs, X12 or HL7 with other separators, FHIR in XML,
  dates written in words other than "Month d, yyyy" and "d Month yyyy".
- Binary files (PDF, images, Office documents, audio) are refused, not
  scanned: a pass for them would mean nothing, so they are findings.
- Fixtures: a real-looking test record is still a finding; list the file in
  the exceptions file or make the data obviously synthetic.

## Options

- `exceptions` (default `.phi-exceptions.txt`): the exceptions file read when
  `--exceptions` is not given. Override per container with
  `PHI_CHECK_EXCEPTIONS` in `containerEnv`, no rebuild.
- `installTaskfile` (default `true`): installs the Taskfile below.

## State

None: the tool keeps no login or config, so there is no volume and no
environment variable to persist.

## In devcontainer.json

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/phi-check:1": {
    "exceptions": ".phi-exceptions.txt"
  }
}
```

Python comes with it (`dependsOn`); the repo need not list it. A repo that
lists the python Feature with other options gets two installs of it, as the
`az` notes explain for azure-cli.

## Checking that it works

```sh
phi-check --version                  # phi-check 1.0.0
printf 'nothing here\n' | phi-check -   # phi-check: clean, 1 file(s)
```

## Tasks

- `phi-check:version`: which `phi-check` runs and its version.
- `phi-check:check FILE=<file or folder>`: run it; extra options after `--`.

## Why it exists

Secret scanners (gitleaks, trufflehog) find credentials, not health data,
and the DLP products that find PHI are services, not a command that runs in
a devcontainer with no network. This is the small, offline, readable
counterpart: patterns anyone can review, in one module.

## Version and upgrade

The Feature version is the tool's version (`phi-check --version`). Pin it with
the Feature reference (`phi-check:1` or `:1.0.0`); an upgrade is a rebuild.
A new pattern is a minor version, since it can refuse files that passed.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/phi-check/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
