# ADR-0042: devhost-verify stays the one commit check and gains the AOF checks

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-01 |
| **Deciders** | the Operator; proposed by the host session (story S1 of the AOF apply plan) |

## Context

The Operator is planting the AOF seed (Agentic Operating Framework 0.5.0) into this repository.
The seed's template brings its own commit check (`.githooks/pre-commit`) and its own redact list
(`.redact-list`). This repository already has a commit check, `devhost-verify`
(`local-features/devhost/share/python/verify.py` and `guards.py`), run by the pre-commit hook,
and one redact list, `.devhost/redact-names.txt`. Two commit checks and two lists would drift
apart, and an engineer would not know which one refused a commit.

A comparison of the two found most of AOF's checks already covered (redact words, credential
shapes). Three were missing: an email address that does not end in `.invalid` in a staged added
line, a checked copy (`docs/aof/<name>.md` against `docs/aof/<name>.md.sha256`) that differs,
and a commit identity (author or committer) whose address does not end in `.invalid`.

## Decision

`devhost-verify` stays the one commit check. It gains the AOF checks it lacked, as guards in its
existing style (`file:line: message`, never quoting the matched address or word):
`staged_emails`, `checked_copies` and `commit_identity`. `.devhost/redact-names.txt` stays the
only redact list; no `.redact-list` or `.redact-exceptions` file is added, and the seed's
`.githooks/pre-commit` is not adopted. The path exceptions in `name-exceptions.txt` also exempt a
path from the email check.

## Options considered

### Option 1: keep devhost-verify and add the AOF checks to it

One check, one list, one place an engineer looks. The cost is a small amount of code and tests in
the devhost Feature. This wins.

### Option 2: adopt AOF's pre-commit hook beside devhost-verify

Two hooks and two redact lists to keep in step; the weaker check (whole words only) would run
beside the stricter one. It lost for the drift and for the confusion over which refused a commit.

### Option 3: replace devhost-verify with AOF's hook

AOF's hook does not check the ledger, the ADR shape, the lexicon, the task descriptions or the
skill names, which `devhost-verify` does. It lost because the repository would lose those checks.

## Consequences

- One list and one commit check stay in force, so the guards can be read in one file.
- The email guard checks staged added lines only, because addresses already tracked do not end
  in `.invalid`; it allows the literal forbidden address the rules quote.
- The checked-copies guard passes while `docs/aof/` holds no copies; the AOF apply plan's later
  story adds them.
- The commit-identity guard also runs on a plain `task devhost:verify` when something is staged.
- The devhost local Feature's version takes a minor bump.

## Change log

| Date | Change |
|---|---|
| 2026-11-01 | First draft, accepted by the Operator's ruling of the same day. |
