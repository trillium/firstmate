# Urgency protocol

This document owns the design decisions, lifecycle, measured latencies, and follow-ups for the urgent path.
[`bin/fm-urgent.sh`](../bin/fm-urgent.sh) owns the flags and exit codes, and [`.agents/skills/urgent/SKILL.md`](../.agents/skills/urgent/SKILL.md) owns when firstmate runs it.

## Why it exists

The normal brief, spawn, and report path is too slow for an ask the captain needs in minutes.
A real miss motivated it: an in-person event went ahead without six separate print-ready QR PDFs, each with a unique code.
The urgent path trades supervision for speed: one interactive agent pane, opened in the same turn, that the captain talks to directly.

## Decisions

### Urgency detection versus explicit invocation

Explicit invocation only.
Firstmate runs the launcher when the captain marks an ask urgent or deadline-bound, or asks for a hands-on session.
A wrong guess in either direction is costly: a false positive burns an interactive session and a captain's attention, and a false negative is today's behavior.
Automatic detection is a follow-up and needs an agreed threshold first.

### Runtime selection

Claude Code is the default, and Pi is available with `--harness pi`.
Claude Code gives the strongest native sub-agent support and per-session permission settings, so it carries the default.
Pi launches only when `pi list` shows an installed sub-agent package; otherwise the launch stops with that reason.
No other harness is offered, because the urgent path needs a reviewed launch recipe for each.

### Authority transfer

The grant travels in the first prompt, and the standing role rides the system prompt.
The grant is one line, defaults to local work plus research inside the working and output directories, and always excludes pushing, publishing, messaging, spending, and changes outside the output directory.
The pane asks the captain, in the pane, for anything outside the grant.
Claude Code additionally gets a per-session settings file that preapproves in-scope tools and native sub-agents and denies pushes, recursive deletes, privilege escalation, and merges.
The captain's own settings are never edited.
The pane is told never to write firstmate briefs or spawn firstmate workers.

### Interactive window mechanics

One new Herdr tab labelled `urgent:<slug>` opens in the launcher's own workspace of the default session, or one tmux window when Herdr is not the resolved backend.
The script types a single `bash launch.sh` line into the new pane and reads the pane to detect readiness.
Only pane-level operations are used: open one tab or window, type, read, and close the pane the script itself recorded.
No session, server, or workspace lifecycle command is ever issued, and no other pane is ever touched.
The default working directory is `~/.fm-urgent/<slug>`, outside every repository, so the pane never loads firstmate's supervisor instructions.
The first launch may show Claude Code's folder-trust dialog; the script reports that in its launch line and the captain answers it once in the pane, after which the folder is trusted for later sessions.

### Capability discovery

The launcher checks the harness before opening anything.
Claude Code must be installed.
Pi must be installed and `pi list` must show a sub-agent package.
Failure exits non-zero with one plain-English line, leaves no record, and never falls back to a brief.

### Timeout and resumption

Every session has an idle timeout, ten hours by default and set with `--idle-timeout`.
A small detached watcher polls the pane, treats any screen change or busy state as activity, and closes the pane only after the timeout has elapsed with no activity and the agent is not mid-turn.
The watcher keeps its last screen fingerprint on disk, so restarting it with `rearm` does not count as activity.
The record and transcript pointer stay readable after the pane closes; the harness's own session resume is the way back into the conversation.

### Output preservation

Nothing is deleted at close.
Before any close, the output directory is copied to `data/urgent/<slug>/out`, along with the prompt, the record, the last screen, and a pointer to the harness transcript.
The original output directory is never removed.
A pane the captain closes by hand is recorded as closed externally and preserved the same way.

### Failure handling

A failed launch relays one plain line to the captain and leaves the normal path available for the captain to choose.
`done` on a mid-turn agent is refused with exit code 3 unless forced, so completion never cuts off work.
A dead watcher is visible in `status` and restarted with `rearm`.

## Lifecycle commands

- `fm-urgent.sh <slug> ... -- <ask>` launches a session.
- `fm-urgent.sh done <slug>` is the captain's explicit completion.
- `fm-urgent.sh list` and `fm-urgent.sh status <slug>` show sessions, the idle deadline, and watcher health.
- `fm-urgent.sh rearm <slug>` restarts a dead watcher.

## Measured latencies

The first live test was the QR regression, run on 2026-10-25 with Claude Code 2.1.293 on the Herdr backend.
The ask was six separate print-ready PDF files, one unique QR code each, pointing at six distinct URLs.

| Measure | Result |
| --- | --- |
| Launcher start to new tab open | under 1 second |
| Launcher start to interactive prompt ready | 2 seconds |
| Launcher start to all six PDFs present | 76 seconds, sampled every 8 seconds |
| Decoded result | six one-page letter PDFs, six distinct payloads (`zbarimg` on 200 dpi renders) |
| `done` | closed the pane, copied the seven output files, kept the original directory |

The agent used native sub-agents during the run.
The 76 seconds include several approval prompts that the test answered by hand, so the number is an upper bound for a session whose grant covers its work.
Those prompts showed the preapproved list missed compound `cd` commands and virtualenv-local tools, and the list now covers both.

A Pi smoke launch with the same launcher reached its interactive prompt in 2 seconds and answered the first prompt.
Pi's sub-agent package was installed on this host, so the Pi sub-agent path was exercised only up to launch.

## For captain sign-off

- Explicit invocation instead of automatic detection.
- The default grant text and the denied command list.
- Ten hours as the default idle timeout.
- Trusting `~/.fm-urgent` once in the harness, as the default working area.

## Follow-ups

- Urgency auto-detection, after the captain and firstmate agree on a threshold and its false-positive cost.
- A live Pi run that actually delegates to a sub-agent, and a recorded result for a host where no Pi sub-agent package is installed.
- Pre-trusting the working area so the first launch needs no dialog, if the captain wants that.
- The real-Herdr and tmux pane adapters are exercised live only through the QR and Pi runs; the portable tests use the fake pane.

## Verification

`tests/fm-urgent.test.sh` covers argument parsing, record creation, the fallback exits, the idle-timeout computation, and the done and cleanup paths on the fake pane.
