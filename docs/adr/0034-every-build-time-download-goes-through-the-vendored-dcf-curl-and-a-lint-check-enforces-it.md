# ADR-0034: Every build-time download goes through the vendored `dcf_curl`, and a lint check enforces it

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-28 |
| **Deciders** | the Operator; proposed by the host |

## Context

Consumers' builds failed on network errors during Feature installs. An earlier sweep added
`curl --retry 3` to the downloads it found, but the failures came back: plain `curl --retry`
does not retry every kind of error. A TLS error (curl exit 35) and a download cut off
mid-transfer (exit 56) are not retried, so one dropped connection still fails the install.
The sweep also missed downloads: the go-task, kustomize and velero Features, and the
launcher's Node.js download, had none, and a bare download or a `wget ... | sh` line could be
put back at any time with nothing to notice.

A Feature installs on its own, from its own folder, so it cannot source a file from a
sibling Feature or from the repository root. The repository already has this shape for
`dcf-persist`, a shared helper that is copied into each Feature that needs it and checked
for drift by the vendored-helper check in `task lint`.

## Decision

Every download a Feature makes at build time goes through one shared helper, `dcf_curl`,
which retries every kind of download error, including exit 35 and exit 56. The helper is
vendored: a copy lives in each Feature that downloads, as `dcf-persist` does, and the
vendored-helper check keeps the copies identical.

A lint check, `common:curl-check`, fails on any `curl` or `wget` download in a Feature's
install scripts that does not go through the helper. It is part of `task lint`, so a bare
download cannot reach a pull request unnoticed.

A test proves the helper against a local server that drops the first connection: plain
`curl --retry 3` gives up, `dcf_curl` gets the whole file. The check on plain `curl` in that
test passes on any failure where the file did not come back whole and prints the actual exit
code, because under load plain `curl` sometimes fails with exit 7 instead of 35.

Downloads made on the workstation, before any devcontainer exists, are outside this
decision: the host-side bootstrap cannot use a helper that is vendored into a Feature.

## Options considered

### Option 1: a vendored `dcf_curl` helper plus a lint check

Retries the errors that plain `curl --retry` skips, in one place instead of twelve; a
Feature stays installable on its own; the lint check closes the gap the sweep left open.

### Option 2: `curl --retry 3` inline in every download

The earlier approach. It does not retry TLS errors or a transfer cut off midway, which the
test shows against a server that drops a connection, and it relies on each author
remembering the flags.

### Option 3: one helper sourced from a shared Feature (`common`)

Avoids the copies, but a Feature must install without its siblings being present, so the
helper would not be there when it is needed. The vendoring pattern already exists.

### Option 4: a lint check without a helper

Would force the flags to be present but not make them sufficient; the retry logic would
still be repeated in each script.

## Consequences

- A download that hits a dropped connection or a truncated transfer is retried instead of
  failing the consumer's build.
- A new download in a Feature has one way to be written; a bare `curl` or `wget` fails lint.
- Every Feature that downloads carries a copy of the helper, and a change to it means
  updating every copy and bumping every one of those Features. The first rollout touched 13
  Features and needs a release.
- The helper's test needs a local server and can be sensitive to load; it is kept tolerant
  of which error plain `curl` reports.
- The host-side bootstrap downloads (`bootstrap.sh` and the PowerShell downloads) are not
  covered and need their own retries; the secretary holds that as a backlog item.

## Change log

| Date | Change |
|---|---|
| 2026-10-28 | First draft. |
