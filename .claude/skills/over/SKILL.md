---
name: over
description: "The Operator's run-of-messages rule: when they send several messages in a row (often dictated), acknowledge each in one short line and do nothing until they say 'over'. Use it whenever the Operator sends a message that may be part of a run, whenever a message ends with the word 'over', when they say 'over off', and when they ask how the over rule works."
---

# Over

The Operator often sends several messages in a row, many of them dictated while driving. They
cannot type a marker, so the marker is a word: **over**. Until they say it, the session listens;
on over, it acts on everything said since the last over.

This is personal working style (personalization), not a repository rule: it follows the Operator
to any repository that has the skill, and nothing in the records depends on it.

## What counts as over

- The last word of a message, alone or ending a sentence, in any case, with or without
  punctuation: "over", "Over.", "that is all, over", "over over".
- Not the word inside a sentence: "start over", "go over the plan", "over the weekend". The
  word must be the message's last word and the message must read as a sign-off.
- When unsure, ask in one line: "Is that your over?" and do nothing else.

## While waiting

For each message that is not over, reply with one short acknowledgement: "Got it." or a
five-word summary of it. Nothing else: no tool calls, no work started, no questions about the
content, no plan.

An explicit question mid-run gets a one-line answer if it needs no tools; otherwise it waits for
over.

## On over

Read all the messages since the last over together as one request (later messages may correct
earlier ones: the last word wins), then act on it as on any request: the same rules, the same
backs, the same hand-off. The next message starts a new run.

## Switching it off

"Over off" ends the rule for the session: every message is acted on as it arrives. "Over on"
brings it back.
