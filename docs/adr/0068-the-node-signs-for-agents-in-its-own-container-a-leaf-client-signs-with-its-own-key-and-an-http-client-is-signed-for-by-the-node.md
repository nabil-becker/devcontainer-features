# ADR-0068: The node signs for agents in its own container, a leaf client signs with its own key, and an HTTP client is signed for by the node

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0067 decision 2 says local CLIs use the thin client plus SLIM "so the key stays with the agent".
The architecture review of the `facilitator-node` proposal found that this contradicts what
facilitator 0.2.0 does: a participant in the node's own container never sees a private key; the
node's signer signs for it after a token check (ADR-0061, ADR-0066). The proposal's section 11.2 sets
out three arrangements, and the Operator ruled on 2026-11-20 (ruling AA, with D3 settled by it).
The forces:

- a participant process that holds no key cannot leak one, and the 0.2.0 design relies on that;
- a leaf client on another machine cannot use the node's signer without sending the node its key or
  asking the node to sign for it, which weakens the proof;
- a cloud AI or any HTTP client holds no key at all, so the node must sign for it, and the record has
  to say so;
- the lexicon's "Facilitator node" entry says what signs for whom.

## Decision

1. **A participant in the node's own container is signed for by the node.** Its stdio MCP server
   talks to the node's application on loopback with the participant token; the node's signer signs,
   with the key kept in OpenBao (or the state volume when there is no vault). Behaviour of 0.2.0,
   recorded as `via: local-token`.
2. **A leaf client signs with its own key.** `facilitator mcp --node <address>` on a machine that runs
   no node connects to the node's SLIM and Directory, authenticated by an SVID it enrolled for with a
   join token; the node verifies the signature and never holds the key. Recorded as `via: self`.
3. **An HTTP client is signed for by the node**, on its behalf, after the OAuth or bearer-token check;
   the packet carries `data.via` naming the transport, the authentication and the client. Recorded as
   `via: http-oauth`. The proof is "this node vouches that this authenticated client wrote it".
4. This amends ADR-0067 decision 2: "the key stays with the agent" holds for the leaf client only.
   The rest of ADR-0067 stands.

## Options considered

### Option 1: three arrangements, each stating who signs (chosen)

Keeps the 0.2.0 behaviour that no participant process touches a key, gives the stronger proof where a
machine can hold its own key, and makes the weaker proof explicit in the record for HTTP clients.

### Option 2: every participant signs with its own key, as ADR-0067 decision 2 reads

Would change 0.2.0: every CLI session would need a key and a signing path, including the ones in the
node's own container, for no gain over the token check there.

### Option 3: the node signs for everyone, leaf clients included

Simplest, but a leaf client's key then lives on the node, and the record cannot tell a client that
vouches for itself from one vouched for by the node.

## Consequences

- The record distinguishes three strengths of proof; `transcript` shows `via` and `verify` checks it.
- ADR-0067's decision 2 text is not edited; this record is the amendment, and the lexicon's
  "Facilitator node" entry already says the node signs for the agents in its own container.
- Whether sign-packet accepts the agent's key as it stands (it is read through an ssh-agent today) is
  a slice N3 question; the fallback is a roster entry that binds the sign-packet key to the SPIFFE ID,
  countersigned by the issuer.
- The leaf client needs an install path: the Feature option `mode: node | leaf`.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's ruling AA of the same day. |
