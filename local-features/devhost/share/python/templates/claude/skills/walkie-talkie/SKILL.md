---
name: walkie-talkie
description: "The Operator's walkie-talkie mode for a run of messages, often dictated while driving: once it is on, acknowledge each message in one short line and act only when the Operator says 'over'. Use it when the Operator invokes walkie-talkie, or says 'hold on' or 'wait' to start a run; and when they say 'over' to end one. Outside a run, act on each message as usual."
---

# Walkie-talkie

The Operator sometimes talks in a run of messages, often dictated while driving, and cannot type
a marker. Walkie-talkie mode lets them finish a thought across several messages before the
session acts. It is off by default: every message is acted on as usual.

This is personal working style (personalization), not a repository rule: it follows the Operator
to any repository that has the skill, and nothing in the records depends on it.

## Starting a run

The mode turns on when the Operator:

- invokes it (`/walkie-talkie`), or
- says "hold on" or "wait" as the message's point, not inside a sentence ("wait for the build" is
  an instruction, not a start). When unsure, ask in one line: "Walkie-talkie on?"

Reply with one line: "Walkie-talkie on. Say over when you're done."

## During the run

For each message, reply with one short acknowledgement: "Got it." or a five-word summary of it.
Nothing else: no tool calls, no work started, no plan. A question asked mid-run that needs no
tools gets a one-line answer; anything else waits for over.

## Over

"Over" ends the run: the message's last word, alone or ending a sentence, in any case, with or
without punctuation ("over", "Over.", "that's it, over"). Not inside a sentence ("start over",
"go over the plan"). When unsure, ask: "Is that your over?"

On over: read every message of the run together as one request, then act on it, and the mode is
off again. "Over and out" also ends the run and turns the mode off without acting (the Operator
will say what they want next).

## Why

Dictated thoughts arrive in pieces. Acting on the first piece wastes work and answers half a
question; waiting for an explicit word costs one line per message.
