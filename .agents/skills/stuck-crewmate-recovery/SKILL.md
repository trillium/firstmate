---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
  Defaults to executing a non-destructive recovery autonomously on a repeat wedge escalation, reserving captain consultation for destructive or irreversible actions.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

## Repeat wedge escalations: recover, do not consult

A stale wake whose reason carries the `demand-deep-inspection` marker means the same pane has wedge-escalated `FM_WEDGE_DEMAND_INSPECT_COUNT` times in a row, three by default; [`docs/architecture.md`](../../../docs/architecture.md) owns that mechanism, and the watcher itself never interrupts, signals, or restarts anything.
The marker demands a closer look, and the decision that follows the look is yours rather than the captain's.

Inspect before acting, because the marker exists precisely to stop a reflexive re-absorb.
Read the targeted current state with `bin/fm-crew-state.sh <id>` and the validation log behind it, and establish that the worker's run step is genuinely not advancing rather than merely quiet.

Once the inspection shows no advance, run the recovery yourself and immediately, with no captain consultation, whenever the action is non-destructive.
The `interrupt`, `exit`, and `relaunch` verbs are non-destructive by construction, because each preserves the endpoint, the worktree, and every uncommitted change ([`docs/agent-control.md`](../../../docs/agent-control.md)), so restarting a hung validation, a hung build, or a hung poll risks nothing a captain decision could protect.
Enter the ladder above at the step the inspection justifies rather than relaunching a worker that only needs one corrective line.
Waiting for the captain here costs the fleet the whole idle window and buys no safety.

The captain-consultation path is unchanged and still fires for:

- A recovery action that is itself destructive or irreversible, including discarding uncommitted or unlanded work, forcing a teardown, or resetting a branch that holds the task's only copy of its work.
- Anything security-sensitive or outward-facing, under `AGENTS.md` section 9.
- A real failure after this ladder is exhausted, which is step 5 above.

## Record an autonomous recovery

An autonomous recovery has to be visible after the fact, because nobody watched it happen.
Write the decision and its cost into the task's durable backlog note, which is the linked bead's comment under the beads backend:

```
YOLO_DECISION: relaunched <task> after <n> consecutive wedge escalations, idle <seconds>s with no run-step advance
YOLO_TRADEOFF: the worker loses its in-pane reasoning context and any still-live turn is cancelled; the worktree, its commits, and the validation run are preserved
```

Carry it to the captain in the next batched update rather than as its own message, because a recovery that worked is not an escalation.
