# ADR-0035: A Feature that ships a check or transform tool gives it the linter CLI contract

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-29 |
| **Deciders** | the Operator; proposed by the host |

## Context

The `phi-check` Feature (backlog branch `feature/phi-check-feature/1`) ships a tool that checks
files for protected health information. The first sketch tied it to git: a `--staged` option and
a Feature-installed pre-commit hook. Linters and formatters (yamllint, sqlfluff, shellcheck,
ruff, eslint) share an informal contract that involves no git at all: they take paths or
standard input, print one finding per line, exit with a code that separates findings from a
broken run, read a config file, and leave hook wiring to the repository's hook manager
(`pre-commit`, lefthook, lint-staged) and CI. The repository runs as an ecosystem where
anything a consuming repo has to script around is a gap to close here, and other tool-shaped
Features will follow `phi-check`, so the shape needs one answer.

## Decision

A Feature that ships a check or transform tool gives it the linter CLI contract:

- **Input:** paths (files or folders) and `-` for standard input; `--stdin-filename` names the
  standard input in the output.
- **Output:** one `path:line: rule` per finding, and `--format` offers a machine format such as
  `json` (and `github`) for agents and CI.
- **Exit codes:** 0 clean, 1 findings, 2 usage or internal error. It still fails closed, and a
  caller can tell a finding from a broken run.
- **Exceptions:** kept in a config or exceptions file found from the current folder, with
  `--exceptions` and `--no-exceptions` to point at one or turn it off. Inline disable comments
  are offered only where silencing one finding cannot hide a safety-relevant one; `phi-check`
  has none, and its NOTES says so.
- **No git:** the tool knows nothing of git, staged changes or hooks. The Feature installs no
  hook and has no `installHooks` option. Each repository wires the tool into its own hook
  manager and CI, and the Feature's NOTES gives the snippets.

The rule is also recorded as a Feature principle in `docs/principles/non-functional-requirements.md` (NFR-11), so
reviews check it.

## Options considered

### Option 1: the linter CLI contract (chosen)

It is the contract engineers and agents already know, it composes with whatever hook manager a
repository uses, and the tool is testable with files and standard input alone. The repository
keeps ownership of its hooks.

### Option 2: a Feature-installed hook with chaining

The Feature would install a pre-commit hook and chain to any existing one. Rejected: chaining
is fragile, it overrides the repository's own hooks, and it ties the tool to git, which a
consumer who runs it in CI or on a folder does not want.

### Option 3: a `--staged` mode inside the tool

The tool would read the staged set itself. Rejected: hook managers already pass staged files
as paths, so the mode duplicates their job and couples the tool to git.

## Consequences

- Easier: any hook manager or CI step can call the tool; agents read the JSON format; a new
  tool-shaped Feature has a checklist to follow.
- Harder: each consuming repo writes its own hook wiring, from the snippets in the NOTES.
- No inline disables for `phi-check` means an exception costs a dated, reasoned line in the
  exceptions file, which is deliberate.
- To do: the `phi-check` build follows this contract (`--label` becomes `--stdin-filename`, an
  error exits 2); the feature principle is added to `docs/principles/non-functional-requirements.md` (NFR-11).

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First draft. |
