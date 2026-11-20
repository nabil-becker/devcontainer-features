# The facilitator's first run: the jester scenario, by hand (2026-11-20)

The manual acceptance run of slice 3 of `docs/proposals/facilitator-agent.md` (backlog id
`facilitator-first-version`). Who it serves: the Operator, through the host, and the engineer who will
download `facilitator` and type "@jester tell @domain-expert-one a joke". Run in this devhost (x86_64,
Python 3.13, Claude Code 2.1.311) with the facilitator 0.1.0 installed into a throwaway root from the
branch, on the real AGNTCY Directory (dirctl 1.9.1) and SLIM node (slimctl 3.4.6), all on loopback.

## What ran

| Participant | How | Harness |
| --- | --- | --- |
| `you` | `facilitator send --text "@jester tell @domain-expert-one a joke"` | the terminal |
| `domain-expert-one` | **real Claude Code**, `claude -p --model haiku --max-budget-usd 1 --max-turns 12 --strict-mcp-config --mcp-config <facilitator mcp --as domain-expert-one>`, the persona sentence from `facilitator snippet` as `--append-system-prompt`, `FACILITATOR_TOKEN` from `tokens/domain-expert-one` in its environment | a background shell |
| `jester` | `facilitator model --as jester --endpoint http://127.0.0.1:28181/v1 --model fake-tiny --definition personas/jester.md` against **a tiny fake OpenAI-compatible endpoint** (a Python script that answers a joke, then a thanks). There is no model runtime in this devhost and none was installed; the Operator runs the real local model later | a background shell |

Keys: **in OpenBao** (`facilitator/keys/you`, `.../jester`, `.../domain-expert-one`, `.../facilitator`),
loaded into the facilitator's ssh-agent for the sitting; no private key file was written. SLIM's secrets
in OpenBao `facilitator/slim`.

## What happened

`facilitator infra up` started the ssh-agent, the Directory and the SLIM node in about 1.5 s;
`facilitator register --all` pushed two OASF records. Both participants were attached (in `receive`)
within 12 s. The send, then:

```text
12:29:02 @you: @jester tell @domain-expert-one a joke
           -> @jester  [mention]
12:29:03 @jester [1 hop]: @domain-expert-one Why did the signed packet refuse to change? It had too much integrity.
           -> @domain-expert-one  [mention]
12:29:04 @domain-expert-one [2 hops]: @jester Because any change to a signed packet breaks its signature, so the verifier rejects it as tampered.
           -> @jester  [mention]
12:29:04 @jester [3 hops]: @you Delivered; the expert was amused.
           -> @you  [mention]
```

Every delivery's A2A task ended `completed`. Claude Code called `receive`, `reply`, then `receive` once
more (nothing yet), and stopped: 5 turns, 46 s, **$0.0038**. It addressed the jester explicitly
(`@jester`), so its reply went by rule 1, not rule 3; with no mention it would have gone to the jester as
the asker (the unit and integration tests show that path).

## The verified chain

`facilitator verify --conv c-ce4df564`, exit 0, 16 entries (roster, thread, 4 messages, 4 routes, 6
task states), every signature checked afresh:

```text
c-ce4df564/m-72bffa3fa400  hops 3  from jester  signed by ssh-ed25519 AAAAC3NzaC1lZDI1...  entry e0a7611bc715
c-ce4df564/m-26c9c6e22fd6  hops 2  from domain-expert-one  signed by ssh-ed25519 AAAAC3NzaC1lZDI1...  entry 348bce906cbf
c-ce4df564/m-c54ffd223eb3  hops 1  from jester  signed by ssh-ed25519 AAAAC3NzaC1lZDI1...  entry 82a882d17e4d
c-ce4df564/m-c18017725f3b  hops 0  from you  signed by ssh-ed25519 AAAAC3NzaC1lZDI1...  entry aef46cee9a39
facilitator: c-ce4df564: 16 entries, 4 message chain(s) walked: every chain verifies back to a human
```

## What it taught

> **Note (2026-11-20, after the Operator's ruling):** the addressed-only reading of rule 1 described below was
> dropped. The Operator ruled "both": every `@handle` in a message is delivered, each once, as proposal
> section 4.4 rule 1 says, and the hop count bounds the chain. The record of the run is unchanged.

- **Rule 1 as written does not give the scenario.** "@handle in the text delivers to that participant,
  each mention once" would deliver the human's request to both the jester and the expert. The build reads
  rule 1 as the *addressed* mentions: the first `@handle` and those right after it; later mentions are
  recorded in the message and not delivered. This is the closest reading that gives section 2's picture;
  it is for the Operator to confirm.
- **SLIM's client logs to standard output**, which is the MCP channel. The MCP server keeps a private copy
  of standard output for the protocol and sets SLIM's tracing to errors only.
- **Claude Code passes its environment to a stdio MCP server**, so `FACILITATOR_TOKEN` set by the harness
  reaches `facilitator mcp` with no `-e` in the MCP entry.
- The run cost less than half a cent; the infrastructure took about 175 MB, as the spike measured.
- Everything started was stopped by pid at the end (`facilitator infra down`, the wrapper, the fake endpoint).
