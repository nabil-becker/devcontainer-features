---
name: registry-explain
description: "Show where a resolved registry skill comes from: every line with the layer and version it came from, what was skipped and why, and refs that point at nothing (dcf-registry explain). Use when the person asks why a skill says something, which layer set a value, or what refers to a path."
argument-hint: "<skills/name>[:key] [--uses]"
---

# Explain a registry path

The person gave: `$ARGUMENTS`

Run `dcf-registry explain` with the Bash tool, from the repository root, with that path as one
quoted argument, and `--uses` after it when the person gave `--uses` (what refers to the path):

```sh
dcf-registry explain 'skills/<name>[:key]' [--uses]
```

With no path given, ask which skill (`skills/<name>`). Show the output as it is, then say in one
or two lines which layer decides the value they asked about. Explain is read-only; it never
resolves. If it says there is no resolved view, offer `/registry-refresh`.
