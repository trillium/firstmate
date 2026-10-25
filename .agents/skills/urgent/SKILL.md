---
name: urgent
description: >-
  Load in the same turn the captain marks an ask urgent or deadline-bound (for example "urgent", "right now", "I need this before <time>", "it is starting soon"), or asks for a hands-on session instead of a delegated task.
  It launches one interactive Urgency Agent pane with `bin/fm-urgent.sh` instead of writing a brief and spawning a worker.
user-invocable: false
metadata:
  internal: true
---

# urgent

The normal brief, spawn, and report path is too slow when the captain needs an artifact in minutes.
The urgent path skips it: one interactive agent pane, opened in this turn, that the captain talks to directly.
[`docs/urgency-protocol.md`](../../../docs/urgency-protocol.md) owns the design, the lifecycle, and the measured latencies; `bin/fm-urgent.sh --help` owns the flags.

## When to use it

- Use it only on an explicit signal: the captain calls the ask urgent or deadline-bound, or asks for a hands-on session.
- Never infer urgency yourself and never start it on your own judgment; urgency auto-detection is a documented follow-up.
- Leave every other ask on the normal delegation path.

## What to do, in this turn

1. Pick a short slug (lowercase letters, digits, dashes) naming the ask.
2. Run `bin/fm-urgent.sh <slug> --harness claude --grant "<one-line authority>" -- "<the captain's ask in their own words>"`.
   Pass `--context <text-or-file>` for any background the pane needs, since it starts with no memory of this chat.
   Use `--harness pi` only if the captain names Pi.
3. Tell the captain the pane name `urgent:<slug>` and where its output dir is, in the same reply.
4. Stop.
   Do not write a brief, spawn a worker, open a backlog item, supervise the pane, or read its screen.

## Failure

- A non-zero exit prints one plain-English reason.
- Relay that reason to the captain as the outcome and ask whether to proceed on the normal path.
- Never fall back to a brief on your own.

## Closing

- Only the captain's explicit word, or the idle timeout, ends a session.
- On "done with <slug>" run `bin/fm-urgent.sh done <slug>`; exit 3 means the pane is mid-turn, so tell the captain and wait.
- Never close, read, or send text to any pane that `fm-urgent.sh` did not open.
