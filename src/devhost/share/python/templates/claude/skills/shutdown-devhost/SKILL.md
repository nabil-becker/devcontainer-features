---
name: shutdown-devhost
description: "Prepare the devhost to be stopped, rebuilt or left for the night without losing work: close the current work, run the shutdown check, wait for the backs, ask about a running night shift, name the stop command, and report what was saved, what is open and how to resume. Use it when the Operator says shut down, stop the container, rebuild, restart the devhost, power off, or 'I'm done for the day' without a night shift. Its counterpart is restart-devhost."
---

# Shut down the devhost

The dev container specification has no stop hook, so nothing guards a stop on its own. This is
the agent's side of it; the rules that can be written down are the script
`devhost-shutdown-check` (`task devhost:shutdown-check`), and the host's `task devcontainer:stop`
runs the same check before it stops the container (ADR 0015).

## Steps

1. **Close the current work** with `/close-session`: the records checked, `devhost-verify`
   green, the work committed on a topic branch, and pushed when the Operator has asked for it.
   Never commit or push on your own; ask.
2. **Run the check:** `devhost-shutdown-check`. One line per finding: changes not committed,
   untracked files, commits not pushed (or no upstream), a back running, a stretch waiting to be
   logged, a tester run, a night shift mid-plan. Stashes are listed as notes. Fix what is yours to
   fix (commit, push on request) and put the rest to the Operator.
3. **Wait for the backs.** They run after every turn, so the turn that ends this session always
   leaves one more run behind (the scribe's entry for this very turn). Wait until the locks are
   free and nothing is pending: run the check again after a minute, and again until it passes, or
   until it has stayed the same for five minutes, then say what is held and ask. Read what the
   backs wrote (`git status`) and commit it only when asked. (A `shutdown.started` marker that
   pauses their hooks is open as `safe-shutdown-backs-pause`; until it exists the wait is all
   there is.)
4. **A night shift.** If the check reports one mid-plan, or the Operator mentioned one, do not
   stop it: ask whether it should end (the `night-shift` skill's rules: finish the report, commit
   it) or the container should stay up.
5. **Name the stop command**, and do not run it yourself: from the workstation, `task
   devcontainer:stop` (it runs the check first and refuses to stop when it fails; `FORCE=1`
   overrides it). A stop by the container engine directly is not guarded.
6. **Report**, short, in the Operator's terms: what was saved (commits, branch, pushed or not,
   ledger entries), what is still open (findings, stash, untracked files, the night shift, the
   backlog items in progress) and how to resume (`restart-devhost`, or `task devcontainer:up`
   then `task devcontainer:claude`, and the branch to continue on).

## Why

A stop cuts off whatever is half done: a back writing a ledger entry, a test run, commits that
exist only in the container. The script is the same every time and cannot skip a rule; the agent
adds what needs judgment and tells the Operator what is safe.
