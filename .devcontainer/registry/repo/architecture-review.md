## In this repository

- **The requirements** are `docs/principles/non-functional-requirements.md`.
- **The repository's own checks**, after the decisions:
  - **Agent CLIs**, for anything that touches them: the capability matrix
    (`docs/proposals/agents-v2.md`, section 14) and NFR-12 (two vendors or a named fallback).
  - **The line** (NFR-13, `manages-the-environment-not-the-cli`): does the design manage the
    agent's environment (which agent, its state, skills, records, how it starts and is found
    again), or re-implement something a CLI already does? A capability one CLI has is that
    adapter's or Feature's option, not a new concept in the agents spec, unless NFR-12's
    two-vendor test is met.
- **Placement**: the layers are a Feature option, a CLI adapter, the agents list spec, the
  launcher and a consumer's own config.

The capability matrix and the line between the environment and the CLI are standing rules here
beside the NFRs and the ADRs: a design that re-implements what an agent CLI already does is the
drift they catch.
