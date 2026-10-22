# The shutdown check

A shutdown check is an optional script a repository defines so that
`task devcontainer:stop` (and `devcontainer:rebuild`, which stops first) does
not destroy work. A repository without one stops without a check.

## What a check is for

Refuse only what a stop can break: work in flight. A background job holding
its lock, a git operation in progress (a rebase, a merge, an `index.lock`),
uncommitted work that lives only in the container, a stash left behind.
Report everything else and let the stop go ahead: state on named volumes and
on the host disk (the checkout, bind mounts) survives a stop.

## Contract

- **Exit codes:** `0` safe to stop; non-zero refuses the stop, and the host
  exits with that code. Print what is wrong; the output is shown above the
  refusal. Exit `127` (command not found) from a configured check gets its own
  message: the check is not installed in the container.
- **Where it runs:** inside the running container, as the remote user, from
  the workspace folder (`devcontainer exec` starts there), as `bash -lc`.
  It runs before `devcontainer:stop`, before the stop inside
  `devcontainer:rebuild`, and on `devcontainer:prepshutdown`, which runs it
  without stopping anything. With no running container none of them runs it.
- **May wait:** a check MAY wait briefly for in-flight work to finish rather
  than refuse at once (for example up to 120 s for a background run that
  starts at the end of every agent turn), and refuse when the wait ends.

## Resolution

When `STOP_CHECK` is unset, the host runs one snippet in the container
(`_SHUTDOWN_CHECK_DEFAULT` in `devcontainer.yml`):

1. `task` is on PATH and `task --summary shutdown:check` succeeds (the
   repository's root Taskfile defines it): run `task shutdown:check`;
2. else `devhost-shutdown-check` is on PATH (the `devhost` Feature): run it;
3. else print `no shutdown check defined; stopping` and exit `0`.

`STOP_CHECK=<command>` (a Task var, or in `.devcontainer/.env`) replaces the
resolution with that command; it must not contain a single quote. `FORCE=1`
skips the check altogether (`task devcontainer:stop FORCE=1`).

## Starting point

The bootstrap writes `.devcontainer/shutdown-check.sh` (from
[`shutdown-check.sh`](shutdown-check.sh)) only where none exists. It refuses a
git operation in progress and a stash left behind, and reports uncommitted and
unpushed work. The bootstrap's `Taskfile.yml` defines `shutdown:check` as
`sh .devcontainer/shutdown-check.sh`; a repository whose Taskfile already
exists adds that task from the lines the bootstrap prints. Add repository
checks at the TODO in the script.
