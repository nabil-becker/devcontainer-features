---
name: registry-refresh
description: "Rebuild the skills the component registry resolves, now: fetch every registry layer, resolve them for who you are and hand the resolved skills to the CLI (dcf-registry refresh). Use when the person asks to refresh, reload or update their registry skills, or right after they changed a registry layer."
---

# Refresh the registry's skills

Run this with the Bash tool, from the repository root, and show the person its output as it is:

```sh
dcf-registry refresh --session "${CLAUDE_SESSION_ID}"
```

The session id says which agent is asking, so its own registry path is refreshed (an agent can
have its own); a CLI that leaves `${CLAUDE_SESSION_ID}` as it is, or a session no agent started,
refreshes every agent the registry has handed skills to.

Then tell them, in at most three short lines:

- In Claude Code the changed skill files are picked up in this running session (the output says
  so); a skill already used in this conversation keeps its old text until it is used in a new
  conversation.
- Another CLI gets the files but reads them only when its session is restarted.
- If the output says the skills folder is new, a session started before now needs `/reload-skills`.

If it failed, say what the output says and that the skills stay as they were. Never edit the
copied skills in the CLI's skills folder: the next refresh replaces them; changes go into a layer.
