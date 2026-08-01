---
name: night-ops-directive
description: >-
  Agent-only policy for a captain-authorized autonomous work session across a federated task
  store or backlog with no captain present to answer routine questions.
  Load when the captain authorizes autonomous, unattended, or overnight work across a backlog
  or federated task store, or when reconciling that a standing autonomous-dispatch directive is
  still active.
user-invocable: false
metadata:
  internal: true
---

# Autonomous overnight dispatch

This skill is the standing policy for a captain-authorized stretch of unattended work.
Work through a federated task store or backlog without pausing for questions that `AGENTS.md` section 7's `yolo` authority already answers, and without collapsing into hands-on implementation.

## Standing directive

- Firstmate stays a delegator for the whole session, including overnight: read state, decide routing, write briefs, spawn crewmates, supervise, and report.
  Do not personally hand-edit project files, grind through binary or database debugging, or `git diff` a project clone to do a crewmate's job.
  If a bounded, low-risk edit to firstmate's own shared tracked material is genuinely faster to author directly than to brief, treat that as the exception, not the norm.
- Prefer stacked PRs for multi-step work over delaying a wave of dispatch.
  Do not hold otherwise ready work waiting for an unrelated PR to land unless section 7's serialization test is met.
- Firstmate owns its own wake cadence for this directive.
  `ScheduleWakeup` and `CronCreate` are blocked for the primary session by `bin/fm-subagent-pretool-check.sh`; do not attempt either.
  The watcher heartbeat (`bin/fm-watch.sh`, `FM_HEARTBEAT` default 600s, doubling per idle heartbeat up to `FM_HEARTBEAT_MAX` default 7200s, resetting on any actionable wake) is the durable wake mechanism and needs no separate timer.
- Infra and migration work discovered in the task store is in scope for this directive; do not gate it away as out-of-scope by default.
- Fork-first pushes for non-captain-writable default branches are already enforced automatically by the ship brief scaffold (`AGENTS.md` section 11); no separate action is needed here beyond trusting that mechanism.
- Pace dispatch waves against CI and review-bot rate limits (see `coderabbit-pr-gate` for the CodeRabbit-specific reaction routine) rather than firing every ready item at once.

## Yolo scope for this directive

`AGENTS.md` section 7's `yolo` reversibility test applies: the qualifying test for a routine `yolo`-covered gate, including a PR merge, is reversibility, meaning whether it can be undone if it turns out wrong.
This directive does not expand `yolo` past section 7's boundaries: destructive, irreversible, and security-sensitive choices remain captain-only regardless of how autonomous the session is.

## Human-only task triage and the promotion path

A federated task-store item that names a physical, financial, credential, interpersonal, or otherwise non-code action is not crewmate work.
Route it to a dedicated human-tasks-only federated store rather than leaving it mixed into the code-mappable backlog or attempting to work it.
Move a qualifying item with `bd transfer <id> <human-tasks-store>`, not `bd promote`, which only promotes a wisp to a permanent bead within the same store.
`bd transfer` closes the source row with a pointer to the destination, creates the new row in the destination store, and links the two with a `supersedes` edge so the move stays queryable from either side.

If the destination human-tasks store is not yet functional, do not hand-debug its provisioning personally beyond one bounded verification attempt.
File the blocker as a backlog item and keep triaging code-mappable work through the normal task lifecycle instead.

## Session-boundary notes

This directive persists across restarts because it lives in tracked `AGENTS.md` and this skill, not in conversation memory.
A restart mid-directive is a non-event: reconcile fleet state per section 5 and resume dispatch, it does not require the captain to re-issue the directive.
