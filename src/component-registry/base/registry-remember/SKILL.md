---
name: registry-remember
description: "Remember one line in the person's own registry layer (the layer marked writable) and refresh, so every skill, or one skill, carries it from now on (dcf-registry remember). Only when the person asks to remember something in the registry."
argument-hint: "[skills/<name>] <line>"
disable-model-invocation: true
---

# Remember a line in your own layer

The person gave: `$ARGUMENTS`

If it starts with `skills/<name>`, the line is for that skill only; otherwise it is for every
skill. Run with the Bash tool, from the repository root, the line as one single-quoted argument
after `--` (a `'` in it written as `'\''`), never unquoted:

```sh
dcf-registry remember -- '<line>'                    # every skill
dcf-registry remember --skill <name> -- '<line>'     # one skill
```

It appends the line to the layer the layer list marks `writable: true` and refreshes. Show its
output as it is. If it refuses (no writable layer, two of them, a layer that is not a folder),
say why in one line and what to change in the layer list; nothing was written. Never write the
line anywhere else, and never into the repository's `.claude/skills`.
