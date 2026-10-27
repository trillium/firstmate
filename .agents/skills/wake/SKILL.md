---
name: wake
description: Dumb timer — wake (time) (prompt). Use when the captain or a worker wants a fire-once reminder, e.g. `/wake +30m recheck the red CI leg` or `/wake tomorrow 09:00 morning fleet review`.
user-invocable: true
metadata:
  internal: true
---

# wake

A dumb timer. One wake = one launchd one-shot job, nothing else. No store,
no sweeper, no coalescing engine, no lifecycle, no fanciness.

## Usage

```
wake +30m recheck the red CI leg on PR #164
wake +2h ping the migration worker if still red
wake tomorrow 09:00 morning fleet review
```

Time accepts relative (`+30m`, `+6h`), absolute (RFC3339), and named
(`tomorrow`, `next monday`, bare dates) forms, resolved to one fire time.

## Mechanics

1. Compute the fire time. Write one plist under `~/Library/LaunchAgents`
   (`com.firstmate.wake.<slug>.plist`) with a `StartCalendarInterval` for
   that time. The job appends the prompt verbatim to the supervisor wake
   queue, then unloads and deletes its own plist.
2. That is the entire system. Delivery reuses the ordinary wake path
   (wake queue → watcher → supervisor turn) because the job writes a normal
   wake record — no new protocol, no claim/process loop.
3. If the machine is asleep or off at fire time, launchd runs the job on
   wake; late delivery is accepted without apology or retry logic.
4. To cancel a pending wake, unload and delete its plist. To list pending
   wakes, list the `com.firstmate.wake.*` plists.

## Non-rules

- No recurring wakes. No coalescing. No dead-session handling beyond what
  the ordinary wake lifecycle already does. Anything smarter belongs in
  launchd intervals, beads timer gates, or the watcher — not here.
